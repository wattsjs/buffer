import Foundation

@main
@MainActor
enum SmartUIRoutingTests {
    static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
        let a = UUID(), b = UUID(), now = Date()
        let ca = ServerConfig(id: a, name: "Fixture A", type: .m3u, m3uURL: "http://127.0.0.1/a.m3u")
        let cb = ServerConfig(id: b, name: "Fixture B", type: .m3u, m3uURL: "http://127.0.0.1/b.m3u")
        func channel(_ suffix: String) -> Channel {
            Channel(id: "42", name: "Fixture Sports", logoURL: nil, group: "Sports",
                streamURL: URL(string: "http://127.0.0.1/\(suffix).m3u8")!, epgChannelID: "Shared.au",
                catchup: .init(kind: .shift, days: 1, source: nil))
        }
        let rawA = channel("a"), rawB = channel("b")
        let ka = SourceChannelIdentity(sourceID: a, nativeID: "42")
        let kb = SourceChannelIdentity(sourceID: b, nativeID: "42")
        let pa = EPGProgram(id: "p", channelID: "Shared.au", title: "Source A programme", description: "",
            start: now.addingTimeInterval(-1_800), end: now.addingTimeInterval(1_800))
        let pb = EPGProgram(id: "p", channelID: "Shared.au", title: "Source B programme", description: "",
            start: now.addingTimeInterval(-1_800), end: now.addingTimeInterval(1_800))
        let sa = SmartSportsSnapshotLoader.activeSource(config: ca, channels: [rawA], programs: ["Shared.au": [pa]], allowedKeys: [ka])
        let sb = SmartSportsSnapshotLoader.activeSource(config: cb, channels: [rawB], programs: ["Shared.au": [pb]], allowedKeys: [kb])
        func variant(_ config: ServerConfig, _ channel: Channel) -> SmartSportsVariantDefinition {
            .init(sourceID: config.id, sourceName: config.name, nativeID: channel.id,
                identity: .init(channel: channel), advertisedFormat: "", advertisedFPS: nil,
                width: nil, height: nil, fps: nil, measuredAt: nil, measurementContext: "Unmeasured")
        }
        let feedID = "smart:sports:routing-fixture"
        let definition = SmartSportsDefinition(schemaVersion: 1, playlistID: SmartSportsCoordinator.playlistID,
            name: "Smart Sports", provenance: "Loopback-only routing fixture",
            feeds: [.init(id: feedID, name: "Fixture Sports", country: "AU", language: "en", edition: "national",
                guideStatus: "Timing review", caveats: [], variants: [variant(ca, rawA), variant(cb, rawB)])], heldEndpoints: [])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("smart-ui-routing-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let coordinator = SmartSportsCoordinator(definition: definition, store: .init(fileURL: file),
            ledger: .init(), snapshotLoader: { _ in .init(sources: [sa, sb], issues: [:]) })
        let model = EPGViewModel(smartSports: coordinator)
        model.playlists = [ca, cb]
        model.activePlaylistID = a
        model.channels = sa.snapshot.channels
        model.programs = sa.programs
        let preferences = ["buffer_favorites_smart_sports_v1", "buffer_recents_smart_sports_v1",
                           "buffer_channel_usage_smart_sports_v1", "buffer_group_usage_smart_sports_v1", EPGViewModel.disableVODKey]
        let saved = Dictionary(uniqueKeysWithValues: preferences.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        defer {
            for key in preferences {
                if let value = saved[key] ?? nil { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for key in preferences { UserDefaults.standard.removeObject(forKey: key) }
        model.activateSmartSports()
        await model.syncAndWait()
        await model.testWaitForProgramSearchIndex()
        expect(model.displayedChannels.count == 1 && model.filteredChannels.count == 1, "Activation publishes logical rows to actual EPG derived caches")
        expect(model.channels[0].sourceChannelIdentity == ka && model.programs["Shared.au"]?[0].title == pa.title,
            "Smart activation preserves physical source storage")
        expect(model.displayedPlaylistID == EPGViewModel.smartSportsReminderPlaylistID, "Reminder namespace is stable independently of backing source")
        await coordinator.setPreferredVariant(kb, for: feedID)
        await coordinator.setPreferredGuide(ka, for: feedID)
        let display = model.displayedChannels[0]
        let program = model.displayedPrograms[display.epgChannelID!]![0]
        let play = model.resolvePlaybackRequest(.live(display))!
        expect(play.channel.sourceChannelIdentity == kb && play.channel.id == feedID, "Live opening resolves chosen physical source while retaining logical identity")
        expect(model.currentProgram(for: display)?.title == pa.title && model.currentProgram(for: play.channel)?.title == pb.title,
            "Display and player read independently owned guides despite equal raw guide IDs")
        expect(model.programsForChannel(play.channel, between: pa.start, and: pa.end).first?.title == pb.title,
            "Physical player range lookup cannot borrow active source buckets")
        let action = model.sourceProgramAction(channel: display, program: program)!
        expect(action.channel.sourceChannelIdentity == ka && action.program.id == pa.id && action.program.channelID == pa.channelID,
            "Programme recording resolves display guide source and raw programme binding")
        expect(model.resolvePlaybackRequest(.catchup(display, from: program.start)) == nil,
            "Unqualified Smart archive cannot become live playback")
        model.toggleFavorite(display)
        model.addRecent(play.channel)
        expect(model.favoriteChannelIDs == [feedID] && model.recentChannelIDs == [feedID], "Favorites and recents use logical identity")
        expect(model.sourceProgramAction(channel: display, program: .init(id: program.id, channelID: program.channelID,
            title: program.title, description: "", start: program.start.addingTimeInterval(3_600), end: program.end.addingTimeInterval(3_600))) == nil,
            "Changed guide times reject stale action instead of shifting source timing")
        model.setActivePlaylist(id: a)
        await model.testWaitForProgramSearchIndex()
        expect(!model.isSmartSportsActive && model.displayedChannels[0].sourceChannelIdentity == ka,
            "Returning to same original source restores physical rows without destroying them")
        expect(model.isFavorite(display), "Open Smart player favorite survives original-source browsing")
        expect(model.favoriteChannelIDs.isEmpty, "Smart favorites do not contaminate original source preferences")
        var edited = cb; edited.m3uURL = "http://127.0.0.1/revised.m3u"
        model.playlists = [ca, edited]
        expect(model.resolvePlaybackRequest(.live(display)) == nil, "Obsolete credential/endpoint revision cannot open cached authenticated source")
        let reminder = ProgramReminder(id: "fixture", playlistID: EPGViewModel.smartSportsReminderPlaylistID,
            programID: program.id, channelID: feedID, channelName: display.name, programTitle: program.title,
            programDescription: "", programStart: program.start, programEnd: program.end,
            notifyAt: now, createdAt: now, leadMinutes: 0, streamURL: action.channel.streamURL,
            sourceOwnership: action.channel.sourceOwnership, sourceProgramID: action.program.id)
        let resolvedReminder = await model.resolveReminder(reminder)
        expect(resolvedReminder?.sourceChannelIdentity == ka, "Reminder resolves its pinned UUID/native source rather than current live preference")
        let data = try JSONEncoder().encode(reminder)
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "sourceOwnership"); legacy.removeValue(forKey: "sourceProgramID")
        let decoded = try JSONDecoder().decode(ProgramReminder.self, from: JSONSerialization.data(withJSONObject: legacy))
        expect(decoded.sourceOwnership == nil && decoded.sourceProgramID == nil, "Legacy reminders decode without ownership fields")
        UserDefaults.standard.set(false, forKey: EPGViewModel.disableVODKey)
        let videoA = VODItem(id: "42", name: "A Movie", posterURL: nil, group: "Movies",
            streamURL: URL(string: "http://127.0.0.1/a-movie.mp4")!, kind: .movie)
        let videoB = VODItem(id: "42", name: "B Movie", posterURL: nil, group: "Movies",
            streamURL: URL(string: "http://127.0.0.1/b-movie.mp4")!, kind: .movie)
        model.vodItems = [videoA]
        let ownedA = try await model.resolveVODPlaybackChannel(videoA, sourceID: a)
        expect(ownedA.channel.sourceChannelIdentity == .init(sourceID: a, nativeID: "vod:42"),
            "VOD source ownership uses UUID and typed native ID")
        expect(ownedA.channel.sourceOwnership?.accountKey == sa.snapshot.channels[0].sourceOwnership?.accountKey,
            "VOD player shares the physical account budget with live playback")
        let ownedResume = PlaybackRequest.resume(ownedA.channel, at: 75)
        expect(model.resolvePlaybackRequest(ownedResume) == ownedResume,
            "A source-resolved VOD resume is not rejected by the guide’s live-only channel lookup")
        model.activePlaylistID = b
        model.vodItems = [videoB]
        let ownedB = try await model.resolveVODPlaybackChannel(videoB, sourceID: b)
        expect(ownedA.channel != ownedB.channel && ownedB.channel.sourceChannelIdentity?.sourceID == b,
            "Equal VOD native IDs from different sources cannot reuse each other’s player window")
        var staleSourceRejected = false
        do { _ = try await model.resolveVODPlaybackChannel(videoA, sourceID: a) }
        catch VODPlaybackSourceError.changed { staleSourceRejected = true }
        expect(staleSourceRejected, "A stale source view cannot open another source’s identically numbered VOD item")
        let latestVideoB = VODItem(id: "42", name: "B Movie", posterURL: nil, group: "Movies",
            streamURL: URL(string: "http://127.0.0.1/revised-b-movie.mp4")!, kind: .movie)
        model.vodItems = [latestVideoB]
        let refreshedResume = try await model.resolveVODPlaybackChannel(videoB, sourceID: b)
        expect(refreshedResume.channel.streamURL == latestVideoB.streamURL,
            "Resume resolves the current owned catalog URL instead of a persisted obsolete endpoint")
        UserDefaults.standard.set(true, forKey: EPGViewModel.disableVODKey)
        var disabledRejected = false
        do { _ = try await model.resolveVODPlaybackChannel(latestVideoB, sourceID: b) }
        catch VODPlaybackSourceError.unavailable { disabledRejected = true }
        expect(disabledRejected, "Disabled VOD cannot start through an already-rendered action")
        model.activePlaylistID = a
        let revisedLive = Channel(id: "42", name: rawA.name, logoURL: nil, group: rawA.group,
            streamURL: URL(string: "http://127.0.0.1/revised-a-live.m3u8")!, epgChannelID: rawA.epgChannelID,
            catchup: rawA.catchup, sourceOwnership: sa.snapshot.channels[0].sourceOwnership)
        model.channels = [revisedLive]
        let refreshedLive = model.resolvePlaybackRequest(.live(sa.snapshot.channels[0]))
        expect(refreshedLive?.channel.streamURL == revisedLive.streamURL,
            "An ordinary rendered row resolves the current native endpoint after URL revision")
        let requestedArchiveStart = now.addingTimeInterval(-600)
        let refreshedArchive = model.resolvePlaybackRequest(.catchup(sa.snapshot.channels[0], from: requestedArchiveStart))
        expect(refreshedArchive?.channel.streamURL == revisedLive.streamURL && refreshedArchive?.intent == .catchup(start: requestedArchiveStart),
            "Ordinary source refresh preserves archive intent instead of substituting live")
        print("Smart UI source-routing checks: \(checks) passed")
    }
}
