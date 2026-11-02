import Foundation

@main
enum PlaybackControlTests {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }

        var state = PlaybackControlState()
        expect(state.shouldPause, "idle player must be paused")
        state.beginLoad(autoplay: true)
        let firstLoad = state.generation
        expect(!state.shouldPause, "autoplay should request playback")
        expect(state.acceptsLoad(firstLoad), "current URL resolution should be accepted")
        expect(!state.acceptsFrame(firstLoad, fileLoadedGeneration: 0), "old buffered frame before file load must not count")
        expect(state.acceptsFrame(firstLoad, fileLoadedGeneration: firstLoad), "current loaded frame should count")

        // User intent while URL resolution is suspended wins over autoplay.
        state.requestPlayback(false)
        expect(state.shouldPause && !state.playbackRequested, "pause during redirect resolution must persist")
        state.backgroundSuspended = true
        state.backgroundSuspended = false
        expect(state.shouldPause, "focus promotion/render attachment must preserve user pause")
        state.cacheSuspended = true
        state.cacheSuspended = false
        expect(state.shouldPause, "cache recovery must preserve user pause")
        state.systemSuspended = true
        state.systemSuspended = false
        expect(state.shouldPause, "system wake must preserve user pause")

        state.requestPlayback(true)
        state.systemSuspended = true
        expect(state.shouldPause && state.playbackRequested, "sleep suspends without cancelling play intent")
        state.requestPlayback(false)
        state.beginLoad(autoplay: state.playbackRequested)
        state.systemSuspended = false
        expect(state.shouldPause, "pause during sleep or pending recovery must survive reload and wake")
        state.systemSuspended = true
        state.requestPlayback(true)
        state.beginLoad(autoplay: state.playbackRequested)
        expect(state.shouldPause, "loading while asleep must not resume output")
        state.systemSuspended = false
        expect(!state.shouldPause, "wake restores current play intent")

        // Focus policy suspends playback without losing the intent to play.
        state.requestPlayback(true)
        state.backgroundSuspended = true
        expect(state.shouldPause && state.playbackRequested, "thumbnail suspension must preserve play intent")
        state.beginLoad(autoplay: true)
        expect(state.shouldPause, "loading/reconnecting a thumbnail must retain suspension")
        state.backgroundSuspended = false
        expect(!state.shouldPause, "thumbnail promotion should resume requested playback")
        expect(!state.acceptsLoad(firstLoad), "replacing a load invalidates its resolver")
        expect(!state.acceptsFrame(firstLoad, fileLoadedGeneration: state.generation), "delayed rendered-frame task must not label the next load")

        let stoppedLoad = state.generation
        state.stop()
        expect(!state.acceptsLoad(stoppedLoad), "stop/reuse must invalidate a pending resolver")
        expect(!state.acceptsFrame(state.generation, fileLoadedGeneration: state.generation), "idle pooled player must not report a rendered load")
        state.beginLoad(autoplay: false)
        expect(state.shouldPause, "non-autoplay load must remain paused")

        // Simulate a delayed backend reply while intent changes repeatedly.
        let firstWrite = state.reconcilePause()!
        expect(firstWrite.paused, "initial write must pause")
        state.requestPlayback(true)
        expect(state.reconcilePause() == nil, "do not overlap asynchronous pause writes")
        state.requestPlayback(false)
        expect(state.reconcilePause() == nil, "coalesce writes until completion")
        let latestWrite = state.completePauseWrite(id: firstWrite.id)!
        expect(latestWrite.paused, "completion must send newest intent")
        expect(latestWrite.id != firstWrite.id, "pause replies need distinct IDs")
        expect(state.completePauseWrite(id: firstWrite.id) == nil, "stale completion must not finish newer write")
        state.requestPlayback(true)
        state.cacheSuspended = true
        expect(state.reconcilePause() == nil, "cache suspension also waits for in-flight completion")
        state.cacheSuspended = false
        expect(state.reconcilePause() == nil, "cache resume coalesces to current intent")
        let resumedWrite = state.completePauseWrite(id: latestWrite.id)!
        expect(!resumedWrite.paused, "backend must converge to current play intent")
        expect(state.completePauseWrite(id: resumedWrite.id) == nil, "no redundant write when already reconciled")
        let reloadWrite = state.reconcilePause()!
        expect(!reloadWrite.paused, "FILE_LOADED can reassert unchanged play intent")
        state.stop()
        expect(state.reconcilePause() == nil, "stop waits for prior pause write completion")
        let stopWrite = state.completePauseWrite(id: reloadWrite.id)!
        expect(stopWrite.paused, "late backend reply after stop must converge to paused")

        // The independent truth table covers every suspension combination.
        for requested in [false, true] {
            for background in [false, true] {
                for cache in [false, true] {
                    for system in [false, true] {
                        var s = PlaybackControlState()
                        s.beginLoad(autoplay: requested)
                        s.backgroundSuspended = background
                        s.cacheSuspended = cache
                        s.systemSuspended = system
                        expect(s.shouldPause == (!requested || background || system || cache), "pause owner truth table")
                        let write = s.reconcilePause()!
                        expect(write.paused == s.shouldPause, "backend write must follow owners")
                        expect(s.completePauseWrite(id: write.id) == nil, "single write completes cleanly")
                    }
                }
            }
        }
        print("Playback control regression checks: \(checks) passed")
    }
}
