/// Playback intent outlives mpv's transient pause notifications. Rendering,
/// resource policies and cache recovery may suspend playback, but cannot change
/// whether the owner requested it. Kept independent of libmpv for regression tests.
struct PlaybackControlState {
    struct PauseWrite: Equatable {
        let id: UInt64
        let paused: Bool
    }

    private(set) var generation = 0
    private(set) var hasActiveLoad = false
    private(set) var playbackRequested = false
    var backgroundSuspended = false
    var systemSuspended = false
    var cacheSuspended = false
    var startupSuspended = false

    private var requestSerial: UInt64 = 0
    private var pauseWriteInFlight: PauseWrite?
    private var pauseReconciliationPending = false
    var inFlightPauseWrite: PauseWrite? { pauseWriteInFlight }
    var pauseWritesAreSettled: Bool { pauseWriteInFlight == nil && !pauseReconciliationPending }

    var shouldPause: Bool {
        !playbackRequested || backgroundSuspended || systemSuspended || cacheSuspended || startupSuspended
    }

    func indicatesBuffering(nativePausedForCache: Bool, startupWaiting: Bool? = nil) -> Bool {
        playbackRequested && !backgroundSuspended && !systemSuspended &&
            (nativePausedForCache || cacheSuspended || (startupWaiting ?? startupSuspended))
    }

    mutating func beginLoad(autoplay: Bool) {
        generation &+= 1
        hasActiveLoad = true
        playbackRequested = autoplay
        cacheSuspended = false
        startupSuspended = false
    }

    mutating func stop() {
        generation &+= 1
        hasActiveLoad = false
        playbackRequested = false
        cacheSuspended = false
        startupSuspended = false
    }

    mutating func requestPlayback(_ requested: Bool) {
        playbackRequested = requested
        cacheSuspended = false
    }

    func acceptsLoad(_ candidate: Int) -> Bool {
        hasActiveLoad && candidate == generation
    }

    func acceptsFrame(_ candidate: Int, fileLoadedGeneration: Int) -> Bool {
        acceptsLoad(candidate) && fileLoadedGeneration == generation
    }

    /// libmpv does not guarantee ordering among async calls. Send one pause
    /// write at a time, coalescing changes to the newest intent until its reply.
    mutating func reconcilePause() -> PauseWrite? {
        pauseReconciliationPending = true
        return nextPauseWrite()
    }

    mutating func completePauseWrite(id: UInt64) -> PauseWrite? {
        guard pauseWriteInFlight?.id == id else { return nil }
        pauseWriteInFlight = nil
        return nextPauseWrite()
    }

    private mutating func nextPauseWrite() -> PauseWrite? {
        guard pauseWriteInFlight == nil, pauseReconciliationPending else { return nil }
        pauseReconciliationPending = false
        requestSerial &+= 1
        let write = PauseWrite(id: (1 << 63) | requestSerial, paused: shouldPause)
        pauseWriteInFlight = write
        return write
    }
}
