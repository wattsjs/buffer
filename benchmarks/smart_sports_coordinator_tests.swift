import Foundation

actor WarmSmartSnapshotFixture {
    var result: SmartSportsSnapshotLoadResult
    init(_ result: SmartSportsSnapshotLoadResult) { self.result = result }
    func load() -> SmartSportsSnapshotLoadResult { result }
    func replace(_ result: SmartSportsSnapshotLoadResult) { self.result = result }
}

@main
@MainActor
struct SmartSportsCoordinatorTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }

    static func main() async throws {
        let now = Date()
        let a = UUID(), b = UUID()
        let configA = ServerConfig(id: a, name: "Fixture A", type: .m3u, m3uURL: "http://127.0.0.1/fixture-a.m3u")
        let configB = ServerConfig(id: b, name: "Fixture B", type: .m3u, m3uURL: "http://127.0.0.1/fixture-b.m3u")
        let nativeA = physical(source: "a"), nativeB = physical(source: "b")
        let keyA = SourceChannelIdentity(sourceID: a, nativeID: "42")
        let keyB = SourceChannelIdentity(sourceID: b, nativeID: "42")
        let definition = SmartSportsDefinition(schemaVersion: 1, playlistID: SmartSportsCoordinator.playlistID,
            name: "Smart Sports", provenance: "Local fixture",
            feeds: [.init(id: "smart:sports:fixture", name: "Fixture Sports", country: "AU", language: "en",
                edition: "national", guideStatus: "Timing review", caveats: [],
                variants: [variant(sourceID: a, channel: nativeA), variant(sourceID: b, channel: nativeB)])], heldEndpoints: [])
        let rowsA = [EPGProgram(id: "42", channelID: "SharedGuide.au", title: "A source schedule", description: "",
            start: now.addingTimeInterval(-1_800), end: now.addingTimeInterval(1_800))]
        let rowsB = [EPGProgram(id: "42", channelID: "SharedGuide.au", title: "B different schedule", description: "",
            start: now.addingTimeInterval(1_800), end: now.addingTimeInterval(5_400))]
        let sourceA = SmartSportsSnapshotLoader.activeSource(config: configA, channels: [nativeA],
            programs: ["SharedGuide.au": rowsA], allowedKeys: [keyA])
        let sourceB = SmartSportsSnapshotLoader.activeSource(config: configB, channels: [nativeB],
            programs: ["SharedGuide.au": rowsB], allowedKeys: [keyB])
        check(sourceA.snapshot.channels.first?.sourceChannelIdentity == keyA, "Loader stamps source-native identity")
        check(sourceA.snapshot.channels.first?.sourceOwnership?.accountKey == SourceAccountKey(config: configA),
              "Loader stamps shared capacity account")
        check(sourceA.programs["SharedGuide.au"]?.first?.start == rowsA[0].start, "Loader preserves raw timing")
        let unrelated = Channel(id: "99", name: "Unrelated", logoURL: nil, group: "Other",
            streamURL: URL(string: "http://127.0.0.1/unrelated")!, epgChannelID: "Other.guide")
        let filtered = SmartSportsSnapshotLoader.activeSource(config: configA, channels: [nativeA, unrelated],
            programs: ["SharedGuide.au": rowsA, "Other.guide": rowsB], allowedKeys: [keyA])
        check(filtered.snapshot.channels.count == 1 && filtered.programs.count == 1,
              "Loader retains relevant rows and guide buckets only")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("smart-coordinator-tests-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let ledger = AccountCapacityLedger()
        let coordinator = SmartSportsCoordinator(definition: definition,
            store: .init(fileURL: file), ledger: ledger, snapshotLoader: { _ in
                .init(sources: [sourceA, sourceB], issues: [:])
            })
        var callbacks = 0
        coordinator.onChange = { callbacks += 1 }
        await coordinator.refresh(configurations: [configA, configB], activeConfig: configA,
            activeChannels: [nativeA], activePrograms: ["SharedGuide.au": rowsA])
        check(coordinator.displayedChannels.count == 1, "One stable logical row for two sources")
        check(coordinator.displayedChannels[0].id == "smart:sports:fixture", "Logical row identity stable")
        check(coordinator.displayedChannels[0].epgChannelID == "smart-guide:smart:sports:fixture", "Logical guide namespace")
        check(coordinator.displayedPrograms.values.first?.first?.channelID == coordinator.displayedChannels[0].epgChannelID,
              "Display guide IDs agree with row lookup")
        check(coordinator.displayedPrograms.values.first?.first?.id.hasPrefix(keyA.rawValue) == true,
              "Display programme ID includes physical source")
        check(coordinator.displayedChannels[0].catchup == nil, "Timing review never advertises borrowed archive")
        check(coordinator.sourcePrograms(for: a)["SharedGuide.au"]?.first?.title == "A source schedule"
            && coordinator.sourcePrograms(for: b)["SharedGuide.au"]?.first?.title == "B different schedule",
              "Identical raw guide keys do not collide across sources")
        check(callbacks >= 2, "Active publication precedes other source hydration")
        let physicalMatching = coordinator.sportsMatchingSnapshot()
        check(Set(physicalMatching.channels.compactMap(\.sourceChannelIdentity)) == [keyA, keyB],
              "Sports alternatives contain both physical sources rather than one logical row")
        check(physicalMatching.channels.allSatisfy { $0.id == "42" && $0.epgChannelID == "SharedGuide.au" && $0.sourceOwnership?.logicalChannelID == nil },
              "Matching retains raw source/native/guide action identity")
        check(physicalMatching.programs[a.uuidString.lowercased() + "|SharedGuide.au"]?.first?.title == rowsA[0].title
            && physicalMatching.programs[b.uuidString.lowercased() + "|SharedGuide.au"]?.first?.title == rowsB[0].title,
              "Physical matching guides have separate source namespaces and unshifted times")
        let expandedMatching = coordinator.sportsMatchingSnapshot(activeConfig: configA,
            activeChannels: [nativeA, unrelated], activePrograms: ["SharedGuide.au": rowsA, "Other.guide": rowsB])
        check(expandedMatching.channels.count == 3,
              "Complete active catalog supplements curated snapshots without replacing other source alternatives")
        check(expandedMatching.channels.first { $0.id == "99" }?.sourceChannelIdentity?.sourceID == a,
              "Supplemented ordinary row carries actual source ownership")
        let cacheStart = coordinator.sportsMatchingCatalogBuildCount
        _ = coordinator.sportsMatchingSnapshot(activeConfig: configA, activeChannels: [nativeA],
            activePrograms: ["SharedGuide.au": rowsA], activeCatalogVersion: 101)
        check(coordinator.sportsMatchingCatalogBuildCount == cacheStart + 1, "First physical catalog snapshot builds once")
        let newGuideRow = EPGProgram(id: "fresh-guide", channelID: "SharedGuide.au", title: "New guide publication", description: "",
            start: rowsA[0].start, end: rowsA[0].end)
        let cachedGuideOnly = coordinator.sportsMatchingSnapshot(activeConfig: configA, activeChannels: [nativeA],
            activePrograms: ["SharedGuide.au": [newGuideRow]], activeCatalogVersion: 101)
        check(coordinator.sportsMatchingCatalogBuildCount == cacheStart + 1,
              "Guide-only update does not restamp physical channels or recalculate per-row account digests")
        check(cachedGuideOnly.programs[a.uuidString.lowercased() + "|SharedGuide.au"]?.first?.id == "fresh-guide",
              "Cached physical catalog still receives newest guide arrays")
        let replacedPhysical = Channel(id: nativeA.id, name: nativeA.name, logoURL: nativeA.logoURL, group: nativeA.group,
            streamURL: URL(string: "http://127.0.0.1/replaced-endpoint")!, epgChannelID: nativeA.epgChannelID)
        let changedCatalogSnapshot = coordinator.sportsMatchingSnapshot(activeConfig: configA,
            activeChannels: [replacedPhysical], activePrograms: ["SharedGuide.au": rowsA], activeCatalogVersion: 102)
        check(coordinator.sportsMatchingCatalogBuildCount == cacheStart + 2,
              "Physical endpoint revision invalidates cached channels")
        check(changedCatalogSnapshot.channels.first { $0.sourceChannelIdentity == keyA }?.streamURL == replacedPhysical.streamURL,
              "Cache never resurrects old endpoint after a catalog change")
        var revisedConfig = configA
        revisedConfig.m3uURL = "http://127.0.0.1/revised-fixture.m3u"
        _ = coordinator.sportsMatchingSnapshot(activeConfig: revisedConfig, activeChannels: [replacedPhysical],
            activePrograms: ["SharedGuide.au": rowsA], activeCatalogVersion: 102)
        check(coordinator.sportsMatchingCatalogBuildCount == cacheStart + 3,
              "Source input revision invalidates a same-number catalog cache")
        let account = SourceAccountKey(config: configA)
        let stampedOnce = SmartSportsSnapshotLoader.stamp(nativeA, config: configA, accountKey: account)
        let reusedStamp = SmartSportsSnapshotLoader.stamp(stampedOnce, config: configA, accountKey: account)
        check(reusedStamp.sourceOwnership == stampedOnce.sourceOwnership && reusedStamp.streamURL == stampedOnce.streamURL,
              "Precomputed account stamping preserves exact physical ownership and endpoint")

        await coordinator.setPreferredVariant(keyB, for: "smart:sports:fixture")
        await coordinator.setPreferredGuide(keyA, for: "smart:sports:fixture")
        let playback = coordinator.playbackChannel(for: "smart:sports:fixture")!
        check(playback.sourceChannelIdentity == keyB, "Explicit source override routes physical endpoint")
        check(playback.id == "smart:sports:fixture" && playback.sourceOwnership?.logicalChannelID == playback.id,
              "Physical switch preserves window/favorite identity")
        check(playback.epgChannelID == "SharedGuide.au" && playback.sourceOwnership?.guideBinding?.sourceID == b,
              "Physical playback keeps its own raw guide binding")
        check(coordinator.displayedPrograms.values.first?.first?.title == "A source schedule",
              "Guide choice independent of chosen playback")
        check(coordinator.config(for: b)?.id == b, "Action can resolve actual source configuration")
        check(coordinator.programs(for: playback).first?.start == rowsB[0].start,
              "Physical action receives that source's unshifted guide")
        await coordinator.reject(keyB)
        check(coordinator.catalog?.reviewItems.first { $0.key == keyB }?.state == .rejected,
              "Exclude proposal updates review state")
        check(coordinator.sportsMatchingSnapshot().channels.allSatisfy { $0.sourceChannelIdentity != keyB },
              "Rejected endpoint is also excluded from event alternatives")
        await coordinator.restoreProposal(keyB)
        check(coordinator.preferredVariant(for: "smart:sports:fixture") == nil,
              "Restore proposal clears endpoint choice")
        check(coordinator.variants(for: "smart:sports:fixture").first { $0.key == keyB }?.state == .metadataCandidate,
              "Restore proposal restores exact current metadata candidate")
        await coordinator.setPreferredVariant(keyB, for: "smart:sports:fixture")
        let lease = try ledger.reserve(for: sourceB.snapshot.channels[0], kind: .recording, ownerID: UUID()).get()
        check(coordinator.playbackChannel(for: "smart:sports:fixture")?.sourceChannelIdentity == keyA,
              "Recording uses same account gate as initial selection")
        check(coordinator.displayedChannels[0].streamURL == nativeB.streamURL, "Saturated source remains visible")
        check(ledger.confirmTeardown(lease: lease), "Only media owner releases capacity")
        var catchup = SmartSportsSelectionContext(mode: .catchup,
            requestedArchiveStart: now.addingTimeInterval(-1_200))
        check(coordinator.playbackChannel(for: "smart:sports:fixture", context: catchup) == nil,
              "Archive without source timing validation fails closed")
        catchup.validatedArchiveKeys = [keyA]
        check(coordinator.playbackChannel(for: "smart:sports:fixture", context: catchup)?.sourceChannelIdentity == keyA,
              "Explicit archive timing gate overrides a different live preference")

        let missing = await SmartSportsSnapshotLoader.load(configurations: [configB], definition: definition,
            overrides: .init())
        check(missing.sources.isEmpty && missing.issues[b] != nil, "Missing v8 cache unavailable; no URL fabrication")

        let warmFixture = WarmSmartSnapshotFixture(.init(sources: [sourceA, sourceB], issues: [:]))
        let warm = SmartSportsCoordinator(definition: definition,
            store: .init(fileURL: file), ledger: .init(), snapshotLoader: { _ in await warmFixture.load() })
        await warm.refresh(configurations: [configA, configB])
        await warmFixture.replace(.init(sources: [sourceA], issues: [b: "Fixture channel read failed"],
            resolvedConfigurations: [a: configA, b: configB]))
        await warm.refresh(configurations: [configA, configB])
        check(warm.config(for: b) != nil && warm.currentChannel(for: keyB)?.streamURL == nativeB.streamURL,
              "Same-revision transient channel read failure retains the usable owned endpoint")
        check(warm.sourcePrograms(for: b)["SharedGuide.au"]?.first?.title == rowsB[0].title,
              "Same-revision read failure retains raw warm guide times")
        check(warm.sourceIssues[b] != nil && warm.errorMessage?.contains("last available") == true,
              "Retained data never claims a successful refresh")
        let noGuide = SmartSportsLoadedSource(config: configB, snapshot: sourceB.snapshot,
            programs: [:], savedAt: nil, guideReadSucceeded: false)
        await warmFixture.replace(.init(sources: [sourceA, noGuide], issues: [b: "Fixture guide read failed"],
            resolvedConfigurations: [a: configA, b: configB]))
        await warm.refresh(configurations: [configA, configB])
        check(warm.sourcePrograms(for: b)["SharedGuide.au"]?.first?.start == rowsB[0].start,
              "Missing guide file cannot erase an unchanged warm binding")
        let obsolete = EPGProgram(id: "old", channelID: "SharedGuide.au", title: "Expired", description: "",
            start: now.addingTimeInterval(-40 * 86_400), end: now.addingTimeInterval(-39 * 86_400))
        let future = EPGProgram(id: "future", channelID: "SharedGuide.au", title: "Beyond bound", description: "",
            start: now.addingTimeInterval(20 * 86_400), end: now.addingTimeInterval(21 * 86_400))
        let wrongBinding = EPGProgram(id: "wrong", channelID: "BBCOne.uk", title: "Wrong bucket", description: "",
            start: rowsB[0].start, end: rowsB[0].end)
        let dense = SmartSportsLoadedSource(config: configB, snapshot: sourceB.snapshot,
            programs: ["SharedGuide.au": rowsB + [obsolete, future, wrongBinding]], savedAt: now)
        let bounded = SmartSportsSnapshotLoader.retainingWarmGuide(dense, for: noGuide, now: now)
        check(bounded.programs["SharedGuide.au"]?.map(\.id) == rowsB.map(\.id),
              "Warm fallback preserves ordinary age bounds and exact raw guide binding")
        let changedIdentity = Channel(id: "42", name: "Different station", logoURL: nil, group: "Other",
            streamURL: nativeB.streamURL, epgChannelID: "SharedGuide.au")
        let changedSource = SmartSportsLoadedSource(config: configB,
            snapshot: .init(sourceID: b, sourceName: configB.name,
                channels: [SmartSportsSnapshotLoader.stamp(changedIdentity, config: configB)]),
            programs: [:], savedAt: now, guideReadSucceeded: false)
        await warmFixture.replace(.init(sources: [sourceA, changedSource], issues: [b: "Fixture guide read failed"]))
        await warm.refresh(configurations: [configA, configB])
        check(warm.sourcePrograms(for: b).isEmpty && warm.variants(for: "smart:sports:fixture")
            .first(where: { $0.key == keyB })?.state == .changedIdentity,
              "Recycled native identity never borrows the old warm guide")
        check(warm.sportsMatchingSnapshot().channels.allSatisfy { $0.sourceChannelIdentity != keyB },
              "Changed native identity is excluded from physical sports alternatives pending review")
        await warmFixture.replace(.init(sources: [sourceA, sourceB], issues: [:]))
        await warm.refresh(configurations: [configA, configB])
        let emptySnapshot = SmartSportsLoadedSource(config: configB,
            snapshot: .init(sourceID: b, sourceName: configB.name, channels: []), programs: [:], savedAt: now)
        await warmFixture.replace(.init(sources: [sourceA, emptySnapshot], issues: [:]))
        await warm.refresh(configurations: [configA, configB])
        check(warm.currentChannel(for: keyB) == nil && warm.sourcePrograms(for: b).isEmpty,
              "Successful empty current channel snapshot remains authoritative")
        // Account credential/guide revisions must invalidate warm data before
        // a failing replacement cache read; these fixture values never leave localhost.
        let originalAccount = ServerConfig(id: b, name: "Fixture account", type: .xtream,
            serverURL: "http://127.0.0.1", username: "fixture", password: "old-fixture", epgURL: "http://127.0.0.1/guide")
        let ownedAccount = SmartSportsSnapshotLoader.activeSource(config: originalAccount, channels: [nativeB],
            programs: ["SharedGuide.au": rowsB], allowedKeys: [keyB])
        for revision in ["password", "guide", "unresolved", "removed"] {
            await warmFixture.replace(.init(sources: [sourceA, ownedAccount], issues: [:]))
            await warm.refresh(configurations: [configA, originalAccount])
            var edited = originalAccount
            if revision == "password" { edited.password = "new-fixture" }
            if revision == "guide" { edited.epgURL = "http://127.0.0.1/revised-guide" }
            if revision == "unresolved" { edited.password = "" }
            await warmFixture.replace(.init(sources: [sourceA], issues: [b: "Fixture read failed"],
                resolvedConfigurations: revision == "unresolved" || revision == "removed" ? [:] : [b: edited]))
            await warm.refresh(configurations: revision == "removed" ? [configA] : [configA, edited])
            check(warm.config(for: b) == nil && warm.sourcePrograms(for: b).isEmpty,
                  "Removed, changed or unresolved revision cannot resurrect warm source: \(revision)")
        }

        let delayed = SmartSportsCoordinator(definition: definition,
            store: .init(fileURL: file), ledger: AccountCapacityLedger(), snapshotLoader: { request in
                let isOld = request.configurations.first?.name == "Old request"
                try? await Task.sleep(for: .milliseconds(isOld ? 200 : 10))
                return .init(sources: isOld ? [sourceB] : [sourceA], issues: [:])
            })
        var old = configA; old.name = "Old request"
        let oldTask = Task { await delayed.refresh(configurations: [old, configB]) }
        try await Task.sleep(for: .milliseconds(20))
        await delayed.refresh(configurations: [configA])
        await oldTask.value
        check(delayed.config(for: a) != nil && delayed.config(for: b) == nil, "Old refresh cannot publish over new epoch")
        check(delayed.isLoading == false, "Newest refresh owns loading state")
        let cancelled = Task { await delayed.refresh(configurations: [old]) }
        try await Task.sleep(for: .milliseconds(20))
        delayed.cancelRefresh()
        cancelled.cancel()
        await cancelled.value
        check(delayed.config(for: b) == nil && !delayed.isLoading, "Cancelled loader cannot swap source ownership")

        let availabilityLedger = AccountCapacityLedger()
        let availability = SmartSportsCoordinator(definition: definition, store: .init(fileURL: file),
            ledger: availabilityLedger, snapshotLoader: { _ in .init(sources: [sourceA, sourceB], issues: [:]) })
        await availability.refresh(configurations: [configA, configB])
        var physicalProbes: [SourceChannelIdentity: StreamProbe] = [:]
        availability.probeLookup = { channel in channel.sourceChannelIdentity.flatMap { physicalProbes[$0] } }
        func probe(_ channel: Channel, status: StreamProbe.Status, date: Date = now,
                   fingerprint: Bool = true, provenance: Bool = true) -> StreamProbe {
            var result = StreamProbe(status: status, probedAt: date, probeSeconds: 0.1,
                width: 1920, height: 1080, fps: 50, videoCodec: "h264", audioCodec: "aac",
                audioChannels: 2, sampleRate: 48_000, bitRate: 0, hasVideo: true, hasAudio: true, errorMessage: nil)
            if fingerprint { result.endpointFingerprint = StreamProbe.endpointFingerprint(for: channel.streamURL) }
            if provenance { result.metadataProvenance = .streamProbe; result.metadataObservedAt = date }
            return result
        }
        physicalProbes[keyB] = probe(nativeB, status: .offline)
        await availability.setPreferredVariant(keyB, for: "smart:sports:fixture")
        let alternative = availability.selection(for: "smart:sports:fixture", context: .init(now: now))
        check(alternative?.selected.key == keyA && availability.preferredVariant(for: "smart:sports:fixture") == keyB,
              "Fresh failed preferred endpoint yields to an eligible unknown alternative without erasing preference")
        check(alternative?.reasons.contains(where: { $0.contains("recently failed") }) == true,
              "Failed preferred-source fallback is explained")
        let validatedArchive = SmartSportsSelectionContext(mode: .catchup, now: now,
            requestedArchiveStart: now.addingTimeInterval(-1_200), validatedArchiveKeys: [keyA, keyB])
        check(availability.selection(for: "smart:sports:fixture", context: validatedArchive)?.selected.key == keyB,
              "A failed live probe cannot disqualify a separately validated archive endpoint")
        let mixed = availability.aggregateAvailability(for: "smart:sports:fixture", now: now)
        check(mixed.state == .uncertain && mixed.uncertainCount == 1 && mixed.observedFailureCount == 1,
              "One failed physical endpoint cannot mark an unknown logical alternative offline")
        physicalProbes[keyA] = probe(nativeA, status: .ok)
        check(availability.aggregateAvailability(for: "smart:sports:fixture", now: now).state == .observedAvailable,
              "Aggregate reports a fresh successful current-endpoint observation")
        physicalProbes[keyA] = probe(nativeA, status: .timedOut)
        check(availability.aggregateAvailability(for: "smart:sports:fixture", now: now).state == .observedFailures,
              "All fresh matched failures remain explicit, not a permanent blacklist")
        check(availability.selection(for: "smart:sports:fixture", context: .init(now: now))?.selected.key == keyB,
              "When every eligible source recently failed, preferred retry remains possible")
        physicalProbes[keyA] = probe(nativeA, status: .offline, fingerprint: false)
        check(availability.aggregateAvailability(for: "smart:sports:fixture", now: now).state == .uncertain,
              "Legacy failure without endpoint revision stays uncertain")
        physicalProbes[keyA] = probe(nativeA, status: .offline, provenance: false)
        check(availability.aggregateAvailability(for: "smart:sports:fixture", now: now).state == .uncertain,
              "Failure without explicit observation provenance stays uncertain")
        physicalProbes[keyA] = probe(nativeA, status: .offline, date: now.addingTimeInterval(-901))
        check(availability.aggregateAvailability(for: "smart:sports:fixture", now: now).state == .uncertain,
              "Stale failure cannot establish current logical unavailability")
        physicalProbes[keyA] = probe(nativeA, status: .offline, date: now.addingTimeInterval(10))
        check(availability.aggregateAvailability(for: "smart:sports:fixture", now: now).state == .uncertain,
              "Future failure timestamp is rejected")
        var wrongRevision = probe(nativeA, status: .offline)
        wrongRevision.endpointFingerprint = "obsolete-endpoint"
        physicalProbes[keyA] = wrongRevision
        check(availability.aggregateAvailability(for: "smart:sports:fixture", now: now).state == .uncertain,
              "Reused native ID cannot inherit another endpoint's failed status")
        let busyA = try availabilityLedger.reserve(for: sourceA.snapshot.channels[0], kind: .player, ownerID: UUID(), now: now).get()
        let busyB = try availabilityLedger.reserve(for: sourceB.snapshot.channels[0], kind: .recording, ownerID: UUID(), now: now).get()
        check(availability.aggregateAvailability(for: "smart:sports:fixture", now: now).state == .busy,
              "Account capacity is distinguished from observed failures and unknown availability")
        check(availability.selection(for: "smart:sports:fixture", context: .init(now: now)) == nil,
              "Failed-probe ranking cannot bypass occupied account capacity")
        check(availability.selection(for: "smart:sports:fixture", context: .init(now: now), ignoreCapacity: true) != nil,
              "Existing-owner replacement planning may rank alternatives before teardown and reservation")
        availabilityLedger.confirmTeardown(lease: busyA)
        availabilityLedger.confirmTeardown(lease: busyB)
        await availability.reject(keyA)
        await availability.reject(keyB)
        check(availability.aggregateAvailability(for: "smart:sports:fixture", now: now).state == .unavailable,
              "No accepted current metadata member is unavailable, not online or busy")
        // Saved choices on retired curated feeds move to the automatic feed
        // that now holds the same stream; unrelated stale entries are dropped.
        do {
            let src = UUID()
            let kept = Channel(id: "keep", name: "AU: ESPN", logoURL: nil, group: "AU | Sports",
                               streamURL: URL(string: "http://127.0.0.1/keep")!, epgChannelID: "espn.au")
            let auto = SmartSportsDefinition(schemaVersion: 1, playlistID: "smart:sports:v1", name: "Smart Channels",
                provenance: "test", feeds: [SmartSportsFeedDefinition(id: "smart:auto:au:espn", name: "ESPN", country: "AU",
                    language: "", edition: "Sports", guideStatus: "", caveats: [], variants: [variant(sourceID: src, channel: kept)])],
                heldEndpoints: [])
            let keptKey = SmartSportsEndpointKey(sourceID: src, nativeID: "keep").rawValue
            var overrides = SmartSportsOverrides()
            overrides.preferredVariants = ["smart:sports:au.espn-1": keptKey, "smart:sports:gone": "\(UUID().uuidString)|x"]
            overrides.preferredGuides = ["smart:sports:au.espn-1": keptKey]
            overrides.links["\(src.uuidString)|old"] = .init(feedID: "smart:sports:gone", identity: .init(channel: kept))
            check(SmartSportsCoordinator.migrateRetiredFeedOverrides(&overrides, definition: auto), "Migration reported no change")
            check(overrides.preferredVariants == ["smart:auto:au:espn": keptKey]
                  && overrides.preferredGuides == ["smart:auto:au:espn": keptKey], "Preferences did not move to the automatic feed")
            check(overrides.links.isEmpty, "Links to retired feeds were kept")
            check(!SmartSportsCoordinator.migrateRetiredFeedOverrides(&overrides, definition: auto), "Migration is not idempotent")
        }
        print("PASS \(checks) Smart Sports coordinator/loader namespace, source action, account, archive and epoch checks")
    }

    static func physical(source: String) -> Channel {
        Channel(id: "42", name: "Fixture Sports", logoURL: nil, group: "AU Sports",
            streamURL: URL(string: "http://127.0.0.1/\(source)/42")!, epgChannelID: "SharedGuide.au",
            catchup: .init(kind: .xc, days: 1, source: nil))
    }

    static func variant(sourceID: UUID, channel: Channel) -> SmartSportsVariantDefinition {
        .init(sourceID: sourceID, sourceName: "Fixture", nativeID: channel.id, identity: .init(channel: channel),
              advertisedFormat: "FHD", advertisedFPS: nil, width: nil, height: nil,
              fps: nil, measuredAt: nil, measurementContext: "Unmeasured")
    }
}
