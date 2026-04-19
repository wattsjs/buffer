import Foundation
import Observation

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
    }

    let id = UUID()
    var channel: Channel
    var currentProgram: EPGProgram?

    // MPVPlayer is created lazily on first access. SwiftUI re-invokes view
    // inits on every parent re-render; a discarded slot must not spawn an
    // mpv instance just to be torn down a moment later.
    @ObservationIgnored private var _player: MPVPlayer?
    @ObservationIgnored var player: MPVPlayer {
        if let existing = _player { return existing }
        let new = MPVPlayer()
        new.onPlaybackEnded = { [weak self] reason in
            self?.handlePlaybackEnded(reason)
        }
        new.onMediaInfoChanged = { [weak self] info in
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
        _player = new
        return new
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
    @ObservationIgnored private var firstFailureAt: Date?
    @ObservationIgnored private var playbackWatchdog: Task<Void, Never>?
    @ObservationIgnored private var stallWatchdog: Task<Void, Never>?
    @ObservationIgnored private var playbackMode: PlaybackMode = .live
    @ObservationIgnored private var lastObservedTimePos: Double = 0
    @ObservationIgnored private var lastPlaybackProgressAt: Date?
    @ObservationIgnored private var expectedStoppedEndFiles: Int = 0

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
        case .eof, .error:
            break
        }

        guard playbackMode == .live else {
            cancelReconnect()
            if case .error(_, let message) = reason {
                player.setReconnectingErrorMessage("Playback failed: \(message)")
            }
            return
        }

        scheduleReconnect(reason: reason)
    }

    private func scheduleReconnect(reason: MPVEndReason, immediate: Bool = false) {
        // Mark the start of a failure streak so we know when to give up
        // visibly. `firstFailureAt` is cleared on every successful playback
        // beyond `healthyPlaybackSeconds`.
        if firstFailureAt == nil {
            firstFailureAt = Date()
        }

        let attempt = reconnectAttempt
        reconnectAttempt += 1

        // 0.25s, 0.5s, 1s, 2s, 4s, then capped at 5s. The first retry is
        // snappy so a single bad segment barely blips; later retries
        // breathe so we don't hammer a dead upstream.
        let delay: Double
        if immediate {
            delay = 0
        } else {
            let baseDelay = 0.25 * pow(2.0, Double(min(attempt, 5)))
            delay = min(baseDelay, 5.0)
        }

        let failureAge = firstFailureAt.map { Date().timeIntervalSince($0) } ?? 0
        let shouldSurfaceError = failureAge >= fatalReconnectWindow

        let player = self.player
        if shouldSurfaceError {
            switch reason {
            case .eof:
                player.setReconnectingErrorMessage("Stream offline — still trying.")
            case .error(_, let message):
                player.setReconnectingErrorMessage("Stream offline — still trying. (\(message))")
            case .stopped:
                break
            }
        }

        playbackWatchdog?.cancel()
        playbackWatchdog = nil
        stallWatchdog?.cancel()
        stallWatchdog = nil

        reconnectTask?.cancel()
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
        reconnectTask = nil
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

                let currentTimePos = self.player.timePos
                if currentTimePos - self.lastObservedTimePos >= self.playbackProgressEpsilon {
                    self.lastObservedTimePos = currentTimePos
                    self.lastPlaybackProgressAt = Date()
                    continue
                }

                self.lastObservedTimePos = currentTimePos

                if !self.player.isPlaying {
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

    private func stopRecoveryTasks(resetFailureWindow: Bool) {
        reconnectTask?.cancel()
        reconnectTask = nil
        playbackWatchdog?.cancel()
        playbackWatchdog = nil
        stallWatchdog?.cancel()
        stallWatchdog = nil
        lastPlaybackProgressAt = nil

        if resetFailureWindow {
            reconnectAttempt = 0
            firstFailureAt = nil
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

    init(channel: Channel, currentProgram: EPGProgram?) {
        self.channel = channel
        self.currentProgram = currentProgram
    }

    func unregisterFromRegistry() {
        cancelReconnect()
    }

    func loadInitialLive() {
        playbackMode = .live
        stopRecoveryTasks(resetFailureWindow: true)
        player.clearReconnectingErrorMessage()
        noteExpectedStopIfReplacingCurrentItem()
        player.loadURL(channel.streamURL, autoplay: true)
        armRecoveryWatchdogs()
        // The user is actively watching this channel — bump probe priority so
        // the badge populates quickly even if scrolling hadn't requested it.
        StreamProbeService.shared.requestProbe(for: channel, priority: .userInitiated)
    }

    func loadLive() {
        playbackMode = .live
        stopRecoveryTasks(resetFailureWindow: true)
        player.clearReconnectingErrorMessage()
        noteExpectedStopIfReplacingCurrentItem()
        player.loadURL(channel.streamURL, autoplay: true)
        armRecoveryWatchdogs()
        StreamProbeService.shared.requestProbe(for: channel, priority: .userInitiated)
    }

    func loadCatchup(_ url: URL) {
        playbackMode = .catchup
        cancelReconnect()
        player.clearReconnectingErrorMessage()
        noteExpectedStopIfReplacingCurrentItem()
        player.loadURL(url, autoplay: true)
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

    /// Called from `PlayerView.onAppear`. Side effects (loadURL/play) must
    /// not run in `init` since SwiftUI may discard the PlayerSession.
    /// Pass `skipInitialLoad: true` when the caller is about to issue its own
    /// `loadURL` (e.g. a pending-catchup hand-off) so we don't fire a throw-
    /// away live load that mpv immediately replaces.
    func start(skipInitialLoad: Bool = false) {
        guard !started else { return }
        started = true
        guard !skipInitialLoad else { return }
        let first = slots[0]
        first.loadInitialLive()
    }

    var focusedSlot: PlayerSlot {
        slots.first { $0.id == focusedSlotID } ?? slots[0]
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
        // Apply mute AFTER loadURL+play: mpv initializes its audio output on
        // file load, and setting `mute` before that can race (a burst of
        // audio leaks out before the mute takes effect).
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
            slot.player.setMute(!focused)
            slot.player.configureResources(multiView: multi, focused: focused)
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
}
