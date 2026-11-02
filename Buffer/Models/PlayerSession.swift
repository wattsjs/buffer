import AppKit
import Foundation
import Observation
import OSLog

/// Small, file-local reuse pool for MPVPlayer handles (Agent 01/04).
/// Keeps 1–3 warm instances (mpv handle + observers + timers + GL setup)
/// alive when PlayerSlots are removed, so the next addChannel / window open
/// can skip the expensive mpv_create + 30+ option + observer setup.
private final class MPVPlayerPool {
    static let shared = MPVPlayerPool()
    private var idle: [MPVPlayer] = []
    private let maxIdle = 3

    private init() {}

    @MainActor
    func acquire() -> MPVPlayer {
        if !idle.isEmpty {
            let p = idle.removeLast()
            p.prepareForReuse()
            return p
        }
        return MPVPlayer()
    }

    @MainActor
    func release(_ p: MPVPlayer) {
        // A handle must not be assigned to another account while an old
        // asynchronous STOP is still closing its upstream connection.
        p.stopWhenBackendIdle { [self, p] in
            p.prepareForReuse()
            if idle.count < maxIdle { idle.append(p) }
        }
    }

    @MainActor
    func prewarmFocusedHandle() {
        guard idle.isEmpty else { return }
        let p = MPVPlayer()
        p.prepareForReuse()
        idle.append(p)
        AppLog.playback.info("Prewarmed mpv player handle idle=\(self.idle.count, privacy: .public)")
    }
}

@MainActor
private enum PlayerStartupTiming {
    private static var openStartedAt: [String: Date] = [:]

    static func noteOpen(channel: Channel) {
        openStartedAt[channel.preferenceIdentity] = Date()
        AppLog.playback.info("player open-request channel=\(channel.name, privacy: .public) id=\(channel.id, privacy: .public)")
    }

    static func noteFirstFrame(channel: Channel) {
        guard let startedAt = openStartedAt.removeValue(forKey: channel.preferenceIdentity) else { return }
        let elapsedMs = Int((Date().timeIntervalSince(startedAt) * 1000).rounded())
        PerfMetrics.shared.record("playback.openToFirstFrameMs", Double(elapsedMs))
        AppLog.playback.info("player open-to-first-frame channel=\(channel.name, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)")
    }
}

/// Wall-clock description of an in-flight catchup playback. Owned by
/// `PlayerSlot` (not the view) so the state survives chrome rebuilds, focus
/// changes, and can drive auto-advance when a clip ends.
struct CatchupPlayback {
    /// The wall-clock span the transport bar represents — normally one EPG
    /// program, or an ad-hoc window when no guide data matched.
    var timeline: DateInterval
    /// Wall-clock time corresponding to position 0 of the clip mpv currently
    /// has loaded. `loadedStart + player.timePos` = the moment being watched.
    var loadedStart: Date
    /// EPG program anchoring `timeline`, when one matched.
    var programID: String?
    /// True from the moment a catchup load/seek is issued until the new clip
    /// actually starts playing.
    var isSwitching: Bool
}

enum MultiViewLayout: String, CaseIterable, Identifiable {
    case single
    case oneTwo
    case twoByTwo
    case threeByThree
    case focusedThumbnails

    var id: String { rawValue }

    var capacity: Int {
        switch self {
        case .single: return 1
        case .oneTwo: return 3
        case .twoByTwo: return 4
        case .threeByThree: return 9
        case .focusedThumbnails: return 9
        }
    }

    var label: String {
        switch self {
        case .single: return "Single"
        case .oneTwo: return "1 + 2"
        case .twoByTwo: return "2 × 2"
        case .threeByThree: return "3 × 3"
        case .focusedThumbnails: return "Focus + Thumbnails"
        }
    }

    var symbol: String {
        switch self {
        case .single: return "rectangle"
        case .oneTwo: return "rectangle.split.2x1"
        case .twoByTwo: return "rectangle.split.2x2"
        case .threeByThree: return "rectangle.split.3x3"
        case .focusedThumbnails: return "rectangle.grid.1x2"
        }
    }

    static func smallestFitting(_ count: Int) -> MultiViewLayout {
        switch count {
        case ...1: return .single
        case 2...3: return .oneTwo
        case 4: return .twoByTwo
        default: return .threeByThree
        }
    }
}

@MainActor
@Observable
final class PlayerSlot: Identifiable {
    private enum PlaybackMode {
        case live
        case catchup
        case onDemand
    }

    let id = UUID()
    var channel: Channel
    var currentProgram: EPGProgram?
    private(set) var playbackStreamHealth = StreamHealth()
    private(set) var recoveryErrorMessage: String?
    private(set) var sourceChangeMessage: String?
    var logicalChannelID: String { channel.sourceOwnership?.preferenceIdentity ?? channel.id }
    @ObservationIgnored private var capacityLease: AccountCapacityLedger.Lease?
    @ObservationIgnored private var sourceEpoch: UInt64 = 0
    @ObservationIgnored private var liveAlternatives: [Channel] = []
    @ObservationIgnored private var resolveLiveAlternative: ((SourceChannelIdentity) -> Channel?)?
    @ObservationIgnored private var smartRecovery = SmartLiveRecoveryPolicy()
    @ObservationIgnored private var isRetired = false

    /// Non-nil while this slot plays from the channel archive.
    private(set) var catchup: CatchupPlayback?
    /// Fired when a catchup clip reaches its end (provider EOF). The owner
    /// decides what "next" means — advance to the following program's
    /// archive or return to live.
    @ObservationIgnored var onCatchupClipEnded: (() -> Void)?
    @ObservationIgnored private var catchupSwitchTimeout: Task<Void, Never>?

    var isCatchup: Bool { catchup != nil }

    /// The wall-clock moment currently being watched, when in catchup.
    var catchupWallClock: Date? {
        catchup.map { $0.loadedStart.addingTimeInterval(player.timePos) }
    }

    // MPVPlayer is created lazily on first access (or acquired from the
    // warm reuse pool). SwiftUI re-invokes view inits on every parent
    // re-render; a discarded slot must not spawn an mpv instance just to
    // be torn down a moment later. Removed slots return their handle to
    // the pool (up to 3) for fast reuse on the next addChannel/zap.
    @ObservationIgnored fileprivate var _player: MPVPlayer?
    @ObservationIgnored var player: MPVPlayer {
        if let existing = _player { return existing }
        // Prefer a warm pooled handle (avoids mpv_create + full option/observer
        // setup + render init). The pool is populated on removeSlot / session
        // teardown.
        let new = MPVPlayerPool.shared.acquire()
        attachCallbacks(to: new)
        if isBackgroundPaused {
            new.pauseBackgroundActivity()
        } else {
            // A handle recycled while asleep may have no state-poll timer.
            new.resumeBackgroundActivity()
        }
        _player = new
        return new
    }

    private func attachCallbacks(to player: MPVPlayer) {
        let epoch = sourceEpoch
        player.onPlaybackEnded = { [weak self] reason in
            guard let self, self.sourceEpoch == epoch, !self.isRetired else { return }
            self.handlePlaybackEnded(reason)
        }
        player.onFileLoaded = { [weak self] in
            guard let self, self.sourceEpoch == epoch, !self.isRetired else { return }
            self.handleFileLoaded()
        }
        player.onFirstFrame = { [weak self] in
            guard let self, self.sourceEpoch == epoch, !self.isRetired else { return }
            self.handleFirstFrame()
        }
        player.onStreamIssue = { [weak self] issue in
            guard let self, self.sourceEpoch == epoch, !self.isRetired else { return }
            self.handleStreamIssue(issue)
        }
        player.onMediaInfoChanged = { [weak self] info in
            guard let self, self.sourceEpoch == epoch, !self.isRetired else { return }
            // Archive metadata describes an archive URL, not whether this
            // channel's live endpoint is currently available.
            guard self.playbackMode != .catchup else { return }
            StreamProbeService.shared.recordPlaybackInfo(
                channel: self.channel,
                width: info.width,
                height: info.height,
                fps: info.fps,
                videoCodec: info.videoCodec,
                audioCodec: info.audioCodec,
                audioChannels: info.audioChannels,
                liveLatencySeconds: info.liveLatencySeconds
            )
        }
    }

    // MARK: - Silent reconnect policy
    //
    // Live HLS streams drop for all kinds of transient reasons: provider
    // edge hiccups, HLS playlist discontinuities, the demuxer hitting a
    // malformed segment, spurious EOF on an HD feed (mpv issue #2385).
    // mpv's libavformat reconnect only covers single-socket network
    // stalls; once the demuxer gives up, the video chain stays dead.
    //
    // We recover by re-issuing `loadURL` on exponential backoff. Nothing is
    // surfaced to the UI unless reconnects keep failing for long enough that
    // the stream is clearly offline.

    @ObservationIgnored private var reconnectAttempt: Int = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReconnectIs509: Bool = false
    @ObservationIgnored private var firstFailureAt: Date?
    @ObservationIgnored private var stallWatchdog: Task<Void, Never>?
    @ObservationIgnored private var playbackMode: PlaybackMode = .live
    @ObservationIgnored private var livenessMonitor: PlaybackLivenessMonitor?
    @ObservationIgnored private var lastReconnectAt: Date?
    @ObservationIgnored private var pendingOnDemandSeekSeconds: Double?
    @ObservationIgnored private var pendingCatchupSeekSeconds: Double?
    @ObservationIgnored private var hasRenderedAnyFrame = false
    @ObservationIgnored private var lastTelemetrySnapshotAt: Date?
    @ObservationIgnored private var lastEvidenceSample: (time: TimeInterval, position: Double, frames: Int, generation: Int)?
    @ObservationIgnored private var observedHealthySeconds: Double = 0
    @ObservationIgnored private var observedBufferingSeconds: Double = 0

    /// Tracks whether we have explicitly paused recovery Tasks + player for
    /// system sleep via AppLifecycleCoordinator. Prevents duplicate work on
    /// rapid sleep/wake and ensures clean Task cancellation.
    @ObservationIgnored private var isBackgroundPaused = false

    /// After this long of continuous reconnect failures without a single
    /// sustained playback, surface an error to the user. The reconnect task
    /// keeps running — a first frame clears the banner and observed healthy
    /// progress resets the failure streak.
    @ObservationIgnored private let fatalReconnectWindow: TimeInterval = 60
    @ObservationIgnored private let startupFailureVisibleWindow: TimeInterval = 8
    @ObservationIgnored private let startupFailureSlowRetryWindow: TimeInterval = 12
    @ObservationIgnored private let startupFailureSlowRetryDelay: TimeInterval = 15

    @ObservationIgnored private let minimumImmediateReconnectSpacing: TimeInterval = 2
    @ObservationIgnored private let telemetrySnapshotInterval: TimeInterval = 10
    @ObservationIgnored private let slowRetryFailureWindow: TimeInterval = 60
    @ObservationIgnored private let slowRetryDelay: TimeInterval = 30

    // 509-specific retry policy. Providers often use 509 for short CDN or
    // account throttling blips; recover quickly and silently first, then only
    // show UI if the same playback session keeps failing.
    @ObservationIgnored private let http509BaseDelay: TimeInterval = 1
    @ObservationIgnored private let http509MaxDelay: TimeInterval = 6
    @ObservationIgnored private let http509VisibleFailureWindow: TimeInterval = 12
    @ObservationIgnored private let http509SlowRetryDelay: TimeInterval = 10

    fileprivate func handlePlaybackEnded(_ reason: MPVEndReason) {
        switch reason {
        case .stopped:
            // MPVPlayer filters replacement/obsolete item events by actual
            // playlist entry. A STOP delivered here belongs to this load.
            cancelReconnect()
            return
        case .eof, .error, .http509:
            break
        }

        guard playbackMode == .live else {
            cancelReconnect()
            switch reason {
            case .error(_, let message):
                player.setReconnectingErrorMessage("Playback failed: \(message)")
            case .http509(let message):
                player.setReconnectingErrorMessage("Bandwidth limit — stream paused: \(message)")
            case .eof:
                if playbackMode == .catchup {
                    endCatchupSwitching()
                    onCatchupClipEnded?()
                }
            case .stopped:
                break
            }
            return
        }

        scheduleReconnect(reason: reason)
    }

    private func handleFileLoaded() {
        livenessMonitor = PlaybackLivenessMonitor(position: player.timePos, now: ProcessInfo.processInfo.systemUptime)
        player.clearReconnectingErrorMessage()
        if playbackMode == .onDemand, let seekSeconds = pendingOnDemandSeekSeconds {
            pendingOnDemandSeekSeconds = nil
            player.seek(to: seekSeconds)
        }
        if playbackMode == .catchup, let seekSeconds = pendingCatchupSeekSeconds {
            pendingCatchupSeekSeconds = nil
            player.seek(to: seekSeconds)
        }
    }

    private func handleFirstFrame() {
        guard !player.startupTargetTimedOut else { return }
        hasRenderedAnyFrame = true
        clearRecoveryErrorMessage()
        endCatchupSwitching()
        PlayerStartupTiming.noteFirstFrame(channel: channel)
    }

    private func handleStreamIssue(_ issue: MPVStreamIssue) {
        guard playbackMode == .live else { return }
        if let event = streamHealthEvent(for: issue) {
            playbackStreamHealth.record(event)
        }
        // A warning (including 509) is not a terminal transport failure. HLS
        // can keep rendering cached segments while ffmpeg retries internally.
        // Replacing the load here discards that media and may amplify provider
        // throttling. END_FILE and measured lack of progress own escalation.
    }

    private func isHTTP509Message(_ message: String) -> Bool {
        message.range(
            of: #"\b(?:HTTP error|HTTP|Server returned)\s+509\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func streamHealthEvent(for issue: MPVStreamIssue) -> StreamHealthEvent? {
        switch issue {
        case .httpError(let message):
            return isHTTP509Message(message) ? .http509 : nil
        case .hlsReloadFailed:
            return .playlistReloadFailure
        case .reconnecting:
            return .reconnect
        }
    }

    private func scheduleReconnect(reason: MPVEndReason, immediate: Bool = false) {
        guard playbackMode == .live, !isBackgroundPaused, !isRetired else { return }
        let is509 = if case .http509 = reason { true } else { false }
        if reconnectTask != nil {
            guard is509, !pendingReconnectIs509 else {
                AppLog.playback.debug("Reconnect already scheduled channel=\(self.channel.name, privacy: .public) pendingIs509=\(self.pendingReconnectIs509, privacy: .public) ignoredReason=\(String(describing: reason), privacy: .public)")
                return
            }
        }
        AppLog.playback.warning("Scheduling reconnect channel=\(self.channel.name, privacy: .public) is509=\(is509, privacy: .public) reason=\(String(describing: reason), privacy: .public) immediate=\(immediate, privacy: .public) attempt=\(self.reconnectAttempt, privacy: .public)")

        // Mark the start of a failure streak so we know when to give up
        // visibly. It is cleared after sustained successful playback.
        if firstFailureAt == nil {
            firstFailureAt = Date()
        }

        let attempt = reconnectAttempt
        reconnectAttempt += 1
        smartRecovery.noteFailure(now: ProcessInfo.processInfo.systemUptime)

        stallWatchdog?.cancel()
        stallWatchdog = nil

        if is509 {
            let failureAge = firstFailureAt.map { Date().timeIntervalSince($0) } ?? 0
            let fastDelay = min(http509BaseDelay * pow(2.0, Double(min(attempt, 3))), http509MaxDelay)
            let delay = failureAge >= slowRetryFailureWindow ? http509SlowRetryDelay : fastDelay
            if failureAge >= http509VisibleFailureWindow {
                setRecoveryErrorMessage("Bandwidth limit — retrying in \(Int(delay))s…")
            } else {
                clearRecoveryErrorMessage()
            }
            reconnectTask?.cancel()
            pendingReconnectIs509 = true
            reconnectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.performReconnect()
            }
            return
        }

        let failureAge = firstFailureAt.map { Date().timeIntervalSince($0) } ?? 0
        let isStartupFailure = !hasRenderedAnyFrame
        let visibleFailureWindow = isStartupFailure ? startupFailureVisibleWindow : fatalReconnectWindow
        let slowRetryWindow = isStartupFailure ? startupFailureSlowRetryWindow : slowRetryFailureWindow
        let slowRetryDelay = isStartupFailure ? startupFailureSlowRetryDelay : self.slowRetryDelay
        let shouldSurfaceError = failureAge >= visibleFailureWindow
        let shouldSlowRetry = failureAge >= slowRetryWindow

        let delay: Double
        if immediate {
            let sinceLastReconnect = lastReconnectAt.map { Date().timeIntervalSince($0) } ?? .infinity
            let spacingDelay = max(0, minimumImmediateReconnectSpacing - sinceLastReconnect)
            let repeatedFailureDelay = min(Double(attempt) * 0.75, 3.0)
            delay = shouldSlowRetry ? slowRetryDelay : max(spacingDelay, repeatedFailureDelay)
        } else {
            let baseDelay = 0.25 * pow(2.0, Double(min(attempt, 5)))
            delay = shouldSlowRetry ? slowRetryDelay : min(baseDelay, 5.0)
        }

        if shouldSurfaceError {
            let retrySeconds = max(1, Int(delay.rounded(.up)))
            switch reason {
            case .eof:
                setRecoveryErrorMessage("Stream offline — retrying in \(retrySeconds)s.")
            case .error(_, let message):
                setRecoveryErrorMessage("Stream offline — retrying in \(retrySeconds)s. (\(message))")
            case .stopped, .http509:
                break
            }
        }

        reconnectTask?.cancel()
        pendingReconnectIs509 = false
        reconnectTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            self.performReconnect()
        }
    }

    private func performReconnect() {
        guard playbackMode == .live, !isBackgroundPaused, !isRetired else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let current = physicalKey(channel)
        let eligibleAlternatives = liveAlternatives.compactMap { candidate -> Channel? in
            guard let identity = candidate.sourceChannelIdentity else { return nil }
            let resolved = resolveLiveAlternative.map { $0(identity) } ?? candidate
            guard let resolved, !resolved.isOnDemand,
                  resolved.sourceOwnership?.logicalChannelID == channel.sourceOwnership?.logicalChannelID,
                  resolved.sourceChannelIdentity == identity else { return nil }
            return resolved
        }
        if case .alternate(let key) = smartRecovery.decision(
            current: current, alternatives: eligibleAlternatives.map(physicalKey), now: now,
            playbackRequested: player.wantsPlayback, suspended: isBackgroundPaused,
            epochMatches: true
        ), let alternate = eligibleAlternatives.first(where: { physicalKey($0) == key }) {
            switchLiveSource(to: alternate, now: now)
            return
        }
        AppLog.playback.info("Performing reconnect channel=\(self.channel.name, privacy: .public)")
        playbackStreamHealth.record(.recoveryReload)
        lastReconnectAt = Date()
        reconnectTask = nil
        pendingReconnectIs509 = false
        stopRecoveryTasks(resetFailureWindow: false)
        // The stream just failed — a cached CDN edge assignment is a prime
        // suspect (expired token, dead edge). Force a fresh resolution.
        MPVPlayer.invalidateResolvedURL(for: channel.streamURL)
        player.loadURL(channel.streamURL, autoplay: player.wantsPlayback, live: true)
        armRecoveryWatchdogs()
    }

    private func armStallWatchdog() {
        stallWatchdog?.cancel()
        livenessMonitor = PlaybackLivenessMonitor(position: player.timePos, now: ProcessInfo.processInfo.systemUptime)

        stallWatchdog = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                guard self.playbackMode == .live, !self.isBackgroundPaused else { return }
                guard self.player.focusedScaling else { return }

                self.samplePlaybackEvidence()
                self.emitPlaybackTelemetryIfNeeded()
                if self.player.startupHoldActive {
                    self.livenessMonitor = PlaybackLivenessMonitor(position: self.player.timePos, now: ProcessInfo.processInfo.systemUptime)
                    continue
                }
                let signal = self.livenessMonitor?.sample(
                    position: self.player.timePos,
                    now: ProcessInfo.processInfo.systemUptime,
                    playbackRequested: self.player.wantsPlayback,
                    isPlaying: self.player.isPlaying,
                    isLoading: self.player.isLoading,
                    isBuffering: self.player.isBuffering
                )
                switch signal {
                case .healthy:
                    self.smartRecovery.noteHealthy()
                    self.reconnectAttempt = 0
                    self.firstFailureAt = nil
                    self.clearRecoveryErrorMessage()
                case .stalled:
                    let reason: MPVEndReason = .error(
                        code: 0,
                        message: self.player.isBuffering || self.player.isLoading
                            ? "playback stalled while buffering"
                            : "playback stalled"
                    )
                    self.scheduleReconnect(reason: reason, immediate: true)
                    return
                case nil:
                    break
                }
            }
        }
    }

    private func emitPlaybackTelemetryIfNeeded() {
        let now = Date()
        if let lastTelemetrySnapshotAt,
           now.timeIntervalSince(lastTelemetrySnapshotAt) < telemetrySnapshotInterval {
            return
        }
        lastTelemetrySnapshotAt = now
        if allowsOrdinaryLiveEvidence {
            StreamProbeService.shared.recordPlaybackHealth(channel: channel, health: playbackStreamHealth,
                healthySeconds: observedHealthySeconds, bufferingSeconds: observedBufferingSeconds, at: now,
                ordinaryLive: true)
            StreamProbeService.shared.recordPlaybackBitrate(channel: channel, bitsPerSecond: player.playbackStats.videoBitrateBps)
        }
        observedHealthySeconds = 0
        observedBufferingSeconds = 0
        let health = playbackStreamHealth
        AppLog.playback.info("telemetry heartbeat channel=\(self.channel.name, privacy: .public) mode=\(String(describing: self.playbackMode), privacy: .public) health=\(health.statusLabel, privacy: .public) reconnects=\(health.reconnectCount, privacy: .public) http509=\(health.http509Count, privacy: .public) recoveryReloads=\(health.recoveryReloadCount, privacy: .public) playlistFails=\(health.playlistReloadFailureCount, privacy: .public)")
        player.logPlaybackSyncSnapshot("heartbeat")
    }

    private func samplePlaybackEvidence() {
        guard allowsOrdinaryLiveEvidence else {
            lastEvidenceSample = nil
            observedHealthySeconds = 0
            observedBufferingSeconds = 0
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let position = player.timePos
        let frames = player.telemetryRenderedFrameCount
        let generation = player.telemetryLoadGeneration
        defer { lastEvidenceSample = (now, position, frames, generation) }
        guard let prior = lastEvidenceSample, player.wantsPlayback, !isBackgroundPaused,
              prior.generation == generation,
              position.isFinite, prior.position.isFinite else { return }
        let elapsed = now - prior.time
        guard elapsed > 0, elapsed <= 2.5 else { return }
        if player.isBuffering { observedBufferingSeconds += elapsed }
        let delta = position - prior.position
        if player.isPlaying, !player.isLoading, !player.isBuffering,
           (player.mediaInfo.width <= 0 || frames > prior.frames),
           delta >= 0.25, delta <= max(5, elapsed * 3) { observedHealthySeconds += elapsed }
    }

    var allowsOrdinaryLiveEvidence: Bool {
        guard playbackMode == .live, !channel.isOnDemand, !isBackgroundPaused else { return false }
#if DEBUG
        guard !PlaybackValidation.isEnabled, !SavedPlaybackScenario.isCapturing,
              !player.usesArchiveTimestampRecovery, !player.usesStartupReserve,
              !player.startupTargetEnabled, !player.nativeCacheOnlyEnabled,
              !player.liveAnalysisEnabled else { return false }
#endif
        return true
    }

    private func armRecoveryWatchdogs() {
        guard playbackMode == .live, !isBackgroundPaused, player.focusedScaling else { return }
        armStallWatchdog()
    }

    /// Suspends the per-slot progress watchdog (but leaves any
    /// in-flight reconnectTask). Called for non-focused multi-view
    /// thumbnails so we don't have N× 1 Hz Tasks + spurious reconnects
    /// while the player is intentionally throttled (vid=no, paused).
    /// On focus promotion we selectively re-arm only the active pane.
    /// Healthy and stalled decisions share one timer in the focused slot.
    func suspendBackgroundRecovery() {
        stallWatchdog?.cancel()
        stallWatchdog = nil
        livenessMonitor = nil
        lastEvidenceSample = nil
        // Intentionally do *not* cancel reconnectTask here; a pending
        // silent recovery for a thumbnail can complete and keep the slot
        // "warm" for later promotion. Full stop only via cancelReconnect.
    }

    /// Re-arms recovery only for the now-focused live slot (idempotent).
    func ensureRecoveryWatchdogsArmedForFocus() {
        guard playbackMode == .live, !isBackgroundPaused, reconnectTask == nil else { return }
        // Only (re)arm if we don't already have active ones; avoids
        // duplicate Tasks on rapid focus toggles.
        if stallWatchdog == nil {
            armRecoveryWatchdogs()
        }
    }

    private func stopRecoveryTasks(resetFailureWindow: Bool) {
        reconnectTask?.cancel()
        reconnectTask = nil
        pendingReconnectIs509 = false
        stallWatchdog?.cancel()
        stallWatchdog = nil
        livenessMonitor = nil

        if resetFailureWindow {
            reconnectAttempt = 0
            firstFailureAt = nil
            lastReconnectAt = nil
            clearRecoveryErrorMessage()
        }

    }

    private func setRecoveryErrorMessage(_ message: String) {
        recoveryErrorMessage = message
        player.setReconnectingErrorMessage(message)
    }

    private func clearRecoveryErrorMessage() {
        recoveryErrorMessage = nil
        _player?.clearReconnectingErrorMessage()
    }

    func cancelReconnect() {
        stopRecoveryTasks(resetFailureWindow: true)
    }

    // MARK: - AppLifecycleCoordinator integration (Agent 09)
    //
    // These are invoked by PlayerSessionRegistry (which is notified by the
    // central coordinator on macOS sleep/wake). They ensure watchdogs,
    // reconnect Tasks, and the MPV cache timer are fully stopped during sleep
    // (preventing accumulation, stale Date() math, and reconnect floods on
    // wake) and cleanly restarted afterwards. Rapid sleep/wake + 9-view is
    // the exact scenario that used to leak Tasks and freeze the app.

    func pauseBackgroundWork() {
        guard !isBackgroundPaused else { return }
        isBackgroundPaused = true

        AppLog.playback.info("Pausing player background work channel=\(self.channel.name, privacy: .public)")

        reconnectTask?.cancel()
        reconnectTask = nil
        pendingReconnectIs509 = false
        stallWatchdog?.cancel()
        stallWatchdog = nil
        livenessMonitor = nil

        _player?.pauseBackgroundActivity()
    }

    func resumeBackgroundWork() {
        guard isBackgroundPaused else { return }
        isBackgroundPaused = false

        AppLog.playback.info("Resuming player background work channel=\(self.channel.name, privacy: .public)")

        guard let player = _player else { return }
        player.resumeBackgroundActivity()

        // Finite media resumes only if its owner still requests playback.
        // resumeBackgroundActivity removes suspension without changing intent.
        guard playbackMode == .live else { return }

        // Live: safest to do a fresh load after sleep to re-establish
        // network paths, HLS playlists, etc. Then re-arm the stall/reconnect
        // watchdogs exactly as a normal load does.
        stopRecoveryTasks(resetFailureWindow: false)
        player.clearReconnectingErrorMessage()
        player.loadURL(channel.streamURL, autoplay: player.wantsPlayback, live: true)
        armRecoveryWatchdogs()
        StreamProbeService.shared.requestProbe(for: channel, priority: .userInitiated)
    }

    init(channel: Channel, currentProgram: EPGProgram?, recoveryPolicy: SmartLiveRecoveryPolicy = SmartLiveRecoveryPolicy()) {
        self.channel = channel
        self.currentProgram = currentProgram
        self.smartRecovery = recoveryPolicy
    }

    func unregisterFromRegistry() {
        cancelReconnect()
    }

    /// Root resolves eligibility and explicit overrides. This owner only
    /// considers those alternatives after repeated measured live failures.
    func configureLiveAlternatives(_ channels: [Channel], resolver: ((SourceChannelIdentity) -> Channel?)? = nil) {
        resolveLiveAlternative = resolver
        guard let logicalID = channel.sourceOwnership?.logicalChannelID else {
            liveAlternatives = []
            return
        }
        liveAlternatives = channels.filter {
            !$0.isOnDemand && $0.sourceOwnership != nil &&
            $0.sourceOwnership?.logicalChannelID == logicalID
        }
    }

    private func physicalKey(_ channel: Channel) -> String {
        channel.sourceOwnership?.channelIdentity.rawValue ?? channel.id
    }

    /// Explicit manual source or mode requests use the same teardown barrier
    /// as automatic live recovery. The caller then applies its original
    /// live/archive/resume intent; this method never substitutes that intent.
    func replacePlaybackChannel(_ next: Channel) async -> Bool {
        if physicalKey(channel) == physicalKey(next), channel.streamURL == next.streamURL {
            channel = next
            return true
        }
        sourceEpoch &+= 1
        let epoch = sourceEpoch
        cancelReconnect()
        let backend = player
        let oldLease = capacityLease
        let closed = await waitForBackendTeardown(backend, lease: oldLease)
        guard closed, !Task.isCancelled, !isRetired, sourceEpoch == epoch else { return false }
        channel = next
        attachCallbacks(to: backend)
        observedHealthySeconds = 0
        observedBufferingSeconds = 0
        lastEvidenceSample = nil
        lastTelemetrySnapshotAt = nil
        currentProgram = nil
        sourceChangeMessage = nil
        smartRecovery = SmartLiveRecoveryPolicy()
        return reservePlaybackCapacity()
    }

    private func reservePlaybackCapacity() -> Bool {
        guard let ownership = channel.sourceOwnership else { return true } // pre-migration local/legacy items
        if let capacityLease, capacityLease.accountKey == ownership.accountKey { return true }
        guard capacityLease == nil else { return false }
        switch AccountCapacityLedger.shared.reserve(for: channel, kind: .player, ownerID: id) {
        case .success(let lease): capacityLease = lease; return true
        case .failure:
            setRecoveryErrorMessage("This source has no free playback connections. Close a player or recording and retry.")
            return false
        }
    }

    private func waitForBackendTeardown(_ backend: MPVPlayer, lease: AccountCapacityLedger.Lease?) async -> Bool {
        await withCheckedContinuation { continuation in
            var completed = false
            let deadline = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, !completed else { return }
                completed = true
                self?.setRecoveryErrorMessage("The previous playback connection is still closing. Retry once it has stopped.")
                continuation.resume(returning: false)
            }
            backend.stopWhenBackendIdle { [weak self] in
                if let lease { _ = AccountCapacityLedger.shared.confirmTeardown(lease: lease) }
                if self?.capacityLease == lease { self?.capacityLease = nil }
                guard !completed else { return }
                completed = true
                deadline.cancel()
                continuation.resume(returning: true)
            }
        }
    }

    /// Retain the old lease through actual backend teardown, even if the
    /// window closes or the recovery task is cancelled in the meantime.
    func retireAndRecyclePlayer() {
        isRetired = true
        sourceEpoch &+= 1
        cancelReconnect()
        clearCatchupState()
        guard let player = _player else { return }
        _player = nil
        let lease = capacityLease
        capacityLease = nil
        player.stopWhenBackendIdle { [player] in
            if let lease { _ = AccountCapacityLedger.shared.confirmTeardown(lease: lease) }
            MPVPlayerPool.shared.release(player)
        }
    }

    private func switchLiveSource(to alternate: Channel, now: TimeInterval) {
        let expectedEpoch = sourceEpoch
        let oldChannel = channel
        let backend = player
        let oldLease = capacityLease
        let wantsPlayback = backend.wantsPlayback
        let intentRevision = backend.ownerPlaybackIntentRevision
        stopRecoveryTasks(resetFailureWindow: false)
        reconnectTask = Task { @MainActor [weak self, backend] in
            guard let self else { return }
            let closed = await self.waitForBackendTeardown(backend, lease: oldLease)
            guard closed, !Task.isCancelled, !self.isRetired, self.sourceEpoch == expectedEpoch,
                  self.playbackMode == .live, !self.isBackgroundPaused, wantsPlayback else { return }
            guard backend.ownerPlaybackIntentRevision == intentRevision else { return }
            self.channel = alternate
            guard self.reservePlaybackCapacity() else {
                self.channel = oldChannel
                self.reconnectTask = nil
                return
            }
            self.sourceEpoch &+= 1
            self.attachCallbacks(to: backend)
            self.smartRecovery.didSwitch(from: self.physicalKey(oldChannel), to: self.physicalKey(alternate), now: now)
            self.sourceChangeMessage = "Switched playback source after repeated failures. Live content may skip or repeat."
            self.currentProgram = nil // guide owner refreshes from this physical binding
            self.reconnectTask = nil
            self.reconnectAttempt = 0
            self.firstFailureAt = nil
            self.hasRenderedAnyFrame = false
            self.lastEvidenceSample = nil
            self.observedHealthySeconds = 0
            self.observedBufferingSeconds = 0
            backend.loadURL(alternate.streamURL, autoplay: true, live: true)
            self.armRecoveryWatchdogs()
        }
    }

    func loadInitialLive() {
        sourceEpoch &+= 1
        if let player = _player { attachCallbacks(to: player) }
        if channel.isOnDemand {
            loadOnDemand()
            return
        }
        playbackMode = .live
        clearCatchupState()
        playbackStreamHealth = StreamHealth()
        observedHealthySeconds = 0
        observedBufferingSeconds = 0
        hasRenderedAnyFrame = false
        stopRecoveryTasks(resetFailureWindow: true)
        clearRecoveryErrorMessage()
        guard reservePlaybackCapacity() else { return }
        if useCurrentLiveLoadIfPossible() {
            return
        }
        player.loadURL(channel.streamURL, autoplay: true, live: true)
        armRecoveryWatchdogs()
        // The user is actively watching this channel — bump probe priority so
        // the badge populates quickly even if scrolling hadn't requested it.
        StreamProbeService.shared.requestProbe(for: channel, priority: .userInitiated)
    }

    func loadLive() {
        sourceEpoch &+= 1
        if let player = _player { attachCallbacks(to: player) }
        if channel.isOnDemand {
            loadOnDemand()
            return
        }
        playbackMode = .live
        clearCatchupState()
        playbackStreamHealth = StreamHealth()
        observedHealthySeconds = 0
        observedBufferingSeconds = 0
        hasRenderedAnyFrame = false
        stopRecoveryTasks(resetFailureWindow: true)
        clearRecoveryErrorMessage()
        guard reservePlaybackCapacity() else { return }
        if useCurrentLiveLoadIfPossible() {
            return
        }
        player.loadURL(channel.streamURL, autoplay: true, live: true)
        armRecoveryWatchdogs()
        StreamProbeService.shared.requestProbe(for: channel, priority: .userInitiated)
    }

    private func useCurrentLiveLoadIfPossible() -> Bool {
        let player = self.player
        guard player.currentURL == channel.streamURL else { return false }
        AppLog.playback.info("Using current live load channel=\(self.channel.name, privacy: .public)")
        if player.hasRenderedCurrentLoad {
            hasRenderedAnyFrame = true
            PlayerStartupTiming.noteFirstFrame(channel: channel)
        }
        player.setMute(false)
        player.play()
        let generation = player.telemetryLoadGeneration
        Task { @MainActor [weak player] in
            await Task.yield()
            guard let player, player.telemetryLoadGeneration == generation else { return }
            player.logPlaybackSyncSnapshot("visible-unmuted")
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, player.telemetryLoadGeneration == generation else { return }
            player.logPlaybackSyncSnapshot("visible-2s")
        }
        livenessMonitor = PlaybackLivenessMonitor(position: player.timePos, now: ProcessInfo.processInfo.systemUptime)
        armRecoveryWatchdogs()
        StreamProbeService.shared.requestProbe(for: channel, priority: .userInitiated)
        return true
    }

    // MARK: - Catchup playback

    /// Start archive playback at `start`, presenting `timeline` on the
    /// transport bar. `start` is clamped into the channel's archive window
    /// and to the timeline itself.
    func playCatchup(from start: Date, timeline: DateInterval, programID: String?, autoplay: Bool = true) {
        sourceEpoch &+= 1
        if let player = _player { attachCallbacks(to: player) }
        guard let window = channel.archiveWindow() else {
            failCatchup("Catchup is unavailable from this source.")
            return
        }
        let clampedStart = clampCatchupStart(start, window: window, timeline: timeline)

        // Request through to the end of the timeline so mpv gets one
        // continuous clip for the presented program. Providers clamp
        // still-airing ends themselves.
        let duration = max(timeline.end.timeIntervalSince(clampedStart), 60)
        guard let request = CatchupURLBuilder.request(for: channel, start: clampedStart, duration: duration) else {
            AppLog.playback.error("Catchup URL build failed channel=\(self.channel.name, privacy: .public)")
            failCatchup("This source could not create the requested catchup stream.")
            return
        }

        AppLog.playback.info("Loading catchup channel=\(self.channel.name, privacy: .public) start=\(clampedStart, privacy: .public) timeline=\(timeline.start, privacy: .public)…\(timeline.end, privacy: .public)")

        playbackMode = .catchup
        playbackStreamHealth = StreamHealth()
        cancelReconnect()
        clearRecoveryErrorMessage()
        guard reservePlaybackCapacity() else { return }
        catchup = CatchupPlayback(
            timeline: timeline,
            loadedStart: request.loadedStart,
            programID: programID,
            isSwitching: true
        )
        armCatchupSwitchTimeout()
        player.setMute(false)
        let timestampRecovery = ArchiveTimestampRecovery.options(forArchiveLoad: true).enabled
        // Linearized timelines cannot support a low-level seek. The DEBUG
        // experiment starts at the actual URL minute and reports that origin;
        // only minute-aligned provider seeks can qualify exact wall-clock time.
        pendingCatchupSeekSeconds = !timestampRecovery && request.initialSeekSeconds > 0.001
            ? request.initialSeekSeconds : nil
        player.loadURL(request.url, autoplay: autoplay, archive: true)
    }

    /// Terminal replay failure retains the archive context and intent until
    /// the user explicitly chooses another programme or live playback.
    func stopUnavailableReplay() {
        guard catchup != nil else { return }
        sourceEpoch &+= 1
        pendingCatchupSeekSeconds = nil
        endCatchupSwitching()
        failCatchup("Replay unavailable. This source ended repeated archive clips immediately. Select a programme again to retry.",
            preservingContext: true)
    }

    private func failCatchup(_ message: String, preservingContext: Bool = false) {
        playbackMode = .catchup
        cancelReconnect()
        if !preservingContext { clearCatchupState() }
        if let backend = _player {
            let lease = capacityLease
            backend.stopWhenBackendIdle { [weak self] in
                if let lease { _ = AccountCapacityLedger.shared.confirmTeardown(lease: lease) }
                if self?.capacityLease == lease { self?.capacityLease = nil }
            }
        }
        setRecoveryErrorMessage(message)
    }

    /// Move the catchup playhead to a wall-clock target. Seeks inside the
    /// already-loaded clip when mpv can (cheap), otherwise reloads the
    /// archive URL at the new offset.
    func seekCatchup(toWallClock target: Date) {
        guard let current = catchup, let window = channel.archiveWindow() else { return }
        let clamped = clampCatchupStart(target, window: window, timeline: current.timeline)

        let clipOffset = clamped.timeIntervalSince(current.loadedStart)
        if !player.usesArchiveTimestampRecovery, clipOffset >= 0, player.isSeekable, clipOffset < player.duration - 5 {
            player.seek(to: clipOffset)
            return
        }
        playCatchup(from: clamped, timeline: current.timeline, programID: current.programID,
                    autoplay: player.wantsPlayback)
    }

    /// Leave the archive and reconnect the live stream.
    func returnToLive() {
        guard isCatchup else { return }
        loadLive()
    }

    private func clampCatchupStart(_ start: Date, window: DateInterval, timeline: DateInterval) -> Date {
        // Keep a safety margin inside both edges: providers 404 on requests
        // at the exact archive boundary, and near-live requests race the
        // archiver.
        let earliest = max(window.start.addingTimeInterval(60), timeline.start)
        let latest = window.end.addingTimeInterval(-30)
        return min(max(start, earliest), latest)
    }

    private func armCatchupSwitchTimeout() {
        catchupSwitchTimeout?.cancel()
        catchupSwitchTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.catchup?.isSwitching = false
        }
    }

    private func endCatchupSwitching() {
        catchupSwitchTimeout?.cancel()
        catchupSwitchTimeout = nil
        if catchup?.isSwitching == true {
            catchup?.isSwitching = false
        }
    }

    func seekOnNextOnDemandLoad(to seconds: Double) {
        guard channel.isOnDemand, seconds > 0 else { return }
        pendingOnDemandSeekSeconds = seconds
    }

    /// A replacement endpoint is idle after teardown. Queue its position
    /// before loading so FILE_LOADED applies resume to the new item.
    func resumeOnDemand(to seconds: Double, reload: Bool) {
        guard channel.isOnDemand else { return }
        if reload {
            seekOnNextOnDemandLoad(to: seconds)
            loadInitialLive()
        } else if seconds > 0 {
            player.seek(to: seconds)
        }
    }

    private func loadOnDemand() {
        playbackMode = .onDemand
        clearCatchupState()
        playbackStreamHealth = StreamHealth()
        cancelReconnect()
        clearRecoveryErrorMessage()
        guard reservePlaybackCapacity() else { return }
        player.loadURL(channel.streamURL, autoplay: true)
    }

    private func clearCatchupState() {
        catchupSwitchTimeout?.cancel()
        catchupSwitchTimeout = nil
        catchup = nil
    }
}

@MainActor
@Observable
final class PlayerSession {
    private(set) var slots: [PlayerSlot] = []
    private(set) var focusedSlotID: UUID
    var layout: MultiViewLayout

    /// The NSWindow hosting this session's PlayerView. Registered by the
    /// view so `PlayerSessionRegistry.deliver(_:)` can raise the window when
    /// it hands a new request to an already-open session.
    @ObservationIgnored weak var hostWindow: NSWindow?
    /// A request delivered while this session's window is already open.
    /// PlayerView observes and consumes it.
    var externalRequest: PlaybackRequest?

    private var started = false

    init(initialChannel: Channel, currentProgram: EPGProgram?) {
        let slot = PlayerSlot(channel: initialChannel, currentProgram: currentProgram)
        self.slots = [slot]
        self.focusedSlotID = slot.id
        self.layout = .single
    }

    static func prewarmPlayerPool() {
        MPVPlayerPool.shared.prewarmFocusedHandle()
    }

    static func noteOpen(channel: Channel) {
        PlayerStartupTiming.noteOpen(channel: channel)
    }

    /// Called from `PlayerView.onAppear`. Side effects (loadURL/play) must
    /// not run in `init` since SwiftUI may discard the PlayerSession.
    /// Pass `skipInitialLoad: true` when the caller is about to issue its own
    /// `loadURL` (e.g. a pending-catchup hand-off) so we don't fire a throw-
    /// away live load that mpv immediately replaces.
    func start(skipInitialLoad: Bool = false) {
        guard !started else { return }
        started = true
        guard !skipInitialLoad else { return }
        guard let first = slots.first else {
            // Defensive: should never be empty (init always seeds, remove guards >1).
            assertionFailure("PlayerSession.start with zero slots")
            return
        }
        first.loadInitialLive()
    }

    var focusedSlot: PlayerSlot {
        if let match = slots.first(where: { $0.id == focusedSlotID }) { return match }
        guard let first = slots.first else {
            // Defensive: prevents crash on slots[0] or implicit [0] if ever empty (was force path).
            preconditionFailure("PlayerSession.focusedSlot with zero slots")
        }
        return first
    }

    var isMulti: Bool { slots.count > 1 }

    func canAddMoreSlots() -> Bool {
        slots.count < MultiViewLayout.threeByThree.capacity
    }

    func addChannel(_ channel: Channel, currentProgram: EPGProgram?) {
        guard canAddMoreSlots() else { return }
        if let existing = slots.first(where: { $0.channel.preferenceIdentity == channel.preferenceIdentity }) {
            focus(slotID: existing.id)
            return
        }

        let slot = PlayerSlot(channel: channel, currentProgram: currentProgram)
        slots.append(slot)

        slot.loadInitialLive()
        // New multi-view panes start muted to avoid surprise audio overlap.
        // After that, per-pane controls own each slot's mute/volume state.
        slot.player.setMute(true)
        applySlotPolicies()

        promoteLayoutIfNeeded()
    }

    func removeSlot(id: UUID) {
        guard slots.count > 1 else { return }
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }

        let removed = slots[index]
        removed.player.setMute(true)
        removed.player.pause()
        removed.unregisterFromRegistry()

        // Return the MPVPlayer to the warm pool (if room) instead of letting
        // its deinit destroy the expensive handle. The layer teardown has
        // already reset the render context.
        removed.retireAndRecyclePlayer()

        slots.remove(at: index)

        if focusedSlotID == id, let first = slots.first {
            focusedSlotID = first.id
        }

        applySlotPolicies()
        demoteLayoutIfNeeded()
    }

    func focus(slotID: UUID) {
        guard slots.contains(where: { $0.id == slotID }) else { return }
        focusedSlotID = slotID
        applySlotPolicies()
    }

    func setLayout(_ layout: MultiViewLayout) {
        self.layout = layout
    }

    private func applySlotPolicies() {
        let multi = slots.count > 1
        for slot in slots {
            let focused = slot.id == focusedSlotID
            slot.player.configureResources(multiView: multi, focused: focused)
            if focused {
                slot.ensureRecoveryWatchdogsArmedForFocus()
            } else {
                slot.suspendBackgroundRecovery()
            }
        }
    }

    private func promoteLayoutIfNeeded() {
        let minimum = MultiViewLayout.smallestFitting(slots.count)
        if layout == .single || layout.capacity < slots.count {
            layout = minimum
        }
    }

    private func demoteLayoutIfNeeded() {
        if slots.count == 1 {
            layout = .single
        } else if layout.capacity > slots.count * 2 && layout != .focusedThumbnails {
            layout = MultiViewLayout.smallestFitting(slots.count)
        }
    }

    // MARK: - AppLifecycleCoordinator integration (Agent 09)

    func pauseAllBackgroundWork() {
        for slot in slots {
            slot.pauseBackgroundWork()
        }
    }

    func resumeAllBackgroundWork() {
        for slot in slots {
            slot.resumeBackgroundWork()
        }
        // Re-apply multi-view resource policies (mute, vid track, scaling)
        // after the resume loads may have reset player state.
        applySlotPolicies()
    }

    /// Called on window close / session teardown (and by PlayerView onDisappear)
    /// to return all remaining MPVPlayer handles to the warm pool instead of
    /// destroying them in deinit. This keeps 1–3 ready for the next player
    /// window or addChannel.
    func recycleAllPlayers() {
        for slot in slots {
            slot.retireAndRecyclePlayer()
        }
    }

    func configureLiveAlternatives(_ alternatives: [Channel], resolver: ((SourceChannelIdentity) -> Channel?)? = nil) {
        focusedSlot.configureLiveAlternatives(alternatives, resolver: resolver)
    }
}
