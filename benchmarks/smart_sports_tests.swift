import Foundation

@main
struct SmartSportsTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }

    static func main() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "Buffer/Resources/SmartSportsCatalog.json"))
        let definition = try SmartSportsCatalog.loadDefinition(data: data)
        check(definition.feeds.count == 56, "Frozen feed count")
        check(definition.feeds.reduce(0) { $0 + $1.variants.count } == 320, "Frozen variant count")
        check(definition.heldEndpoints.count == 73, "Held endpoints count")
        check(!String(decoding: data, as: UTF8.self).contains("://"), "Bundled proposal contains no URLs")
        let uniqueKeys = Set(definition.feeds.flatMap { $0.variants.map(\.key) })
        check(uniqueKeys.count == 320, "Source-scoped proposal keys unique")
        check(uniqueKeys.isDisjoint(with: Set(definition.heldEndpoints.map(\.key))), "Held endpoints not members")

        var snapshots = definition.feeds.flatMap(\.variants).reduce(into: [UUID: [Channel]]()) { result, variant in
            result[variant.sourceID, default: []].append(channel(for: variant))
        }.map { SmartSportsSourceSnapshot(sourceID: $0.key, sourceName: "Fixture", channels: $0.value) }
        let catalog = definition.reconcile(snapshots: snapshots)
        check(catalog.feeds.flatMap(\.availableVariants).count == 320, "All frozen identities reconcile")
        check(catalog.reviewItems.count == 73, "Held queue remains excluded")
        check(catalog.feeds.map(\.id) == definition.feeds.map(\.id), "Logical identity preserved")

        let feed = definition.feeds[0]
        let first = feed.variants[0]
        let second = feed.variants[1]
        let actual = channel(for: first)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let changed = Channel(id: first.nativeID, name: first.identity.name + " +1", logoURL: nil,
            group: first.identity.group, streamURL: actual.streamURL, epgChannelID: first.identity.epgChannelID)
        snapshots = replacing(first.key, with: changed, in: snapshots)
        let changedCatalog = definition.reconcile(snapshots: snapshots)
        check(changedCatalog.variants(for: feed.id).first { $0.key == first.key }?.state == .changedIdentity,
              "Timeshift identity cannot silently merge")
        check(changedCatalog.selection(for: feed.id)?.selected.key != first.key, "Changed identity not selected")
        for suffix in [" Ireland", " French", " Event 14", " UHD Ultimate"] {
            let other = Channel(id: first.nativeID, name: first.identity.name + suffix, logoURL: nil,
                group: first.identity.group, streamURL: actual.streamURL, epgChannelID: first.identity.epgChannelID)
            let result = definition.reconcile(snapshots: replacing(first.key, with: other, in: snapshots))
            check(result.variants(for: feed.id).first { $0.key == first.key }?.state == .changedIdentity,
                  "Region/language/event/edition distinction preserved")
        }
        let wrongGuide = Channel(id: first.nativeID, name: first.identity.name, logoURL: nil,
            group: first.identity.group, streamURL: actual.streamURL, epgChannelID: "BBCOne.uk")
        let wrongCatalog = definition.reconcile(snapshots: replacing(first.key, with: wrongGuide, in: snapshots))
        check(wrongCatalog.variants(for: feed.id).first { $0.key == first.key }?.state == .changedIdentity,
              "Wrong BBCOne binding needs review")
        let sameNativeOtherSource = SourceChannelIdentity(sourceID: UUID(), nativeID: first.nativeID)
        check(sameNativeOtherSource != first.key, "Native collisions remain source scoped")

        var overrides = SmartSportsOverrides()
        let splitID = overrides.split(first.key, name: "Reviewed +1 edition", country: "AU", language: "en",
            edition: "+1", identity: .init(channel: changed))
        overrides.preferredVariants[splitID] = first.key.rawValue
        let split = definition.reconcile(snapshots: snapshots, overrides: overrides)
        check(!split.variants(for: feed.id).contains { $0.key == first.key }, "Split removed from base")
        check(split.selection(for: splitID)?.selected.key == first.key, "Manual split available")
        check(definition.reconcile(snapshots: snapshots, overrides: overrides).feeds.last?.id == splitID,
              "Split survives refresh with stable ID")
        overrides.reject(first.key)
        check(definition.reconcile(snapshots: snapshots, overrides: overrides).selection(for: splitID) == nil,
              "Rejection survives refresh")
        check(overrides.preferredVariants[splitID] == first.key.rawValue, "Unavailable preference retained")

        let held = definition.heldEndpoints[0]
        let heldChannel = Channel(id: held.nativeID, name: "Reviewed separate UHD edition", logoURL: nil,
            group: "4K", streamURL: URL(string: "http://127.0.0.1/held")!, epgChannelID: "Ultimate.uk")
        snapshots.append(.init(sourceID: held.sourceID, sourceName: "Held fixture", channels: [heldChannel]))
        let heldCatalog = definition.reconcile(snapshots: snapshots)
        check(!heldCatalog.feeds.flatMap(\.availableVariants).contains { $0.key == held.key }, "Held live row excluded")
        var heldOverride = SmartSportsOverrides()
        let heldSplit = heldOverride.split(held.key, name: "Reviewed UHD", country: "UK", language: "en",
            edition: "UHD", identity: .init(channel: heldChannel))
        check(definition.reconcile(snapshots: snapshots, overrides: heldOverride)
            .selection(for: heldSplit)?.selected.key == held.key, "Explicit review can accept held separately")
        var rejectHeld = SmartSportsOverrides()
        rejectHeld.reject(held.key)
        check(definition.reconcile(snapshots: snapshots, overrides: rejectHeld).reviewItems
            .first { $0.key == held.key }?.state == .rejected, "Held exclusion visible to review UI")

        snapshots = replacing(first.key, with: actual, in: snapshots)
        var healthy = SmartSportsObservation(observedAt: now, provenance: .passivePlayback,
            endpointFingerprint: SmartSportsCatalog.endpointFingerprint(for: actual),
            playedSeconds: 240, startupSeconds: 1.2, width: 1280, height: 720, fps: 50)
        let other = channel(for: second)
        var high = SmartSportsObservation(observedAt: now, provenance: .formatProbe,
            endpointFingerprint: SmartSportsCatalog.endpointFingerprint(for: other),
            width: 3840, height: 2160, fps: 60)
        var observed = definition.reconcile(snapshots: snapshots, observations: [first.key: healthy, second.key: high])
        check(observed.selection(for: feed.id, context: .init(now: now))?.selected.key == first.key,
              "Sustained reliability precedes format quality")
        healthy.failures = 1
        observed = definition.reconcile(snapshots: snapshots, observations: [first.key: healthy, second.key: high])
        check(observed.selection(for: feed.id, context: .init(now: now))?.selected.key == second.key,
              "Recent failed playback ranks behind unknown reliability")
        healthy.failures = 0; healthy.droppedFrames = 100; healthy.renderedFrames = 1_000
        observed = definition.reconcile(snapshots: snapshots, observations: [first.key: healthy, second.key: high])
        check(observed.selection(for: feed.id, context: .init(now: now))?.selected.key == second.key,
              "Measured drops influence reliability")
        high.endpointFingerprint = "obsolete"
        observed = definition.reconcile(snapshots: snapshots, observations: [second.key: high])
        check(observed.variants(for: feed.id).first { $0.key == second.key }?.observation?.provenance != .formatProbe,
              "Old endpoint measurements invalidated")
        high.endpointFingerprint = SmartSportsCatalog.endpointFingerprint(for: other)
        high.fps = 25
        healthy.droppedFrames = 0; healthy.playedSeconds = 30
        observed = definition.reconcile(snapshots: snapshots, observations: [first.key: healthy, second.key: high])
        check(observed.selection(for: feed.id, context: .init(now: now))?.selected.key == first.key,
              "Observed sports motion precedes useful resolution")
        check(observed.selection(for: feed.id, context: .init(now: now))?.uncertainty.contains("Sustained reliability is unqualified.") == true,
              "Short scenario not qualification")
        var context = SmartSportsSelectionContext(now: now)
        context.unavailableEndpoints.insert(first.key)
        check(observed.selection(for: feed.id, context: context)?.selected.key != first.key, "Account cap/device gate")
        context.unavailableSources = Set(feed.variants.map(\.sourceID))
        check(observed.selection(for: feed.id, context: context) == nil, "No eligible source fails closed")

        var preferred = SmartSportsOverrides()
        preferred.preferredVariants[feed.id] = second.key.rawValue
        preferred.preferredGuides[feed.id] = first.key.rawValue
        let independent = definition.reconcile(snapshots: snapshots, overrides: preferred)
        let programs = Dictionary(uniqueKeysWithValues: [first, second].map { variant in
            (variant.key, [EPGProgram(id: variant.nativeID, channelID: variant.identity.epgChannelID!, title: "Fixture Sport",
                description: "", start: now.addingTimeInterval(-1_800), end: now.addingTimeInterval(1_800))])
        })
        check(independent.selection(for: feed.id, context: .init(now: now))?.selected.key == second.key,
              "Manual physical source selected")
        check(independent.guideSelection(for: feed.id, programs: programs, now: now)?.key == first.key,
              "Guide independent of playback")
        check(independent.guideSelection(for: feed.id, programs: [first.key: [EPGProgram(id: "wrong", channelID: "BBCOne.uk",
            title: "Wrong", description: "", start: now, end: now.addingTimeInterval(100))]], now: now) == nil,
              "Wrong source guide bucket refused")
        for dummy in ["live.bossdummy", "channel.p13", "foo.v3", "bosssports.1", "channel.NCAABgames1", "stan/event1"] {
            check(SmartSportsCatalog.isSuspiciousGuideID(dummy), "Dummy/event guide excluded")
        }
        var archive = SmartSportsSelectionContext(mode: .catchup, now: now,
            requestedArchiveStart: now.addingTimeInterval(-3_600))
        check(independent.selection(for: feed.id, context: archive) == nil, "Archive never falls back live")
        let replayable = Channel(id: first.nativeID, name: first.identity.name, logoURL: nil, group: first.identity.group,
            streamURL: actual.streamURL, epgChannelID: first.identity.epgChannelID,
            catchup: .init(kind: .xc, days: 1, source: nil))
        let archiveCatalog = definition.reconcile(snapshots: replacing(first.key, with: replayable, in: snapshots))
        check(archiveCatalog.selection(for: feed.id, context: archive) == nil, "Advertised archive not timing validation")
        archive.validatedArchiveKeys.insert(first.key)
        check(archiveCatalog.selection(for: feed.id, context: archive)?.selected.key == first.key,
              "Validated wall-clock archive resolves physical endpoint")
        archive.requestedArchiveStart = now.addingTimeInterval(-2 * 86400)
        check(archiveCatalog.selection(for: feed.id, context: archive) == nil, "Archive window enforced")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("smart-sports-tests-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SmartSportsCatalogStore(fileURL: file)
        try await store.save(overrides: preferred)
        try await store.record(healthy, for: first.key)
        let restored = try await SmartSportsCatalogStore(fileURL: file).load()
        check(restored.overrides.preferredGuides[feed.id] == first.key.rawValue, "Atomic override roundtrip")
        check(restored.keyedObservations[first.key]?.fps == 50, "Observation roundtrip")
        let older = SmartSportsObservation(observedAt: now.addingTimeInterval(-100), provenance: .formatProbe, fps: 1)
        try await store.record(older, for: first.key)
        let afterLate = try await store.load()
        check(afterLate.keyedObservations[first.key]?.fps == 50, "Late stale observation cannot overwrite")
        let persistedData = try Data(contentsOf: file)
        check(!String(decoding: persistedData, as: UTF8.self).contains("://"), "Persisted state has no URLs")
        print("PASS \(checks) Smart Sports identity, held membership, manual review, selection, guide, archive and persistence checks")
    }

    static func channel(for variant: SmartSportsVariantDefinition) -> Channel {
        Channel(id: variant.nativeID, name: variant.identity.name, logoURL: nil,
            group: variant.identity.group, streamURL: URL(string: "http://127.0.0.1/\(variant.sourceID)/\(variant.nativeID)")!,
            epgChannelID: variant.identity.epgChannelID)
    }

    static func replacing(_ key: SmartSportsEndpointKey, with channel: Channel,
                          in snapshots: [SmartSportsSourceSnapshot]) -> [SmartSportsSourceSnapshot] {
        snapshots.map { snapshot in
            guard snapshot.sourceID == key.sourceID else { return snapshot }
            return .init(sourceID: snapshot.sourceID, sourceName: snapshot.sourceName,
                         channels: snapshot.channels.map { $0.id == key.nativeID ? channel : $0 })
        }
    }
}
