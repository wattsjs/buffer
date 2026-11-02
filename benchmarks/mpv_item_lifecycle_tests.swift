import Foundation

@main
enum MPVItemLifecycleTests {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }

        var state = MPVItemLifecycle()
        state.invalidate(generation: 1)
        let a = state.enqueue(.load("local-A"), generation: 1)!
        let oldAProperty = MPVItemLifecycle.Identity(generation: 1, playlistEntryID: 101)
        state.invalidate(generation: 2)
        expect(state.enqueue(.load("local-B"), generation: 2) == nil, "overlapping item mutations must wait for replies")
        // A has opened in mpv, but its events are still queued while the UI
        // asks for B. Using the latest submitted generation used to credit A.
        state.started(playlistEntryID: 101)
        expect(state.loaded() == nil, "queued A FILE_LOADED must not label requested B")
        expect(state.activeIdentity == nil, "queued A time/dimensions must not publish while B is pending")
        expect(!state.acceptsProperty(for: oldAProperty), "old A GET reply before B starts must be rejected")
        expect(!state.acceptsProperty(for: nil), "read issued while B requested but A active has no accepted source identity")
        let aCompletion = state.complete(requestID: a.id, playlistEntryID: 101)!
        expect(aCompletion.loaded == nil && aCompletion.ended == nil, "late A command reply must not restore obsolete identity")
        let b = aCompletion.next!
        expect(b.generation == 2 && b.command == .load("local-B"), "A reply must dispatch newest B request")
        expect(state.ended(playlistEntryID: 101, reason: .stopped) == nil, "A replacement STOP must not reach current owner")
        expect(state.loadedIdentity == nil, "no first-frame credit before B actually loads")
        expect(state.complete(requestID: a.id, playlistEntryID: 101) == nil, "duplicate reply cannot complete B")
        expect(state.complete(requestID: b.id, playlistEntryID: 202)?.loaded == nil, "command success is not evidence of FILE_LOADED")
        state.started(playlistEntryID: 202)
        let bIdentity = state.loaded()!
        expect(bIdentity == .init(generation: 2, playlistEntryID: 202), "B must receive actual entry identity")
        expect(state.acceptsProperty(for: bIdentity), "acknowledged B properties must publish")
        expect(!state.acceptsProperty(for: oldAProperty), "queued old A GET reply must not overwrite loaded B")
        expect(state.ended(playlistEntryID: 101, reason: .error(code: -1, message: "late A error")) == nil, "obsolete error must not initiate B recovery")
        expect(state.loadedIdentity == bIdentity, "obsolete end must not invalidate B's renderer")
        let bEnd = state.ended(playlistEntryID: 202, reason: .eof)!
        expect(bEnd.identity == bIdentity && bEnd.reason == .eof, "genuine active EOF must remain deliverable")
        expect(state.loadedIdentity == nil, "ended item cannot keep accumulating rendered-frame telemetry")

        // The C API permits completion/event timing to differ. Loaded/failure
        // events seen before binding must be delivered once identity is known.
        state.invalidate(generation: 3)
        let earlyLoad = state.enqueue(.load("local-C"), generation: 3)!
        state.started(playlistEntryID: 303)
        expect(state.loaded() == nil, "unacknowledged item cannot be accepted")
        expect(state.complete(requestID: earlyLoad.id, playlistEntryID: 303)?.loaded == .init(generation: 3, playlistEntryID: 303), "pre-reply FILE_LOADED must not get lost")
        state.invalidate(generation: 4)
        let failedLoad = state.enqueue(.load("missing-local-file"), generation: 4)!
        state.started(playlistEntryID: 404)
        expect(state.ended(playlistEntryID: 404, reason: .error(code: -13, message: "local file missing")) == nil, "failure before reply waits for binding")
        let failure = state.complete(requestID: failedLoad.id, playlistEntryID: 404)?.ended
        expect(failure?.identity.generation == 4 && failure?.reason == .error(code: -13, message: "local file missing"), "actual active failure must survive early event ordering")

        // STOP and loadfile share the sequencing boundary. A pending STOP can
        // be coalesced into a newer replace, but an issued STOP must complete.
        state.invalidate(generation: 5)
        let stop = state.enqueue(.stop, generation: 5)!
        state.invalidate(generation: 6)
        expect(state.enqueue(.load("local-D"), generation: 6) == nil, "new load must not race an issued STOP")
        state.invalidate(generation: 7)
        expect(state.enqueue(.load("local-E"), generation: 7) == nil, "coalescing must retain one in-flight mutation")
        let latest = state.complete(requestID: stop.id, playlistEntryID: nil)!.next!
        expect(latest.generation == 7 && latest.command == .load("local-E"), "unsent D must be superseded by E")
        _ = state.complete(requestID: latest.id, playlistEntryID: 707)
        state.started(playlistEntryID: 707)
        let eIdentity = state.loaded()!
        state.invalidate(generation: 8)
        expect(state.loadedIdentity != eIdentity, "stop/reuse must reject deferred old render tasks")
        expect(state.ended(playlistEntryID: 707, reason: .stopped) == nil, "late pool STOP must not reach new owner")

        // M3U/playlist expansion creates new IDs without a Swift generation.
        let playlist = state.enqueue(.load("local-playlist"), generation: 8)!
        _ = state.complete(requestID: playlist.id, playlistEntryID: 800)
        state.started(playlistEntryID: 800)
        state.redirected(playlistEntryID: 800, first: 801, count: 2)
        state.started(playlistEntryID: 801)
        expect(state.loaded() == .init(generation: 8, playlistEntryID: 801), "redirect child must preserve request association")
        state.invalidate(generation: 9)
        let earlyPlaylist = state.enqueue(.load("early-local-playlist"), generation: 9)!
        state.started(playlistEntryID: 900)
        state.redirected(playlistEntryID: 900, first: 901, count: 1)
        state.started(playlistEntryID: 901)
        _ = state.loaded()
        expect(state.complete(requestID: earlyPlaylist.id, playlistEntryID: 900)?.loaded == .init(generation: 9, playlistEntryID: 901), "early playlist expansion must resolve through the root reply")
        expect(!state.isBackendIdle, "an acknowledged active file is not stopped")
        state.invalidate(generation: 10)
        let finalStop = state.enqueue(.stop, generation: 10)!
        expect(!state.isBackendIdle, "invalidating owner state cannot prove backend teardown")
        _ = state.complete(requestID: finalStop.id, playlistEntryID: nil)
        expect(!state.isBackendIdle, "STOP command reply alone cannot prove END_FILE arrived")
        _ = state.ended(playlistEntryID: 901, reason: .stopped)
        expect(state.isBackendIdle, "END_FILE plus no pending commands proves item teardown")
        print("MPV item lifecycle regression checks: \(checks) passed")
    }
}
