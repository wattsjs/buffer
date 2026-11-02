import Foundation

@main enum StartupTargetTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
        var hold = StartupTargetHold(generation: 2, targetSeconds: 5)
        check(hold.evaluate(cacheSeconds: 8, generation: 2, at: 100) == .waiting,
              "a reported old cache cannot release before current FILE_LOADED")
        hold.fileLoaded(generation: 1, at: 0)
        check(hold.evaluate(cacheSeconds: 8, generation: 2, at: 100) == .waiting,
              "old source FILE_LOADED cannot arm the current target")
        hold.fileLoaded(generation: 2, at: 100)
        for value in [Double?.none, .some(-1), .some(.nan), .some(.infinity), .some(0), .some(4.999)] {
            check(hold.evaluate(cacheSeconds: value, generation: 2, at: 101) == .waiting,
                  "invalid, zero and insufficient reported cache cannot release")
        }
        check(hold.evaluate(cacheSeconds: 6, generation: 1, at: 101) == .waiting,
              "stale source cache cannot release the current target")
        check(hold.evaluate(cacheSeconds: 5.006, generation: 2, at: 102) == .ready(cacheSeconds: 5.006),
              "release records the actual unrounded reported value at the target")
        check(hold.evaluate(cacheSeconds: 6, generation: 2, at: 103) == .waiting,
              "a released hold cannot release a second time")
        var timeout = StartupTargetHold(generation: 3, targetSeconds: 5)
        timeout.fileLoaded(generation: 3, at: 10)
        check(timeout.evaluate(cacheSeconds: 1.5, generation: 3, at: 21.99) == .waiting,
              "short native reserve is insufficient")
        check(timeout.evaluate(cacheSeconds: 1.5, generation: 3, at: 22) == .timedOut,
              "additional wait is bounded at 12 seconds after FILE_LOADED")
        check(timeout.evaluate(cacheSeconds: 8, generation: 3, at: 23) == .waiting,
              "timeout cannot turn into a successful release later")
        var late = StartupTargetHold(generation: 4, targetSeconds: 5)
        late.fileLoaded(generation: 4, at: 10)
        check(late.evaluate(cacheSeconds: 8, generation: 4, at: 23) == .timedOut,
              "a late qualifying sample cannot bypass the bounded wait")

        var control = PlaybackControlState()
        control.beginLoad(autoplay: true)
        let previousUnpause = control.reconcilePause()!
        control.startupSuspended = true
        check(control.shouldPause, "startup hold participates in existing pause ownership")
        check(control.reconcilePause() == nil && !control.pauseWritesAreSettled,
              "an old unpause request must complete before the desired hold is acknowledged")
        let heldPause = control.completePauseWrite(id: previousUnpause.id)!
        check(heldPause.paused && !control.pauseWritesAreSettled,
              "the next serialized pause must reflect the hold")
        check(control.completePauseWrite(id: heldPause.id) == nil && control.pauseWritesAreSettled,
              "load barrier opens only after latest hold pause completes")
        control.requestPlayback(true)
        check(control.startupSuspended && control.shouldPause, "owner play cannot bypass an unsatisfied target")
        control.requestPlayback(false)
        control.startupSuspended = false
        check(control.shouldPause && !control.playbackRequested, "target release cannot undo a newer user pause")
        control.requestPlayback(true)
        control.startupSuspended = true
        control.systemSuspended = true
        control.startupSuspended = false
        check(control.shouldPause, "target release cannot override system suspension")
        control.systemSuspended = false
        control.cacheSuspended = true
        check(control.indicatesBuffering(nativePausedForCache: true), "native and app buffering combine")
        control.cacheSuspended = false
        check(control.indicatesBuffering(nativePausedForCache: true),
              "app floor resume must not clear native paused-for-cache buffering")
        control.startupSuspended = true
        check(control.indicatesBuffering(nativePausedForCache: false),
              "a native cache notification cannot clear an active startup hold")
        check(!control.indicatesBuffering(nativePausedForCache: false, startupWaiting: false) && control.shouldPause,
              "failed bounded wait remains paused while its UI stops claiming an active startup wait")
        control.stop()
        check(!control.startupSuspended && !control.indicatesBuffering(nativePausedForCache: true),
              "stop/reuse clears the hold and its buffering UI")
        print("PASS \(checks) startup target and pause ownership checks")
    }
}
