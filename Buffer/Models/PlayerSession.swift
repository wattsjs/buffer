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
    private var prebuffered: [String: MPVPlayer] = [:]
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
        p.prepareForReuse()
        if idle.count < maxIdle {
            idle.append(p)
        }
        // else: drop the reference; MPVPlayer.deinit will call destroy()
    }

    @MainActor
    func prewarmFocusedHandle() {
        guard idle.isEmpty, prebuffered.isEmpty else { return }
        let p = MPVPlayer()
        p.prepareForReuse()
        idle.append(p)
        AppLog.playback.info("Prewarmed mpv player handle idle=\(self.idle.count, privacy: .public)")
    }

    @MainActor
    func prebuffer(channel: Channel) -> MPVPlayer? {
        guard !channel.isOnDemand else { return nil }
        if let existing = prebuffered[channel.id], existing.currentURL == channel.streamURL {
            return existing
        }

        for (_, player) in prebuffered {
            release(player)
        }
        prebuffered.removeAll()

        let player: MPVPlayer
        if idle.isEmpty {
            player = MPVPlayer()
        } else {
            player = idle.removeLast()
            player.prepareForReuse()
        }

        player.onPlaybackEnded = nil
        player.onFileLoaded = nil
        player.onFirstFrame = { [weak self, weak player] in
            guard
                let self,
                let player,
                self.prebuffered[channel.id] === player,
                player.currentURL == channel.streamURL
            else { return }

            player.setMute(true)
            AppLog.playback.info("Prebuffer ready muted-playing channel=\(channel.name, privacy: .public)")
            player.logPlaybackSyncSnapshot("prebuffer-ready")
        }
        player.onStreamIssue = nil
        player.onMediaInfoChanged = nil
        player.setMute(true)
        player.loadURL(channel.streamURL, autoplay: true)
        prebuffered[channel.id] = player
        AppLog.playback.info("Prebuffering channel name=\(channel.name, privacy: .public) id=\(channel.id, privacy: .public)")
        return player
    }

    @MainActor
    func acquirePrebuffered(for channel: Channel) -> MPVPlayer? {
        guard let player = prebuffered.removeValue(forKey: channel.id) else {
            AppLog.playback.debug("No prebuffered player channel=\(channel.name, privacy: .public)")
            return nil
        }
        guard player.currentURL == channel.streamURL else {
            AppLog.playback.info("Discarding prebuffered player channel=\(channel.name, privacy: .public) currentURLMatches=false")
            release(player)
            return nil
        }
        guard player.hasRenderedCurrentLoad, player.isPlaying else {
            AppLog.playback.info("Discarding prebuffered player channel=\(channel.name, privacy: .public) ready=false")
            release(player)
            return nil
        }
        AppLog.playback.info("Using prebuffered player channel=\(channel.name, privacy: .public)")
        player.logPlaybackSyncSnapshot("prebuffer-acquired")
        return player
    }
}

@MainActor
private enum PlayerStartupTiming {
    private static var openStartedAt: [String: Date] = [:]

    static func noteOpen(channel: Channel) {
        openStartedAt[channel.id] = Date()
        AppLog.playback.info("player open-request channel=\(channel.name, privacy: .public) id=\(channel.id, privacy: .public)")
    }

    static func noteFirstFrame(channel: Channel) {
        guard let startedAt = openStartedAt.removeValue(forKey: channel.id) else { return }
        let elapsedMs = Int((Date().timeIntervalSince(startedAt) * 1000).rounded())
        AppLog.playback.info("player open-to-first-frame channel=\(channel.name, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)")
    }
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
        let new = MPVPlayerPool.shared.acquirePrebuffered(for: channel) ?? MPVPlayerPool.shared.acquire()
        attachCallbacks(to: new)
        _player = new
        return new
    }

    private func attachCallbacks(to player: MPVPlayer) {
        player.onPlaybackEnded = { [weak self] reason in
            self?.handlePlaybackEnded(reason)
        }
        player.onFileLoaded = { [weak self] in
            self?.handleFileLoaded()
        }
        player.onFirstFrame = { [weak self] in
            self?.handleFirstFrame()
        }
        player.onStreamIssue = { [weak self] issue in
            self?.handleStreamIssue(issue)
        }
        player.onMediaInfoChanged = { [weak self] info in
            guard let self else { return }
            StreamProbeService.shared.recordPlaybackInfo(
                channelID: self.channel.id,
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
    @ObservationIgnored private var playbackWatchdog: Task<Void, Never>?
    @ObservationIgnored private var stallWatchdog: Task<Void, Never>?
    @ObservationIgnored private var playbackMode: PlaybackMode = .live
    @ObservationIgnored private var lastObservedTimePos: Double = 0
    @ObservationIgnored private var lastPlaybackProgressAt: Date?
    @ObservationIgnored private var expectedStoppedEndFiles: Int = 0
    @ObservationIgnored private var lastReconnectAt: Date?
    @ObservationIgnored private var pendingOnDemandSeekSeconds: Double?

    /// Tracks whether we have explicitly paused recovery Tasks + player for
    /// system sleep via AppLifecycleCoordinator. Prevents duplicate work on
    /// rapid sleep/wake and ensures clean Task cancellation.
    @ObservationIgnored private var isBackgroundPaused = false

    /// After this long of continuous reconnect failures without a single
    /// successful `FILE_LOADED`, surface an error to the user. The reconnect
    /// task keeps running in the background — the banner auto-clears if a
    /// later attempt gets a frame through.
    @ObservationIgnored private let fatalReconnectWindow: TimeInterval = 60

    /// Seconds of continuous playback required before we consider the stream
    /// "healthy" and reset the reconnect backoff counter.
    @ObservationIgnored private let healthyPlaybackSeconds: Double = 5
    /// If playback keeps claiming to be alive but `timePos` does not advance
    /// for longer than these windows, treat it as a dead player and reload the
    /// live source. This covers hangs that never surface as `END_FILE`.
    @ObservationIgnored private let stalledWhileLoadingSeconds: TimeInterval = 15
    @ObservationIgnored private let stalledWhileBufferingSeconds: TimeInterval = 12
    @ObservationIgnored private let stalledWhilePlayingSeconds: TimeInterval = 6
    @ObservationIgnored private let playbackProgressEpsilon: Double = 0.25
    @ObservationIgnored private let minimumImmediateReconnectSpacing: TimeInterval = 2
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
            // Initiated by us (new loadfile, teardown). Nothing to do.
            if expectedStoppedEndFiles > 0 {
                expectedStoppedEndFiles -= 1
                return
            }
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
            case .eof, .stopped:
                break
            }
            return
        }

        scheduleReconnect(reason: reason)
    }

    private func handleFileLoaded() {
        lastObservedTimePos = player.timePos
        lastPlaybackProgressAt = Date()
        player.clearReconnectingErrorMessage()
        if playbackMode == .onDemand, let seekSeconds = pendingOnDemandSeekSeconds {
            pendingOnDemandSeekSeconds = nil
            player.seek(to: seekSeconds)
        }
    }

    private func handleFirstFrame() {
        PlayerStartupTiming.noteFirstFrame(channel: channel)
    }

    private func handleStreamIssue(_ issue: MPVStreamIssue) {
        guard playbackMode == .live else { return }
        if let event = streamHealthEvent(for: issue) {
            playbackStreamHealth.record(event)
        }
        guard reconnectTask == nil else { return }

        let recoveryReason: MPVEndReason?
        switch issue {
        case .hlsReloadFailed:
            recoveryReason = .error(
                code: 0,
                message: "stream network recovery: \(issue.recoveryMessage)"
            )
        case .httpError(let message) where isHTTP509Message(message):
            recoveryReason = .http509(message: message)
        case .httpError:
            recoveryReason = .error(
                code: 0,
                message: "stream network recovery: \(issue.recoveryMessage)"
            )
        case .reconnecting:
            // mpv's libavformat reconnect is a lightweight segment-level
            // recovery path. Escalating these warnings to `loadfile replace`
            // interrupts otherwise healthy playback; the stall watchdog will
            // still reload if the playhead actually stops advancing.
            recoveryReason = nil
        }

        guard let reason = recoveryReason else { return }
        scheduleReconnect(reason: reason, immediate: true)
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

        playbackWatchdog?.cancel()
        playbackWatchdog = nil
        stallWatchdog?.cancel()
        stallWatchdog = nil

        if is509 {
            let failureAge = firstFailureAt.map { Date().timeIntervalSince($0) } ?? 0
            let fastDelay = min(http509BaseDelay * pow(2.0, Double(min(attempt, 3))), http509MaxDelay)
            let delay = failureAge >= slowRetryFailureWindow ? http509SlowRetryDelay : fastDelay
            if failureAge >= http509VisibleFailureWindow {
                player.setReconnectingErrorMessage("Bandwidth limit — retrying in \(Int(delay))s…")
            } else {
                player.clearReconnectingErrorMessage()
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
        let shouldSurfaceError = failureAge >= fatalReconnectWindow
        let shouldSlowRetry = failureAge >= slowRetryFailureWindow

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

        let player = self.player
        if shouldSurfaceError {
            switch reason {
            case .eof:
                player.setReconnectingErrorMessage("Stream offline — retrying in background.")
            case .error(_, let message):
                player.setReconnectingErrorMessage("Stream offline — retrying in background. (\(message))")
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
        guard playbackMode == .live else { return }
        AppLog.playback.info("Performing reconnect channel=\(self.channel.name, privacy: .public)")
        playbackStreamHealth.record(.recoveryReload)
        lastReconnectAt = Date()
        reconnectTask = nil
        pendingReconnectIs509 = false
        stopRecoveryTasks(resetFailureWindow: false)
        noteExpectedStopIfReplacingCurrentItem()
        player.loadURL(channel.streamURL, autoplay: true)
        armRecoveryWatchdogs()
    }

    /// Watches timePos; once playback has advanced by `healthyPlaybackSeconds`
    /// since the last reload, declare the session healthy and reset backoff.
    private func armHealthyPlaybackWatchdog() {
        playbackWatchdog?.cancel()
        let startTime = player.timePos
        playbackWatchdog = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                if self.player.isPlaying,
                   self.player.timePos - startTime >= self.healthyPlaybackSeconds {
                    self.reconnectAttempt = 0
                    self.firstFailureAt = nil
                    self.player.clearReconnectingErrorMessage()
                    return
                }
            }
        }
    }

    private func armStallWatchdog() {
        stallWatchdog?.cancel()
        lastObservedTimePos = player.timePos
        lastPlaybackProgressAt = Date()

        stallWatchdog = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                guard self.playbackMode == .live else { return }

                // Background thumbnail guard (post-pool multi-view robustness):
                // Throttled slots (focusedScaling=false) have vid disabled and
                // should not drive 1 Hz stall detection or cause spurious
                // reconnects while the pane is tiny. Promotion re-arms via
                // applySlotPolicies. This + suspendBackgroundRecovery cuts
                // active watchdogs from 9 to 1 in full grid.
                if !self.player.focusedScaling {
                    try? await Task.sleep(for: .seconds(4))
                    continue
                }

                let currentTimePos = self.player.timePos
                if currentTimePos - self.lastObservedTimePos >= self.playbackProgressEpsilon {
                    self.lastObservedTimePos = currentTimePos
                    self.lastPlaybackProgressAt = Date()
                    continue
                }

                self.lastObservedTimePos = currentTimePos

                if !self.player.isPlaying,
                   !self.player.isBuffering,
                   !self.player.isLoading {
                    self.lastPlaybackProgressAt = Date()
                    continue
                }

                let threshold: TimeInterval
                if self.player.isLoading {
                    threshold = self.stalledWhileLoadingSeconds
                } else if self.player.isBuffering {
                    threshold = self.stalledWhileBufferingSeconds
                } else {
                    threshold = self.stalledWhilePlayingSeconds
                }

                let lastProgressAt = self.lastPlaybackProgressAt ?? Date()
                if Date().timeIntervalSince(lastProgressAt) < threshold {
                    continue
                }

                let reason: MPVEndReason = .error(
                    code: 0,
                    message: self.player.isBuffering || self.player.isLoading
                        ? "playback stalled while buffering"
                        : "playback stalled"
                )
                self.scheduleReconnect(reason: reason, immediate: true)
                return
            }
        }
    }

    private func armRecoveryWatchdogs() {
        armHealthyPlaybackWatchdog()
        armStallWatchdog()
    }

    /// Suspends the per-slot stall/healthy watchdogs (but leaves any
    /// in-flight reconnectTask). Called for non-focused multi-view
    /// thumbnails so we don't have N× 1 Hz Tasks + spurious reconnects
    /// while the player is intentionally throttled (vid=no, paused).
    /// On focus promotion we selectively re-arm only the active pane.
    /// This + focusedScaling guard inside the loops tames the "timers
    /// exploding in multi-view" problem after pool work.
    func suspendBackgroundRecovery() {
        playbackWatchdog?.cancel()
        playbackWatchdog = nil
        stallWatchdog?.cancel()
        stallWatchdog = nil
        lastPlaybackProgressAt = nil
        // Intentionally do *not* cancel reconnectTask here; a pending
        // silent recovery for a thumbnail can complete and keep the slot
        // "warm" for later promotion. Full stop only via cancelReconnect.
    }

    /// Re-arms recovery only for the now-focused live slot (idempotent).
    func ensureRecoveryWatchdogsArmedForFocus() {
        guard playbackMode == .live else { return }
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
        playbackWatchdog?.cancel()
        playbackWatchdog = nil
        stallWatchdog?.cancel()
        stallWatchdog = nil
        lastPlaybackProgressAt = nil

        if resetFailureWindow {
            reconnectAttempt = 0
            firstFailureAt = nil
            lastReconnectAt = nil
        }

    }

    private func noteExpectedStopIfReplacingCurrentItem() {
        if player.currentURL != nil {
            expectedStoppedEndFiles += 1
        }
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
        playbackWatchdog?.cancel()
        playbackWatchdog = nil
        stallWatchdog?.cancel()
        stallWatchdog = nil
        lastPlaybackProgressAt = nil

        player.pause()
        player.pauseBackgroundActivity()
    }

    func resumeBackgroundWork() {
        guard isBackgroundPaused else { return }
        isBackgroundPaused = false

        AppLog.playback.info("Resuming player background work channel=\(self.channel.name, privacy: .public)")

        player.resumeBackgroundActivity()

        guard playbackMode == .live else {
            // Catchup / on-demand: just unpause from where we left off.
            player.play()
            return
        }

        // Live: safest to do a fresh load after sleep to re-establish
        // network paths, HLS playlists, etc. Then re-arm the stall/reconnect
        // watchdogs exactly as a normal load does.
        stopRecoveryTasks(resetFailureWindow: false)
        player.clearReconnectingErrorMessage()
        noteExpectedStopIfReplacingCurrentItem()
        player.loadURL(channel.streamURL, autoplay: true)
        armRecoveryWatchdogs()
        StreamProbeService.shared.requestProbe(for: channel, priority: .userInitiated)
    }

    init(channel: Channel, currentProgram: EPGProgram?) {
        self.channel = channel
        self.currentProgram = currentProgram
    }

    func unregisterFromRegistry() {
        cancelReconnect()
    }

    func loadInitialLive() {
        if channel.isOnDemand {
            loadOnDemand()
            return
        }
        playbackMode = .live
        playbackStreamHealth = StreamHealth()
        stopRecoveryTasks(resetFailureWindow: true)
        player.clearReconnectingErrorMessage()
        if useCurrentLiveLoadIfPossible() {
            return
        }
        noteExpectedStopIfReplacingCurrentItem()
        player.loadURL(channel.streamURL, autoplay: true)
        armRecoveryWatchdogs()
        // The user is actively watching this channel — bump probe priority so
        // the badge populates quickly even if scrolling hadn't requested it.
        StreamProbeService.shared.requestProbe(for: channel, priority: .userInitiated)
    }

    func loadLive() {
        if channel.isOnDemand {
            loadOnDemand()
            return
        }
        playbackMode = .live
        playbackStreamHealth = StreamHealth()
        stopRecoveryTasks(resetFailureWindow: true)
        player.clearReconnectingErrorMessage()
        if useCurrentLiveLoadIfPossible() {
            return
        }
        noteExpectedStopIfReplacingCurrentItem()
        player.loadURL(channel.streamURL, autoplay: true)
        armRecoveryWatchdogs()
        StreamProbeService.shared.requestProbe(for: channel, priority: .userInitiated)
    }

    private func useCurrentLiveLoadIfPossible() -> Bool {
        let player = self.player
        guard player.currentURL == channel.streamURL else { return false }
        AppLog.playback.info("Using current live load channel=\(self.channel.name, privacy: .public)")
        if player.hasRenderedCurrentLoad {
            PlayerStartupTiming.noteFirstFrame(channel: channel)
        }
        Task { @MainActor [weak player] in
            await Task.yield()
            guard let player else { return }
            player.setMute(false)
            player.play()
            player.logPlaybackSyncSnapshot("visible-unmuted")
            try? await Task.sleep(for: .seconds(2))
            player.logPlaybackSyncSnapshot("visible-2s")
        }
        lastObservedTimePos = player.timePos
        lastPlaybackProgressAt = Date()
        armRecoveryWatchdogs()
        StreamProbeService.shared.requestProbe(for: channel, priority: .userInitiated)
        return true
    }

    func loadCatchup(_ url: URL) {
        playbackMode = .catchup
        playbackStreamHealth = StreamHealth()
        cancelReconnect()
        player.clearReconnectingErrorMessage()
        noteExpectedStopIfReplacingCurrentItem()
        player.setMute(false)
        player.loadURL(url, autoplay: true)
    }

    func seekOnNextOnDemandLoad(to seconds: Double) {
        guard channel.isOnDemand, seconds > 0 else { return }
        pendingOnDemandSeekSeconds = seconds
    }

    private func loadOnDemand() {
        playbackMode = .onDemand
        playbackStreamHealth = StreamHealth()
        cancelReconnect()
        player.clearReconnectingErrorMessage()
        noteExpectedStopIfReplacingCurrentItem()
        player.loadURL(channel.streamURL, autoplay: true)
    }
}

@MainActor
@Observable
final class PlayerSession {
    private(set) var slots: [PlayerSlot] = []
    private(set) var focusedSlotID: UUID
    var layout: MultiViewLayout

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

    static func prebuffer(channel: Channel) -> MPVPlayer? {
        MPVPlayerPool.shared.prebuffer(channel: channel)
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
        if let existing = slots.first(where: { $0.channel.id == channel.id }) {
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
        if let p = removed._player {
            removed._player = nil
            MPVPlayerPool.shared.release(p)
        }

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
            if let p = slot._player {
                slot._player = nil
                MPVPlayerPool.shared.release(p)
            }
        }
    }
}
