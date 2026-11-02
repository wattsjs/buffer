import Foundation

@MainActor
private final class FakeBackend: SavedPlaybackScenarioBackend {
    var hasUnrelatedPlayers = false
    var calls: [String] = []
    var live = false
    var failPrepare: String?
    var failObserve = false
    var failClose = false
    var restoreSucceeds = true
    func captureOriginalState() throws -> String { calls.append("capture"); return "original" }
    func prepare(_ item: SavedPlaybackScenarioPlan.Case, timeoutSeconds: Int) async throws -> String {
        precondition(!live, "Source changed while previous backend was live")
        let channel = item.channelName ?? item.vodName ?? item.vodID!
        calls.append("prepare:\(channel)")
        if channel == failPrepare { throw SavedScenarioFailure.channelMissing }
        return channel
    }
    func open(_ item: String) async throws { calls.append("open:\(item)"); live = true }
    func observe(caseIndex: Int, seconds: Int, emit: @escaping ([String: Any]) -> Void) async throws {
        calls.append("observe:\(caseIndex)")
        if failObserve { throw SavedScenarioFailure.playerChanged }
    }
    func closeOwnedPlayer(timeoutSeconds: Int) async throws {
        calls.append("close")
        if failClose { throw SavedScenarioFailure.stopTimedOut }
        live = false
    }
    func restore(_ state: String, timeoutSeconds: Int) async -> Bool {
        precondition(!live, "Restore attempted with a live backend")
        calls.append("restore:\(state)")
        return restoreSucceeds
    }
}

@main
struct SavedScenarioTests {
    @MainActor
    static func main() async throws {
        let data = Data(#"{"schema":1,"caseSeconds":45,"sourceTimeoutSeconds":30,"cases":[{"sourceName":"Source A","channelName":"First"},{"sourceName":"Source B","channelName":"Second"}]}"#.utf8)
        let plan = try SavedPlaybackScenarioPlan.decode(data)
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label); checks += 1
        }
        var events: [[String: Any]] = []
        let success = FakeBackend()
        await SavedPlaybackScenarioCoordinator.run(plan: plan, backend: success) { events.append($0) }
        check(success.calls == ["capture", "prepare:First", "open:First", "observe:0", "close",
                                "prepare:Second", "open:Second", "observe:1", "close", "restore:original"],
              "Each stream must stop before next source preparation")
        check(events.last?["restored"] as? Bool == true, "Original state restored")
        check(events.filter { $0["event"] as? String == "case-closed" }.count == 2, "Both backend acknowledgments emitted")

        events = []
        let missing = FakeBackend(); missing.failPrepare = "First"
        await SavedPlaybackScenarioCoordinator.run(plan: plan, backend: missing) { events.append($0) }
        check(missing.calls == ["capture", "prepare:First", "prepare:Second", "open:Second", "observe:1", "close", "restore:original"],
              "Missing case must not open fake playback and later cases still run")
        let missingEnd = events.first { $0["event"] as? String == "case-end" }
        check(missingEnd?["captured"] as? Bool == false, "Missing case cannot claim healthy capture")
        check(missingEnd?["reason"] as? String == SavedScenarioFailure.channelMissing.rawValue, "Missing case has a safe reason")

        events = []
        let observeFailure = FakeBackend(); observeFailure.failObserve = true
        await SavedPlaybackScenarioCoordinator.run(plan: plan, backend: observeFailure) { events.append($0) }
        check(observeFailure.calls.filter { $0 == "close" }.count == 2, "Observation failure still tears down both owned streams")
        check(observeFailure.calls.last == "restore:original", "Observation failure still restores source")

        events = []
        let stopFailure = FakeBackend(); stopFailure.failClose = true
        await SavedPlaybackScenarioCoordinator.run(plan: plan, backend: stopFailure) { events.append($0) }
        check(!stopFailure.calls.contains("prepare:Second"), "Unconfirmed stop prevents next source")
        check(!stopFailure.calls.contains("restore:original"), "Unconfirmed stop prevents source restoration overlap")
        check(events.last?["teardownConfirmed"] as? Bool == false, "Unconfirmed stop fails evidence")

        events = []
        let unrelated = FakeBackend(); unrelated.hasUnrelatedPlayers = true
        await SavedPlaybackScenarioCoordinator.run(plan: plan, backend: unrelated) { events.append($0) }
        check(unrelated.calls.isEmpty, "Unrelated existing player must prevent all mutations")
        check(events.contains { $0["reason"] as? String == SavedScenarioFailure.unrelatedPlayers.rawValue }, "Unrelated player is explicit evidence failure")

        let quickData = Data(#"{"schema":1,"caseSeconds":25,"sourceTimeoutSeconds":30,"cases":[{"sourceName":"A","channelName":"First"}]}"#.utf8)
        check(try SavedPlaybackScenarioPlan.decode(quickData).caseSeconds == 25, "Quick matrix retains a bounded observation interval")
        let vodData = Data(#"{"schema":1,"caseSeconds":25,"sourceTimeoutSeconds":30,"cases":[{"sourceName":"A","vodID":"123","playbackMode":"vod","vodResumeSeconds":60}]}"#.utf8)
        let vodPlan = try SavedPlaybackScenarioPlan.decode(vodData)
        check(vodPlan.cases[0].requestsVOD, "VOD is an explicit on-demand request")
        check(vodPlan.cases[0].vodResumeSeconds == 60, "VOD resume position preserved")
        let vodBackend = FakeBackend()
        await SavedPlaybackScenarioCoordinator.run(plan: vodPlan, backend: vodBackend) { _ in }
        check(vodBackend.calls == ["capture", "prepare:123", "open:123", "observe:0", "close", "restore:original"],
              "VOD follows the same confirmed sequential lifecycle")
        for bad in [
            #"{"schema":1,"caseSeconds":45,"sourceTimeoutSeconds":30,"password":"forbidden","cases":[]}"#,
            #"{"schema":1,"caseSeconds":45,"sourceTimeoutSeconds":30,"cases":[{"sourceName":"http://not-a-selector","channelName":"First"}]}"#,
            #"{"schema":1,"caseSeconds":45,"sourceTimeoutSeconds":30,"cases":[{"sourceName":"A","channelName":"First","expectedWidth":1920}]}"#,
            #"{"schema":1,"caseSeconds":10,"sourceTimeoutSeconds":30,"cases":[{"sourceName":"A","channelName":"First"}]}"#,
            #"{"schema":1,"caseSeconds":25,"sourceTimeoutSeconds":30,"cases":[{"sourceName":"A","channelName":"First","playbackMode":"vod"}]}"#,
            #"{"schema":1,"caseSeconds":25,"sourceTimeoutSeconds":30,"cases":[{"sourceName":"A","vodName":"Movie"}]}"#,
            #"{"schema":1,"caseSeconds":25,"sourceTimeoutSeconds":30,"cases":[{"sourceName":"A","vodName":"Movie","channelID":"1","playbackMode":"vod"}]}"#,
            #"{"schema":1,"caseSeconds":25,"sourceTimeoutSeconds":30,"cases":[{"sourceName":"A","vodID":"1","playbackMode":"vod","vodResumeSeconds":0}]}"#
        ] {
            do { _ = try SavedPlaybackScenarioPlan.decode(Data(bad.utf8)); preconditionFailure("Unsafe or incomplete plan accepted") }
            catch { checks += 1 }
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let archiveChannel = Channel(id: "archive", name: "Archive", logoURL: nil, group: "Tests",
            streamURL: URL(string: "http://127.0.0.1/unopened")!, epgChannelID: "guide",
            catchup: CatchupInfo(kind: .shift, days: 2, source: nil))
        let actual = EPGProgram(id: "real", channelID: "guide", title: "Actual guide entry", description: "",
            start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600))
        let older = EPGProgram(id: "older", channelID: "guide", title: "Older guide entry", description: "",
            start: now.addingTimeInterval(-10800), end: now.addingTimeInterval(-7200))
        let chosen = try SavedScenarioArchiveSelection.programme(channel: archiveChannel, programmes: [older, actual],
            offsetMinutes: 90, minimumDurationSeconds: 75, now: now)
        check(chosen.id == actual.id, "Catch-up selects the actual programme at or preceding the requested offset")
        do { _ = try SavedScenarioArchiveSelection.programme(channel: archiveChannel, programmes: [], offsetMinutes: 90,
                minimumDurationSeconds: 75, now: now); preconditionFailure("Invented missing archive programme") }
        catch SavedScenarioFailure.catchupProgrammeUnavailable { checks += 1 }
        do { _ = try SavedScenarioArchiveSelection.programme(channel: archiveChannel, programmes: [actual], offsetMinutes: 4320,
                minimumDurationSeconds: 75, now: now); preconditionFailure("Accepted offset outside advertised archive") }
        catch SavedScenarioFailure.archiveUnavailable { checks += 1 }
        let noArchive = Channel(id: "live", name: "Live", logoURL: nil, group: "Tests",
            streamURL: URL(string: "http://127.0.0.1/unopened")!, epgChannelID: "guide")
        do { _ = try SavedScenarioArchiveSelection.programme(channel: noArchive, programmes: [actual], offsetMinutes: 90,
                minimumDurationSeconds: 75, now: now); preconditionFailure("No-archive channel accepted") }
        catch SavedScenarioFailure.archiveUnavailable { checks += 1 }
        let wrongGuide = EPGProgram(id: "other", channelID: "wrong-guide", title: "Other channel", description: "",
            start: actual.start, end: actual.end)
        do { _ = try SavedScenarioArchiveSelection.programme(channel: archiveChannel, programmes: [wrongGuide], offsetMinutes: 90,
                minimumDurationSeconds: 75, now: now); preconditionFailure("Other channel programme accepted") }
        catch SavedScenarioFailure.catchupProgrammeUnavailable { checks += 1 }
        print("Saved scenario coordinator: \(checks) checks passed")
    }
}
