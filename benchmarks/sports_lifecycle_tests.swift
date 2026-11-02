import Foundation

final class SportsMatchBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    var isEntered: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func wait() {
        condition.lock()
        entered = true
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

@main
struct SportsLifecycleTests {
    @MainActor static func main() async {
        let session = fixtureSession()
        let client = ESPNClient(session: session)
        let now = Date()
        let league = League.all.first { $0.slug == "nba" }!
        let event = SportEvent(
            id: "fixture", sport: .basketball, league: league,
            title: "Boston Celtics vs Los Angeles Lakers", shortTitle: "BOS vs LAL",
            homeTeam: TeamInfo(name: "Lakers", abbreviation: "LAL", displayName: "Los Angeles Lakers", score: nil, logoURL: nil, record: nil),
            awayTeam: TeamInfo(name: "Celtics", abbreviation: "BOS", displayName: "Boston Celtics", score: nil, logoURL: nil, record: nil),
            startDate: now, status: .live(detail: nil), broadcast: ["ESPN"],
            venue: nil, detail: nil, tournamentName: nil, leader: nil
        )
        func channel(_ id: String) -> Channel {
            Channel(id: id, name: "ESPN NBA", logoURL: nil, group: "Sports",
                    streamURL: URL(string: "http://127.0.0.1/\(id)")!, epgChannelID: id)
        }
        func guide(_ id: String) -> [String: [EPGProgram]] {
            [id: [EPGProgram(id: id, channelID: id, title: event.title, description: "NBA basketball",
                             start: now, end: now.addingTimeInterval(3600))]]
        }
        func update(_ model: SportsViewModel, id: String, hasGuide: Bool = true,
                    version: Int, guideVersion: Int, hidden: Set<String> = [], deferred: Bool = false) {
            model.updateStreamMatchingContext(
                channels: [channel(id)], programs: hasGuide ? guide(id) : [:],
                favoriteChannelIDs: [], channelPreferenceScores: [:], groupPreferenceScores: [:],
                hiddenGroups: hidden, guideVersion: guideVersion, channelSetVersion: version,
                deferGuideIndex: deferred
            )
        }

        // A model awaiting fixture I/O must be releasable; deinit must cancel
        // all active transports instead of letting them finish behind the UI.
        FixtureURLProtocol.reset(delay: 5)
        var loadingModel: SportsViewModel? = SportsViewModel(espn: client, fixtureCache: .disabled)
        let weakLoadingModel = WeakSportsModel(loadingModel)
        loadingModel?.refresh()
        await waitUntil("Sports refresh did not start") { FixtureURLProtocol.counts.started >= 8 }
        loadingModel = nil
        precondition(weakLoadingModel.value == nil, "Networking retained the sports model")
        await waitUntil("Model disposal did not cancel transport work") { FixtureURLProtocol.counts.active == 0 }
        precondition(FixtureURLProtocol.counts.started == 8)

        FixtureURLProtocol.reset()
        let model = SportsViewModel(espn: client, fixtureCache: .disabled)
        update(model, id: "source-a", version: 1, guideVersion: 1)
        await waitUntil("Initial index did not publish") { model.isStreamIndexReady }
        let initialMatches = await model.matchEvent(event)
        precondition(initialMatches.map(\.channel.id) == ["source-a"])

        // Preference revisions represent actual ranking values, independently
        // of the index and source. Equal rebuilt maps must keep their revision.
        let rankingModel = SportsViewModel(espn: client, fixtureCache: .disabled)
        let first = channel("ranking-first")
        let second = channel("ranking-second")
        let rankingGuide = guide(first.id).merging(guide(second.id)) { old, _ in old }
        rankingModel.updateStreamMatchingContext(channels: [first, second], programs: rankingGuide,
                                                 favoriteChannelIDs: [], channelPreferenceScores: [:], groupPreferenceScores: [:],
                                                 hiddenGroups: [], guideVersion: 1, channelSetVersion: 1)
        await waitUntil("Ranking fixture did not index") { rankingModel.isStreamIndexReady }
        let rankingIndexVersion = rankingModel.searchIndexVersion
        rankingModel.updateStreamMatchingPreferences(favoriteChannelIDs: [first.id], channelPreferenceScores: [:], groupPreferenceScores: [:])
        let favoriteVersion = rankingModel.matchingPreferencesVersion
        precondition(favoriteVersion > 0)
        let favoriteMatches = await rankingModel.matchEvent(event)
        precondition(favoriteMatches.first?.channel.id == first.id)
        rankingModel.updateStreamMatchingPreferences(favoriteChannelIDs: [first.id], channelPreferenceScores: [:], groupPreferenceScores: [:])
        precondition(rankingModel.matchingPreferencesVersion == favoriteVersion)
        rankingModel.updateStreamMatchingPreferences(favoriteChannelIDs: [], channelPreferenceScores: [second.id: 1.0], groupPreferenceScores: [:])
        precondition(rankingModel.matchingPreferencesVersion == favoriteVersion + 1)
        let channelRankedMatches = await rankingModel.matchEvent(event)
        precondition(channelRankedMatches.first?.channel.id == second.id)
        let scoreVersion = rankingModel.matchingPreferencesVersion
        rankingModel.updateStreamMatchingPreferences(favoriteChannelIDs: [], channelPreferenceScores: [second.id: 1.0], groupPreferenceScores: [:])
        precondition(rankingModel.matchingPreferencesVersion == scoreVersion, "Equal rebuilt scores changed the revision")
        rankingModel.updateStreamMatchingPreferences(favoriteChannelIDs: [], channelPreferenceScores: [second.id: 0.5], groupPreferenceScores: [:])
        precondition(rankingModel.matchingPreferencesVersion == scoreVersion + 1, "A score change with unchanged favorites didn't advance")
        rankingModel.updateStreamMatchingPreferences(favoriteChannelIDs: [], channelPreferenceScores: [:], groupPreferenceScores: [:])
        precondition(rankingModel.matchingPreferencesVersion == scoreVersion + 2, "Clearing usage scores didn't advance")
        precondition(rankingModel.searchIndexVersion == rankingIndexVersion, "Preference updates rebuilt the channel index")

        // Fresh quality changes are ranking inputs, not guide/catalog changes.
        // An open popover's preference revision must change and rerank while
        // the same guide index remains available.
        let quality = StreamMatchQuality(availability: .observedAvailable, observedHeight: 2160, observedFPS: 50)
        rankingModel.updateStreamMatchingPreferences(favoriteChannelIDs: [first.id], channelPreferenceScores: [:],
            groupPreferenceScores: [:], qualityByChannel: [second.id: quality])
        let qualityVersion = rankingModel.matchingPreferencesVersion
        let qualityMatches = await rankingModel.matchEvent(event)
        precondition(qualityMatches.first?.channel.id == second.id, "Current stream quality did not outrank a local favorite")
        rankingModel.updateStreamMatchingPreferences(favoriteChannelIDs: [first.id], channelPreferenceScores: [:],
            groupPreferenceScores: [:], qualityByChannel: [second.id: quality])
        precondition(rankingModel.matchingPreferencesVersion == qualityVersion, "Identical quality snapshot invalidated cached matches")
        precondition(rankingModel.searchIndexVersion == rankingIndexVersion, "Quality update rebuilt the EPG index")
        rankingModel.updateStreamMatchingPreferences(favoriteChannelIDs: [first.id], channelPreferenceScores: [:],
            groupPreferenceScores: [:], qualityByChannel: [second.id: .init(availability: .failed, observedHeight: 2160, observedFPS: 50)])
        let failedQualityMatches = await rankingModel.matchEvent(event)
        precondition(failedQualityMatches.first?.channel.id == first.id, "Fresh failed UHD retained priority over an eligible favorite")
        precondition(rankingModel.matchingPreferencesVersion == qualityVersion + 1)

        // Identical guide/catalog tokens update preference state without
        // causing another detached index build or publication.
        let initialVersion = model.searchIndexVersion
        update(model, id: "source-a", version: 1, guideVersion: 1)
        try? await Task.sleep(for: .milliseconds(450))
        precondition(model.searchIndexVersion == initialVersion)

        // Coalesce five guide updates into one publication for the latest
        // input, keeping the existing same-source index useful meanwhile.
        for version in 2...6 {
            update(model, id: "source-a", version: 1, guideVersion: version)
        }
        await waitUntil("Coalesced guide index did not publish") { model.searchIndexVersion > initialVersion }
        precondition(model.searchIndexVersion == initialVersion + 1)

        // A progressive history tail retains this source's usable index and
        // performs no repeated full builds. Ending the tail builds the latest
        // token once, even though that token itself did not change.
        let beforeTail = model.searchIndexVersion
        for version in 7...20 {
            update(model, id: "source-a", version: 1, guideVersion: version, deferred: true)
        }
        try? await Task.sleep(for: .milliseconds(450))
        precondition(model.isStreamIndexReady && model.searchIndexVersion == beforeTail)
        update(model, id: "source-a", version: 1, guideVersion: 20)
        await waitUntil("Final history token did not build") { model.searchIndexVersion > beforeTail }
        precondition(model.searchIndexVersion == beforeTail + 1)

#if SPORTS_MATCH_TESTING
        // Hold the actual match worker while a same-source history update
        // arrives. No replacement index starts, so the retained match stays valid.
        let barrier = SportsMatchBarrier()
        model.matchWorkerBarrierForTesting = { barrier.wait() }
        let matchPublicationVersion = model.searchIndexVersion
        let inFlight = Task { @MainActor in await model.matchEvent(event) }
        await waitUntil("Warm match worker did not enter") { barrier.isEntered }
        for version in 21...24 {
            update(model, id: "source-a", version: 1, guideVersion: version, deferred: true)
        }
        precondition(model.isStreamIndexReady && model.searchIndexVersion == matchPublicationVersion)
        barrier.release()
        let retainedMatches = await inFlight.value
        precondition(retainedMatches.map(\.channel.id) == ["source-a"],
                     "History update rejected an in-flight match without any new index work")
        model.matchWorkerBarrierForTesting = nil
        print("PASS deterministic in-flight warm Sports match survives deferred guide updates")
#endif

        let coldTail = SportsViewModel(espn: client, fixtureCache: .disabled)
        update(coldTail, id: "cold-tail", version: 1, guideVersion: 1, deferred: true)
        await waitUntil("Cold progressive guide never became useful") { coldTail.isStreamIndexReady }
        let firstTailVersion = coldTail.searchIndexVersion
        for version in 2...10 {
            update(coldTail, id: "cold-tail", version: 1, guideVersion: version, deferred: true)
        }
        try? await Task.sleep(for: .milliseconds(450))
        precondition(coldTail.searchIndexVersion == firstTailVersion && coldTail.isStreamIndexReady)

        // A switched source whose guide has not arrived must invalidate the
        // old source immediately, including matches requested in the debounce.
        update(model, id: "source-b", hasGuide: false, version: 2, guideVersion: 7)
        precondition(!model.isStreamIndexReady)
        let staleMatches = await model.matchEvent(event)
        precondition(staleMatches.isEmpty, "Prior source matches remained available")
        update(model, id: "source-b", version: 2, guideVersion: 8)
        await waitUntil("Replacement source index did not publish") { model.isStreamIndexReady }
        let replacementMatches = await model.matchEvent(event)
        precondition(replacementMatches.map(\.channel.id) == ["source-b"])

        // Hiding the matched group invalidates it before the next build.
        update(model, id: "source-b", version: 2, guideVersion: 8, hidden: ["Sports"])
        precondition(!model.isStreamIndexReady)
        let hidingMatches = await model.matchEvent(event)
        precondition(hidingMatches.isEmpty)
        await waitUntil("Hidden-group index did not publish") { !model.isStreamIndexBuilding }
        let hiddenMatches = await model.matchEvent(event)
        precondition(hiddenMatches.count == 1 && hiddenMatches[0].isHidden,
                     "Hidden-group fallback did not use updated visibility")

        // Superseding a scheduled build with an empty catalog cannot publish
        // channels after account removal.
        update(model, id: "source-c", version: 3, guideVersion: 9)
        model.updateStreamMatchingContext(channels: [], programs: [:], favoriteChannelIDs: [],
                                          channelPreferenceScores: [:], groupPreferenceScores: [:],
                                          hiddenGroups: [], guideVersion: 10, channelSetVersion: 4)
        let emptiedVersion = model.searchIndexVersion
        try? await Task.sleep(for: .milliseconds(450))
        precondition(!model.isStreamIndexReady && !model.isStreamIndexBuilding)
        precondition(model.searchIndexVersion == emptiedVersion)

        // Disposing a model during debounce and during timer sleep releases it.
        var debouncingModel: SportsViewModel? = SportsViewModel(espn: client, fixtureCache: .disabled)
        let weakDebouncingModel = WeakSportsModel(debouncingModel)
        update(debouncingModel!, id: "discarded", version: 1, guideVersion: 1)
        debouncingModel?.startAutoRefresh()
        debouncingModel = nil
        precondition(weakDebouncingModel.value == nil)

        // A completed refresh clears its task handle and can be refreshed again.
        model.refresh()
        await waitUntil("Sports fixture refresh did not complete", timeout: 10) { model.hasLoadedOnce && !model.isLoading }
        let lastRefresh = model.lastRefreshed
        model.refresh()
        await waitUntil("Second fixture refresh did not complete", timeout: 10) { model.lastRefreshed != lastRefresh && !model.isLoading }

        // HTTP failures must not erase a previously available fixture list or
        // claim that it was freshly updated. A real empty feed can clear it.
        FixtureURLProtocol.reset(delay: 0.001, golfEvents: 0, eventTitle: "Retained fixture")
        model.refresh()
        await waitUntil("Fresh fixture list did not load", timeout: 10) { !model.isLoading }
        let retainedCount = model.totalEvents
        let retainedAt = model.lastRefreshed
        precondition(retainedCount > 0 && model.refreshWarning == nil)
        FixtureURLProtocol.reset(delay: 0.001, golfEvents: 0, httpStatus: 503)
        model.refresh()
        await waitUntil("Failed refresh did not finish", timeout: 10) { !model.isLoading }
        precondition(model.totalEvents == retainedCount && model.lastRefreshed == retainedAt)
        precondition(model.refreshWarning != nil)
        let unavailableModel = SportsViewModel(espn: client, fixtureCache: .disabled)
        unavailableModel.refresh()
        await waitUntil("Initial failed refresh did not finish", timeout: 10) { !unavailableModel.isLoading }
        precondition(unavailableModel.hasLoadedOnce && unavailableModel.lastRefreshed == nil
                     && unavailableModel.refreshWarning != nil && unavailableModel.totalEvents == 0)
        // Cold disk hydration must publish before a slow failed network feed,
        // retaining the saved timestamp rather than fabricating a refresh.
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("buffer-sports-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let fixtureCache = SportsFixtureCache(fileURL: cacheDirectory.appendingPathComponent("fixtures.json"))
        let savedAt = Date().addingTimeInterval(-60)
        fixtureCache.enqueueSave(SportsFixtureCache.Snapshot(events: [event],
            confirmedAt: [SportsFixtureCache.eventKey(event): savedAt], refreshedAt: savedAt))
        await fixtureCache.flush()
        FixtureURLProtocol.reset(delay: 0.1, golfEvents: 0, httpStatus: 503)
        let cachedModel = SportsViewModel(espn: client, fixtureCache: fixtureCache)
        cachedModel.refresh()
        await waitUntil("Saved fixture hydration waited for failed transport") { cachedModel.totalEvents > 0 }
        precondition(cachedModel.isLoading && cachedModel.lastRefreshed == savedAt && cachedModel.refreshWarning != nil)
        await waitUntil("Cached model's failed refresh did not finish", timeout: 10) { !cachedModel.isLoading }
        precondition(cachedModel.totalEvents == 1 && cachedModel.lastRefreshed == savedAt)
        precondition(cachedModel.refreshWarning != nil)

        FixtureURLProtocol.reset(delay: 0.001, golfEvents: 0)
        model.refresh()
        await waitUntil("Successful empty refresh did not finish", timeout: 10) { !model.isLoading }
        precondition(model.totalEvents == 0 && model.refreshWarning == nil && model.lastRefreshed != retainedAt)

        // Restarting a manual refresh cancels the previous one; only the
        // newest fixture result can update sections or clear isLoading.
        FixtureURLProtocol.reset(delay: 1, golfEvents: 0, eventTitle: "Obsolete result")
        model.refresh()
        await waitUntil("Refresh to be superseded did not start") { FixtureURLProtocol.counts.started == 8 }
        FixtureURLProtocol.setResponse(delay: 0.01, eventTitle: "Latest result")
        model.refresh()
        // Each in-flight request captured the old response before the fixture
        // changed; the replacement exclusively owns loading/publication state.
        await waitUntil("Superseded refresh transports did not stop") { FixtureURLProtocol.counts.started >= 16 }
        precondition(model.isLoading)
        await waitUntil("Replacement refresh did not complete", timeout: 10) { !model.isLoading }
        let refreshedEvents = model.sections.flatMap(\.events)
        precondition(!refreshedEvents.isEmpty && refreshedEvents.allSatisfy { $0.title == "Latest result" })

        session.invalidateAndCancel()
        print("PASS sports model disposal, transport cancellation, index source invalidation, preference revisions/ranking, unchanged-input skip, guide rebuild coalescing, hidden groups, empty catalog, repeat refresh, outage fixture retention, accurate freshness, initial unavailable state, successful empty replacement")
    }
}
