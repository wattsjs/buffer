import Foundation

private struct TestFailure: Error, CustomStringConvertible { let description: String }

@main struct SyncIntegration {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(description: message) }
    }
    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TestFailure(description: "timed out waiting for test state") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor static func runPreferenceRevisionTests() throws {
        let vm = EPGViewModel()
        let first = Channel(id: "1", name: "First", logoURL: nil, group: "First Group",
                            streamURL: URL(string: "http://127.0.0.1/first")!, epgChannelID: nil)
        let second = Channel(id: "2", name: "Second", logoURL: nil, group: "Second Group",
                             streamURL: URL(string: "http://127.0.0.1/second")!, epgChannelID: nil)
        vm.channels = [first, second]
        vm.channelUsageCounts = [first.id: 4, second.id: 3]
        vm.groupUsageCounts = [first.group: 4, second.group: 3]
        vm.recentChannelIDs = [first.id, second.id]
        let unchangedRecents = vm.recentChannelIDs
        let unchangedFavorites = vm.favoriteChannelIDs
        let previousScores = vm.channelPreferenceScores
        let previousVersion = vm.preferenceScoresVersion
        vm.addRecent(first)
        try require(vm.recentChannelIDs == unchangedRecents && vm.favoriteChannelIDs == unchangedFavorites,
                    "fixture changed recents/favorites while exercising repeat usage")
        try require(vm.channelPreferenceScores != previousScores && vm.preferenceScoresVersion > previousVersion,
                    "repeat usage with unchanged most-recent channel didn't publish a score revision")

        let stableVersion = vm.preferenceScoresVersion
        let unchangedCounts = Dictionary(uniqueKeysWithValues: vm.channelUsageCounts.map { ($0.key, $0.value) })
        vm.channelUsageCounts = unchangedCounts
        vm.recentChannelIDs = unchangedRecents
        try require(vm.preferenceScoresVersion == stableVersion, "equivalent rebuilt rankings advanced their revision")
        vm.channelUsageCounts[first.id, default: 0] += 3
        try require(vm.recentChannelIDs == unchangedRecents && vm.favoriteChannelIDs == unchangedFavorites,
                    "fixture changed recents/favorites while exercising direct count update")
        try require(vm.preferenceScoresVersion > stableVersion, "usage changed without a published score revision")

        vm.recentChannelIDs = []
        let clearVersion = vm.preferenceScoresVersion
        try require(!vm.channelPreferenceScores.isEmpty && !vm.groupPreferenceScores.isEmpty, "empty-recents usage fixture lost ranking inputs")
        vm.resetRecommendations()
        try require(vm.recentChannelIDs.isEmpty && vm.favoriteChannelIDs == unchangedFavorites,
                    "clear usage fixture changed recents/favorites")
        try require(vm.preferenceScoresVersion > clearVersion && vm.channelPreferenceScores.isEmpty && vm.groupPreferenceScores.isEmpty,
                    "clearing usage with already empty recents didn't publish score removal")
        let clearedVersion = vm.preferenceScoresVersion
        vm.resetRecommendations()
        try require(vm.preferenceScoresVersion == clearedVersion, "repeated empty reset advanced score revision")
    }

    static func movie(_ name: String = "Cached Movie") -> VODItem {
        VODItem(id: "1", name: name, posterURL: nil, group: "Movies", streamURL: URL(string: "http://127.0.0.1/movie/1.mp4")!, kind: .movie)
    }
    static func series(_ name: String = "Cached Series") -> VODSeries {
        VODSeries(id: "1", name: name, posterURL: nil, group: "Series")
    }
    static func channel(_ name: String = "Cached Channel") -> Channel {
        Channel(id: "1", name: name, logoURL: nil, group: "Test", streamURL: URL(string: "http://127.0.0.1/1.ts")!, epgChannelID: "epg-1")
    }
    @MainActor static func runM3UIdentityMigration() throws {
        let vm = EPGViewModel()
        let config = ServerConfig(name: "M3U Fixture", type: .m3u, m3uURL: "http://127.0.0.1/fixture.m3u")
        vm.playlists = [config]
        vm.activePlaylistID = config.id
        let oldID = "74B36661-F6DC-45B2-940E-6004D03E7CDB"
        let duplicateID = "97108CF1-21C0-4ACA-874A-C8E3E180D0CA"
        let url = URL(string: "http://127.0.0.1/live.ts")!
        let old = Channel(id: oldID, name: "Old", logoURL: nil, group: "Old Group", streamURL: url, epgChannelID: nil)
        let duplicate = Channel(id: duplicateID, name: "Old Duplicate", logoURL: nil, group: "Old Group", streamURL: url, epgChannelID: nil)
        let provided = Channel(id: "provided", name: "Provided", logoURL: nil, group: "Old Group", streamURL: URL(string: "http://127.0.0.1/provided.ts")!, epgChannelID: "guide")
        vm.channels = [old, duplicate, provided]
        vm.favoriteChannelIDs = [oldID, duplicateID, provided.id, "temporarily-unavailable"]
        vm.recentChannelIDs = [oldID, duplicateID, provided.id, "temporarily-unavailable"]
        vm.channelUsageCounts = [oldID: 5, duplicateID: 7, provided.id: 2, "temporarily-unavailable": 1]
        vm.revealChannelID = oldID
        let refreshed = M3UParser.parse("#EXTINF:-1 group-title=\"New Group\",Renamed\nhttp://127.0.0.1/live.ts\n#EXTINF:-1,Renamed Duplicate\nhttp://127.0.0.1/live.ts\n") + [provided]
        vm.channelUsageCounts[refreshed[0].id] = 3
        vm.channels = refreshed
        try require(vm.favoriteChannelIDs == [refreshed[0].id, refreshed[1].id, provided.id, "temporarily-unavailable"], "legacy favorites were erased instead of migrated")
        try require(vm.recentChannelIDs == [refreshed[0].id, refreshed[1].id, provided.id, "temporarily-unavailable"], "legacy recent ordering changed during migration")
        try require(vm.channelUsageCounts[refreshed[0].id] == 8 && vm.channelUsageCounts[refreshed[1].id] == 7 && vm.channelUsageCounts[provided.id] == 2, "legacy usage counts were not preserved/combined")
        try require(vm.channelUsageCounts[oldID] == nil && vm.channelUsageCounts[duplicateID] == nil, "legacy usage keys were retained")
        try require(vm.revealChannelID == refreshed[0].id, "legacy reveal selection did not migrate")
        try require(vm.favoriteChannels.count == 3 && vm.recentChannels.count == 3, "migrated preferences do not resolve actual refreshed channels")
        let key = DataCache.preferenceKey(for: config)
        try require(Set(UserDefaults.standard.stringArray(forKey: "buffer_favorites_\(key)") ?? []) == vm.favoriteChannelIDs, "favorite migration was not persisted")
        try require(UserDefaults.standard.stringArray(forKey: "buffer_recents_\(key)") == vm.recentChannelIDs, "recent migration was not persisted")
        try require((UserDefaults.standard.dictionary(forKey: "buffer_channel_usage_\(key)") as? [String: Int]) == vm.channelUsageCounts, "usage migration was not persisted")
        let originalCounts = vm.channelUsageCounts
        vm.channels = M3UParser.parse("#EXTINF:-1 group-title=\"Another Group\",Renamed Again\nhttp://127.0.0.1/live.ts\n#EXTINF:-1,Duplicate Again\nhttp://127.0.0.1/live.ts\n") + [provided]
        try require(vm.channelUsageCounts == originalCounts && vm.favoriteChannels.count == 3, "second refresh repeated migration or lost stable preferences")

        let mixed = EPGViewModel()
        mixed.playlists = [config]
        mixed.activePlaylistID = config.id
        let sharedURLProvided = Channel(id: "provided", name: "Provided", logoURL: nil, group: "Test", streamURL: url, epgChannelID: "guide")
        mixed.channels = [sharedURLProvided, old]
        mixed.favoriteChannelIDs = [oldID]
        mixed.recentChannelIDs = [oldID]
        mixed.channelUsageCounts = [oldID: 4, sharedURLProvided.id: 2]
        mixed.channels = [sharedURLProvided, refreshed[0]]
        try require(mixed.favoriteChannelIDs == [refreshed[0].id] && mixed.recentChannelIDs == [refreshed[0].id], "anonymous URL migration selected an explicit provider row sharing that URL")
        try require(mixed.channelUsageCounts[refreshed[0].id] == 4 && mixed.channelUsageCounts[sharedURLProvided.id] == 2, "shared URL migration modified explicit provider preferences")
    }

    @MainActor static func runLibraryMemoryScenario(_ scenario: String, config: ServerConfig) async throws {
        let key = DataCache.cacheKey(for: config)
        let benchmark = scenario == "library-search-benchmark"
        let unmatchedCount = benchmark ? 100_000 : 20_000
        var guide: [String: [EPGProgram]] = [:]
        let now = Date()
        for i in 0..<unmatchedCount {
            let epgID = "unmatched-\(i / 20)"
            guide[epgID, default: []].append(EPGProgram(id: "unmatched-\(i)", channelID: epgID, title: "Unsearchable \(i)", description: "", start: now.addingTimeInterval(-60), end: now.addingTimeInterval(3600)))
        }
        let matching: [EPGProgram] = (0..<3).map { index in
            let start = now.addingTimeInterval(Double(index * 60 - 60))
            let end = now.addingTimeInterval(Double((index + 1) * 60 + 3600))
            return EPGProgram(id: "matched-\(index)", channelID: "epg-1", title: "Équipe Title \(index)", description: "", start: start, end: end)
        }
        if scenario != "search-empty-match" { guide["epg-1"] = matching }
        DataCache.saveChannels([channel(), Channel(id: "variant", name: "Other Variant", logoURL: nil, group: "Test", streamURL: URL(string: "http://127.0.0.1/variant.ts")!, epgChannelID: "epg-1")], key: key)
        DataCache.savePrograms(guide, key: key)
        DataCache.saveVODItems([movie()], key: key)
        DataCache.saveVODSeries([series()], key: key)
        let disabled = scenario.hasPrefix("hydration-disabled")
        UserDefaults.standard.set(disabled, forKey: EPGViewModel.disableVODKey)
        if scenario == "hydration-disable-inflight" || scenario == "hydration-toggle-inflight" { DataCache.delayVODReads(for: key) }
        let vm = EPGViewModel()
        vm.playlists = [config]
        let started = ContinuousClock.now
        vm.setActivePlaylist(id: config.id)
        let initialIndexVersion = vm.searchIndexVersion
        if scenario == "hydration-disable-inflight" || scenario == "hydration-toggle-inflight" {
            try await waitUntil { DataCache.itemReadCount(for: key) == 1 }
            UserDefaults.standard.set(true, forKey: EPGViewModel.disableVODKey)
            vm.applyVODPreference(disabled: true)
            if scenario == "hydration-toggle-inflight" {
                UserDefaults.standard.set(false, forKey: EPGViewModel.disableVODKey)
                vm.applyVODPreference(disabled: false)
            }
        }
        await vm.hydrate()
        if scenario == "hydration-toggle-inflight" {
            try require(DataCache.itemReadCount(for: key) == 1 && DataCache.seriesReadCount(for: key) == 0, "catalog revision change read another obsolete catalog snapshot")
            try require(vm.vodItems.isEmpty && vm.vodSeries.isEmpty, "disable/re-enable published old inflight cached catalog")
            await vm.syncAndWait()
            try require(vm.vodItems.first?.name == "A Movie" && vm.vodSeries.first?.name == "A Series", "disable/re-enable failed to load current catalog")
            return
        }
        let expectedCount = scenario == "search-empty-match" ? 0 : 3
        if expectedCount > 0 {
            try await waitUntil { vm.searchIndexVersion >= initialIndexVersion + 2 }
        } else {
            // The empty matched snapshot completes synchronously without a
            // detached worker or a redundant empty-index publication. Cache
            // hydration above is the completion barrier for this case.
            try require(vm.hasLoadedOnce && vm.channels.count == 2 &&
                        vm.programSearchIndexBuildCount == 0 && vm.programSearchStore.isEmpty,
                        "unmatched guide hydration launched a search worker or retained its arrays")
        }
        try require(vm.searchEntries.count == expectedCount, "unmatched guides leaked into searchable entries")
        for entry in vm.searchEntries {
            let program = matching[entry.programIndex]
            try require(entry.id == program.id && entry.epgID == "epg-1" && entry.channelID == "1" && entry.titleLower == program.title.lowercased() && entry.start == program.start && entry.end == program.end, "search entry fields/first variant mapping changed")
        }
        if !benchmark {
            try require(vm.searchEntries.capacity < 64, "search index reserved unmatched guide program storage")
            if disabled {
                try require(DataCache.itemReadCount(for: key) == 0 && DataCache.seriesReadCount(for: key) == 0, "disabled VOD hydration read/decoded catalog caches")
                try require(vm.vodItems.isEmpty && vm.vodSeries.isEmpty, "disabled catalog published")
            } else if scenario == "hydration-disable-inflight" {
                try require(DataCache.itemReadCount(for: key) == 1 && DataCache.seriesReadCount(for: key) == 0, "disable during movie read scheduled series decoding")
                try require(vm.vodItems.isEmpty && vm.vodSeries.isEmpty, "inflight disabled catalog published")
            } else {
                try require(DataCache.itemReadCount(for: key) == 1 && DataCache.seriesReadCount(for: key) == 1, "enabled VOD hydration skipped catalog caches")
                try require(vm.vodItems.first?.name == "Cached Movie" && vm.vodSeries.first?.name == "Cached Series", "enabled catalog did not hydrate")
            }
        }
        if benchmark {
            print("LIBRARY_MEMORY_JSON {\"fixture\":\"library-search-unmatched-v1\",\"elapsedMs\":\(AppLog.elapsedMilliseconds(since: started)),\"guidePrograms\":\(unmatchedCount + matching.count),\"searchEntries\":\(vm.searchEntries.count),\"searchCapacity\":\(vm.searchEntries.capacity),\"entryStride\":\(MemoryLayout<ProgramSearchEntry>.stride),\"checksum\":\(vm.searchEntries.reduce(0) { $0 + $1.programIndex })}")
        }
    }

    @MainActor static func runCacheRevisionScenario(_ scenario: String, config: ServerConfig) async throws {
        let defaults = UserDefaults.standard
        let metadataKeys = ["buffer_playlists_v1", "buffer_active_playlist_id", "buffer_server_config", "buffer_server_status"]
        for key in metadataKeys { defaults.removeObject(forKey: key) }
        defer { for key in metadataKeys { defaults.removeObject(forKey: key) } }
        let oldKey = DataCache.cacheKey(for: config)
        DataCache.saveChannels([channel("Old Credential Channel")], key: oldKey)
        DataCache.saveVODItems([movie("Old Credential Movie")], key: oldKey)
        DataCache.saveVODSeries([series("Old Credential Series")], key: oldKey)
        DataCache.savePrograms(["epg-1": [EPGProgram(id: "old-revision", channelID: "epg-1", title: "Old Revision Guide", description: "", start: .now.addingTimeInterval(-60), end: .now.addingTimeInterval(3600))]], key: oldKey)
        let preferencesKey = DataCache.preferenceKey(for: config)
        defaults.set(["1"], forKey: "buffer_favorites_\(preferencesKey)")
        var edited = config
        if scenario == "cache-custom-guide-inactive" {
            edited.epgURL = config.serverURL + "/custom-guide.xml"
        } else {
            edited.password = "revision-B"
        }
        try require(DataCache.cacheKey(for: edited) != oldKey, "edited content inputs kept old cache identity")
        try require(DataCache.preferenceKey(for: edited) == preferencesKey, "edited content inputs changed preference identity")
        let vm = EPGViewModel()
        if scenario.hasSuffix("inactive") {
            let other = ServerConfig(name: "Other Fixture", serverURL: config.serverURL + "/other", username: "fixture", password: "other")
            vm.playlists = [config, other]
            vm.activePlaylistID = other.id
            vm.updatePlaylist(edited)
            vm.setActivePlaylist(id: config.id)
            await vm.hydrate()
            try require(vm.channels.isEmpty && vm.programs.isEmpty && vm.vodItems.isEmpty && vm.vodSeries.isEmpty, "inactive source edit hydrated obsolete content")
            try require(DataCache.channelReadCount(for: oldKey) == 0, "inactive source edit read old authenticated cache")
            try require(vm.favoriteChannelIDs == ["1"], "inactive source edit lost favorites")
            return
        }
        vm.addPlaylist(config)
        await vm.hydrate()
        try require(vm.channels.first?.name == "Old Credential Channel", "baseline current cache did not hydrate")
        try await waitUntil { ServerPasswordStore.writeCount(for: config.id) == 1 }
        vm.updatePlaylist(edited)
        await vm.syncAndWait()
        try require(vm.channels.isEmpty && vm.programs.isEmpty && vm.vodItems.isEmpty && vm.vodSeries.isEmpty && vm.errorMessage != nil, "failed refresh retained edited-source obsolete content")
        try await waitUntil { ServerPasswordStore.writeCount(for: config.id) == 2 }
        let reopened = EPGViewModel()
        await reopened.hydrate()
        try require(reopened.serverConfig?.password == edited.password, "relaunch did not resolve edited saved credential")
        try require(reopened.channels.isEmpty && reopened.programs.isEmpty && reopened.vodItems.isEmpty && reopened.vodSeries.isEmpty, "relaunch after failed edit refreshed obsolete authenticated content")
        try require(DataCache.channelReadCount(for: oldKey) == 1, "relaunch read earlier credential cache instead of current primary")
        try require(reopened.favoriteChannelIDs == ["1"], "relaunch after credential edit lost favorites")
    }

    @MainActor static func runLegacyM3UMigration() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("buffer-identity-\(UUID()).m3u")
        let content = "#EXTINF:-1 group-title=\"New Group\",Refreshed\nhttp://127.0.0.1/live.ts\n"
        try Data(content.utf8).write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let config = ServerConfig(name: "Legacy M3U Fixture", type: .m3u, m3uURL: temporary.path)
        let oldID = "CA0C3B31-4136-4875-B65B-63F320C680D6"
        let legacyChannel = Channel(id: oldID, name: "Old", logoURL: nil, group: "Old Group", streamURL: URL(string: "http://127.0.0.1/live.ts")!, epgChannelID: nil)
        let legacyKey = DataCache.legacyCacheKeys(for: config).first { $0 != DataCache.cacheKey(for: config) }!
        DataCache.saveChannels([legacyChannel], key: legacyKey)
        let prefKey = DataCache.preferenceKey(for: config)
        UserDefaults.standard.set([oldID], forKey: "buffer_favorites_\(prefKey)")
        UserDefaults.standard.set([oldID], forKey: "buffer_recents_\(prefKey)")
        UserDefaults.standard.set([oldID: 9], forKey: "buffer_channel_usage_\(prefKey)")
        UserDefaults.standard.set(true, forKey: EPGViewModel.disableVODKey)
        let vm = EPGViewModel()
        vm.playlists = [config]
        vm.setActivePlaylist(id: config.id)
        await vm.hydrate()
        try require(vm.channels.isEmpty && DataCache.channelReadCount(for: legacyKey) == 0, "legacy channel URLs became playable during startup")
        await vm.syncAndWait()
        let refreshed = M3UParser.parse(content)[0]
        try require(vm.channels.first?.id == refreshed.id && vm.channels.first?.name == "Refreshed", "legacy cache replaced freshly parsed current catalog")
        try require(vm.favoriteChannelIDs == [refreshed.id] && vm.recentChannelIDs == [refreshed.id] && vm.channelUsageCounts == [refreshed.id: 9], "schema rollout lost old UUID favorites/history/usage")
        try require(DataCache.channelReadCount(for: legacyKey) == 1, "legacy preference map was not read exactly once")
        await vm.syncAndWait()
        try require(DataCache.channelReadCount(for: legacyKey) == 1 && vm.channelUsageCounts[refreshed.id] == 9, "later refresh repeated legacy cache decoding/migration")
    }
    @MainActor static func main() async {
        do { try await run() }
        catch {
            fputs("FAIL \(error)\n", stderr)
            exit(1)
        }
    }
    @MainActor static func run() async throws {
        let base = CommandLine.arguments[1]
        let scenario = CommandLine.arguments[2]
        if scenario == "preference-revisions" {
            try runPreferenceRevisionTests()
            print("PASS preference-revisions")
            return
        }
        if scenario == "m3u-identities" {
            try runM3UIdentityMigration()
            print("PASS m3u-identities")
            return
        }
        UserDefaults.standard.set(false, forKey: EPGViewModel.disableVODKey)
        UserDefaults.standard.set(0, forKey: SyncInterval.playlistStorageKey)
        UserDefaults.standard.set(0, forKey: SyncInterval.epgStorageKey)
        let a = ServerConfig(name: "Fixture A", serverURL: base + "/A", username: "fixture", password: "revision-A")
        let b = ServerConfig(name: "Fixture B", serverURL: base + "/B", username: "fixture", password: "revision-B")
        if scenario.hasPrefix("cache-") {
            try await runCacheRevisionScenario(scenario, config: a)
            print("PASS \(scenario)")
            return
        }
        if scenario == "m3u-legacy-cache-migration" {
            try await runLegacyM3UMigration()
            print("PASS m3u-legacy-cache-migration")
            return
        }
        if scenario.hasPrefix("hydration-disabled") || scenario == "hydration-disable-inflight" || scenario == "hydration-toggle-inflight" || scenario.hasPrefix("search-") || scenario == "library-search-benchmark" {
            try await runLibraryMemoryScenario(scenario, config: a)
            print("PASS \(scenario)")
            return
        }
        if scenario.hasPrefix("credential-") {
            try await runCredentialScenario(scenario, config: a)
            print("PASS \(scenario)")
            return
        }
        let vm = EPGViewModel()
        vm.playlists = [a, b]
        vm.activePlaylistID = a.id
        vm.vodItems = [movie()]
        vm.vodSeries = [series()]
        let scenarioStarted = ContinuousClock.now
        switch scenario {
        case "guide-retry":
            UserDefaults.standard.set(true, forKey: EPGViewModel.disableVODKey)
            vm.selection = .group("Priority")
            await vm.syncAndWait()
            try require(!vm.programs.values.contains { $0.contains { $0.title.hasPrefix("History") } }, "empty response fixture unexpectedly produced archive rows")
            let started = ContinuousClock.now
            await vm.syncAndWait()
            let history = vm.programs.values.filter { $0.contains { $0.title.hasPrefix("History") } }.count
            try require(history == 88, "manual full refresh was prevented from retrying prior empty API responses")
            print("GUIDE_BENCH_JSON {\"fixture\":\"guide-retry-96-v1\",\"historyChannels\":\(history),\"completeMs\":\(AppLog.elapsedMilliseconds(since: started))}")
        case "stalker-guide":
            var config = a
            config.type = .stalker
            config.username = "00:11:22:33:44:55"
            vm.playlists = [config]
            vm.activePlaylistID = config.id
            UserDefaults.standard.set(true, forKey: EPGViewModel.disableVODKey)
            let started = ContinuousClock.now
            vm.sync()
            try await waitUntil { vm.channels.first != nil }
            let ch = vm.channels[0]
            try await waitUntil { vm.currentProgram(for: ch) != nil }
            try require(ch.epgChannelID == "external-guide", "Stalker fixture did not cover differing XMLTV/native IDs")
            try require(AppLog.elapsedMilliseconds(since: started) < 650, "Stalker current rows waited for extended guide")
            await vm.syncAndWait()
            try require(vm.currentProgram(for: ch)?.title == "Stalker Current", "failed Stalker extended response erased current guide")
            let retained = vm.programs["external-guide"] ?? []
            try require(retained.count == 3 && Set(retained.map(\.id)).count == 3, "blank/numeric Stalker listing IDs collapsed valid guide or titleless row replaced current")
        case "guide-progressive", "guide-empty-xml", "guide-retention", "guide-slow-xml", "guide-alias", "guide-missing-id", "guide-unmatched-id":
            UserDefaults.standard.set(true, forKey: EPGViewModel.disableVODKey)
            let fixtureNow = Date()
            if scenario == "guide-retention" {
                let cachedChannels = (0..<96).map { i in
                    Channel(id: String(i), name: "Channel \(i)", logoURL: nil, group: i >= 88 ? "Priority" : "Background", streamURL: URL(string: base + "/\(i).ts")!, epgChannelID: "epg-\(i)", catchup: CatchupInfo(kind: .xc, days: 7, source: nil))
                }
                let retained = EPGProgram(id: "retained-90", channelID: "epg-90", title: "Retained Five Days", description: "", start: fixtureNow.addingTimeInterval(-5 * 86400), end: fixtureNow.addingTimeInterval(-5 * 86400 + 3600))
                DataCache.saveChannels(cachedChannels, key: DataCache.cacheKey(for: a))
                DataCache.savePrograms(["epg-90": [retained]], key: DataCache.cacheKey(for: a))
                vm.activePlaylistID = nil
                vm.setActivePlaylist(id: a.id)
                await vm.hydrate()
                try require(vm.programs["epg-90"]?.first?.id == "retained-90", "stale live window discarded still-available cached history")
            }
            vm.selection = .group("Priority")
            let started = ContinuousClock.now
            let initialGuideVersion = vm.guideVersion
            vm.sync()
            try await waitUntil { vm.channels.contains { $0.id == "90" } }
            let selected = vm.channels.first { $0.id == "90" }!
            try await waitUntil { vm.currentProgram(for: selected) != nil }
            let firstCurrent = AppLog.elapsedMilliseconds(since: started)
            let selectedGuideID = selected.epgChannelID!
            try await waitUntil { (vm.programs[selectedGuideID]?.first?.start ?? .distantFuture) < fixtureNow.addingTimeInterval(-36 * 3600) }
            let firstHistory = AppLog.elapsedMilliseconds(since: started)
            if !CommandLine.arguments.contains("--measure-only") {
                try require(firstCurrent < 650, "useful visible rows waited for slow background history tail")
                try require(firstHistory < 750, "visible channel history was not prioritized/progressively published")
                try require(vm.isRefreshing, "fixture did not exercise partial guide while background requests were active")
            }
            if vm.isRefreshing { await vm.syncAndWait() }
            let total = AppLog.elapsedMilliseconds(since: started)
            let publicationCount = vm.guideVersion - initialGuideVersion
            #if GUIDE_PRODUCTION_METRICS
            let commitBudget = vm.guideMaximumCommitMilliseconds
            if !CommandLine.arguments.contains("--measure-only") {
                try require(publicationCount <= 10, "burst requests caused unbounded guide/search/sports invalidations")
                try require(commitBudget < 20, "progressive guide main-actor commit exceeded fixture budget")
            }
            let commitJSON = String(commitBudget)
            #else
            let commitJSON = "null"
            #endif
            let historyKeys = vm.programs.values.filter { $0.contains { $0.title.hasPrefix("History") } }.count
            try require(historyKeys == (scenario == "guide-alias" ? 82 : 88), "partial history responses fabricated, dropped, or hid successful channel coverage")
            let currentRows = vm.channels.filter { vm.currentProgram(for: $0) != nil }.count
            try require(currentRows == (scenario == "guide-empty-xml" ? 88 : 96), "partial API failures erased successful current guide or fabricated unavailable rows")
            if scenario == "guide-unmatched-id" {
                try require(selectedGuideID == "sky-sport-1-nz-uhd" && selected.name == "Sky Sport 1 UHD (NZ)", "fixture did not preserve unmatched configured guide ID")
                try require(vm.programs[selectedGuideID]?.allSatisfy { $0.title.hasPrefix("History 90") } == true, "unmatched UHD row borrowed a neighbouring XML programme")
            }
            if scenario == "guide-retention" {
                try require(vm.programs["epg-90"]?.contains { $0.id == "retained-90" } == true, "sparse fresh responses erased cached deeper archive history")
                try require(DataCache.loadPrograms(key: DataCache.cacheKey(for: a))?.programs["epg-90"]?.contains { $0.id == "retained-90" } == true, "retained archive history was not persisted")
            }
            print("GUIDE_BENCH_JSON {\"fixture\":\"guide-progressive-96-v1\",\"firstCurrentMs\":\(firstCurrent),\"firstVisibleHistoryMs\":\(firstHistory),\"completeMs\":\(total),\"currentRows\":\(currentRows),\"historyChannels\":\(historyKeys),\"requestedHistoryDays\":7,\"returnedHistoryDays\":2,\"publications\":\(publicationCount),\"maximumMainCommitMs\":\(commitJSON)}")
        case "catalog-partial", "catalog-all-fail", "catalog-empty", "overlap":
            vm.sync()
            if scenario == "overlap" {
                try await waitUntil { !vm.programs.isEmpty }
                try require(vm.vodItems.first?.name == "Cached Movie", "catalog blocked guide publication or joined prematurely")
                try require(vm.isRefreshing, "refresh stopped before catalog finished")
            }
            await vm.syncAndWait()
            try require(vm.serverStatus?.guideStatus == "Reachable", "guide status missing after catalog failure")
            try require(!vm.programs.isEmpty, "guide missing after catalog failure")
            if scenario == "catalog-partial" {
                try require(vm.vodItems.first?.name == "Cached Movie", "failed movie request erased cached movies")
                try require(vm.vodSeries.first?.name == "A Series", "independently successful series response was discarded")
                try require(vm.errorMessage != nil, "catalog failure was hidden")
            } else if scenario == "catalog-all-fail" {
                try require(vm.vodItems.first?.name == "Cached Movie" && vm.vodSeries.first?.name == "Cached Series", "failed catalog requests erased cache")
            } else if scenario == "catalog-empty" {
                try require(vm.vodItems.isEmpty && vm.vodSeries.isEmpty, "successful empty catalog did not clear old cache")
            } else {
                try require(vm.vodItems.first?.name == "A Movie", "movie catalog did not publish")
            }
        case "source-switch":
            vm.sync()
            try await waitUntil { vm.channels.first?.name == "A Channel" }
            vm.setActivePlaylist(id: b.id)
            await vm.hydrate()
            vm.sync()
            try await waitUntil { vm.channels.first?.name == "B Channel" }
            // A's old guide completes while B is still working. A cleanup
            // must not release B's coalescing handle or loading indicator.
            try await Task.sleep(for: .milliseconds(600))
            try require(vm.isRefreshing, "obsolete refresh cleared new source's loading state")
            vm.sync()
            await vm.syncAndWait()
            try await Task.sleep(for: .milliseconds(500))
            try require(vm.channels.first?.name == "B Channel", "stale channels published after switch")
            try require(vm.vodItems.first?.name == "B Movie", "stale movie catalog published after switch")
            try require(!vm.programs.isEmpty, "new source's guide did not publish")
            try require(vm.programs.values.flatMap { $0 }.allSatisfy { $0.title == "B Guide" }, "guides from different sources merged")
            try require(vm.serverStatus?.cacheKey == DataCache.preferenceKey(for: b), "stale status published")
        case "source-edit":
            vm.sync()
            try await waitUntil { vm.channels.first?.name == "A Channel" }
            var edited = a
            edited.password = "revision-B"
            try require(DataCache.cacheKey(for: a) != DataCache.cacheKey(for: edited), "credential edit retained old content cache key")
            try require(DataCache.preferenceKey(for: a) == DataCache.preferenceKey(for: edited), "credential edit lost source preferences")
            vm.updatePlaylist(edited)
            await vm.hydrate()
            try require(vm.channels.allSatisfy { $0.streamURL.path.contains("revision-B") }, "credential edit rehydrated old authenticated URLs")
            await vm.syncAndWait()
            try await Task.sleep(for: .milliseconds(600))
            try require(vm.vodItems.first?.name == "A New Movie", "same-key credential edit published obsolete catalog")
            try require(!vm.programs.isEmpty, "new revision's guide did not publish")
            try require(vm.programs.values.flatMap { $0 }.allSatisfy { $0.title == "A New Guide" }, "same-key credential edit published obsolete guide")
        case "empty-cache-switch":
            vm.channels = [channel()]
            vm.programs = ["epg-1": [EPGProgram(id: "old", channelID: "epg-1", title: "Old Guide", description: "", start: .now, end: .now.addingTimeInterval(3600))]]
            vm.seriesEpisodes = ["1": [movie()]]
            vm.vodItemDetails = ["1": movie()]
            vm.setActivePlaylist(id: b.id)
            await vm.hydrate()
            try require(vm.channels.isEmpty && vm.programs.isEmpty && vm.vodItems.isEmpty && vm.vodSeries.isEmpty && vm.seriesEpisodes.isEmpty && vm.vodItemDetails.isEmpty, "uncached source retained actionable content from previous account")
        case "hydration-switch":
            DataCache.saveChannels([channel("A Cached Channel")], key: DataCache.cacheKey(for: a))
            DataCache.delayReads(for: DataCache.cacheKey(for: a))
            vm.activePlaylistID = nil
            vm.setActivePlaylist(id: a.id)
            try await Task.sleep(for: .milliseconds(60))
            vm.setActivePlaylist(id: b.id)
            await vm.hydrate()
            try await Task.sleep(for: .milliseconds(500))
            try require(vm.channels.isEmpty, "cancelled disk hydration published previous account's cache")
        case "details-switch":
            let first = Task { await vm.loadDetails(for: movie()) }
            try await Task.sleep(for: .milliseconds(80))
            vm.setActivePlaylist(id: b.id)
            await vm.hydrate()
            let second = Task { await vm.loadDetails(for: movie("B Movie")) }
            try await Task.sleep(for: .milliseconds(360))
            try require(vm.loadingVODItemIDs.contains("1"), "obsolete detail request cleared new source's loading marker")
            try require(vm.vodItemDetails.isEmpty, "obsolete detail response published into new source")
            await first.value
            await second.value
            try require(vm.vodItemDetails["1"]?.name == "B Detail", "new source's detail failed to publish")
        case "episodes-switch":
            let first = Task { await vm.loadEpisodes(for: series()) }
            try await Task.sleep(for: .milliseconds(80))
            vm.setActivePlaylist(id: b.id)
            await vm.hydrate()
            let second = Task { await vm.loadEpisodes(for: series("B Series")) }
            try await Task.sleep(for: .milliseconds(360))
            try require(vm.loadingSeriesIDs.contains("1"), "obsolete episode request cleared new source's loading marker")
            try require(vm.seriesEpisodes.isEmpty, "obsolete episode response published into new source")
            await first.value
            await second.value
            try require(vm.seriesEpisodes["1"]?.first?.name == "B Episode", "new source's episode failed to publish")
        case "episodes-retry":
            await vm.loadEpisodes(for: series())
            try require(vm.seriesEpisodeLoadErrors["1"] != nil, "transient episode error was hidden")
            try require(vm.seriesEpisodes["1"] == nil, "failed episode request was cached as a successful empty result")
            await vm.loadEpisodes(for: series())
            try require(vm.seriesEpisodes["1"]?.first?.name == "A Episode", "failed episode request could not be retried")
            try require(vm.seriesEpisodeLoadErrors["1"] == nil, "successful episode retry retained error")
        case "status-switch":
            let first = Task { await vm.refreshServerStatus() }
            try await Task.sleep(for: .milliseconds(80))
            vm.setActivePlaylist(id: b.id)
            await vm.hydrate()
            await vm.refreshServerStatus()
            await first.value
            try require(vm.serverStatus?.accountStatus == "B", "previous account's status overwrote selected account")
        case "disable-inflight":
            vm.sync()
            try await waitUntil { !vm.programs.isEmpty }
            UserDefaults.standard.set(true, forKey: EPGViewModel.disableVODKey)
            vm.applyVODPreference(disabled: true)
            await vm.syncAndWait()
            try require(vm.vodItems.isEmpty && vm.vodSeries.isEmpty, "in-flight catalog repopulated disabled VOD")
        case "toggle-vod-inflight":
            vm.sync()
            try await waitUntil { !vm.programs.isEmpty }
            UserDefaults.standard.set(true, forKey: EPGViewModel.disableVODKey)
            vm.applyVODPreference(disabled: true)
            UserDefaults.standard.set(false, forKey: EPGViewModel.disableVODKey)
            vm.applyVODPreference(disabled: false)
            // Both the Settings page and root library observe this change.
            // A repeated callback must keep the first catalogue generation.
            vm.applyVODPreference(disabled: false)
            await vm.syncAndWait()
            try require(vm.vodItems.first?.name == "A Movie" && vm.vodSeries.first?.name == "A Series", "VOD enabling refresh was dropped behind existing catalog join")
        case "lookback-inflight":
            vm.channels = [channel()]
            vm.sync(scope: .epg)
            try await Task.sleep(for: .milliseconds(80))
            vm.syncGuideForLookbackChange()
            await vm.syncAndWait(scope: .epg)
        case "scope-upgrade":
            vm.channels = [channel()]
            vm.sync(scope: .epg)
            try await Task.sleep(for: .milliseconds(80))
            await vm.syncAndWait(scope: .all)
            try require(vm.channels.first?.name == "A Channel", "full refresh request was dropped during guide-only refresh")
            try require(vm.vodItems.first?.name == "A Movie", "full refresh returned before queued catalog finished")
        case "lookup-invalidation":
            await vm.syncAndWait()
            let ch = vm.channels[0]
            try require(vm.program(for: ch, at: Date())?.title == "A Guide", "prepared published guide lookup missing")
            let replacement = EPGProgram(id: "replacement", channelID: "epg-1", title: "Replacement", description: "", start: .now.addingTimeInterval(-60), end: .now.addingTimeInterval(60))
            vm.programs = ["epg-1": [replacement]]
            try require(vm.program(for: ch, at: Date())?.title == "Replacement", "direct guide replacement retained stale prepared lookup")
            try require(vm.programsForChannel(ch, between: .now.addingTimeInterval(-10), and: .now.addingTimeInterval(10)).first?.id == "replacement", "direct guide replacement retained stale hour buckets")
        case "xml-cancel":
            let worker = Task { try await XMLTVParser.parse(from: URL(string: base + "/A/xmltv.php")!) }
            try await Task.sleep(for: .milliseconds(100))
            let started = ContinuousClock.now
            worker.cancel()
            do {
                _ = try await worker.value
                throw TestFailure(description: "cancelled remote guide returned success")
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            }
            try require(AppLog.elapsedMilliseconds(since: started) < 500, "cancelled guide transport continued to await slow server")
        case "xml-attributes":
            let xml = """
            <tv xmlns:p="urn:test">
            <programme s="x" channel-id="wrong" p:channel="also-wrong" channel="epg-1" stop="20260101010000 +0000" start="20260101000000 +0000"><title>Reordered</title><desc>Text</desc></programme>
            <programme x="x" stop="20260101010000 +0000" start="20260101000000 +0000"><title>Missing Channel</title></programme>
            <programme start="20260101000000 +0000" stop="20260101010000 +0000" channel="epg-2"><title>Standard</title></programme>
            </tv>
            """
            let parsed = XMLTVParser.parse(data: Data(xml.utf8))
            try require(parsed.count == 2, "short/optional XML attributes or missing channel changed listing count")
            try require(parsed[0].channelID == "epg-1" && parsed[0].title == "Reordered" && parsed[0].description == "Text", "attribute names/order were not honored")
            try require(parsed[0].end.timeIntervalSince(parsed[0].start) == 3600, "reordered dates parsed incorrectly")
            try require(parsed[1].channelID == "epg-2", "standard attribute order regressed")
        case "xml-chunks":
            var xml = "<tv>"
            let description = String(repeating: "Fútbol 🏟️ 東京 ", count: 80)
            for i in 0..<300 {
                xml += "<programme channel=\"epg-\(i)\" stop=\"20260101010000 +0000\" start=\"20260101000000 +0000\"><title>Fixture \(i) ⚽</title><desc>\(description)</desc></programme>"
            }
            xml += "</tv>"
            let data = Data(xml.utf8)
            try require(data.count > 128 * 1024, "fixture did not cross parser chunk boundaries")
            let expected = XMLTVParser.parse(data: data)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("buffer-xml-test-\(UUID()).xml")
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let chunked = try await XMLTVParser.parse(from: url)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let before = try encoder.encode(expected)
            let after = try encoder.encode(chunked)
            try require(expected.count == 300 && before == after, "chunked async XML parse differs from single-buffer parse")
            try require(chunked[149].description == description.trimmingCharacters(in: .whitespacesAndNewlines), "chunk boundaries damaged Unicode text")
        default: throw TestFailure(description: "unknown fixture scenario")
        }
        print("PASS \(scenario)")
        if scenario == "overlap" {
            print("SYNC_BENCH_JSON {\"fixture\":\"sync-http-overlap-v1\",\"elapsedMs\":\(AppLog.elapsedMilliseconds(since: scenarioStarted))}")
        }
    }

    @MainActor static func runCredentialScenario(_ scenario: String, config: ServerConfig) async throws {
        let defaults = UserDefaults.standard
        for key in ["buffer_playlists_v1", "buffer_active_playlist_id", "buffer_server_config", "buffer_server_status"] {
            defaults.removeObject(forKey: key)
        }
        defer {
            for key in ["buffer_playlists_v1", "buffer_active_playlist_id", "buffer_server_config", "buffer_server_status"] {
                defaults.removeObject(forKey: key)
            }
        }
        let key = DataCache.cacheKey(for: config)
        DataCache.saveChannels([channel("Saved Channel")], key: key)
        ServerPasswordStore.configure(for: config.id, password: scenario == "credential-missing" ? nil : config.password, delay: 0.55, saveSucceeds: scenario != "credential-legacy-failure")
        let encoded = try JSONEncoder().encode(config)
        var metadata = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        metadata.removeValue(forKey: "password")
        let metadataData = try JSONSerialization.data(withJSONObject: [metadata])
        if scenario == "credential-legacy" || scenario == "credential-legacy-failure" {
            defaults.set(encoded, forKey: "buffer_server_config")
            var oldStatus = ServerAccountStatus.initial(for: config, cacheKey: "old-slot")
            oldStatus.channelCount = 7
            defaults.set(try JSONEncoder().encode(oldStatus), forKey: "buffer_server_status")
        } else {
            defaults.set(metadataData, forKey: "buffer_playlists_v1")
            defaults.set(config.id.uuidString, forKey: "buffer_active_playlist_id")
        }
        defaults.set(["1"], forKey: "buffer_favorites_\(DataCache.preferenceKey(for: config))")
        if scenario == "credential-lifetime" {
            weak var reference: EPGViewModel?
            do {
                let temporary = EPGViewModel()
                reference = temporary
                try await Task.sleep(for: .milliseconds(30))
            }
            await Task.yield()
            try require(reference == nil, "blocked credential worker retained view model")
            try await Task.sleep(for: .milliseconds(600))
            return
        }
        let started = ContinuousClock.now
        let vm = EPGViewModel()
        try require(AppLog.elapsedMilliseconds(since: started) < 200, "app initialization blocked on slow Keychain")
        try require(vm.playlists.first?.name == config.name, "saved source metadata was not available immediately")
        if scenario == "credential-legacy" || scenario == "credential-legacy-failure" {
            await vm.hydrate()
            try require(vm.serverConfig?.password == config.password, "plaintext legacy credential lost during migration")
            try require(vm.channels.first?.name == "Saved Channel", "legacy source cache did not hydrate")
            try require(vm.serverStatus?.channelCount == 7, "legacy source status did not migrate")
            if scenario == "credential-legacy-failure" {
                try await waitUntil { vm.errorMessage != nil }
                try require(defaults.data(forKey: "buffer_playlists_v1") == nil, "failed migration committed unread password metadata")
                try require(defaults.data(forKey: "buffer_server_config") == encoded, "failed migration lost legacy credential payload")
                return
            }
            try await waitUntil { ServerPasswordStore.writeCount(for: config.id) == 1 }
            let migrated = try JSONSerialization.jsonObject(with: defaults.data(forKey: "buffer_playlists_v1")!) as! [[String: Any]]
            try require(migrated.first?["password"] == nil, "migration wrote a password into metadata")
            return
        }
        try require(vm.serverConfig == nil && vm.isLoadingSourceCredentials, "unread credential was exposed as ready source")
        let heartbeatStarted = ContinuousClock.now
        var heartbeats = 0
        let heartbeat = Task { @MainActor in
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(20))
                heartbeats += 1
            }
        }
        try await Task.sleep(for: .milliseconds(160))
        await heartbeat.value
        try require(AppLog.elapsedMilliseconds(since: heartbeatStarted) < 350, "main actor heartbeat waited for slow Keychain completion")
        try require(heartbeats == 6, "main actor heartbeat stalled during slow Keychain")
        try require(vm.serverConfig == nil && vm.isLoadingSourceCredentials, "fixture did not exercise unresolved credentials during heartbeat")
        try require(DataCache.channelReadCount(for: key) == 0, "saved cache loaded before credentials resolved")
        vm.sync()
        try require(vm.channels.isEmpty, "unread credential triggered source data loading")
        switch scenario {
        case "credential-bootstrap", "credential-missing":
            await vm.hydrate()
            if scenario == "credential-missing" {
                try require(vm.serverConfig == nil && vm.errorMessage != nil && !vm.isLoadingSourceCredentials, "missing Keychain entry became empty ready credential")
                try require(DataCache.channelReadCount(for: key) == 0, "missing credential allowed authenticated cache hydration")
                vm.sync()
                try require(vm.errorMessage != nil, "refresh hid missing credential error")
            } else {
                try require(vm.serverConfig?.password == config.password, "saved credential did not publish")
                try require(vm.channels.first?.name == "Saved Channel", "resolved saved source cache did not hydrate")
                try require(vm.favoriteChannelIDs == ["1"], "source preferences were not restored after credential resolution")
            }
        case "credential-rename":
            var edited = config
            edited.password = ""
            edited.name = "Renamed while unlocking"
            vm.updatePlaylist(edited)
            await vm.hydrate()
            try require(vm.serverConfig?.name == edited.name && vm.serverConfig?.password == config.password, "pending source metadata edit lost saved credential or name")
            try require(ServerPasswordStore.writeCount(for: config.id) == 0, "pending metadata edit wrote empty password")
            try require(vm.channels.first?.name == "Saved Channel", "pending metadata edit stranded startup hydration")
        case "credential-edit":
            var edited = config
            edited.password = ""
            edited.serverURL += "/edited"
            vm.updatePlaylist(edited)
            await vm.hydrate()
            try require(vm.serverConfig?.serverURL == edited.serverURL && vm.serverConfig?.password == config.password, "late credential result overwrote edited source metadata")
            try require(ServerPasswordStore.writeCount(for: config.id) == 0, "pending source edit wrote empty password")
            try require(vm.channels.isEmpty, "pending source edit published old source cache")
        case "credential-delete":
            vm.removePlaylist(id: config.id)
            try await Task.sleep(for: .milliseconds(650))
            try require(vm.playlists.isEmpty && vm.serverConfig == nil && vm.channels.isEmpty, "late credential result resurrected deleted source")
        case "credential-provided":
            var edited = config
            edited.password = "provided-replacement"
            edited.serverURL += "/provided"
            vm.updatePlaylist(edited)
            await vm.hydrate()
            try await Task.sleep(for: .milliseconds(650))
            try require(vm.serverConfig?.password == edited.password && vm.serverConfig?.serverURL == edited.serverURL, "late credential read replaced explicitly provided new password")
            try require(ServerPasswordStore.writeCount(for: config.id) == 1, "provided source password did not save asynchronously")
        default: throw TestFailure(description: "unknown credential fixture scenario")
        }
    }
}
