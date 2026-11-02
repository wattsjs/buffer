import Foundation

enum SavedPlaybackScenario { nonisolated(unsafe) static var isCapturing = true }
enum PlaybackValidation { nonisolated(unsafe) static var isEnabled = true }

/// A backend boundary double only: lifecycle/reconnect policy comes from the
/// production PlayerSlot, and pause ownership from PlaybackControlState.
/// Never opens sockets, creates mpv handles, or launches an application.
@MainActor
final class MPVPlayer {
    struct PlaybackStats { var videoBitrateBps: Int64 = 0 }
    var playbackStats = PlaybackStats()
    struct MediaInfo {
        var width = 0
        var height = 0
        var fps = 0.0
        var videoCodec = ""
        var audioCodec = ""
        var audioChannels = 0
        var liveLatencySeconds: Double?
    }
    var onPlaybackEnded: ((MPVEndReason) -> Void)?
    var onFileLoaded: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    var onStreamIssue: ((MPVStreamIssue) -> Void)?
    var onMediaInfoChanged: ((MediaInfo) -> Void)?
    var control = PlaybackControlState()
    var currentURL: URL?
    var timePos = 0.0
    var duration = 0.0
    var isSeekable = false
    var hasRenderedCurrentLoad = false
    var isPlaying: Bool { currentURL != nil && !control.shouldPause }
    var wantsPlayback: Bool { control.playbackRequested }
    var isBuffering = false
    var isLoading = false
    var focusedScaling = true
    var telemetryLoadGeneration: Int { control.generation }
    var loadCount = 0
    var mediaInfo = MediaInfo()
    var telemetryRenderedFrameCount = 0
    var ownerPlaybackIntentRevision: UInt64 = 0
    var holdsTeardown = false
    var teardownCompletions: [() -> Void] = []
    func stopWhenBackendIdle(_ completion: @escaping () -> Void) {
        control.stop()
        currentURL = nil
        if holdsTeardown { teardownCompletions.append(completion) }
        else { completion() }
    }
    func confirmBackendIdle() {
        holdsTeardown = false
        let completions = teardownCompletions
        teardownCompletions.removeAll()
        for completion in completions { completion() }
    }
    var usesArchiveTimestampRecovery = false
    var seekCount = 0
    var errorMessage: String?
    var usesStartupReserve = false
    var startupTargetTimedOut = false
    var startupHoldActive: Bool { control.startupSuspended }
    var startupTargetEnabled = false
    var nativeCacheOnlyEnabled = false
    var liveAnalysisEnabled = false

    static func invalidateResolvedURL(for url: URL) {}
    func prepareForReuse() {
        onPlaybackEnded = nil
        onFileLoaded = nil
        onFirstFrame = nil
        onStreamIssue = nil
        onMediaInfoChanged = nil
        control.stop()
        control.backgroundSuspended = false
        control.systemSuspended = false
        currentURL = nil
        errorMessage = nil
        isLoading = false
        focusedScaling = true
        usesStartupReserve = false
        startupTargetEnabled = false
        nativeCacheOnlyEnabled = false
    }
    func loadURL(_ url: URL, autoplay: Bool, archive: Bool = false, live: Bool = false) {
        ownerPlaybackIntentRevision &+= 1
        control.beginLoad(autoplay: autoplay)
        currentURL = url
        loadCount += 1
        timePos = 0
        isLoading = true
        usesArchiveTimestampRecovery = ArchiveTimestampRecovery.options(forArchiveLoad: archive).enabled
        let eligibleLive = live && !archive && !url.isFileURL
        startupTargetEnabled = MPVStartupTarget.enabled(forLiveLoad: eligibleLive)
        control.startupSuspended = startupTargetEnabled
        nativeCacheOnlyEnabled = MPVNativeCacheOnly.enabled(forLiveLoad: eligibleLive)
        usesStartupReserve = !startupTargetEnabled && MPVStartupReserve.enabled(forLiveLoad: eligibleLive)
    }
    func play() { ownerPlaybackIntentRevision &+= 1; control.requestPlayback(true) }
    func pause() { ownerPlaybackIntentRevision &+= 1; control.requestPlayback(false) }
    func pauseBackgroundActivity() { control.systemSuspended = true }
    func resumeBackgroundActivity() { control.systemSuspended = false }
    func seek(to seconds: Double) { timePos = seconds; seekCount += 1 }
    func setMute(_ muted: Bool) {}
    func logPlaybackSyncSnapshot(_ label: String) {}
    func setReconnectingErrorMessage(_ message: String) { errorMessage = message }
    func clearReconnectingErrorMessage() { errorMessage = nil }
    func configureResources(multiView: Bool, focused: Bool) {
        focusedScaling = !multiView || focused
        control.backgroundSuspended = multiView && !focused
    }
}

@MainActor
final class StreamProbeService {
    static let shared = StreamProbeService()
    func recordPlaybackInfo(channel: Channel, width: Int, height: Int, fps: Double,
                            videoCodec: String, audioCodec: String, audioChannels: Int,
                            liveLatencySeconds: Double?) {}
    func requestProbe(for channel: Channel, priority: TaskPriority) {}
    func recordPlaybackHealth(channel: Channel, health: StreamHealth,
                              healthySeconds: Double, bufferingSeconds: Double, at date: Date,
                              ordinaryLive: Bool = false) {}
    func recordPlaybackBitrate(channel: Channel, bitsPerSecond: Int64) {}
}
