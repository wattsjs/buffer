import Foundation
import Libmpv
import Observation

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

enum MPVEndReason: Equatable, Sendable {
    /// Playback was stopped by a `stop` command or a new `loadfile`.
    case stopped
    /// mpv reached EOF. For live streams this is usually a false EOF and the
    /// owner should reconnect; for finite files it's the end of playback.
    case eof
    /// An mpv error code (see `mpv_error_string`).
    case error(code: Int32, message: String)
}

struct MPVMediaInfo: Equatable, Sendable {
    var width: Int = 0
    var height: Int = 0
    var fps: Double = 0
    var videoCodec: String = ""
    var audioCodec: String = ""
    var audioChannels: Int = 0
    var hwdec: String = ""

    var resolutionLabel: String {
        width > 0 && height > 0 ? "\(width)×\(height)" : ""
    }

    var fpsLabel: String {
        fps > 0 ? "\(Int(fps.rounded(.up))) fps" : ""
    }
}

@MainActor
@Observable
final class MPVPlayer {
    private enum Tuning {
        static let stateEpsilon = 0.01
        static let timePosEpsilon = 0.05
        static let cacheEpsilon = 0.25

        /// mpv's demuxer readahead still matters for how much data can build
        /// up while playback is manually paused. Match it to the user-facing
        /// buffer budget so a paused live stream can keep filling that window.
        static func demuxerReadAheadSeconds(for bufferSeconds: Int) -> Double {
            max(Double(bufferSeconds), 1)
        }

        /// Hysteresis controls how far the cache must drain before mpv resumes
        /// fetching. Keep it at ~40% of the buffer window so there's enough
        /// runway to survive a network hiccup after the demuxer pauses.
        /// Per the mpv manual, this value must be less than cache-secs to
        /// avoid the demuxer never resuming.
        static func demuxerHysteresisSeconds(for bufferSeconds: Int) -> Double {
            let secs = Double(bufferSeconds)
            return max(min(secs * 0.4, secs - 1), 0)
        }
    }

    private(set) var mediaInfo = MPVMediaInfo()
    private(set) var isPlaying = false
    private(set) var errorMessage: String?
    private(set) var cacheSeconds: Double = 0
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
    private(set) var duration: Double = 0
    private(set) var isSeekable: Bool = false
    /// Last URL handed to `loadURL`. Used by callers to avoid redundant
    /// `loadURL` calls when handing off a player.
    private(set) var currentURL: URL?

    /// Called whenever mpv fires MPV_EVENT_END_FILE. When non-nil, MPVPlayer
    /// suppresses its automatic `errorMessage` for error/EOF reasons — the
    /// handler owns recovery policy (silent reconnect, user-facing error, etc).
    /// Leaving this `nil` keeps the legacy behaviour for callers that prefer a
    /// simple "show error to user" flow (e.g. recording playback of a finite
    /// file, where a retry makes no sense).
    var onPlaybackEnded: ((MPVEndReason) -> Void)?

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

    private var containerFps: Double = 0
    private var estimatedFps: Double = 0

    private var handle: OpaquePointer?
    private(set) var renderContext: OpaquePointer?
    private var wakeupPipe: [Int32] = [-1, -1]
    private var eventSource: DispatchSourceRead?
    private var statePollTimer: DispatchSourceTimer?
    private var bufferSeconds: Int = BufferSetting.read()
    private var defaultsObserver: NSObjectProtocol?

    init() {
        setupMPV()
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

    func loadURL(_ url: URL, autoplay: Bool = false, fastProbe: Bool = false) {
        guard let handle else { return }
        errorMessage = nil
        resetMediaTrackState()
        timePos = 0
        duration = 0
        isSeekable = false
        cacheSeconds = 0
        isBuffering = false
        setFlag("pause", !autoplay)
        isPlaying = autoplay
        isLoading = true
        currentURL = url

        // Fast-probe path is used for known local MPEG-TS sources (recording
        // files + the tail-follow proxy). With the default 1 MiB probesize +
        // 2 s analyzeduration, mpv's ffmpeg demuxer can spend 5–10 s scanning
        // the head of a multi-gigabyte .ts file before reporting stream info.
        // For MPEG-TS the SPS usually lands in the first few KB, so shrinking
        // the probe window by ~16x trims the open delay without losing
        // detection. Restored to the safe HLS defaults on the next non-fast
        // load so channel streams aren't affected.
        if fastProbe {
            setRuntimeProperty(handle, "demuxer-lavf-probesize", "65536")
            setRuntimeProperty(handle, "demuxer-lavf-analyzeduration", "0.1")
        } else {
            setRuntimeProperty(handle, "demuxer-lavf-probesize", "1048576")
            setRuntimeProperty(handle, "demuxer-lavf-analyzeduration", "2.0")
        }

        let path = url.absoluteString
        command(handle, ["loadfile", path, "replace"])
        setFlag("pause", !autoplay)
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

    func play() {
        setFlag("pause", false)
        isPlaying = true
    }

    func pause() {
        setFlag("pause", true)
        isPlaying = false
    }

    func togglePause() {
        isPlaying ? pause() : play()
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

    /// Adjust buffer sizes and polling rate based on whether this player is
    /// in a multi-view grid and whether it holds focus (audio + controls).
    /// Non-focused players get smaller demuxer buffers and slower state
    /// polling to free CPU, memory, and main-thread time for the focused
    /// stream.
    func configureResources(multiView: Bool, focused: Bool) {
        guard let handle else { return }

        let maxBytes: String
        let maxBackBytes: String
        let pollMs: Int
        let cacheSecs: Int

        if !multiView {
            maxBytes = "64MiB"
            maxBackBytes = "8MiB"
            pollMs = 250
            cacheSecs = bufferSeconds
        } else if focused {
            maxBytes = "32MiB"
            maxBackBytes = "4MiB"
            pollMs = 250
            cacheSecs = bufferSeconds
        } else {
            maxBytes = "16MiB"
            maxBackBytes = "2MiB"
            pollMs = 1000
            cacheSecs = max(bufferSeconds / 2, 1)
        }

        setRuntimeProperty(handle, "demuxer-max-bytes", maxBytes)
        setRuntimeProperty(handle, "demuxer-max-back-bytes", maxBackBytes)

        var cacheVal = Double(cacheSecs)
        _ = "cache-secs".withCString { n in
            mpv_set_property(handle, n, MPV_FORMAT_DOUBLE, &cacheVal)
        }
        var readahead = Tuning.demuxerReadAheadSeconds(for: cacheSecs)
        _ = "demuxer-readahead-secs".withCString { n in
            mpv_set_property(handle, n, MPV_FORMAT_DOUBLE, &readahead)
        }
        var hysteresis = Tuning.demuxerHysteresisSeconds(for: cacheSecs)
        _ = "demuxer-hysteresis-secs".withCString { n in
            mpv_set_property(handle, n, MPV_FORMAT_DOUBLE, &hysteresis)
        }

        statePollTimer?.schedule(
            deadline: .now() + .milliseconds(pollMs),
            repeating: .milliseconds(pollMs),
            leeway: .milliseconds(max(pollMs / 4, 50))
        )
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
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiBuf.baseAddress!)),
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
        return true
    }

    func setRenderUpdateCallback(_ cb: @escaping mpv_render_update_fn, context: UnsafeMutableRawPointer?) {
        guard let ctx = renderContext else { return }
        mpv_render_context_set_update_callback(ctx, cb, context)
    }

    func resetRenderContext() {
        if let ctx = renderContext {
            mpv_render_context_set_update_callback(ctx, nil, nil)
            mpv_render_context_free(ctx)
            renderContext = nil
        }
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
        setOption(newHandle, "hwdec", "videotoolbox")
        setOption(newHandle, "hwdec-codecs", "all")
        setOption(newHandle, "vd-lavc-dr", "auto")
        // Auto thread count explodes to one H.264 frame thread per core on Apple
        // Silicon, which shows up as 16 av:h264:df* threads in Instruments even
        // when VideoToolbox is active. Keep software fallback available, but cap
        // it to a small pool so playback doesn't burn CPU on scheduler churn.
        setOption(newHandle, "vd-lavc-threads", "2")
        setOption(newHandle, "video-sync", "audio")
        setOption(newHandle, "video-timing-offset", "0.025")
        setOption(newHandle, "interpolation", "no")
        setOption(newHandle, "opengl-swapinterval", "0")
        setOption(newHandle, "swapchain-depth", "2")
        setOption(newHandle, "scale", "bilinear")
        setOption(newHandle, "cscale", "bilinear")
        setOption(newHandle, "dscale", "bilinear")
        setOption(newHandle, "deband", "no")
        setOption(newHandle, "dither", "no")
        setOption(newHandle, "sigmoid-upscaling", "no")
        setOption(newHandle, "correct-downscaling", "no")
        setOption(newHandle, "linear-downscaling", "no")
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
        setOption(newHandle, "volume", "100")
        setOption(newHandle, "volume-max", "130")

        // Live HLS tuning — keep the cache short so IPTV streams stay close to live.
        setOption(newHandle, "cache", "yes")
        setOption(newHandle, "cache-secs", String(bufferSeconds))
        setOption(newHandle, "cache-pause", "no")
        setOption(newHandle, "cache-pause-initial", "no")
        setOption(newHandle, "demuxer-max-bytes", "64MiB")
        setOption(newHandle, "demuxer-max-back-bytes", "8MiB")
        setOption(newHandle, "demuxer-readahead-secs", String(Tuning.demuxerReadAheadSeconds(for: bufferSeconds)))
        setOption(newHandle, "demuxer-hysteresis-secs", String(Tuning.demuxerHysteresisSeconds(for: bufferSeconds)))
        // The `low-latency` profile sets `demuxer-lavf-probe-info=nostreams`
        // and shrinks the probe window to almost nothing — ffmpeg never reads
        // enough to extract fps/codec/audio-params from the HLS TS segments,
        // and mpv reports empty `container-fps`.
        //
        // Both `probesize` and `analyzeduration` are ceilings: ffmpeg stops
        // probing the instant it finds stream info (the H.264 SPS is usually
        // in the first ~10 KB / <0.5 s), so bumping them has no effect on
        // startup latency for normal HLS — the larger window only kicks in
        // for pathological feeds that delay stream headers.
        setOption(newHandle, "demuxer-lavf-probe-info", "auto")
        setOption(newHandle, "demuxer-lavf-probesize", "1048576")
        setOption(newHandle, "demuxer-lavf-analyzeduration", "2.0")
        setOption(newHandle, "network-timeout", "10")
        // libavformat-level reconnect covers single-socket network hiccups
        // inside one segment fetch. It does NOT recover from HLS playlist
        // errors, demuxer parse failures, or false-EOF — those surface as
        // MPV_EVENT_END_FILE and are handled by the owner via `onPlaybackEnded`
        // (see PlayerSlot's reconnect policy).
        setOption(newHandle, "stream-lavf-o",
                  "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_on_http_error=5xx,reconnect_delay_max=5")
        setOption(newHandle, "user-agent", "Buffer/1.0")

        let initErr = mpv_initialize(newHandle)
        if initErr < 0 {
            errorMessage = "mpv_initialize failed: \(String(cString: mpv_error_string(initErr)))"
            mpv_destroy(newHandle)
            handle = nil
            return
        }

        // Observe playback + media-info properties
        mpv_observe_property(newHandle, PropID.pause.rawValue, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(newHandle, PropID.width.rawValue, "width", MPV_FORMAT_INT64)
        mpv_observe_property(newHandle, PropID.height.rawValue, "height", MPV_FORMAT_INT64)
        mpv_observe_property(newHandle, PropID.fps.rawValue, "container-fps", MPV_FORMAT_DOUBLE)
        mpv_observe_property(newHandle, PropID.estimatedFps.rawValue, "estimated-vf-fps", MPV_FORMAT_DOUBLE)
        mpv_observe_property(newHandle, PropID.videoCodec.rawValue, "video-codec", MPV_FORMAT_STRING)
        mpv_observe_property(newHandle, PropID.audioCodec.rawValue, "audio-codec", MPV_FORMAT_STRING)
        mpv_observe_property(newHandle, PropID.audioChannels.rawValue, "audio-params/channel-count", MPV_FORMAT_INT64)
        mpv_observe_property(newHandle, PropID.hwdec.rawValue, "hwdec-current", MPV_FORMAT_STRING)
        mpv_observe_property(newHandle, PropID.pausedForCache.rawValue, "paused-for-cache", MPV_FORMAT_FLAG)

        startEventPump(handle: newHandle)
        startStatePolling()

        // Pull info+ logs from mpv into our console so diagnostics from
        // async commands (dump-cache open/close, recorder errors, muxer
        // warnings) surface instead of disappearing into mpv's internal
        // logger. Noisy but invaluable when something silently fails.
        mpv_request_log_messages(newHandle, "info")
    }

    private func reloadBufferSetting() {
        let newValue = BufferSetting.read()
        guard newValue != bufferSeconds else { return }
        bufferSeconds = newValue
        guard let handle else { return }
        var value = Double(newValue)
        _ = "cache-secs".withCString { n in
            mpv_set_property(handle, n, MPV_FORMAT_DOUBLE, &value)
        }
        var readahead = Tuning.demuxerReadAheadSeconds(for: newValue)
        _ = "demuxer-readahead-secs".withCString { n in
            mpv_set_property(handle, n, MPV_FORMAT_DOUBLE, &readahead)
        }
        var hysteresis = Tuning.demuxerHysteresisSeconds(for: newValue)
        _ = "demuxer-hysteresis-secs".withCString { n in
            mpv_set_property(handle, n, MPV_FORMAT_DOUBLE, &hysteresis)
        }
    }

    private func destroy() {
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }
        statePollTimer?.cancel()
        statePollTimer = nil
        eventSource?.cancel()
        eventSource = nil
        if wakeupPipe[0] >= 0 { close(wakeupPipe[0]); wakeupPipe[0] = -1 }
        if wakeupPipe[1] >= 0 { close(wakeupPipe[1]); wakeupPipe[1] = -1 }

        if let ctx = renderContext {
            mpv_render_context_set_update_callback(ctx, nil, nil)
            mpv_render_context_free(ctx)
            renderContext = nil
        }
        // `mpv_terminate_destroy` synchronously waits for mpv's internal
        // worker threads to unwind — which can take tens of seconds when
        // the demuxer is mid-reconnect or waiting on a socket read. Hand
        // the handle to a detached queue so main doesn't pin waiting for
        // teardown. Everything else on `self` has already been released
        // above, so it's safe to let the handle die outside this actor.
        if let capturedHandle = handle {
            handle = nil
            DispatchQueue.global(qos: .userInitiated).async {
                mpv_terminate_destroy(capturedHandle)
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
            var drain = [UInt8](repeating: 0, count: 64)
            _ = drain.withUnsafeMutableBufferPointer {
                read(readFD, $0.baseAddress, $0.count)
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
        guard let handle else { return }
        var pending = PendingChanges()
        while true {
            let evtPtr = mpv_wait_event(handle, 0)
            guard let evt = evtPtr?.pointee else {
                applyPendingChanges(pending)
                return
            }
            switch evt.event_id {
            case MPV_EVENT_NONE:
                applyPendingChanges(pending)
                return
            case MPV_EVENT_SHUTDOWN:
                applyPendingChanges(pending)
                return
            case MPV_EVENT_PROPERTY_CHANGE:
                if let prop = evt.data?.assumingMemoryBound(to: mpv_event_property.self).pointee {
                    collectProperty(id: evt.reply_userdata, prop: prop, into: &pending)
                }
            case MPV_EVENT_START_FILE:
                errorMessage = nil
            case MPV_EVENT_FILE_LOADED:
                errorMessage = nil
                if let paused = readFlagProperty("pause") {
                    pending.isPlaying = !paused
                }
                if let fps = readDoubleProperty("container-fps") {
                    pending.containerFps = max(pending.containerFps ?? 0, fps)
                } else {
                    pending.containerFps = pending.containerFps ?? 0
                }
                if let fps = readDoubleProperty("estimated-vf-fps") {
                    pending.estimatedFps = max(pending.estimatedFps ?? 0, fps)
                } else {
                    pending.estimatedFps = pending.estimatedFps ?? 0
                }
                collectPolledState(into: &pending)
            case MPV_EVENT_END_FILE:
                if let end = evt.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
                    handleEndFileEvent(end)
                }
            case MPV_EVENT_LOG_MESSAGE:
                if let msg = evt.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee,
                   let text = msg.text {
                    print("[mpv] \(String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            default:
                break
            }
        }
    }

    private func handleEndFileEvent(_ event: mpv_event_end_file) {
        setState(\.isPlaying, false)
        setState(\.isBuffering, false)
        setState(\.isLoading, false)

        let endReason: MPVEndReason
        switch event.reason {
        case MPV_END_FILE_REASON_STOP, MPV_END_FILE_REASON_QUIT, MPV_END_FILE_REASON_REDIRECT:
            endReason = .stopped
        case MPV_END_FILE_REASON_EOF:
            endReason = .eof
        case MPV_END_FILE_REASON_ERROR:
            let message = event.error < 0
                ? String(cString: mpv_error_string(event.error))
                : "unknown playback error"
            endReason = .error(code: event.error, message: message)
        default:
            endReason = .stopped
        }

        // If an owner has installed a recovery handler, let it decide what
        // the user sees — it may be about to silently reconnect, in which
        // case surfacing an error banner would flicker the UI for no reason.
        if let handler = onPlaybackEnded {
            handler(endReason)
            return
        }

        // Legacy path for callers that don't handle reconnect themselves
        // (e.g. RecordingPlayback): surface errors directly.
        if case .error(_, let message) = endReason {
            errorMessage = "Playback failed: \(message)"
        }
    }

    private func resetMediaTrackState() {
        containerFps = 0
        estimatedFps = 0
        mediaInfo = MPVMediaInfo()
    }

    private func startStatePolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.pollPlayerState()
        }
        timer.resume()
        statePollTimer = timer
    }

    private func pollPlayerState() {
        guard handle != nil else { return }
        var pending = PendingChanges()
        collectPolledState(into: &pending)
        applyPendingChanges(pending)
    }

    private func collectPolledState(into pending: inout PendingChanges) {
        pending.cacheSeconds = readDoubleProperty("demuxer-cache-duration") ?? 0
        pending.volume = readDoubleProperty("volume")
        pending.isMuted = readFlagProperty("mute")
        pending.timePos = readDoubleProperty("time-pos")
        pending.duration = readDoubleProperty("duration") ?? 0
        pending.isSeekable = readFlagProperty("seekable")
    }

    private enum PropID: UInt64 {
        case pause = 1
        case width
        case height
        case fps
        case estimatedFps
        case videoCodec
        case audioCodec
        case audioChannels
        case hwdec
        case pausedForCache
    }

    private struct PendingChanges {
        var isPlaying: Bool?
        var width: Int?
        var height: Int?
        var containerFps: Double?
        var estimatedFps: Double?
        var videoCodec: String?
        var audioCodec: String?
        var audioChannels: Int?
        var hwdec: String?
        var cacheSeconds: Double?
        var isBuffering: Bool?
        var volume: Double?
        var isMuted: Bool?
        var timePos: Double?
        var duration: Double?
        var isSeekable: Bool?

        var hasChanges: Bool {
            isPlaying != nil ||
            width != nil ||
            height != nil ||
            containerFps != nil ||
            estimatedFps != nil ||
            videoCodec != nil ||
            audioCodec != nil ||
            audioChannels != nil ||
            hwdec != nil ||
            cacheSeconds != nil ||
            isBuffering != nil ||
            volume != nil ||
            isMuted != nil ||
            timePos != nil ||
            duration != nil ||
            isSeekable != nil
        }
    }

    private func collectProperty(id: UInt64, prop: mpv_event_property, into pending: inout PendingChanges) {
        guard let kind = PropID(rawValue: id) else { return }
        switch kind {
        case .pause:
            if prop.format == MPV_FORMAT_FLAG, let data = prop.data {
                pending.isPlaying = data.assumingMemoryBound(to: Int32.self).pointee == 0
            }
        case .width:
            pending.width = readInt(prop)
        case .height:
            pending.height = readInt(prop)
        case .fps:
            if prop.format == MPV_FORMAT_DOUBLE, let data = prop.data {
                pending.containerFps = data.assumingMemoryBound(to: Double.self).pointee
            } else {
                pending.containerFps = 0
            }
        case .estimatedFps:
            if prop.format == MPV_FORMAT_DOUBLE, let data = prop.data {
                pending.estimatedFps = data.assumingMemoryBound(to: Double.self).pointee
            } else {
                pending.estimatedFps = 0
            }
        case .videoCodec:
            pending.videoCodec = readString(prop)
        case .audioCodec:
            pending.audioCodec = readString(prop)
        case .audioChannels:
            pending.audioChannels = readInt(prop)
        case .hwdec:
            pending.hwdec = readString(prop)
        case .pausedForCache:
            if prop.format == MPV_FORMAT_FLAG, let data = prop.data {
                pending.isBuffering = data.assumingMemoryBound(to: Int32.self).pointee != 0
            }
        }
    }

    private func applyPendingChanges(_ pending: PendingChanges) {
        guard pending.hasChanges else { return }

        if let isPlaying = pending.isPlaying {
            setState(\.isPlaying, isPlaying)
        }

        var nextMediaInfo = mediaInfo
        if let width = pending.width {
            nextMediaInfo.width = width
        }
        if let height = pending.height {
            nextMediaInfo.height = height
        }
        if let videoCodec = pending.videoCodec {
            nextMediaInfo.videoCodec = videoCodec
        }
        if let audioCodec = pending.audioCodec {
            nextMediaInfo.audioCodec = audioCodec
        }
        if let audioChannels = pending.audioChannels {
            nextMediaInfo.audioChannels = audioChannels
        }
        if let hwdec = pending.hwdec {
            nextMediaInfo.hwdec = hwdec
        }

        var nextContainerFps = pending.containerFps ?? containerFps
        var nextEstimatedFps = pending.estimatedFps ?? estimatedFps
        if nextContainerFps <= 0, nextEstimatedFps <= 0, pending.timePos != nil {
            nextContainerFps = readDoubleProperty("container-fps") ?? nextContainerFps
            nextEstimatedFps = readDoubleProperty("estimated-vf-fps") ?? nextEstimatedFps
        }
        if abs(containerFps - nextContainerFps) >= Tuning.stateEpsilon {
            containerFps = nextContainerFps
        }
        if abs(estimatedFps - nextEstimatedFps) >= Tuning.stateEpsilon {
            estimatedFps = nextEstimatedFps
        }

        let displayFps = max(nextContainerFps, nextEstimatedFps)
        if abs(nextMediaInfo.fps - displayFps) >= Tuning.stateEpsilon {
            nextMediaInfo.fps = displayFps
        }
        if mediaInfo != nextMediaInfo {
            mediaInfo = nextMediaInfo
        }

        if let cacheSeconds = pending.cacheSeconds {
            setApproxState(\.cacheSeconds, cacheSeconds, epsilon: Tuning.cacheEpsilon)
        }
        if let isBuffering = pending.isBuffering {
            setState(\.isBuffering, isBuffering)
        }
        if let volume = pending.volume {
            setApproxState(\.volume, volume, epsilon: Tuning.stateEpsilon)
        }
        if let isMuted = pending.isMuted {
            setState(\.isMuted, isMuted)
        }
        if let timePos = pending.timePos {
            setApproxState(\.timePos, timePos, epsilon: Tuning.timePosEpsilon)
            if isLoading, timePos > 0 {
                setState(\.isLoading, false)
            }
        }
        if let duration = pending.duration {
            setApproxState(\.duration, duration, epsilon: Tuning.stateEpsilon)
        }
        if let isSeekable = pending.isSeekable {
            setState(\.isSeekable, isSeekable)
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

    private func readInt(_ prop: mpv_event_property) -> Int {
        guard prop.format == MPV_FORMAT_INT64, let data = prop.data else { return 0 }
        return Int(data.assumingMemoryBound(to: Int64.self).pointee)
    }

    private func readString(_ prop: mpv_event_property) -> String {
        guard prop.format == MPV_FORMAT_STRING, let data = prop.data else { return "" }
        let pp = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
        return pp.map { String(cString: $0) } ?? ""
    }

    // MARK: - C helpers

    private func setOption(_ handle: OpaquePointer, _ name: String, _ value: String) {
        _ = name.withCString { n in
            value.withCString { v in
                mpv_set_option_string(handle, n, v)
            }
        }
    }

    private func setRuntimeProperty(_ handle: OpaquePointer, _ name: String, _ value: String) {
        _ = name.withCString { n in
            value.withCString { v in
                mpv_set_property_string(handle, n, v)
            }
        }
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let handle else { return }
        var flag: Int32 = value ? 1 : 0
        _ = name.withCString { n in
            mpv_set_property(handle, n, MPV_FORMAT_FLAG, &flag)
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
        var v = value
        _ = name.withCString { n in
            mpv_set_property(handle, n, MPV_FORMAT_DOUBLE, &v)
        }
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

    private func readDoubleProperty(_ name: String) -> Double? {
        guard let handle else { return nil }
        var value = 0.0
        let err = name.withCString { n in
            mpv_get_property(handle, n, MPV_FORMAT_DOUBLE, &value)
        }
        return err >= 0 ? value : nil
    }

    private func readFlagProperty(_ name: String) -> Bool? {
        guard let handle else { return nil }
        var value: Int32 = 0
        let err = name.withCString { n in
            mpv_get_property(handle, n, MPV_FORMAT_FLAG, &value)
        }
        return err >= 0 ? value != 0 : nil
    }

    private func command(_ handle: OpaquePointer, _ args: [String]) {
        let duped: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        var cStrings: [UnsafePointer<CChar>?] = duped.map { UnsafePointer($0) }
        cStrings.append(nil)
        defer { duped.forEach { if let p = $0 { free(p) } } }
        cStrings.withUnsafeMutableBufferPointer { buf in
            _ = mpv_command(handle, buf.baseAddress)
        }
    }

}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
