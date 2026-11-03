import Foundation
#if os(macOS)
import IOKit.pwr_mgt
#endif
import Libmpv
import Observation
import OSLog

enum BufferSetting {
    static let appStorageKey = "mpvBufferSeconds"
    static let `default` = 5
    static let range = 1...30

    static func read() -> Int {
        guard let stored = UserDefaults.standard.object(forKey: appStorageKey) as? Int else {
            return `default`
        }
        return min(max(stored, range.lowerBound), range.upperBound)
    }
}

struct MPVMediaInfo: Equatable, Sendable {
    var width: Int = 0
    var height: Int = 0
    var fps: Double = 0
    var videoCodec: String = ""
    var audioCodec: String = ""
    var audioChannels: Int = 0
    var audioSampleRate: Int = 0
    var hwdec: String = ""
    /// Estimated seconds behind the live edge, adjusted by preferred delay.
    /// `nil` when the stream does not expose a replay window.
    var liveLatencySeconds: Double?

    var resolutionLabel: String {
        width > 0 && height > 0 ? "\(width)×\(height)" : ""
    }

    var fpsLabel: String {
        fps > 0 ? "\(Int(fps.rounded(.up))) fps" : ""
    }
}

struct MPVPlaybackStats: Equatable, Sendable {
    var containerFps: Double = 0
    var estimatedFps: Double = 0
    var videoBitrateBps: Int64 = 0
    var audioBitrateBps: Int64 = 0
    var frameDrops: Int64 = 0
    var decoderFrameDrops: Int64 = 0
    var delayedFrames: Int64 = 0
    var mistimedFrames: Int64 = 0
    var configuredBufferSeconds: Int = BufferSetting.read()
    var cachePauseFloorSeconds: Double = 0
    var cachePauseResumeSeconds: Double = 0
    var renderProfile: String = "focused"
    var autoPausedForCacheFloor: Bool = false
}

@MainActor
@Observable
final class MPVPlayer {
    private enum Tuning {
        // Raised to reduce @Observable update frequency (and therefore SwiftUI
        // redraws + CPU) for non-critical stats in multi-view. Focused playback
        // still feels responsive; background/thumbnail slots benefit hugely.
        static let stateEpsilon = 0.05
        static let timePosEpsilon = 0.25
        static let cacheEpsilon = 0.5
        // ffmpeg I/O buffer for reading stream data. 512 KB cuts system-call
        // overhead by 16× vs the 32 KB default, which matters a lot for 4 K
        // HEVC segments that are 4–8 MB each.
        static let demuxerLavfBufferSize = 524_288
        static let liveLatencyEpsilon = 0.5

        /// User-facing forward buffer target. Startup and mpv's cache-pause
        /// wait should use this target, but steady-state playback should not
        /// pause just because live cache briefly dips below it.
        static func minimumCacheSeconds(for bufferSeconds: Int) -> Double {
            max(Double(bufferSeconds), 1)
        }

        /// Critical steady-state floor for Buffer's own pause guard. mpv's
        /// built-in cache-pause handles normal underruns; this app-level guard
        /// is only for near-empty cache where continuing would visibly freeze.
        static func cachePauseFloorSeconds(for bufferSeconds: Int) -> Double {
            let minimum = minimumCacheSeconds(for: bufferSeconds)
            return min(max(0.5, minimum * 0.2), 1.0)
        }

        /// Resume quickly from the app-level emergency pause. Waiting for the
        /// full user-facing target here turns brief dips into long stalls.
        static func cachePauseResumeSeconds(for bufferSeconds: Int) -> Double {
            max(cachePauseFloorSeconds(for: bufferSeconds) + 0.75, 1.5)
        }

        /// Add a small hysteresis band above the minimum so brief throughput
        /// dips do not cause pause/resume chatter.
        static func resumeCacheSeconds(for bufferSeconds: Int) -> Double {
            let minimum = minimumCacheSeconds(for: bufferSeconds)
            return minimum + max(1, minimum * 0.25)
        }

        /// mpv's cache size is a capacity, not the minimum we want to hold.
        /// Keep enough headroom above the user's live-delay target for jitter,
        /// but cap it so "close to live" users do not drift indefinitely.
        static func cacheCapacitySeconds(for bufferSeconds: Int) -> Double {
            let minimum = minimumCacheSeconds(for: bufferSeconds)
            let capacity = max(minimum * 3, resumeCacheSeconds(for: bufferSeconds) + 2)
            return min(capacity, 60)
        }

        /// mpv's demuxer readahead still matters for how much data can build
        /// up while playback is manually paused. Match it to the cache
        /// capacity, not the user-facing minimum.
        static func demuxerReadAheadSeconds(for bufferSeconds: Int) -> Double {
            cacheCapacitySeconds(for: bufferSeconds)
        }

        /// Startup readahead: smaller window for faster first-frame time.
        /// The full readahead is applied after the first frame renders, so
        /// stall protection ramps up quickly without delaying startup.
        static func startupReadAheadSeconds(for bufferSeconds: Int) -> Double {
            min(Double(bufferSeconds), 8)
        }

        /// Size the packet queue from the time budget. Fixed 16-64 MiB caps
        /// are too small for high-bitrate live sport, which means the player
        /// can hit the byte ceiling before it has actually built the seconds
        /// of cache the user asked for.
        static func demuxerMaxBytes(for bufferSeconds: Int, focused: Bool) -> String {
            let mibPerSecond = focused ? 6 : 4
            let floorMiB = focused ? 96 : 48
            let capMiB = focused ? 256 : 128
            let mib = min(max(bufferSeconds * mibPerSecond, floorMiB), capMiB)
            return "\(mib)MiB"
        }

        static func demuxerMaxBackBytes(for bufferSeconds: Int, focused: Bool) -> String {
            let mib = focused
                ? min(max(bufferSeconds, 8), 32)
                : min(max(bufferSeconds / 2, 4), 16)
            return "\(mib)MiB"
        }

        /// Keep hysteresis disabled so mpv continuously refills the forward
        /// cache instead of letting it drain in chunks. The app's network
        /// buffer setting is meant to buy playback reliability, not just cap
        /// memory use.
        static func demuxerHysteresisSeconds(for bufferSeconds: Int) -> Double {
            0
        }

        /// Amount of cached media mpv should rebuild before leaving
        /// "buffering" mode after an underrun or initial load. Use a partial
        /// target so recovery does not add the full user buffer as latency.
        static func cachePauseWaitSeconds(for bufferSeconds: Int) -> Double {
            min(max(1.25, minimumCacheSeconds(for: bufferSeconds) * 0.5), 3.0)
        }

        static var liveStreamLavfOptions: String {
            [
                // IPTV HLS providers often terminate playlist and segment
                // responses without a finite content length. libavformat's
                // reconnect options treat that normal EOF as a byte-range
                // reconnect loop, delaying or preventing startup. Keep only
                // a socket timeout here; PlayerSlot owns live-stream reload
                // recovery at the item level.
                // 8 s gives enough headroom for slow CDN segments (4–6 s)
                // without triggering premature reconnects during transient
                // network stalls, while still failing faster than the 10 s
                // ffmpeg default.
                "rw_timeout=8000000",
            ].joined(separator: ",")
        }

        /// Transport options for non-HLS network media (VOD files, catchup
        /// TS). These go through ffmpeg's HTTP protocol directly, where a
        /// dropped connection mid-transfer is otherwise a fatal error — and
        /// non-live playback modes have no app-level reconnect. ffmpeg's
        /// reconnect resumes at the current byte offset via a Range request.
        /// `reconnect_at_eof` stays off: a finished stream must still end.
        static var vodStreamLavfOptions: String {
            [
                "rw_timeout=8000000",
                "reconnect=1",
                "reconnect_on_network_error=1",
                "reconnect_delay_max=5",
            ].joined(separator: ",")
        }
    }

    /// True when the URL points at an HLS playlist (as opposed to a VOD
    /// container file, catchup TS stream, or local recording).
    private static func isHLSURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" || ext == "m3u" { return true }
        // Some providers hide the playlist extension behind query routing.
        return url.absoluteString.lowercased().contains(".m3u8")
    }

    private struct MPVLogSuppression {
        var lastEmittedAt: Date
        var suppressedCount: Int
    }

    private(set) var mediaInfo = MPVMediaInfo()
    private(set) var playbackStats = MPVPlaybackStats()
    private(set) var isPlaying = false
    private(set) var errorMessage: String?
    private(set) var cacheSeconds: Double = 0
    @ObservationIgnored private var preciseCacheSample = PlaybackCacheSample()
    var telemetryExactCacheSeconds: Double? {
        preciseCacheSample.currentSeconds(generation: loadGeneration, at: ProcessInfo.processInfo.systemUptime)
    }
    private(set) var usesStartupReserve = false
    private(set) var startupTargetEnabled = false
    private(set) var nativeCacheOnlyEnabled = false
    var startupHoldActive: Bool { playbackControl.startupSuspended }
    private(set) var startupHoldReleasedAtMs: Int?
    private(set) var startupHoldReleaseCacheSeconds: Double?
    private(set) var startupTargetTimedOut = false
    @ObservationIgnored private var startupTargetHold: StartupTargetHold?
    @ObservationIgnored private var pendingStartupLoad: (path: String, generation: Int)?
    @ObservationIgnored private var startupPauseConfirmedGeneration: Int?
    @ObservationIgnored private(set) var telemetryCachePauseInitial: Bool?
    @ObservationIgnored private(set) var telemetryCachePauseWaitSeconds: Double?
    @ObservationIgnored private var loadProbeOptions = MPVLoadProbeOptions.baseline
    var liveAnalysisEnabled: Bool { loadProbeOptions.liveAnalysisRequestedSeconds != nil }
    var liveAnalysisRequestedSeconds: Double? { loadProbeOptions.liveAnalysisRequestedSeconds }
    @ObservationIgnored private(set) var telemetryLavfAnalyzeDurationSeconds: Double?
    @ObservationIgnored private(set) var telemetryLavfProbeSize: Int64?
    @ObservationIgnored private(set) var telemetryLavfProbeInfo: String?
    @ObservationIgnored private var startupPhases = MPVStartupPhases()
    var telemetryStartupPhaseTimingsMilliseconds: [String: Double] { startupPhases.timingsMilliseconds }
    @ObservationIgnored private var rawTimeSample = PlaybackClockSample()
    @ObservationIgnored private var videoPTSSample = PlaybackClockSample()
    var telemetryRawTimePos: Double? {
        rawTimeSample.current(generation: loadGeneration, at: ProcessInfo.processInfo.systemUptime)?.seconds
    }
    var telemetryRawTimePosAgeMilliseconds: Double? {
        rawTimeSample.current(generation: loadGeneration, at: ProcessInfo.processInfo.systemUptime)?.ageMilliseconds
    }
    var telemetryVideoPTS: Double? {
        videoPTSSample.current(generation: loadGeneration, at: ProcessInfo.processInfo.systemUptime)?.seconds
    }
    var telemetryVideoPTSAgeMilliseconds: Double? {
        videoPTSSample.current(generation: loadGeneration, at: ProcessInfo.processInfo.systemUptime)?.ageMilliseconds
    }
    private(set) var isBuffering = false
    /// True from the moment `loadURL` is called until the first frame is
    /// rendered (or the load fails). mpv's `paused-for-cache` only flips after
    /// the demuxer has parsed the stream, so without this flag there's a
    /// visible gap where the UI shows "play" while the network fetch is still
    /// in flight.
    private(set) var isLoading = false
    private(set) var volume: Double = 100
    private(set) var isMuted = false
    private(set) var timePos: Double = 0
    private(set) var cacheFloorPauseCount = 0
    private(set) var firstFrameElapsedMs: Int?
    var telemetryLoadGeneration: Int { loadGeneration }
    var telemetryBackendItemIdle: Bool {
        currentURL == nil && itemLifecycle.isBackendIdle
    }
    @ObservationIgnored private var backendTeardownCompletions: [() -> Void] = []

    /// An accepted STOP command alone does not prove the upstream is closed.
    /// Defer connection leases and handle reuse until the item lifecycle has
    /// received both command completion and the last entry's END_FILE.
    func stopWhenBackendIdle(_ completion: @escaping () -> Void) {
        backendTeardownCompletions.append(completion)
        stop()
        completeBackendTeardownIfIdle()
    }

    private func completeBackendTeardownIfIdle() {
        guard telemetryBackendItemIdle, !backendTeardownCompletions.isEmpty else { return }
        let completions = backendTeardownCompletions
        backendTeardownCompletions.removeAll()
        for completion in completions { completion() }
    }
    /// Only the entry acknowledged by loadfile and FILE_LOADED may contribute
    /// render telemetry. A newer requested generation alone proves nothing.
    var renderItemIdentity: MPVItemLifecycle.Identity? { itemLifecycle.loadedIdentity }
    var telemetryBufferingMilliseconds: Int {
        bufferingTotalMilliseconds + (bufferingStartedAt.map { AppLog.elapsedMilliseconds(since: $0) } ?? 0)
    }
    @ObservationIgnored private(set) var telemetryAudioOutput: String?
    @ObservationIgnored private(set) var telemetryDemuxerStartTime: Double?
    @ObservationIgnored private(set) var telemetryAVSyncSeconds: Double?
    @ObservationIgnored private(set) var telemetryPause: Bool?
    @ObservationIgnored private(set) var telemetryPausedForCache: Bool?
    /// Owner intent, independent of cache, thumbnail, and system suspension.
    var wantsPlayback: Bool { playbackRequested }
    private(set) var ownerPlaybackIntentRevision: UInt64 = 0
    var telemetryPlaybackRequested: Bool { wantsPlayback }
    @ObservationIgnored private(set) var telemetryRenderedFrameCount = 0
    @ObservationIgnored private(set) var telemetryLastRenderElapsedMs: Double?
    @ObservationIgnored private var lastRenderedAt: ContinuousClock.Instant?
    var telemetrySecondsSinceLastRender: Double? {
        lastRenderedAt.map { Self.milliseconds($0.duration(to: .now)) / 1_000 }
    }
    private(set) var duration: Double = 0
    private(set) var isSeekable: Bool = false
    /// Last URL handed to `loadURL`. Used by callers to avoid redundant
    /// `loadURL` calls when handing off a player.
    private(set) var currentURL: URL?
    var hasRenderedCurrentLoad: Bool {
        currentURL != nil && firstRenderedLoadGeneration == loadGeneration
    }

    /// Called whenever mpv fires MPV_EVENT_END_FILE. When non-nil, MPVPlayer
    /// suppresses its automatic `errorMessage` for error/EOF reasons — the
    /// handler owns recovery policy (silent reconnect, user-facing error, etc).
    /// Leaving this `nil` keeps the legacy behaviour for callers that prefer a
    /// simple "show error to user" flow (e.g. recording playback of a finite
    /// file, where a retry makes no sense).
    var onPlaybackEnded: ((MPVEndReason) -> Void)?
    /// Emitted when newly parsed media metadata becomes available. Intended for
    /// lightweight consumers such as StreamProbeService cache updates.
    var onMediaInfoChanged: ((MPVMediaInfo) -> Void)?
    /// Emitted after mpv has opened the media and reported FILE_LOADED.
    /// Owners use this to reset recovery watchdog state from "loading" to
    /// "waiting for first playback progress".
    var onFileLoaded: (() -> Void)?
    /// Emitted after the first frame for a load is actually drawn.
    var onFirstFrame: (() -> Void)?
    /// Emitted for mpv network/HLS warnings that do not always terminate
    /// playback. Owners can use this as a liveness signal when mpv sits in its
    /// own reconnect loop without delivering `MPV_EVENT_END_FILE`.
    var onStreamIssue: ((MPVStreamIssue) -> Void)?

    /// True if we have no rewind window, or playback is within a few seconds of
    /// the live edge. Streams without a DVR window are considered always-live.
    var isAtLiveEdge: Bool {
        guard isSeekable, duration > 0 else { return true }
        return (duration - timePos) < 5
    }

    /// User-configured latency we intentionally keep behind the edge when the
    /// stream exposes enough buffered material to do so.
    var preferredLiveDelay: Double {
        guard canReplay else { return 0 }
        return min(Double(bufferSeconds), duration)
    }

    /// Current user-selected network buffer budget.
    var configuredBufferSeconds: Double {
        Double(bufferSeconds)
    }

    /// Playhead position representing the app's "live" state: the live edge
    /// if there's no replay window, otherwise the edge minus the preferred
    /// buffer delay.
    var preferredLivePosition: Double {
        guard canReplay else { return timePos }
        return max(duration - preferredLiveDelay, 0)
    }

    /// Whether playback is already at the app's preferred live position.
    var isAtPreferredLivePosition: Bool {
        if canReplay {
            return abs(timePos - preferredLivePosition) < 5 || timePos > preferredLivePosition
        }

        let target = configuredBufferSeconds
        guard target > 0 else { return cacheSeconds < 1 }
        return cacheSeconds <= target + 0.5
    }

    /// True if the current source exposes a rewind window we can scrub through.
    var canReplay: Bool {
        isSeekable && duration > 0
    }

    @ObservationIgnored private var containerFps: Double = 0
    @ObservationIgnored private var estimatedFps: Double = 0

    private var handle: OpaquePointer?
    private(set) var renderContext: OpaquePointer?
    /// Drawing reads the render context through this box on the render queue.
    nonisolated let renderTarget = MPVRenderTarget()
    private var wakeupPipe: [Int32] = [-1, -1]
    private var eventSource: DispatchSourceRead?
    private var statePollTimer: DispatchSourceTimer?
    private var bufferSeconds: Int = BufferSetting.read()
    @ObservationIgnored private var activeCachePauseFloorSeconds: Double = Tuning.cachePauseFloorSeconds(for: BufferSetting.read())
    @ObservationIgnored private var activeCachePauseResumeSeconds: Double = Tuning.cachePauseResumeSeconds(for: BufferSetting.read())
    @ObservationIgnored private var playbackControl = PlaybackControlState() {
        didSet { renderTarget.update(backgroundSuspended: playbackControl.backgroundSuspended) }
    }
    private var autoPausedForCacheFloor: Bool {
        get { playbackControl.cacheSuspended }
        set { playbackControl.cacheSuspended = newValue }
    }
    @ObservationIgnored var focusedScaling: Bool = true   // internal: read by PlayerSlot watchdog guards for multi-view throttling decisions
    /// Set when we deliberately disabled the video track for a background
    /// thumbnail slot in multi-view. We restore it ("auto") on promotion.
    var videoDisabledForBackground: Bool { playbackControl.backgroundSuspended }
    private var defaultsObserver: NSObjectProtocol?
    private var mpvLogSuppression: [String: MPVLogSuppression] = [:]
    @ObservationIgnored private var lastHTTPStatusCode: Int = 0
    private var playbackRequested: Bool { playbackControl.playbackRequested }
    @ObservationIgnored private var redirectResolutionTask: Task<Void, Never>?
    @ObservationIgnored private var loadStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var bufferingStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var bufferingEventCount = 0
    @ObservationIgnored private var bufferingTotalMilliseconds = 0
    private var loadGeneration: Int { playbackControl.generation }
    @ObservationIgnored private var itemLifecycle = MPVItemLifecycle() {
        didSet { renderTarget.update(itemIdentity: itemLifecycle.loadedIdentity) }
    }
    /// Outstanding async property reads: fixed ring indexed by serial & mask.
    @ObservationIgnored private var propertyRequests = MPVPropertyRequestRing()
    @ObservationIgnored private var firstRenderedLoadGeneration = 0
#if os(macOS)
    @ObservationIgnored private var displayPowerAssertion = IOPMAssertionID(0)
#endif
    @ObservationIgnored private var holdsDisplayPowerAssertion = false
    @ObservationIgnored private var lastTelemetryFrameDrops: Int64 = 0
    @ObservationIgnored private var lastTelemetryDecoderDrops: Int64 = 0
    @ObservationIgnored private var lastTelemetryMistimed: Int64 = 0
    @ObservationIgnored private var telemetryNetworkWarns: Int = 0
    @ObservationIgnored private var telemetryDecodeWarns: Int = 0
    @ObservationIgnored private var lastDrawableWidth: Int = 0
    @ObservationIgnored private var lastDrawableHeight: Int = 0
    @ObservationIgnored private var fileLoadedGeneration = 0
    @ObservationIgnored private var lastFileLoadedIdentity: MPVItemLifecycle.Identity?

    /// In-memory cache of resolved CDN URLs. Xtream stream URLs redirect to
    /// CDN edge servers; caching the final URL avoids a ~1s HEAD request on
    /// every channel switch. Entries expire after 5 minutes since CDN tokens
    /// and edge assignments can rotate.
    @ObservationIgnored private static var resolvedURLCache: [URL: (resolved: URL, timestamp: Date)] = [:]
    @ObservationIgnored private static let resolvedURLCacheTTL: TimeInterval = 300

    /// Drops the cached CDN resolution for a URL. Reconnect policy calls this
    /// when a stream is failing so the reload re-resolves the edge assignment
    /// instead of reusing a possibly expired CDN URL for the rest of the TTL.
    static func invalidateResolvedURL(for url: URL) {
        resolvedURLCache[url] = nil
    }

    init() {
        setupMPV()
        refreshPlaybackTuningStats(renderProfile: "focused")
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let player = self else { return }
            Task { @MainActor in
                player.reloadBufferSetting()
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            destroy()
        }
    }

    // MARK: - Public API

    /// Resolves an HTTP redirect chain to the final CDN URL. For Xtream Codes
    /// streams, the initial URL redirects to a CDN edge server. Resolving this
    /// eagerly via URLSession (which reuses HTTP connections) avoids ~4s of
    /// redirect + TLS renegotiation overhead inside mpv/ffmpeg.
    /// Results are cached for 5 minutes to avoid the HEAD request on every
    /// channel switch.
    private static func resolveRedirect(for url: URL) async -> URL? {
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        guard url.host?.contains("silksurfer.com") == true || url.host?.contains("783.") == true else { return nil }

        // Check cache first
        if let cached = resolvedURLCache[url],
           Date().timeIntervalSince(cached.timestamp) < resolvedURLCacheTTL {
            return cached.resolved
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request) as? (Data, HTTPURLResponse) else {
            return nil
        }
        if let finalURL = response.url, finalURL != url {
            resolvedURLCache[url] = (resolved: finalURL, timestamp: Date())
            return finalURL
        }
        return nil
    }

    @ObservationIgnored private(set) var usesArchiveTimestampRecovery = false

    func loadURL(_ url: URL, autoplay: Bool = false, fastProbe: Bool = false, archive: Bool = false, live: Bool = false) {
        ownerPlaybackIntentRevision &+= 1
        guard let handle else { return }
        setRuntimeProperty(handle, "video-timing-offset", MPVRenderTiming.videoTimingOffset)
        let eligibleLive = live && !archive && !url.isFileURL
        startupTargetEnabled = MPVStartupTarget.enabled(forLiveLoad: eligibleLive)
        nativeCacheOnlyEnabled = MPVNativeCacheOnly.enabled(forLiveLoad: eligibleLive)
        usesStartupReserve = !startupTargetEnabled && MPVStartupReserve.enabled(forLiveLoad: eligibleLive)

        updateBufferingState(false, source: "load-replaced")
        redirectResolutionTask?.cancel()
        playbackControl.beginLoad(autoplay: autoplay)
        itemLifecycle.invalidate(generation: loadGeneration)
        firstRenderedLoadGeneration = 0
        loadStartedAt = ContinuousClock.now
        resetLoadTelemetry()
        let validationActive = PlaybackValidation.isEnabled || SavedPlaybackScenario.isCapturing
        loadProbeOptions = MPVLoadProbeOptions.configuration(url: url, live: live, archive: archive,
            fastProbe: fastProbe, validationActive: validationActive, arguments: CommandLine.arguments)
#if DEBUG
        startupPhases.reset(generation: loadGeneration, enabled: validationActive)
#endif
        playbackControl.startupSuspended = startupTargetEnabled
        startupTargetHold = startupTargetEnabled
            ? StartupTargetHold(generation: loadGeneration, targetSeconds: Double(bufferSeconds)) : nil
        AppLog.playback.info("mpv load-start generation=\(self.loadGeneration, privacy: .public) url=\(url.absoluteString, privacy: .private(mask: .hash)) autoplay=\(autoplay, privacy: .public) fastProbe=\(fastProbe, privacy: .public)")
        errorMessage = nil
        resetMediaTrackState()
        timePos = 0
        duration = 0
        isSeekable = false
        cacheSeconds = 0
        bufferingEventCount = 0
        bufferingTotalMilliseconds = 0
        autoPausedForCacheFloor = false
        refreshPlaybackTuningStats(autoPausedForCacheFloor: false)
        isPlaying = !playbackControl.shouldPause
        isLoading = true
        currentURL = url
        lastTelemetryFrameDrops = 0
        lastTelemetryDecoderDrops = 0
        lastTelemetryMistimed = 0
        telemetryNetworkWarns = 0
        telemetryDecodeWarns = 0
        lastDrawableWidth = 0
        lastDrawableHeight = 0
        fileLoadedGeneration = 0
        lastFileLoadedIdentity = nil
        updateDisplayPowerAssertion()
        if startupTargetEnabled { applyPlaybackPauseState() }

        // Fast-probe path is used for known local MPEG-TS sources (recording
        // files). With the regular live probe/analyze window,
        // mpv's ffmpeg demuxer can still spend seconds scanning the head of a
        // multi-gigabyte .ts file before reporting stream info.
        // For MPEG-TS the SPS usually lands in the first few KB, so shrinking
        // the probe window by ~16x trims the open delay without losing
        // detection. Restored to the safe HLS defaults on the next non-fast
        // load so channel streams aren't affected.
        setRuntimeProperty(handle, "demuxer-lavf-probesize", "\(loadProbeOptions.probeSize)")
        setRuntimeProperty(handle, "demuxer-lavf-analyzeduration", "\(loadProbeOptions.analyzeDurationSeconds)")
        setRuntimeProperty(handle, "demuxer-lavf-probe-info", loadProbeOptions.probeInfo)
        // For HLS playlists, set the format explicitly so ffmpeg skips the
        // content-based detection step, and raise the probescore so it skips
        // low-confidence verification. Everything else (VOD .mkv/.mp4, catchup
        // .ts, recordings) must auto-detect: forcing "hls" makes ffmpeg's HLS
        // demuxer reject non-playlist input outright. Properties persist
        // across loads on a reused handle, so both branches always set both.
        let isHLS = Self.isHLSURL(url)
        setRuntimeProperty(handle, "demuxer-lavf-format", isHLS ? "hls" : "")
        setRuntimeProperty(handle, "demuxer-lavf-probescore", isHLS ? "50" : "26")
        // Segment/VOD transport recovery lives at the ffmpeg HTTP layer for
        // non-HLS media: a mid-transfer socket drop resumes at the current
        // byte offset instead of killing playback (which non-live modes
        // surface straight to the user). HLS keeps the plain timeout-only
        // options — its recovery is handled by the demuxer retry flags and
        // PlayerSlot's reconnect policy.
        let isNetwork = url.scheme == "http" || url.scheme == "https"
        setRuntimeProperty(
            handle, "stream-lavf-o",
            !isHLS && isNetwork ? Tuning.vodStreamLavfOptions : Tuning.liveStreamLavfOptions
        )
        // These options are properties of the retained handle. Restore the
        // baseline on every load before applying a validation-only override.
        let timestampOptions = ArchiveTimestampRecovery.options(forArchiveLoad: archive)
        usesArchiveTimestampRecovery = timestampOptions.enabled
        setRuntimeProperty(handle, "demuxer-lavf-o", timestampOptions.lavf)
        setRuntimeProperty(handle, "demuxer-lavf-linearize-timestamps", timestampOptions.linearize)
        setRuntimeProperty(handle, "vid", videoDisabledForBackground ? "no" : "auto")

        // Controlled transport experiment: never retry authentication/provider
        // throttling, EOF, or unbounded reconnects. Not enabled in normal runs.
        if isHLS, PlaybackValidation.config?.httpRetry == true {
            setRuntimeProperty(handle, "stream-lavf-o", "rw_timeout=8000000,reconnect_on_http_error=502,reconnect_on_network_error=1,reconnect_max_retries=3,reconnect_delay_max=2,reconnect_delay_total_max=5")
            setRuntimeProperty(handle, "demuxer-lavf-o", timestampOptions.lavf + ",reconnect_on_http_error=502,reconnect_on_network_error=1,reconnect_max_retries=3,reconnect_delay_max=2,reconnect_delay_total_max=5")
        }

        // Eagerly resolve CDN redirects before handing the URL to mpv.
        // URLSession reuses connections and resolves redirects faster than
        // mpv/ffmpeg's internal HTTP stack, saving ~4s on Xtream streams.
        let capturedURL = url
        let capturedGeneration = loadGeneration
        redirectResolutionTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, self.handle != nil else { return }
            guard self.playbackControl.acceptsLoad(capturedGeneration) else {
                AppLog.playback.info("mpv redirect resolution cancelled (stale generation)")
                return
            }
            self.noteStartupPhase(.redirectStarted, generation: capturedGeneration)
            let resolvedURL = await Self.resolveRedirect(for: capturedURL) ?? capturedURL
            guard !Task.isCancelled,
                  self.playbackControl.acceptsLoad(capturedGeneration),
                  let handle = self.handle else { return }
            self.redirectResolutionTask = nil
            self.noteStartupPhase(.redirectCompleted, generation: capturedGeneration)
            if resolvedURL != capturedURL {
                AppLog.playback.info("mpv redirect resolved to=\(resolvedURL.absoluteString, privacy: .private(mask: .hash))")
                self.currentURL = resolvedURL
            }
            let path = resolvedURL.absoluteString
            // Use a smaller readahead for faster startup; increased after first frame.
            setRuntimeProperty(handle, "demuxer-readahead-secs", "\(Tuning.startupReadAheadSeconds(for: self.bufferSeconds))")
            if self.startupTargetEnabled {
                self.pendingStartupLoad = (path, capturedGeneration)
                self.applyPlaybackPauseState()
                self.startTargetLoadIfPauseConfirmed()
            } else if let request = self.itemLifecycle.enqueue(.load(path), generation: capturedGeneration) {
                self.submitItemCommand(request)
            }
            self.applyPlaybackPauseState()
        }
    }

    func noteRenderedFrame(width: Int, height: Int, identity: MPVItemLifecycle.Identity, renderedAt: ContinuousClock.Instant) {
        guard currentURL != nil,
              itemLifecycle.loadedIdentity == identity,
              playbackControl.acceptsFrame(identity.generation, fileLoadedGeneration: fileLoadedGeneration) else { return }
        telemetryRenderedFrameCount &+= 1
        lastRenderedAt = renderedAt
        if let loadStartedAt {
            telemetryLastRenderElapsedMs = Self.milliseconds(loadStartedAt.duration(to: renderedAt))
        }
        guard firstRenderedLoadGeneration != loadGeneration else { return }
        firstRenderedLoadGeneration = loadGeneration
        lastDrawableWidth = width
        lastDrawableHeight = height
        let elapsedMs = loadElapsedMilliseconds().map { Int($0.rounded()) } ?? -1
        if isLoading, !startupHoldActive {
            isLoading = false
            updateDisplayPowerAssertion()
        }
        if firstFrameElapsedMs == nil, elapsedMs >= 0 {
            firstFrameElapsedMs = elapsedMs
        }
        noteStartupPhase(.firstRender, generation: identity.generation)
        if elapsedMs >= 0 { PerfMetrics.shared.record("playback.loadToFirstFrameMs", Double(elapsedMs)) }
        AppLog.playback.info("mpv first-frame generation=\(self.loadGeneration, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) vo=\(width, privacy: .public)x\(height, privacy: .public) coded=\(self.mediaInfo.width, privacy: .public)x\(self.mediaInfo.height, privacy: .public) fileLoaded=\(self.fileLoadedGeneration == self.loadGeneration, privacy: .public)")
        // Upgrade readahead to full value now that playback is established.
        if let handle {
            setRuntimeProperty(handle, "demuxer-readahead-secs", "\(Tuning.demuxerReadAheadSeconds(for: bufferSeconds))")
        }
        onFirstFrame?()
    }

    func seek(to seconds: Double) {
        guard let handle else { return }
        command(handle, ["seek", String(seconds), "absolute"])
    }

    func seekToLiveEdge() {
        guard let handle else { return }
        command(handle, ["seek", "100", "absolute-percent"])
    }

    func seekToPreferredLivePosition() {
        guard canReplay else {
            dropBuffers()
            play()
            return
        }
        seek(to: preferredLivePosition)
    }

    func dropBuffers() {
        guard let handle else { return }
        command(handle, ["drop-buffers"])
    }

    func nudgeVideoOutputAfterRenderContextAttach() {
        guard let handle, currentURL != nil else { return }
        let shouldDropBuffers = !(hasRenderedCurrentLoad && isPlaying)
        setRuntimeProperty(handle, "vid", videoDisabledForBackground ? "no" : "auto")
        if shouldDropBuffers {
            command(handle, ["drop-buffers"])
        }
        applyPlaybackPauseState()
        updateDisplayPowerAssertion()
        AppLog.playback.info("mpv render-context handoff nudged video output dropBuffers=\(shouldDropBuffers, privacy: .public) rendered=\(self.hasRenderedCurrentLoad, privacy: .public)")
        logPlaybackSyncSnapshot("render-context-handoff")
    }

    func logPlaybackSyncSnapshot(_ label: String) {
        let stats = playbackStats
        let info = mediaInfo
        let dropDelta = stats.frameDrops - lastTelemetryFrameDrops
        let decoderDelta = stats.decoderFrameDrops - lastTelemetryDecoderDrops
        let mistimedDelta = stats.mistimedFrames - lastTelemetryMistimed
        lastTelemetryFrameDrops = stats.frameDrops
        lastTelemetryDecoderDrops = stats.decoderFrameDrops
        lastTelemetryMistimed = stats.mistimedFrames
        let networkWarns = telemetryNetworkWarns
        let decodeWarns = telemetryDecodeWarns
        telemetryNetworkWarns = 0
        telemetryDecodeWarns = 0
        AppLog.playback.info("mpv sync \(label, privacy: .public) playing=\(self.isPlaying, privacy: .public) loading=\(self.isLoading, privacy: .public) buffering=\(self.isBuffering, privacy: .public) cacheFloorPause=\(self.autoPausedForCacheFloor, privacy: .public) muted=\(self.isMuted, privacy: .public) volume=\(self.volume, privacy: .public) cache=\(self.cacheSeconds, privacy: .public) time=\(self.timePos, privacy: .public) coded=\(info.width, privacy: .public)x\(info.height, privacy: .public) vo=\(self.lastDrawableWidth, privacy: .public)x\(self.lastDrawableHeight, privacy: .public) fps=\(info.fps, privacy: .public) vfFps=\(stats.estimatedFps, privacy: .public) vcodec=\(info.videoCodec, privacy: .public) acodec=\(info.audioCodec, privacy: .public) ach=\(info.audioChannels, privacy: .public) hwdec=\(info.hwdec, privacy: .public) vbr=\(stats.videoBitrateBps, privacy: .public) abr=\(stats.audioBitrateBps, privacy: .public) frameDrops=\(stats.frameDrops, privacy: .public) dropDelta=\(dropDelta, privacy: .public) decoderDrops=\(stats.decoderFrameDrops, privacy: .public) decoderDelta=\(decoderDelta, privacy: .public) delayed=\(stats.delayedFrames, privacy: .public) mistimed=\(stats.mistimedFrames, privacy: .public) mistimedDelta=\(mistimedDelta, privacy: .public) netWarns=\(networkWarns, privacy: .public) decodeWarns=\(decodeWarns, privacy: .public)")
    }

    func play() {
        ownerPlaybackIntentRevision &+= 1
        playbackControl.requestPlayback(true)
        refreshPlaybackTuningStats(autoPausedForCacheFloor: false)
        applyPlaybackPauseState()
        isPlaying = !playbackControl.shouldPause
        updateDisplayPowerAssertion()
    }

    func pause() {
        ownerPlaybackIntentRevision &+= 1
        playbackControl.requestPlayback(false)
        updateBufferingState(false, source: "owner-pause")
        refreshPlaybackTuningStats(autoPausedForCacheFloor: false)
        applyPlaybackPauseState()
        isPlaying = false
        updateDisplayPowerAssertion()
    }

    func stop() {
        redirectResolutionTask?.cancel()
        redirectResolutionTask = nil
        rawTimeSample.reset()
        videoPTSSample.reset()
        startupPhases.reset(generation: loadGeneration, enabled: false)
        loadProbeOptions = .baseline
        telemetryLavfAnalyzeDurationSeconds = nil
        telemetryLavfProbeSize = nil
        telemetryLavfProbeInfo = nil
        playbackControl.stop()
        startupTargetHold = nil
        pendingStartupLoad = nil
        startupPauseConfirmedGeneration = nil
        itemLifecycle.invalidate(generation: loadGeneration)
        propertyRequests.removeAll()
        if let request = itemLifecycle.enqueue(.stop, generation: loadGeneration) {
            submitItemCommand(request)
        }
        applyPlaybackPauseState()
        isPlaying = false
        updateBufferingState(false, source: "stop")
        isLoading = false
        loadStartedAt = nil
        firstRenderedLoadGeneration = loadGeneration
        fileLoadedGeneration = 0
        lastFileLoadedIdentity = nil
        currentURL = nil
        updateDisplayPowerAssertion()
    }

    func togglePause() {
        playbackRequested ? pause() : play()
    }

    /// Pauses the lightweight cache-floor timer. Called by PlayerSlot during
    /// system sleep to avoid unnecessary work while suspended.
    func pauseBackgroundActivity() {
        playbackControl.systemSuspended = true
        applyPlaybackPauseState()
        isPlaying = false
        updateDisplayPowerAssertion()
        statePollTimer?.cancel()
        statePollTimer = nil
    }

    /// Restarts the cache-floor timer if the player is still alive. Safe to
    /// call on wake even if we did not explicitly pause it.
    func resumeBackgroundActivity() {
        playbackControl.systemSuspended = false
        applyPlaybackPauseState()
        updateDisplayPowerAssertion()
        if statePollTimer == nil, handle != nil {
            startCacheFloorTimer()
        }
    }

    /// Prepares a warm MPVPlayer (from the reuse pool) for assignment to a
    /// new PlayerSlot. Clears owner callbacks and transient state, stops any
    /// prior stream, resets render context if needed. The expensive mpv handle,
    /// event pump, observers, and timers are retained for fast reuse.
    func prepareForReuse() {
        // Detach from any previous owner to prevent stale callbacks or
        // recovery logic firing on an idle pooled instance.
        onPlaybackEnded = nil
        onFileLoaded = nil
        onFirstFrame = nil
        onStreamIssue = nil
        onMediaInfoChanged = nil

        // Halt playback without tearing down the mpv instance.
        stop()

        // Full state reset mirroring the pre-load cleanup in loadURL.
        errorMessage = nil
        resetMediaTrackState()
        timePos = 0
        duration = 0
        isSeekable = false
        cacheSeconds = 0
        updateBufferingState(false, source: "reuse")
        isLoading = false
        autoPausedForCacheFloor = false
        playbackControl.backgroundSuspended = false
        playbackControl.systemSuspended = false
        currentURL = nil
        isPlaying = false
        isMuted = false
        // volume left at last value; loadURL or UI will set as needed
        mediaInfo = MPVMediaInfo()
        playbackStats = MPVPlaybackStats()
        containerFps = 0
        estimatedFps = 0
        lastHTTPStatusCode = 0
        mpvLogSuppression = [:]
        loadStartedAt = nil
        firstRenderedLoadGeneration = loadGeneration
        focusedScaling = true
        usesArchiveTimestampRecovery = false
        usesStartupReserve = false
        startupTargetEnabled = false
        nativeCacheOnlyEnabled = false
        loadProbeOptions = .baseline
        resetLoadTelemetry()
        setMute(false)
        if let handle {
            setRuntimeProperty(handle, "video-timing-offset", MPVRenderTiming.videoTimingOffset)
            setRuntimeProperty(handle, "cache-pause-initial", "no")
            setRuntimeProperty(handle, "demuxer-lavf-probesize", "\(loadProbeOptions.probeSize)")
            setRuntimeProperty(handle, "demuxer-lavf-analyzeduration", "\(loadProbeOptions.analyzeDurationSeconds)")
            setRuntimeProperty(handle, "demuxer-lavf-probe-info", loadProbeOptions.probeInfo)
            setRuntimeProperty(handle, "vid", "auto")
            setRuntimeProperty(handle, "stream-lavf-o", Tuning.liveStreamLavfOptions)
            let timestamps = ArchiveTimestampRecovery.options(forArchiveLoad: false)
            setRuntimeProperty(handle, "demuxer-lavf-o", timestamps.lavf)
            setRuntimeProperty(handle, "demuxer-lavf-linearize-timestamps", timestamps.linearize)
        }
        applyPlaybackPauseState()

        releaseDisplayPowerAssertion()
        resetRenderContext()

        // Restore sensible defaults for next user; configureResources will
        // further tune per focus/multi-view state on first attach.
        activeCachePauseFloorSeconds = Tuning.cachePauseFloorSeconds(for: bufferSeconds)
        activeCachePauseResumeSeconds = Tuning.cachePauseResumeSeconds(for: bufferSeconds)
        refreshPlaybackTuningStats(renderProfile: "focused")
    }

    func setVolume(_ percent: Double) {
        setDouble("volume", percent.clamped(to: 0...130))
    }

    func setMute(_ muted: Bool) {
        setFlag("mute", muted)
    }

    func toggleMute() {
        setMute(!isMuted)
    }

    /// Called by owners (e.g. PlayerSlot) that are running their own
    /// reconnect policy. Sets `errorMessage` without going through the
    /// automatic END_FILE path — used to raise a soft "stream offline"
    /// banner once silent retries have been failing for long enough.
    func setReconnectingErrorMessage(_ message: String) {
        errorMessage = message
    }

    func clearReconnectingErrorMessage() {
        errorMessage = nil
    }

    // MARK: - Resource scaling

    /// Adjust buffer sizes and rendering quality based on whether this player is
    /// in a multi-view grid and whether it holds focus (audio + controls).
    /// Non-focused players get smaller demuxer buffers, fewer decode threads,
    /// and faster (lower-quality) scaling to free GPU and memory bandwidth.
    func configureResources(multiView: Bool, focused: Bool) {
        guard let handle else { return }

        let maxBytes: String
        let maxBackBytes: String
        let cacheFloorSecs: Int
        let scaleFilter: String
        let cscaleFilter: String

        if !multiView {
            maxBytes = Tuning.demuxerMaxBytes(for: bufferSeconds, focused: true)
            maxBackBytes = Tuning.demuxerMaxBackBytes(for: bufferSeconds, focused: true)
            cacheFloorSecs = bufferSeconds
            scaleFilter = "spline36"
            cscaleFilter = "spline36"
            focusedScaling = true
            if videoDisabledForBackground {
                setRuntimeProperty(handle, "vid", "auto")
                playbackControl.backgroundSuspended = false
            }
            playbackControl.backgroundSuspended = false
        } else if focused {
            maxBytes = Tuning.demuxerMaxBytes(for: bufferSeconds, focused: true)
            maxBackBytes = Tuning.demuxerMaxBackBytes(for: bufferSeconds, focused: true)
            cacheFloorSecs = bufferSeconds
            scaleFilter = "spline36"
            cscaleFilter = "spline36"
            focusedScaling = true
            if videoDisabledForBackground {
                setRuntimeProperty(handle, "vid", "auto")
                playbackControl.backgroundSuspended = false
            }
            playbackControl.backgroundSuspended = false
        } else {
            maxBytes = Tuning.demuxerMaxBytes(for: bufferSeconds, focused: false)
            maxBackBytes = Tuning.demuxerMaxBackBytes(for: bufferSeconds, focused: false)
            cacheFloorSecs = max(bufferSeconds / 2, min(bufferSeconds, 5))
            scaleFilter = "bilinear"
            cscaleFilter = "bilinear"
            focusedScaling = false

            // Strong background throttling for multi-view thumbnails (Agents 01/04/09).
            // Pause + drop buffers + disable video track so the decoder does
            // essentially zero work for off-screen slots. The render layer stays
            // attached; on promotion we re-enable video + unpause.
            playbackControl.backgroundSuspended = true
            autoPausedForCacheFloor = false
            command(handle, ["drop-buffers"])
            setRuntimeProperty(handle, "vid", "no")
        }
        applyPlaybackPauseState()

        activeCachePauseFloorSeconds = Tuning.cachePauseFloorSeconds(for: cacheFloorSecs)
        activeCachePauseResumeSeconds = Tuning.cachePauseResumeSeconds(for: cacheFloorSecs)
        refreshPlaybackTuningStats(renderProfile: focusedScaling ? "focused" : "background")

        setRuntimeProperty(handle, "demuxer-max-bytes", maxBytes)
        setRuntimeProperty(handle, "demuxer-max-back-bytes", maxBackBytes)

        setRuntimeDouble(handle, "cache-secs", Tuning.cacheCapacitySeconds(for: cacheFloorSecs))
        setRuntimeDouble(handle, "demuxer-readahead-secs", Tuning.demuxerReadAheadSeconds(for: cacheFloorSecs))
        setRuntimeDouble(handle, "demuxer-hysteresis-secs", Tuning.demuxerHysteresisSeconds(for: cacheFloorSecs))
        setRuntimeDouble(handle, "cache-pause-wait", Tuning.cachePauseWaitSeconds(for: cacheFloorSecs))

        setRuntimeProperty(handle, "scale", scaleFilter)
        setRuntimeProperty(handle, "cscale", cscaleFilter)
        setRuntimeProperty(handle, "dscale", scaleFilter)
    }

    var mpvHandle: OpaquePointer? { handle }
    var renderContextHandle: OpaquePointer? { renderContext }

    // MARK: - Render context (called by MPVPlayerLayer)

    func initRenderContext(
        getProcAddress: @escaping @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    ) -> Bool {
        guard let handle, renderContext == nil else { return renderContext != nil }
        var glInit = mpv_opengl_init_params(
            get_proc_address: getProcAddress,
            get_proc_address_ctx: nil
        )
        var ctx: OpaquePointer?
        let err = withUnsafeMutablePointer(to: &glInit) { glPtr -> Int32 in
            var apiType = Array(MPV_RENDER_API_TYPE_OPENGL.utf8CString)
            return apiType.withUnsafeMutableBufferPointer { apiBuf -> Int32 in
                var advancedControl: Int32 = 1
                return withUnsafeMutablePointer(to: &advancedControl) { advPtr -> Int32 in
                    // baseAddress is always non-nil for a non-empty utf8CString buffer; defensive guard prevents !
                    let apiData: UnsafeMutableRawPointer = apiBuf.baseAddress.map { UnsafeMutableRawPointer($0) } ?? .init(bitPattern: 0)!
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiData),
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(glPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: UnsafeMutableRawPointer(advPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    return mpv_render_context_create(&ctx, handle, &params)
                }
            }
        }
        if err < 0 {
            errorMessage = "render context failed: \(String(cString: mpv_error_string(err)))"
            return false
        }
        renderContext = ctx
        if let ctx { renderTarget.install(ctx, blockForTargetTime: MPVRenderTiming.blockForTargetTime) }
        return true
    }

    func setRenderUpdateCallback(_ cb: @escaping mpv_render_update_fn, context: UnsafeMutableRawPointer?) {
        guard let ctx = renderContext else { return }
        mpv_render_context_set_update_callback(ctx, cb, context)
    }

    func resetRenderContext() {
        guard renderContext != nil else { return }
        renderContext = nil
        renderTarget.free()
    }

    // MARK: - Setup

    private func setupMPV() {
        guard let newHandle = mpv_create() else {
            errorMessage = "mpv_create failed"
            return
        }
        handle = newHandle

        // Pre-init options. These must be set before mpv_initialize.
        setOption(newHandle, "config", "no")
        setOption(newHandle, "vo", "libmpv")
        setOption(newHandle, "gpu-api", "opengl")

        // VideoToolbox hardware decoding — mandatory on Apple Silicon.
        // hwdec-codecs=all enables VT for H.264, HEVC, AV1, VP9, etc.
        // vd-lavc-dr=yes requests direct rendering (zero-copy decode→GPU)
        // which avoids a CPU-side frame copy per decoded picture.
        setOption(newHandle, "hwdec", "videotoolbox")
        setOption(newHandle, "hwdec-codecs", "all")
        // Xtream catchup TS seeks can start on damaged/incomplete GOPs. Fall
        // back to software decoding on the first failed hardware frame instead
        // of waiting through repeated VideoToolbox errors and cache stalls.
        setOption(newHandle, "hwdec-software-fallback", "yes")
        setOption(newHandle, "vd-lavc-dr", "yes")
        setOption(newHandle, "vd-lavc-show-all", "no")

        // Cap software decoder threads. When VideoToolbox is active these
        // are unused; they exist as fallback for codecs VT doesn't handle.
        // Auto (one per core) produces ~16 threads on Apple Silicon — pure
        // scheduler overhead with no throughput gain.
        setOption(newHandle, "vd-lavc-threads", "2")

        // Frame timing. audio sync is correct for live streams where we
        // can't resample; display-resample would be better for local files
        // but adds latency. interpolation is off — live sport at 50/60 fps
        // doesn't benefit, and it costs GPU cycles.
        setOption(newHandle, "video-sync", "audio")
        setOption(newHandle, "video-timing-offset", MPVRenderTiming.videoTimingOffset)
        setOption(newHandle, "interpolation", "no")

        // Triple-buffering for smoother frame delivery under variable decode
        // times. swapchain-depth=2 (double) can stall the decoder pipeline
        // waiting for the previous frame to finish presenting.
        setOption(newHandle, "swapchain-depth", "3")

        // OpenGL performance tuning.
        setOption(newHandle, "opengl-early-flush", "yes")
        setOption(newHandle, "opengl-pbo", "yes")
        // vsync is managed by CAOpenGLLayer's CVDisplayLink — let CoreAnimation
        // handle it. Setting swapinterval=1 fights the layer's own timing.
        setOption(newHandle, "opengl-swapinterval", "0")

        // Scaling defaults. configureResources() overrides per focus state.
        setOption(newHandle, "scale", "spline36")
        setOption(newHandle, "cscale", "spline36")
        setOption(newHandle, "dscale", "spline36")

        // Disable all quality features we don't need for IPTV.
        setOption(newHandle, "deband", "no")
        setOption(newHandle, "dither", "no")
        setOption(newHandle, "sigmoid-upscaling", "no")
        setOption(newHandle, "correct-downscaling", "no")
        setOption(newHandle, "linear-downscaling", "no")

        // UI / OSD disabled — we render our own chrome in SwiftUI.
        setOption(newHandle, "osc", "no")
        setOption(newHandle, "input-default-bindings", "no")
        setOption(newHandle, "input-vo-keyboard", "no")
        setOption(newHandle, "idle", "yes")
        setOption(newHandle, "keep-open", "no")
        setOption(newHandle, "force-window", "no")
        setOption(newHandle, "terminal", "no")
        setOption(newHandle, "osd-level", "0")
        setOption(newHandle, "msg-level", "all=warn")
        setOption(newHandle, "load-scripts", "no")
        setOption(newHandle, "load-stats-overlay", "no")
        setOption(newHandle, "load-osd-console", "no")
        setOption(newHandle, "ytdl", "no")

        // Audio defaults. Validation-only backend experiments use the same
        // bundled C library and preserve normal playback settings.
        var audioOutputOverride = PlaybackValidation.config?.audioOutput
#if DEBUG
        audioOutputOverride = audioOutputOverride ?? SessionObservation.audioOutputOverride
#endif
        if let output = audioOutputOverride,
           ["coreaudio", "avfoundation"].contains(output) {
            setOption(newHandle, "ao", output)
        }
        setOption(newHandle, "volume", "100")
        setOption(newHandle, "volume-max", "130")

        // Live HLS tuning. cache=auto lets mpv decide caching strategy
        // per-stream; cache-pause=yes means mpv pauses when forward cache
        // runs dry instead of dropping frames.
        setOption(newHandle, "cache", "auto")
        setOption(newHandle, "cache-secs", String(Tuning.cacheCapacitySeconds(for: bufferSeconds)))
        setOption(newHandle, "cache-pause", "yes")
        setOption(newHandle, "cache-pause-initial", "no")
        setOption(newHandle, "cache-pause-wait", String(Tuning.cachePauseWaitSeconds(for: bufferSeconds)))

        // Demuxer buffer sizing. Sized in MiB based on bitrate estimates,
        // not fixed — high-bitrate live sport needs more headroom than SD.
        setOption(newHandle, "demuxer-max-bytes", Tuning.demuxerMaxBytes(for: bufferSeconds, focused: true))
        setOption(newHandle, "demuxer-max-back-bytes", Tuning.demuxerMaxBackBytes(for: bufferSeconds, focused: true))
        setOption(newHandle, "demuxer-readahead-secs", String(Tuning.demuxerReadAheadSeconds(for: bufferSeconds)))
        setOption(newHandle, "demuxer-hysteresis-secs", String(Tuning.demuxerHysteresisSeconds(for: bufferSeconds)))

        // Parallel demuxing: decode and demux on separate threads.
        // Reduces latency for high-bitrate streams.
        setOption(newHandle, "demuxer-thread", "yes")

        // ffmpeg demuxer tuning. probesize/analyzeduration are ceilings —
        // ffmpeg stops the instant it finds stream info. The large windows
        // only matter for pathological feeds that delay stream headers.
        setOption(newHandle, "demuxer-lavf-probe-info", "auto")
        // genpts fills missing PTS and igndts discards DTS when PTS exists.
        // Neither repairs a provider clock reset interpreted as a 33-bit TS
        // wrap; the archive-only DEBUG experiment handles that separately.
        // http_persistent reuses TCP connections across segments instead of
        // creating a new one for each HLS segment fetch. http_multiple allows
        // parallel downloads, speeding up the initial segment burst.
        // seg_max_retry re-fetches a failed segment (transient 4xx/5xx, socket
        // drop) before the HLS demuxer skips or errors — ffmpeg's default is 0,
        // meaning a single blip mid-stream becomes a visible glitch.
        // extension_picky=0: ffmpeg 8 refuses HLS segments whose filename
        // extension isn't a known media extension; IPTV providers routinely
        // serve segments with arbitrary names.
        let timestamps = ArchiveTimestampRecovery.options(forArchiveLoad: false)
        setOption(newHandle, "demuxer-lavf-o", timestamps.lavf)
        setOption(newHandle, "demuxer-lavf-linearize-timestamps", timestamps.linearize)
        setOption(newHandle, "demuxer-lavf-probesize", "\(MPVLoadProbeOptions.baseline.probeSize)")
        setOption(newHandle, "demuxer-lavf-analyzeduration", "\(MPVLoadProbeOptions.baseline.analyzeDurationSeconds)")
        setOption(newHandle, "demuxer-lavf-buffersize", "\(Tuning.demuxerLavfBufferSize)")

        // Network timeouts. 5 s is enough for any healthy CDN; the app's
        // reconnect policy handles longer outages faster than mpv's timeout.
        setOption(newHandle, "network-timeout", "5")

        // libavformat-level reconnect covers single-segment network hiccups.
        // HLS playlist errors and false-EOF are handled by PlayerSlot's
        // reconnect policy via onPlaybackEnded.
        setOption(newHandle, "stream-lavf-o", Tuning.liveStreamLavfOptions)
        setOption(newHandle, "user-agent", "Buffer/1.0")
        let initErr = mpv_initialize(newHandle)
        if initErr < 0 {
            errorMessage = "mpv_initialize failed: \(String(cString: mpv_error_string(initErr)))"
            mpv_destroy(newHandle)
            handle = nil
            return
        }

        // Observe playback + media-info properties. Userdata is the
        // MPVProperty raw value, which indexes the flat dispatch batch.
        assert(MPV_FORMAT_STRING.rawValue == MPVFormatCode.string && MPV_FORMAT_FLAG.rawValue == MPVFormatCode.flag
               && MPV_FORMAT_INT64.rawValue == MPVFormatCode.int64 && MPV_FORMAT_DOUBLE.rawValue == MPVFormatCode.double)
        mpv_observe_property(newHandle, MPVProperty.pause.userdata, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(newHandle, MPVProperty.width.userdata, "width", MPV_FORMAT_INT64)
        mpv_observe_property(newHandle, MPVProperty.height.userdata, "height", MPV_FORMAT_INT64)
        mpv_observe_property(newHandle, MPVProperty.fps.userdata, "container-fps", MPV_FORMAT_DOUBLE)
        mpv_observe_property(newHandle, MPVProperty.estimatedFps.userdata, "estimated-vf-fps", MPV_FORMAT_DOUBLE)
        mpv_observe_property(newHandle, MPVProperty.videoCodec.userdata, "video-codec", MPV_FORMAT_STRING)
        mpv_observe_property(newHandle, MPVProperty.audioCodec.userdata, "audio-codec", MPV_FORMAT_STRING)
        mpv_observe_property(newHandle, MPVProperty.audioChannels.userdata, "audio-params/channel-count", MPV_FORMAT_INT64)
        mpv_observe_property(newHandle, MPVProperty.audioSampleRate.userdata, "audio-params/samplerate", MPV_FORMAT_INT64)
        mpv_observe_property(newHandle, MPVProperty.hwdec.userdata, "hwdec-current", MPV_FORMAT_STRING)
        mpv_observe_property(newHandle, MPVProperty.pausedForCache.userdata, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(newHandle, MPVProperty.cacheSeconds.userdata, "demuxer-cache-duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(newHandle, MPVProperty.volume.userdata, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(newHandle, MPVProperty.mute.userdata, "mute", MPV_FORMAT_FLAG)
        mpv_observe_property(newHandle, MPVProperty.timePos.userdata, "time-pos", MPV_FORMAT_DOUBLE)
        // Some library versions expose an independent video clock. Unsupported
        // video-pts remains unavailable, never an alias of time-pos.
        mpv_observe_property(newHandle, MPVProperty.videoPTS.userdata, "video-pts", MPV_FORMAT_DOUBLE)
        mpv_observe_property(newHandle, MPVProperty.duration.userdata, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(newHandle, MPVProperty.seekable.userdata, "seekable", MPV_FORMAT_FLAG)
        mpv_observe_property(newHandle, MPVProperty.videoBitrate.userdata, "video-bitrate", MPV_FORMAT_INT64)
        mpv_observe_property(newHandle, MPVProperty.audioBitrate.userdata, "audio-bitrate", MPV_FORMAT_INT64)
        mpv_observe_property(newHandle, MPVProperty.frameDrops.userdata, "frame-drop-count", MPV_FORMAT_INT64)
        mpv_observe_property(newHandle, MPVProperty.decoderFrameDrops.userdata, "decoder-frame-drop-count", MPV_FORMAT_INT64)
        mpv_observe_property(newHandle, MPVProperty.delayedFrames.userdata, "vo-delayed-frame-count", MPV_FORMAT_INT64)
        mpv_observe_property(newHandle, MPVProperty.mistimedFrames.userdata, "mistimed-frame-count", MPV_FORMAT_INT64)
        mpv_observe_property(newHandle, MPVProperty.audioOutput.userdata, "current-ao", MPV_FORMAT_STRING)
        mpv_observe_property(newHandle, MPVProperty.avSync.userdata, "avsync", MPV_FORMAT_DOUBLE)
        mpv_observe_property(newHandle, MPVProperty.demuxerStartTime.userdata, "demuxer-start-time", MPV_FORMAT_DOUBLE)
        startEventPump(handle: newHandle)
        startCacheFloorTimer()

        // Pull warning-level logs into our console so transport/probe
        // failures remain visible without spamming routine track/renderer
        // state on every load.
        mpv_request_log_messages(newHandle, "warn")
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func loadElapsedMilliseconds() -> Double? {
        guard let loadStartedAt else { return nil }
        return Self.milliseconds(loadStartedAt.duration(to: ContinuousClock.now))
    }

    private func reloadBufferSetting() {
        let newValue = BufferSetting.read()
        guard newValue != bufferSeconds else { return }
        bufferSeconds = newValue
        activeCachePauseFloorSeconds = Tuning.cachePauseFloorSeconds(for: newValue)
        activeCachePauseResumeSeconds = Tuning.cachePauseResumeSeconds(for: newValue)
        refreshPlaybackTuningStats()
        guard let handle else { return }
        setRuntimeProperty(handle, "demuxer-max-bytes", Tuning.demuxerMaxBytes(for: newValue, focused: focusedScaling))
        setRuntimeProperty(handle, "demuxer-max-back-bytes", Tuning.demuxerMaxBackBytes(for: newValue, focused: focusedScaling))
        setRuntimeDouble(handle, "cache-secs", Tuning.cacheCapacitySeconds(for: newValue))
        setRuntimeDouble(handle, "demuxer-readahead-secs", Tuning.demuxerReadAheadSeconds(for: newValue))
        setRuntimeDouble(handle, "demuxer-hysteresis-secs", Tuning.demuxerHysteresisSeconds(for: newValue))
        setRuntimeDouble(handle, "cache-pause-wait", Tuning.cachePauseWaitSeconds(for: newValue))
    }

    private func destroy() {
        redirectResolutionTask?.cancel()
        redirectResolutionTask = nil
        playbackControl.stop()
        playbackControl.backgroundSuspended = false
        releaseDisplayPowerAssertion()
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }
        statePollTimer?.cancel()
        statePollTimer = nil
        eventSource?.cancel()
        eventSource = nil
        if let handle { mpv_set_wakeup_callback(handle, nil, nil) }
        if wakeupPipe[0] >= 0 { close(wakeupPipe[0]); wakeupPipe[0] = -1 }
        if wakeupPipe[1] >= 0 { close(wakeupPipe[1]); wakeupPipe[1] = -1 }

        resetRenderContext()
        // `mpv_terminate_destroy` synchronously waits for mpv's internal
        // worker threads to unwind — which can take tens of seconds when
        // the demuxer is mid-reconnect or waiting on a socket read. Hand
        // the handle to a detached queue so main doesn't pin waiting for
        // teardown. Everything else on `self` has already been released
        // above, so it's safe to let the handle die outside this actor.
        if let capturedHandle = handle {
            let capturedHandleBits = UInt(bitPattern: capturedHandle)
            handle = nil
            DispatchQueue.global(qos: .userInitiated).async {
                if let capturedHandle = OpaquePointer(bitPattern: capturedHandleBits) {
                    mpv_terminate_destroy(capturedHandle)
                }
            }
        }
    }

    // MARK: - Event pump

    private func startEventPump(handle: OpaquePointer) {
        // Use a pipe as a GCD-friendly wakeup channel. mpv calls our wakeup
        // callback from whatever thread — we write to the pipe, GCD reads
        // it on the main queue and drains events. Keeps everything on the
        // main actor without a dedicated thread.
        guard pipe(&wakeupPipe) == 0 else {
            errorMessage = "pipe() failed"
            return
        }

        let readFD = wakeupPipe[0]
        let writeFD = wakeupPipe[1]
        _ = fcntl(readFD, F_SETFL, O_NONBLOCK)
        _ = fcntl(writeFD, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: .main)
        source.setEventHandler { [weak self] in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { buffer in
                _ = read(readFD, buffer.baseAddress, buffer.count)
            }
            self?.drainEvents()
        }
        source.resume()
        eventSource = source

        // mpv_set_wakeup_callback ctx is the write-side of the pipe
        let writePtr = UnsafeMutableRawPointer(bitPattern: UInt(writeFD))
        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx else { return }
            let fd = Int32(truncatingIfNeeded: UInt(bitPattern: Int(bitPattern: ctx)))
            var one: UInt8 = 1
            _ = write(fd, &one, 1)
        }, writePtr)
    }

    private func drainEvents() {
        defer { completeBackendTeardownIfIdle() }
        guard let handle else { return }
        // One stack-resident SoA batch per wakeup; a reset clears two masks.
        var pending = MPVPropertyBatch()
        // Monotonic receipt time, read at most once per wakeup.
        var uptime = Double.nan
        while true {
            let evtPtr = mpv_wait_event(handle, 0)
            guard let evt = evtPtr?.pointee else {
                applyPendingChanges(&pending, uptime: &uptime)
                return
            }
            switch evt.event_id {
            case MPV_EVENT_NONE:
                applyPendingChanges(&pending, uptime: &uptime)
                return
            case MPV_EVENT_SHUTDOWN:
                applyPendingChanges(&pending, uptime: &uptime)
                return
            case MPV_EVENT_PROPERTY_CHANGE:
                if let property = MPVProperty.from(userdata: evt.reply_userdata),
                   property.isHandleProperty || itemLifecycle.activeIdentity != nil,
                   let prop = evt.data?.assumingMemoryBound(to: mpv_event_property.self).pointee {
                    collectProperty(property, prop: prop, into: &pending, uptime: &uptime)
                }
            case MPV_EVENT_GET_PROPERTY_REPLY:
                if let request = propertyRequests.remove(requestID: evt.reply_userdata),
                   playbackControl.acceptsLoad(request.generation),
                   request.property.isHandleProperty || itemLifecycle.acceptsProperty(for: request.item),
                   let prop = evt.data?.assumingMemoryBound(to: mpv_event_property.self).pointee {
                    collectProperty(request.property, prop: prop, into: &pending, uptime: &uptime)
                }
            case MPV_EVENT_COMMAND_REPLY:
                if let completion = itemLifecycle.complete(
                    requestID: evt.reply_userdata,
                    playlistEntryID: Self.playlistEntryID(from: evt)
                ) {
                    pending.reset()
                    if let loaded = completion.loaded { handleFileLoaded(identity: loaded) }
                    if let ended = completion.ended { handleCurrentItemEnded(ended) }
                    if evt.error < 0, completion.request.generation == loadGeneration,
                       case .load = completion.request.command {
                        handleCurrentItemEnded(.init(
                            identity: .init(generation: loadGeneration, playlistEntryID: -1),
                            reason: .error(code: evt.error, message: String(cString: mpv_error_string(evt.error)))
                        ))
                    }
                    if let next = completion.next { submitItemCommand(next) }
                }
            case MPV_EVENT_SET_PROPERTY_REPLY:
                if evt.error < 0, (evt.reply_userdata & (1 << 63)) != 0 {
                    AppLog.playback.error("mpv pause write failed code=\(evt.error, privacy: .public)")
                }
                if startupTargetEnabled, startupHoldActive,
                   let write = playbackControl.inFlightPauseWrite, write.id == evt.reply_userdata {
                    if evt.error >= 0, write.paused {
                        startupPauseConfirmedGeneration = loadGeneration
                    } else if evt.error < 0 {
                        startupPauseConfirmedGeneration = nil
                        pendingStartupLoad = nil
                        startupTargetTimedOut = true
                        setState(\.isLoading, false)
                        errorMessage = "The startup pause could not be applied safely."
                    }
                }
                if let write = playbackControl.completePauseWrite(id: evt.reply_userdata) {
                    submitPauseWrite(write)
                }
                startTargetLoadIfPauseConfirmed()
            case MPV_EVENT_START_FILE:
                pending.reset()
                if let start = evt.data?.assumingMemoryBound(to: mpv_event_start_file.self).pointee {
                    itemLifecycle.started(playlistEntryID: start.playlist_entry_id)
                    if let identity = itemLifecycle.activeIdentity {
                        noteStartupPhase(.startFile, generation: identity.generation)
                    }
                    if itemLifecycle.activeIdentity != nil { errorMessage = nil }
                    AppLog.playback.debug("mpv start-file entry=\(start.playlist_entry_id, privacy: .public)")
                }
            case MPV_EVENT_FILE_LOADED:
                if let loaded = itemLifecycle.loaded() {
                    applyPendingChanges(&pending, uptime: &uptime)
                    handleFileLoaded(identity: loaded)
                }
                pending.reset()
            case MPV_EVENT_END_FILE:
                pending.reset()
                if let end = evt.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
                    handleEndFileEvent(end)
                }
            case MPV_EVENT_LOG_MESSAGE:
                if let msg = evt.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee,
                   let text = msg.text {
                    emitMPVLog(String(cString: text))
                }
            default:
                break
            }
        }
    }

    private func handleFileLoaded(identity: MPVItemLifecycle.Identity) {
        guard playbackControl.acceptsLoad(identity.generation),
              itemLifecycle.loadedIdentity == identity, lastFileLoadedIdentity != identity else { return }
        errorMessage = nil
        lastFileLoadedIdentity = identity
        fileLoadedGeneration = identity.generation
        noteStartupPhase(.fileLoaded, generation: identity.generation)
        applyPlaybackPauseState()
        if !startupHoldActive { setState(\.isLoading, false) }
        startupTargetHold?.fileLoaded(generation: identity.generation, at: ProcessInfo.processInfo.systemUptime)
        let elapsedMs = loadElapsedMilliseconds().map { Int($0.rounded()) } ?? -1
        if elapsedMs >= 0 { PerfMetrics.shared.record("playback.loadToFileLoadedMs", Double(elapsedMs)) }
        AppLog.playback.info("mpv file-loaded generation=\(identity.generation, privacy: .public) entry=\(identity.playlistEntryID, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)")
        onFileLoaded?()
        // Seed properties which may have changed before the command reply
        // bound this entry. Reads are asynchronous and retain entry identity.
        requestProperty(.pause, "pause", MPV_FORMAT_FLAG)
        requestProperty(.width, "width", MPV_FORMAT_INT64)
        requestProperty(.height, "height", MPV_FORMAT_INT64)
        requestProperty(.fps, "container-fps", MPV_FORMAT_DOUBLE)
        requestProperty(.estimatedFps, "estimated-vf-fps", MPV_FORMAT_DOUBLE)
        requestProperty(.videoCodec, "video-codec", MPV_FORMAT_STRING)
        requestProperty(.audioCodec, "audio-codec", MPV_FORMAT_STRING)
        requestProperty(.audioChannels, "audio-params/channel-count", MPV_FORMAT_INT64)
        requestProperty(.audioSampleRate, "audio-params/samplerate", MPV_FORMAT_INT64)
        requestProperty(.hwdec, "hwdec-current", MPV_FORMAT_STRING)
        requestProperty(.cacheSeconds, "demuxer-cache-duration", MPV_FORMAT_DOUBLE)
        requestProperty(.pausedForCache, "paused-for-cache", MPV_FORMAT_FLAG)
        requestProperty(.timePos, "time-pos", MPV_FORMAT_DOUBLE)
        requestProperty(.videoPTS, "video-pts", MPV_FORMAT_DOUBLE)
        requestProperty(.duration, "duration", MPV_FORMAT_DOUBLE)
        requestProperty(.seekable, "seekable", MPV_FORMAT_FLAG)
        requestProperty(.audioOutput, "current-ao", MPV_FORMAT_STRING)
        requestProperty(.avSync, "avsync", MPV_FORMAT_DOUBLE)
        requestProperty(.demuxerStartTime, "demuxer-start-time", MPV_FORMAT_DOUBLE)
        requestProperty(.cachePauseInitial, "options/cache-pause-initial", MPV_FORMAT_FLAG)
        requestProperty(.cachePauseWait, "options/cache-pause-wait", MPV_FORMAT_DOUBLE)
        requestProperty(.lavfAnalyzeDuration, "options/demuxer-lavf-analyzeduration", MPV_FORMAT_DOUBLE)
        requestProperty(.lavfProbeSize, "options/demuxer-lavf-probesize", MPV_FORMAT_INT64)
        requestProperty(.lavfProbeInfo, "options/demuxer-lavf-probe-info", MPV_FORMAT_STRING)
    }

    private func handleEndFileEvent(_ event: mpv_event_end_file) {
        if event.reason == MPV_END_FILE_REASON_REDIRECT, event.playlist_insert_num_entries > 0 {
            itemLifecycle.redirected(playlistEntryID: event.playlist_entry_id,
                                     first: event.playlist_insert_id,
                                     count: Int(event.playlist_insert_num_entries))
            return
        }

        let endReason: MPVEndReason
        switch event.reason {
        case MPV_END_FILE_REASON_STOP, MPV_END_FILE_REASON_QUIT, MPV_END_FILE_REASON_REDIRECT:
            endReason = .stopped
        case MPV_END_FILE_REASON_EOF:
            endReason = .eof
        case MPV_END_FILE_REASON_ERROR:
            // Check if the preceding log messages indicated a 509.
            // Since we excluded 509 from reconnect_on_http_error,
            // it surfaces here immediately instead of after retries.
            if lastHTTPStatusCode == 509 {
                let message = event.error < 0
                    ? String(cString: mpv_error_string(event.error))
                    : "unknown playback error"
                endReason = .http509(message: "HTTP 509: \(message)")
            } else {
                let message = event.error < 0
                    ? String(cString: mpv_error_string(event.error))
                    : "unknown playback error"
                endReason = .error(code: event.error, message: message)
            }
        default:
            endReason = .stopped
        }
        guard let ended = itemLifecycle.ended(playlistEntryID: event.playlist_entry_id, reason: endReason) else { return }
        handleCurrentItemEnded(ended)
    }

    private func handleCurrentItemEnded(_ ended: MPVItemLifecycle.End) {
        guard playbackControl.acceptsLoad(ended.identity.generation) else { return }
        let endReason = ended.reason
        setState(\.isPlaying, false)
        updateBufferingState(false, source: "end-file")
        setState(\.isLoading, false)
        updateDisplayPowerAssertion()
        lastHTTPStatusCode = 0
        AppLog.playback.info("mpv end-file generation=\(ended.identity.generation, privacy: .public) entry=\(ended.identity.playlistEntryID, privacy: .public) reason=\(String(describing: endReason), privacy: .public)")

        // If an owner has installed a recovery handler, let it decide what
        // the user sees — it may be about to silently reconnect, in which
        // case surfacing an error banner would flicker the UI for no reason.
        if let handler = onPlaybackEnded {
            handler(endReason)
            return
        }

        // Legacy path for callers that don't handle reconnect themselves
        // (e.g. RecordingPlayback): surface errors directly.
        switch endReason {
        case .error(_, let message):
            errorMessage = "Playback failed: \(message)"
        case .http509(let message):
            errorMessage = "Bandwidth limit: \(message)"
        case .eof, .stopped:
            break
        }
    }

    private func emitMPVLog(_ rawMessage: String) {
        let message = Self.sanitizedMPVLogMessage(rawMessage)
        // Track the last HTTP status code so handleEndFileEvent can
        // distinguish 509 from transient errors.
        let currentItem = itemLifecycle.activeIdentity != nil
        if currentItem, let code = Self.extractHTTPStatusCode(message) {
            lastHTTPStatusCode = code
        }

        guard !message.isEmpty else { return }

        let category = Self.streamQualityCategory(for: message)
        switch currentItem ? category : "obsolete-item" {
        case "network", "hls", "transport":
            telemetryNetworkWarns += 1
        case "decode":
            telemetryDecodeWarns += 1
        default:
            break
        }

        let key = Self.suppressionKey(for: message)
        let now = Date()
        if var suppression = mpvLogSuppression[key],
           now.timeIntervalSince(suppression.lastEmittedAt) < 2 {
            suppression.suppressedCount += 1
            mpvLogSuppression[key] = suppression
            return
        }

        if let suppression = mpvLogSuppression[key], suppression.suppressedCount > 0 {
            AppLog.playback.debug("mpv suppressed repeated warning category=\(category, privacy: .public) count=\(suppression.suppressedCount, privacy: .public) message=\(message, privacy: .public)")
        }

        mpvLogSuppression[key] = MPVLogSuppression(lastEmittedAt: now, suppressedCount: 0)
        AppLog.playback.warning("mpv category=\(category, privacy: .public) \(message, privacy: .public)")

        if currentItem, let issue = Self.streamIssue(for: message) {
            onStreamIssue?(issue)
        }
    }

    /// Extracts an HTTP status code from an mpv log message. Matches patterns
    /// like "HTTP error 509", "Server returned 5XX", "HTTP 429".
    private static let httpStatusRegexes: [NSRegularExpression] = {
        // Hardcoded patterns; try! is appropriate here (build-time failure on malformed regex).
        [
            try! NSRegularExpression(pattern: #"HTTP error (\d{3})"#, options: .caseInsensitive),
            try! NSRegularExpression(pattern: #"Server returned (\d{3})"#, options: .caseInsensitive),
            try! NSRegularExpression(pattern: #"HTTP (\d{3})"#, options: .caseInsensitive),
        ]
    }()

    private static func extractHTTPStatusCode(_ message: String) -> Int? {
        // ffmpeg formats: "HTTP error 509 Not Found" or "Server returned 5XX ..."
        for pattern in httpStatusRegexes {
            if let match = pattern.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: message),
               let code = Int(message[range]) {
                return code
            }
        }
        return nil
    }

    private static func sanitizedMPVLogMessage(_ rawMessage: String) -> String {
        var message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return "" }

        message = message.replacingOccurrences(
            of: #"secret_token=[^'"\s&]+"#,
            with: "secret_token=<redacted>",
            options: .regularExpression
        )
        message = message.replacingOccurrences(
            of: #"://([^/\s'"]+)/live/[^'"\s]+"#,
            with: "://$1/live/<redacted>",
            options: .regularExpression
        )
        message = message.replacingOccurrences(
            of: #"(https?)://([^/\s'"]+)/[^'"\s]+"#,
            with: "$1://$2/<redacted>",
            options: .regularExpression
        )
        return message
    }

    private static func streamIssue(for message: String) -> MPVStreamIssue? {
        let lowercased = message.lowercased()
        if lowercased.contains("failed to reload playlist") {
            return .hlsReloadFailed(message)
        }
        if lowercased.contains("http error") || lowercased.contains("server returned") {
            return .httpError(message)
        }
        if lowercased.contains("will reconnect") {
            return .reconnecting(message)
        }
        return nil
    }

    private static func suppressionKey(for message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("stream ends prematurely") {
            return "https: Stream ends prematurely"
        }
        return message
    }

    private static func streamQualityCategory(for message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("stream ends prematurely") ||
            lowercased.contains("error reading packet") ||
            lowercased.contains("http error") ||
            lowercased.contains("server returned") ||
            lowercased.contains("connection") ||
            lowercased.contains("tls:") ||
            lowercased.contains("will reconnect") ||
            lowercased.contains("end of file") {
            return "network"
        }
        if lowercased.contains("hls:") || lowercased.contains("playlist") || lowercased.contains("segment") {
            return "hls"
        }
        if lowercased.contains("mpegts:") || lowercased.contains("packet corrupt") || lowercased.contains("invalid audio pts") {
            return "transport"
        }
        if lowercased.contains("h264:") ||
            lowercased.contains("hevc:") ||
            lowercased.contains("nalu") ||
            lowercased.contains("no frame") ||
            lowercased.contains("non-existing pps") {
            return "decode"
        }
        if lowercased.contains("desynchronisation") ||
            lowercased.contains("audio/video") ||
            lowercased.contains("audio device underrun") ||
            lowercased.contains("channel layout") {
            return "av-sync"
        }
        return "mpv"
    }

    private func resetMediaTrackState() {
        containerFps = 0
        estimatedFps = 0
        mediaInfo = MPVMediaInfo()
        lastHTTPStatusCode = 0
    }

    private func resetLoadTelemetry() {
        preciseCacheSample.reset()
        rawTimeSample.reset()
        videoPTSSample.reset()
        startupPhases.reset(generation: loadGeneration, enabled: false)
        telemetryLavfAnalyzeDurationSeconds = nil
        telemetryLavfProbeSize = nil
        telemetryLavfProbeInfo = nil
        telemetryCachePauseInitial = nil
        telemetryCachePauseWaitSeconds = nil
        startupTargetHold = nil
        pendingStartupLoad = nil
        startupPauseConfirmedGeneration = nil
        startupHoldReleasedAtMs = nil
        startupHoldReleaseCacheSeconds = nil
        startupTargetTimedOut = false
        firstFrameElapsedMs = nil
        cacheFloorPauseCount = 0
        telemetryAudioOutput = nil
        telemetryDemuxerStartTime = nil
        telemetryAVSyncSeconds = nil
        telemetryPause = nil
        telemetryPausedForCache = nil
        telemetryRenderedFrameCount = 0
        telemetryLastRenderElapsedMs = nil
        lastRenderedAt = nil
        lastTelemetryFrameDrops = 0
        lastTelemetryDecoderDrops = 0
        lastTelemetryMistimed = 0
        telemetryNetworkWarns = 0
        telemetryDecodeWarns = 0
        lastDrawableWidth = 0
        lastDrawableHeight = 0
        bufferingEventCount = 0
        bufferingTotalMilliseconds = 0
        bufferingStartedAt = nil
        propertyRequests.removeAll()
        var stats = MPVPlaybackStats()
        stats.configuredBufferSeconds = bufferSeconds
        playbackStats = stats
    }

    private func startCacheFloorTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.checkCacheFloor()
        }
        timer.resume()
        statePollTimer = timer
    }

    private func checkCacheFloor() {
        // Do not call mpv_get_property from the main queue here. During TS
        // catchup startup/seek, mpv can hold its dispatch lock while the
        // decoder is reconfiguring; synchronously reading a property from this
        // timer then blocks AppKit's event loop and produces a beach ball.
        // The property observer path updates `cacheSeconds` and calls
        // maintainLiveCacheFloor with the fresh value; this timer only provides
        // a cheap safety pass over the last observed cache value.
        evaluateStartupTarget()
        guard let seconds = telemetryExactCacheSeconds else { return }
        maintainLiveCacheFloor(cacheSeconds: seconds)
    }
    @inline(__always) private func receiptTime(_ uptime: inout Double) -> Double {
        if uptime.isNaN { uptime = ProcessInfo.processInfo.systemUptime }
        return uptime
    }

    /// Decodes one payload into the flat batch. The two playback clocks are
    /// sampled at receipt; everything else is coalesced until the drain ends.
    @inline(__always)
    private func collectProperty(_ property: MPVProperty, prop: mpv_event_property,
                                 into pending: inout MPVPropertyBatch, uptime: inout Double) {
        let format = UInt32(truncatingIfNeeded: prop.format.rawValue)
        let data = UnsafeRawPointer(prop.data)
        switch property {
        case .timePos:
            rawTimeSample.observe(MPVPropertyBatch.finiteDouble(format: format, data: data),
                                  generation: loadGeneration, at: receiptTime(&uptime))
        case .videoPTS:
            videoPTSSample.observe(MPVPropertyBatch.finiteDouble(format: format, data: data),
                                   generation: loadGeneration, at: receiptTime(&uptime))
        default:
            break
        }
        pending.collect(property, format: format, data: data)
    }

    /// Publishes one drain's coalesced changes. Each observed property is
    /// written only when its value actually changed (by its epsilon), so
    /// SwiftUI observers invalidate only for changed fields. Hot comparisons
    /// read the @Observable backing storage to avoid registrar access calls.
    private func applyPendingChanges(_ batch: inout MPVPropertyBatch, uptime: inout Double) {
        guard !batch.isEmpty else { return }

        if batch.has(.pause) {
            let paused = batch.flag(.pause)
            if _isPlaying == paused { isPlaying = !paused }
        }
        if batch.hasAny(MPVPropertyBatch.telemetryMask) {
            // Polled diagnostics, not observed: plain stores.
            if batch.has(.pause) { telemetryPause = batch.flag(.pause) }
            if batch.has(.pausedForCache) { telemetryPausedForCache = batch.flag(.pausedForCache) }
            if batch.has(.audioOutput) {
                telemetryAudioOutput = batch.isUnavailable(.audioOutput) ? nil : batch.audioOutput
            }
            if batch.has(.avSync) { telemetryAVSyncSeconds = batch.optionalDouble(.avSync) }
            if batch.has(.demuxerStartTime) { telemetryDemuxerStartTime = batch.optionalDouble(.demuxerStartTime) }
            if batch.has(.cachePauseInitial) {
                telemetryCachePauseInitial = batch.isUnavailable(.cachePauseInitial) ? nil : batch.flag(.cachePauseInitial)
            }
            if batch.has(.cachePauseWait) { telemetryCachePauseWaitSeconds = batch.optionalDouble(.cachePauseWait) }
            if batch.has(.lavfAnalyzeDuration) {
                telemetryLavfAnalyzeDurationSeconds = batch.optionalDouble(.lavfAnalyzeDuration)
            }
            if batch.has(.lavfProbeSize) {
                telemetryLavfProbeSize = batch.isUnavailable(.lavfProbeSize) ? nil : batch.int64(.lavfProbeSize)
            }
            if batch.has(.lavfProbeInfo) {
                telemetryLavfProbeInfo = batch.isUnavailable(.lavfProbeInfo) ? nil : batch.lavfProbeInfo
            }
        }

        let currentDuration = _duration
        let currentTimePos = _timePos
        let currentIsSeekable = _isSeekable
        let nextDuration = batch.has(.duration) ? batch.double(.duration) : currentDuration
        let nextTimePos = batch.has(.timePos) ? batch.double(.timePos) : currentTimePos
        let nextIsSeekable = batch.has(.seekable) ? batch.flag(.seekable) : currentIsSeekable

        // Media info: decide from stored fields; copy the struct only when a
        // field it holds may change.
        let currentLatency = _mediaInfo.liveLatencySeconds
        var nextLatency = currentLatency
        if nextIsSeekable && nextDuration > 0 && nextDuration.isFinite && nextTimePos.isFinite {
            let targetDelay = min(Double(_bufferSeconds), nextDuration)
            let latency = max(0, nextDuration - nextTimePos - targetDelay)
            if abs((currentLatency ?? 0) - latency) >= Tuning.liveLatencyEpsilon { nextLatency = latency }
        } else {
            nextLatency = nil
        }
        let nextContainerFps = batch.has(.fps) ? batch.double(.fps) : containerFps
        let nextEstimatedFps = batch.has(.estimatedFps) ? batch.double(.estimatedFps) : estimatedFps
        if abs(containerFps - nextContainerFps) >= Tuning.stateEpsilon { containerFps = nextContainerFps }
        if abs(estimatedFps - nextEstimatedFps) >= Tuning.stateEpsilon { estimatedFps = nextEstimatedFps }
        let displayFps = max(nextContainerFps, nextEstimatedFps)
        let fpsChanged = abs(_mediaInfo.fps - displayFps) >= Tuning.stateEpsilon
        if nextLatency != currentLatency || fpsChanged || batch.hasAny(MPVPropertyBatch.mediaInfoMask) {
            var info = _mediaInfo
            if batch.has(.width) { info.width = Int(batch.int64(.width)) }
            if batch.has(.height) { info.height = Int(batch.int64(.height)) }
            if batch.has(.videoCodec) { info.videoCodec = batch.videoCodec }
            if batch.has(.audioCodec) { info.audioCodec = batch.audioCodec }
            if batch.has(.audioChannels) { info.audioChannels = Int(batch.int64(.audioChannels)) }
            if batch.has(.audioSampleRate) { info.audioSampleRate = Int(batch.int64(.audioSampleRate)) }
            if batch.has(.hwdec) { info.hwdec = batch.hwdec }
            info.liveLatencySeconds = nextLatency
            if fpsChanged { info.fps = displayFps }
            if info != _mediaInfo {
                mediaInfo = info
                onMediaInfoChanged?(info)
            }
        }

        if batch.has(.cacheSeconds) {
            let at = receiptTime(&uptime)
            preciseCacheSample.observe(batch.optionalDouble(.cacheSeconds), generation: loadGeneration, at: at)
            if let seconds = preciseCacheSample.currentSeconds(generation: loadGeneration, at: at),
               abs(_cacheSeconds - seconds) >= Tuning.cacheEpsilon {
                cacheSeconds = seconds
            }
        }
        if batch.has(.pausedForCache) {
            updateBufferingState(effectiveBufferingState, source: "mpv")
        }
        if batch.has(.volume) {
            let value = batch.double(.volume)
            if abs(_volume - value) >= Tuning.stateEpsilon { volume = value }
        }
        if batch.has(.mute) {
            let value = batch.flag(.mute)
            if _isMuted != value { isMuted = value }
        }
        if batch.has(.timePos) {
            if abs(currentTimePos - nextTimePos) >= Tuning.timePosEpsilon { timePos = nextTimePos }
            if _isLoading, nextTimePos > 0, !startupHoldActive { isLoading = false }
        }
        if batch.has(.duration), abs(currentDuration - nextDuration) >= Tuning.stateEpsilon { duration = nextDuration }
        if batch.has(.seekable), currentIsSeekable != nextIsSeekable { isSeekable = nextIsSeekable }

        if batch.hasAny(MPVPropertyBatch.statsMask) {
            var stats = _playbackStats
            if batch.has(.fps) { stats.containerFps = batch.double(.fps) }
            if batch.has(.estimatedFps) { stats.estimatedFps = batch.double(.estimatedFps) }
            if batch.has(.videoBitrate) { stats.videoBitrateBps = batch.int64(.videoBitrate) }
            if batch.has(.audioBitrate) { stats.audioBitrateBps = batch.int64(.audioBitrate) }
            if batch.has(.frameDrops) { stats.frameDrops = batch.int64(.frameDrops) }
            if batch.has(.decoderFrameDrops) { stats.decoderFrameDrops = batch.int64(.decoderFrameDrops) }
            if batch.has(.delayedFrames) { stats.delayedFrames = batch.int64(.delayedFrames) }
            if batch.has(.mistimedFrames) { stats.mistimedFrames = batch.int64(.mistimedFrames) }
            if stats != _playbackStats { playbackStats = stats }
        }

        if batch.has(.cacheSeconds) {
            evaluateStartupTarget()
            if let seconds = telemetryExactCacheSeconds {
                maintainLiveCacheFloor(cacheSeconds: seconds)
            }
        }
        updateDisplayPowerAssertion()
    }

    private func updateBufferingState(_ buffering: Bool, source: String) {
        guard isBuffering != buffering else { return }
        setState(\.isBuffering, buffering)

        let now = ContinuousClock.now
        if buffering {
            bufferingStartedAt = now
            bufferingEventCount += 1
            PerfMetrics.shared.increment("playback.bufferingStalls")
            AppLog.playback.warning("buffering begin generation=\(self.loadGeneration, privacy: .public) source=\(source, privacy: .public) event=\(self.bufferingEventCount, privacy: .public) cache=\(self.cacheSeconds, privacy: .public) time=\(self.timePos, privacy: .public) loading=\(self.isLoading, privacy: .public)")
            return
        }

        guard let bufferingStartedAt else { return }
        let elapsedMilliseconds = AppLog.elapsedMilliseconds(since: bufferingStartedAt, now: now)
        self.bufferingStartedAt = nil
        bufferingTotalMilliseconds += elapsedMilliseconds
        PerfMetrics.shared.record("playback.bufferingStallMs", Double(elapsedMilliseconds))
        AppLog.playback.info("buffering end generation=\(self.loadGeneration, privacy: .public) source=\(source, privacy: .public) durationMs=\(elapsedMilliseconds, privacy: .public) totalMs=\(self.bufferingTotalMilliseconds, privacy: .public) events=\(self.bufferingEventCount, privacy: .public) cache=\(self.cacheSeconds, privacy: .public) time=\(self.timePos, privacy: .public)")
    }

    private func maintainLiveCacheFloor(cacheSeconds: Double) {
        guard currentURL?.isFileURL == false,
              !nativeCacheOnlyEnabled,
              playbackRequested,
              !playbackControl.systemSuspended,
              !videoDisabledForBackground,
              !startupHoldActive,
              !isLoading,
              timePos > 0.5,
              cacheSeconds.isFinite, cacheSeconds >= 0 else { return }

        if autoPausedForCacheFloor {
            guard cacheSeconds >= activeCachePauseResumeSeconds else { return }
            autoPausedForCacheFloor = false
            applyPlaybackPauseState()
            refreshPlaybackTuningStats(autoPausedForCacheFloor: false)
            updateDisplayPowerAssertion()
            AppLog.playback.info("cache floor resume cache=\(cacheSeconds, privacy: .public) resume=\(self.activeCachePauseResumeSeconds, privacy: .public)")
            return
        }

        guard isPlaying, cacheSeconds < activeCachePauseFloorSeconds else { return }
        autoPausedForCacheFloor = true
        applyPlaybackPauseState()
        updateBufferingState(true, source: "cache-floor")
        refreshPlaybackTuningStats(autoPausedForCacheFloor: true)
        updateDisplayPowerAssertion()
        cacheFloorPauseCount += 1
        AppLog.playback.warning("cache floor pause cache=\(cacheSeconds, privacy: .public) floor=\(self.activeCachePauseFloorSeconds, privacy: .public) resume=\(self.activeCachePauseResumeSeconds, privacy: .public) count=\(self.cacheFloorPauseCount, privacy: .public)")
    }

    // MARK: - Display sleep prevention

    private var shouldHoldDisplayPowerAssertion: Bool {
        playbackRequested &&
            !playbackControl.systemSuspended &&
            !videoDisabledForBackground &&
            currentURL != nil &&
            (isPlaying || isLoading || isBuffering || autoPausedForCacheFloor)
    }

    private func updateDisplayPowerAssertion() {
        if shouldHoldDisplayPowerAssertion {
            acquireDisplayPowerAssertion()
        } else {
            releaseDisplayPowerAssertion()
        }
    }

#if os(macOS)
    private func acquireDisplayPowerAssertion() {
        guard !holdsDisplayPowerAssertion else { return }
        let reason = "Buffer is playing video" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &displayPowerAssertion
        )
        if result == kIOReturnSuccess {
            holdsDisplayPowerAssertion = true
            AppLog.playback.info("display sleep assertion acquired")
        } else {
            AppLog.playback.warning("display sleep assertion failed result=\(result, privacy: .public)")
        }
    }

    private func releaseDisplayPowerAssertion() {
        guard holdsDisplayPowerAssertion else { return }
        IOPMAssertionRelease(displayPowerAssertion)
        holdsDisplayPowerAssertion = false
        displayPowerAssertion = IOPMAssertionID(0)
        AppLog.playback.info("display sleep assertion released")
    }
#else
    // iOS and tvOS keep the screen awake through the player view's idle
    // timer; only the bookkeeping is shared.
    private func acquireDisplayPowerAssertion() { holdsDisplayPowerAssertion = true }

    private func releaseDisplayPowerAssertion() { holdsDisplayPowerAssertion = false }
#endif

    private func refreshPlaybackTuningStats(
        renderProfile: String? = nil,
        autoPausedForCacheFloor: Bool? = nil
    ) {
        var next = playbackStats
        next.configuredBufferSeconds = bufferSeconds
        next.cachePauseFloorSeconds = activeCachePauseFloorSeconds
        next.cachePauseResumeSeconds = activeCachePauseResumeSeconds
        if let renderProfile {
            next.renderProfile = renderProfile
        }
        if let autoPausedForCacheFloor {
            next.autoPausedForCacheFloor = autoPausedForCacheFloor
        } else {
            next.autoPausedForCacheFloor = self.autoPausedForCacheFloor
        }
        if next != playbackStats {
            playbackStats = next
        }
    }

    private func setState<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<MPVPlayer, Value>, _ value: Value) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    private func setApproxState(_ keyPath: ReferenceWritableKeyPath<MPVPlayer, Double>, _ value: Double, epsilon: Double) {
        guard abs(self[keyPath: keyPath] - value) >= epsilon else { return }
        self[keyPath: keyPath] = value
    }

    // MARK: - C helpers

    private func setOption(_ handle: OpaquePointer, _ name: String, _ value: String) {
        _ = name.withCString { n in
            value.withCString { v in
                mpv_set_option_string(handle, n, v)
            }
        }
    }

    // All runtime control goes through mpv's async request API. The
    // synchronous variants (mpv_command, mpv_set_property, mpv_get_property)
    // block until the core processes the request — and during startup, seeks,
    // or decoder reconfiguration mpv can hold its dispatch lock for hundreds
    // of milliseconds, which beach-balls the main thread (see checkCacheFloor).
    // mpv copies request data before returning, but its API does not guarantee
    // async request order. Pause writes are serialized through completion
    // replies and reconciled again on FILE_LOADED. Get replies carry a load
    // generation so a replaced item's result cannot update the new load.

    private func applyPlaybackPauseState() {
        updateBufferingState(effectiveBufferingState, source: "pause-intent")
        refreshPlaybackTuningStats()
        if let write = playbackControl.reconcilePause() {
            submitPauseWrite(write)
        }
    }

    private var effectiveBufferingState: Bool {
        playbackControl.indicatesBuffering(nativePausedForCache: telemetryPausedForCache ?? false,
                                          startupWaiting: startupHoldActive && !startupTargetTimedOut)
    }

    private func startTargetLoadIfPauseConfirmed() {
        guard startupTargetEnabled, startupHoldActive, !startupTargetTimedOut,
              let pending = pendingStartupLoad, pending.generation == loadGeneration,
              startupPauseConfirmedGeneration == loadGeneration,
              playbackControl.pauseWritesAreSettled else { return }
        pendingStartupLoad = nil
        if let request = itemLifecycle.enqueue(.load(pending.path), generation: pending.generation) {
            submitItemCommand(request)
        }
    }

    private func evaluateStartupTarget() {
        guard startupTargetEnabled, startupHoldActive, !startupTargetTimedOut,
              !playbackControl.systemSuspended else { return }
        switch startupTargetHold?.evaluate(cacheSeconds: telemetryExactCacheSeconds,
                                           generation: loadGeneration, at: ProcessInfo.processInfo.systemUptime) {
        case .ready(let seconds):
            startupHoldReleasedAtMs = loadElapsedMilliseconds().map { Int($0.rounded()) }
            startupHoldReleaseCacheSeconds = seconds
            playbackControl.startupSuspended = false
            setState(\.isLoading, !hasRenderedCurrentLoad)
            applyPlaybackPauseState()
            AppLog.playback.info("startup target release generation=\(self.loadGeneration, privacy: .public) elapsedMs=\(self.startupHoldReleasedAtMs ?? -1, privacy: .public) cache=\(seconds, privacy: .public)")
        case .timedOut:
            startupTargetTimedOut = true
            setState(\.isLoading, false)
            errorMessage = "The reported startup cache did not reach the requested target within 12 seconds."
            applyPlaybackPauseState()
            AppLog.playback.warning("startup target timed out generation=\(self.loadGeneration, privacy: .public)")
        case .waiting, nil:
            break
        }
    }

    private func submitPauseWrite(_ write: PlaybackControlState.PauseWrite) {
        guard let handle else {
            _ = playbackControl.completePauseWrite(id: write.id)
            return
        }
        var flag: Int32 = write.paused ? 1 : 0
        let result = mpv_set_property_async(handle, write.id, "pause", MPV_FORMAT_FLAG, &flag)
        if result < 0 {
            if startupTargetEnabled, startupHoldActive {
                pendingStartupLoad = nil
                startupTargetTimedOut = true
                setState(\.isLoading, false)
                errorMessage = "The startup pause could not be queued safely."
            }
            AppLog.playback.error("mpv pause enqueue failed code=\(result, privacy: .public)")
            if let next = playbackControl.completePauseWrite(id: write.id) {
                submitPauseWrite(next)
            }
        }
    }

    private func setRuntimeProperty(_ handle: OpaquePointer, _ name: String, _ value: String) {
        _ = name.withCString { n in
            value.withCString { v in
                var stringPtr: UnsafeMutablePointer<CChar>? = UnsafeMutablePointer(mutating: v)
                return mpv_set_property_async(handle, 0, n, MPV_FORMAT_STRING, &stringPtr)
            }
        }
    }

    private func setRuntimeDouble(_ handle: OpaquePointer, _ name: String, _ value: Double) {
        var v = value
        _ = name.withCString { n in
            mpv_set_property_async(handle, 0, n, MPV_FORMAT_DOUBLE, &v)
        }
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let handle else { return }
        var flag: Int32 = value ? 1 : 0
        _ = name.withCString { n in
            mpv_set_property_async(handle, 0, n, MPV_FORMAT_FLAG, &flag)
        }
        switch name {
        case "mute":
            setState(\.isMuted, value)
        default:
            break
        }
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard let handle else { return }
        setRuntimeDouble(handle, name, value)
        switch name {
        case "volume":
            setApproxState(\.volume, value, epsilon: Tuning.stateEpsilon)
            if value > 0, isMuted {
                setState(\.isMuted, false)
            }
        default:
            break
        }
    }

    /// Requests a property read; the value arrives as
    /// MPV_EVENT_GET_PROPERTY_REPLY in drainEvents and flows through the same
    /// collectProperty path as observed property changes.
    private func requestProperty(_ id: MPVProperty, _ name: String, _ format: mpv_format) {
        guard let handle else { return }
        let requestID = propertyRequests.insert(generation: loadGeneration, item: itemLifecycle.activeIdentity, property: id)
        let result = name.withCString { n in
            mpv_get_property_async(handle, requestID, n, format)
        }
        if result < 0 { propertyRequests.cancel(requestID: requestID) }
    }

    /// Capture refreshes remain asynchronous, including during a cache pause.
    /// Coalesce outstanding reads rather than queuing them while the core waits.
    func refreshDiagnosticPlaybackClocks() {
#if DEBUG
        guard PlaybackValidation.isEnabled || SavedPlaybackScenario.isCapturing,
              itemLifecycle.loadedIdentity?.generation == loadGeneration else { return }
        if !propertyRequests.containsPending(generation: loadGeneration, property: .timePos) {
            requestProperty(.timePos, "time-pos", MPV_FORMAT_DOUBLE)
        }
        if !propertyRequests.containsPending(generation: loadGeneration, property: .videoPTS) {
            requestProperty(.videoPTS, "video-pts", MPV_FORMAT_DOUBLE)
        }
#endif
    }

    private static func playlistEntryID(from event: mpv_event) -> Int64? {
        guard event.error >= 0,
              let command = event.data?.assumingMemoryBound(to: mpv_event_command.self).pointee,
              command.result.format == MPV_FORMAT_NODE_MAP,
              let list = command.result.u.list?.pointee,
              let keys = list.keys, let values = list.values else { return nil }
        for index in 0..<Int(list.num) {
            if let key = keys[index], String(cString: key) == "playlist_entry_id",
               values[index].format == MPV_FORMAT_INT64 {
                return values[index].u.int64
            }
        }
        return nil
    }

    private func submitItemCommand(_ request: MPVItemLifecycle.Request) {
        guard request.generation == loadGeneration, let handle else {
            _ = itemLifecycle.complete(requestID: request.id, playlistEntryID: nil)
            return
        }
        let args: [String]
        switch request.command {
        case .load(let path):
            // Bind startup settings to this actual playlist entry. An async
            // property write racing loadfile cannot prove which load used it.
            // mpv 0.38+ puts per-file options after the insertion index.
            var startup = "cache-pause-initial=\(usesStartupReserve ? "yes" : "no"),cache-pause-wait=\(Tuning.cachePauseWaitSeconds(for: bufferSeconds)),\(loadProbeOptions.perFileOptions)"
            if startupTargetEnabled { startup += ",pause=yes" }
            args = ["loadfile", path, "replace", "-1", startup]
        case .stop: args = ["stop"]
        }
        let result = command(handle, args, replyID: request.id)
        if result >= 0, case .load = request.command {
            noteStartupPhase(.loadSubmitted, generation: request.generation)
        }
        if result < 0 {
            let completion = itemLifecycle.complete(requestID: request.id, playlistEntryID: nil)
            if case .load = request.command {
                handleCurrentItemEnded(.init(identity: .init(generation: request.generation, playlistEntryID: -1),
                                             reason: .error(code: result, message: String(cString: mpv_error_string(result)))))
            }
            if let next = completion?.next { submitItemCommand(next) }
        }
    }

    private func noteStartupPhase(_ phase: MPVStartupPhases.Phase, generation: Int) {
        guard let elapsed = loadElapsedMilliseconds() else { return }
        startupPhases.note(phase, generation: generation, elapsedMilliseconds: elapsed)
    }

    @discardableResult
    private func command(_ handle: OpaquePointer, _ args: [String], replyID: UInt64 = 0) -> Int32 {
        let duped: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        var cStrings: [UnsafePointer<CChar>?] = duped.map { UnsafePointer($0) }
        cStrings.append(nil)
        defer { duped.forEach { if let p = $0 { free(p) } } }
        return cStrings.withUnsafeMutableBufferPointer { buf in
            mpv_command_async(handle, replyID, buf.baseAddress)
        }
    }

}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
