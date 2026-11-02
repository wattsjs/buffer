import Foundation
import Observation

nonisolated private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false
    var value: Bool { lock.withLock { storedValue } }
    func set() { lock.withLock { storedValue = true } }
}

@MainActor private final class MatchProbe {
    private var continuations: [Int: CheckedContinuation<[StreamMatch], Never>] = [:]
    private(set) var started = 0
    private(set) var canceled: Set<Int> = []

    // Deliberately non-cooperative: lets a canceled request finish late so
    // the production publication guard is exercised independently of sleep.
    func match() async -> [StreamMatch] {
        started += 1
        let request = started
        let result = await withCheckedContinuation { continuations[request] = $0 }
        if Task.isCancelled { canceled.insert(request) }
        return result
    }

    func finish(_ request: Int, with matches: [StreamMatch]) {
        precondition(continuations[request] != nil, "Request has not started or already completed")
        continuations.removeValue(forKey: request)!.resume(returning: matches)
    }
}

@main struct SportCardMatchingTests {
    @MainActor static func main() async {
        let owner = NSObject()
        let now = Date()
        let league = League.all.first { $0.slug == "nba" }!
        func event(score: String? = nil, title: String = "Lakers vs Celtics", broadcast: [String] = ["ESPN"], status: EventStatus = .live(detail: nil)) -> SportEvent {
            SportEvent(
                id: "same-event", sport: .basketball, league: league, title: title, shortTitle: "LAL vs BOS",
                homeTeam: TeamInfo(name: "Lakers", abbreviation: "LAL", displayName: "Los Angeles Lakers", score: score,
                                   logoURL: nil, record: nil),
                awayTeam: TeamInfo(name: "Celtics", abbreviation: "BOS", displayName: "Boston Celtics", score: nil,
                                   logoURL: nil, record: nil),
                startDate: now, status: status, broadcast: broadcast,
                venue: nil, detail: nil, tournamentName: nil, leader: nil
            )
        }
        func context(_ revision: Int, event suppliedEvent: SportEvent? = nil, preferencesVersion: Int = 0) -> SportEventMatchContext {
            SportEventMatchContext(event: suppliedEvent ?? event(), indexVersion: revision, modelIdentity: ObjectIdentifier(owner), preferencesVersion: preferencesVersion)
        }
        func match(_ source: String) -> StreamMatch {
            StreamMatch(
                channel: Channel(id: "shared-channel-id", name: "ESPN NBA", logoURL: nil, group: "Sports",
                                 streamURL: URL(string: "http://127.0.0.1/\(source)")!, epgChannelID: "guide"),
                score: 0.9, reason: "Sports", programTitle: "NBA", programDescription: nil,
                programStart: now, programEnd: now.addingTimeInterval(3600), isHidden: false
            )
        }
        func wait(_ message: String, _ predicate: () -> Bool) async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
            precondition(predicate(), message)
        }

        // Scores change every scoreboard refresh; matching identities change
        // only for fields actually used by matching and preference ordering.
        let a = context(1)
        precondition(a == context(1, event: event(score: "102")))
        precondition(a != context(1, event: event(title: "Different event")))
        precondition(a != context(1, event: event(broadcast: ["TNT"])))
        precondition(a != context(1, event: event(status: .final_(detail: "Final"))), "Finished status retained live action context")
        let scheduledContext = context(1, event: event(status: .scheduled))
        precondition(scheduledContext != context(1, event: event(status: .postponed)), "Postponement retained stale prestart live action context")
        precondition(a == context(1, event: event(status: .live(detail: "Quarter 2"))), "Cosmetic live status detail invalidated matching")
        precondition(a != context(1, preferencesVersion: 1))
        precondition(a != context(2))
        let replacementOwner = NSObject()
        precondition(a != SportEventMatchContext(event: event(), indexVersion: 1, modelIdentity: ObjectIdentifier(replacementOwner)))

        let probe = MatchProbe()
        let state = SportEventMatchState()
        func update(_ key: SportEventMatchContext, presented: Bool = true, unavailable: String? = nil) {
            state.update(context: key, unavailableMessage: unavailable, isPresented: presented) { [probe] in await probe.match() }
        }
        func snapshot(_ key: SportEventMatchContext) -> SportEventMatchState.Snapshot {
            state.snapshot(for: key, unavailableMessage: nil)
        }
        update(a)
        update(a)
        await wait("First request did not start") { probe.started == 1 }
        precondition(snapshot(a).isMatching)
        probe.finish(1, with: [match("source-a")])
        await wait("First request did not publish") { !snapshot(a).isMatching }
        precondition(snapshot(a).matches.first?.channel.streamURL.lastPathComponent == "source-a")
        precondition(state.hasCurrentMatches(for: a))
        update(a, presented: false)
        update(a)
        await Task.yield()
        precondition(probe.started == 1, "Reopening unchanged results repeated matching")

        // Source B deliberately reuses A's channel ID. A render before the
        // onChange callback must already reject A's authenticated destination.
        let b = context(2)
        precondition(snapshot(b).matches.isEmpty)
        precondition(!state.hasCurrentMatches(for: b), "An old button action was accepted for the replacement source")
        let contextInvalidated = ObservationFlag()
        withObservationTracking {
            _ = snapshot(b)
        } onChange: {
            contextInvalidated.set()
        }
        update(b, presented: false)
        precondition(!state.hasCurrentMatches(for: a), "A rendered old row remained actionable after invalidation")
        precondition(contextInvalidated.value, "A new context didn't notify a previously mismatched snapshot")
        precondition(snapshot(b).matches.isEmpty)
        update(b)
        update(b)
        await wait("Replacement request did not start") { probe.started == 2 }
        let c = context(3)
        update(c)
        await wait("Newest request did not start") { probe.started == 3 }
        probe.finish(2, with: [match("source-b")])
        await wait("Old worker did not receive cancellation") { probe.canceled.contains(2) }
        precondition(snapshot(c).matches.isEmpty && snapshot(c).isMatching,
                     "Late canceled completion overwrote the newest request")
        probe.finish(3, with: [match("source-c")])
        await wait("Newest result did not publish") { !snapshot(c).isMatching }
        precondition(snapshot(c).matches.first?.channel.streamURL.lastPathComponent == "source-c")

        // Guide unavailable means no background matching, and no obsolete
        // matches. A newly ready index resumes matching the open popover.
        let unavailable = context(4)
        update(unavailable, unavailable: "Indexing channels and guide data…")
        precondition(snapshot(unavailable).matches.isEmpty && !snapshot(unavailable).isMatching)
        precondition(snapshot(unavailable).unavailableMessage == "Indexing channels and guide data…")
        await Task.yield()
        precondition(probe.started == 3)
        let ready = context(5)
        update(ready)
        await wait("Ready index did not rematch") { probe.started == 4 }
        probe.finish(4, with: [])
        await wait("Empty result did not publish") { !snapshot(ready).isMatching }
        precondition(snapshot(ready).matches.isEmpty && snapshot(ready).unavailableMessage == nil)
        update(ready)
        await Task.yield()
        precondition(probe.started == 4, "A cached empty result repeated matching")

        // Closing/dismissing a card cancels the pending request and a late
        // result cannot populate the cache or reopen a popover.
        let d = context(6)
        update(d)
        await wait("Dismissal request did not start") { probe.started == 5 }
        update(d, presented: false)
        precondition(!snapshot(d).isMatching)
        probe.finish(5, with: [match("dismissed")])
        await wait("Dismissal did not cancel its worker") { probe.canceled.contains(5) }
        precondition(snapshot(d).matches.isEmpty)
        update(d)
        await wait("Reopening canceled request did not retry") { probe.started == 6 }
        probe.finish(6, with: [match("reopened")])
        await wait("Reopened request did not publish") { !snapshot(d).isMatching }
        precondition(snapshot(d).matches.first?.channel.streamURL.lastPathComponent == "reopened")

        // The task must not keep its view-owned state alive during matching.
        var discarded: SportEventMatchState? = SportEventMatchState()
        weak let weakDiscarded = discarded
        discarded!.update(context: a, unavailableMessage: nil, isPresented: true) { [probe] in await probe.match() }
        await wait("Disposal request did not start") { probe.started == 7 }
        discarded = nil
        precondition(weakDiscarded == nil, "Matching retained its card state")
        probe.finish(7, with: [match("discarded")])
        await wait("Disposal did not cancel its worker") { probe.canceled.contains(7) }

        // Several source/guide invalidations delivered in one main-actor turn
        // should dispatch only the newest request, rather than match each
        // intermediate context after it has already become obsolete.
        let burst = SportEventMatchState()
        for version in 10...25 {
            burst.update(context: context(version), unavailableMessage: nil, isPresented: true) { [probe] in await probe.match() }
        }
        await wait("Coalesced source burst did not start") { probe.started == 8 }
        await Task.yield()
        precondition(probe.started == 8, "Canceled source burst requests still dispatched")
        probe.finish(8, with: [match("latest-burst")])
        await wait("Latest burst result did not publish") {
            !burst.snapshot(for: context(25), unavailableMessage: nil).isMatching
        }
        precondition(burst.snapshot(for: context(25), unavailableMessage: nil).matches.first?.channel.streamURL.lastPathComponent == "latest-burst")

        let preferenceProbe = MatchProbe()
        let preferenceState = SportEventMatchState()
        func updatePreferences(_ key: SportEventMatchContext) {
            preferenceState.update(context: key, unavailableMessage: nil, isPresented: true) { [preferenceProbe] in
                await preferenceProbe.match()
            }
        }
        updatePreferences(a)
        await wait("Preference fixture request did not start") { preferenceProbe.started == 1 }
        preferenceProbe.finish(1, with: [match("initial-ranking")])
        await wait("Preference fixture did not publish") { !preferenceState.snapshot(for: a, unavailableMessage: nil).isMatching }
        updatePreferences(context(1, event: event(score: "104")))
        await Task.yield()
        precondition(preferenceProbe.started == 1, "Cosmetic scoreboard score changed matching inputs")
        let preferenceUpdate = context(1, preferencesVersion: 1)
        updatePreferences(preferenceUpdate)
        precondition(preferenceState.snapshot(for: preferenceUpdate, unavailableMessage: nil).matches.isEmpty)
        await wait("Preference version didn't rematch the open card") { preferenceProbe.started == 2 }
        preferenceProbe.finish(2, with: [match("new-ranking")])
        await wait("Preference result did not publish") { !preferenceState.snapshot(for: preferenceUpdate, unavailableMessage: nil).isMatching }
        precondition(preferenceState.snapshot(for: preferenceUpdate, unavailableMessage: nil).matches.first?.channel.streamURL.lastPathComponent == "new-ranking")

        print("PASS sports card cache identity, same-ID source replacement, render-time invalidation, task/source-burst coalescing, stale completion, empty guide/result, dismissal/reopen, preference revisions, cosmetic scores and disposal")
    }
}
