import Foundation

actor SmartCatalogVersionFixture {
    var sources: [SmartSportsLoadedSource]
    init(_ sources: [SmartSportsLoadedSource]) { self.sources = sources }
    func load() -> SmartSportsSnapshotLoadResult { .init(sources: sources, issues: [:]) }
    func replaceGuide(sourceID: UUID, program: EPGProgram) {
        sources = sources.map { source in
            guard source.config.id == sourceID else { return source }
            return .init(config: source.config, snapshot: source.snapshot,
                         programs: [program.channelID: [program]], savedAt: source.savedAt)
        }
    }
}

@main
@MainActor
enum SmartCatalogVersionTests {
    static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
        let a = UUID(), b = UUID(), now = Date()
        let ca = ServerConfig(id: a, name: "A", type: .m3u, m3uURL: "http://127.0.0.1/a.m3u")
        let cb = ServerConfig(id: b, name: "B", type: .m3u, m3uURL: "http://127.0.0.1/b.m3u")
        let ka = SourceChannelIdentity(sourceID: a, nativeID: "42")
        let kb = SourceChannelIdentity(sourceID: b, nativeID: "42")
        func channel(_ source: String) -> Channel {
            .init(id: "42", name: "Fixture Sports", logoURL: nil, group: "Sports",
                  streamURL: URL(string: "http://127.0.0.1/\(source)")!, epgChannelID: "Shared.au",
                  catchup: .init(kind: .shift, days: 1, source: nil))
        }
        func program(_ title: String) -> EPGProgram {
            .init(id: "current", channelID: "Shared.au", title: title, description: "",
                  start: now.addingTimeInterval(-1_800), end: now.addingTimeInterval(1_800))
        }
        let rawA = channel("a"), rawB = channel("b")
        let sa = SmartSportsSnapshotLoader.activeSource(config: ca, channels: [rawA],
            programs: ["Shared.au": [program("A programme")]], allowedKeys: [ka])
        let sb = SmartSportsSnapshotLoader.activeSource(config: cb, channels: [rawB],
            programs: ["Shared.au": [program("B programme")]], allowedKeys: [kb])
        func variant(_ config: ServerConfig, _ channel: Channel) -> SmartSportsVariantDefinition {
            .init(sourceID: config.id, sourceName: config.name, nativeID: channel.id, identity: .init(channel: channel),
                  advertisedFormat: "", advertisedFPS: nil, width: nil, height: nil,
                  fps: nil, measuredAt: nil, measurementContext: "Unmeasured")
        }
        let feedID = "smart:sports:catalog-version-fixture"
        let definition = SmartSportsDefinition(schemaVersion: 1, playlistID: SmartSportsCoordinator.playlistID,
            name: "Smart Sports", provenance: "Local fixture", feeds: [.init(id: feedID, name: "Fixture Sports",
                country: "AU", language: "en", edition: "national", guideStatus: "Aligned", caveats: [],
                variants: [variant(ca, rawA), variant(cb, rawB)])], heldEndpoints: [])
        let fixture = SmartCatalogVersionFixture([sa, sb])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("smart-catalog-versions-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let coordinator = SmartSportsCoordinator(definition: definition, store: .init(fileURL: file),
            ledger: .init(), snapshotLoader: { _ in await fixture.load() })
        let model = EPGViewModel(smartSports: coordinator)
        model.playlists = [ca, cb]
        model.activePlaylistID = a
        model.channels = sa.snapshot.channels
        model.programs = sa.programs
        model.activateSmartSports()
        await model.syncAndWait()
        await coordinator.setPreferredVariant(ka, for: feedID)
        await coordinator.setPreferredGuide(ka, for: feedID)
        let initialCatalogVersion = model.channelCatalogVersion
        let initialGuideVersion = model.guideVersion
        for index in 0..<4 {
            await fixture.replaceGuide(sourceID: a, program: program("Guide update \(index)"))
            await coordinator.refresh(configurations: [ca, cb])
        }
        expect(model.channelCatalogVersion == initialCatalogVersion,
               "Programme-only callbacks must not signal a source/catalog replacement to Sports")
        expect(model.guideVersion > initialGuideVersion, "Programme-only callbacks still invalidate the displayed guide")
        expect(model.currentProgram(for: model.displayedChannels[0])?.title == "Guide update 3",
               "Current guide publication must remain visible")
        await coordinator.setPreferredVariant(kb, for: feedID)
        let sourceVersion = model.channelCatalogVersion
        expect(sourceVersion > initialCatalogVersion, "Manual physical source replacement invalidates the catalog")
        expect(model.displayedChannels[0].sourceChannelIdentity == kb, "Manual source replacement changes actual ownership")
        await coordinator.setPreferredGuide(kb, for: feedID)
        expect(model.channelCatalogVersion > sourceVersion, "Raw source guide binding change invalidates action metadata")
        expect(model.displayedChannels[0].sourceOwnership?.guideBinding?.sourceID == b,
               "Manual guide replacement retains correct source binding")
        let smartVersion = model.channelCatalogVersion
        let smartGuideVersion = model.guideVersion
        model.setActivePlaylist(id: a)
        expect(model.channelCatalogVersion > smartVersion && model.guideVersion > smartGuideVersion,
               "Returning to the same original source invalidates old logical Sports matches")
        expect(model.displayedChannels[0].sourceChannelIdentity == ka && model.displayedChannels[0].id == "42",
               "Original source rows remain physically scoped")
        let ordinaryVersion = model.channelCatalogVersion
        model.activateSmartSports()
        await model.syncAndWait()
        expect(model.channelCatalogVersion > ordinaryVersion,
               "Reentering an unchanged Smart catalog still invalidates the original-source index")
        print("PASS \(checks) actual Smart catalog/guide version and mode-switch regression checks")
    }
}
