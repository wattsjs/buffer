import Foundation

@main struct RecordingOwnershipTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
        func wait(_ condition: () -> Bool) async {
            for _ in 0..<500 { if condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
            fatalError("Recording fixture timed out")
        }
        UserDefaults.standard.removeObject(forKey: "Buffer_recordings_v1")
        UserDefaults.standard.set(false, forKey: "Buffer_recording_wakeEnabled")
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/bench/recording-test-output")
        UserDefaults.standard.set(output.path, forKey: "Buffer_recording_outputDir")
        let manager = RecordingManager.shared
        let sourceA = UUID(), sourceB = UUID(), logicalPlaylist = UUID()
        func channel(_ source: UUID) -> Channel {
            Channel(id: "smart:sports:fixture", name: "Local fixture", logoURL: nil, group: "Tests",
                streamURL: URL(string: "http://127.0.0.1/\(source)/same-native")!, epgChannelID: "same-guide",
                sourceOwnership: ChannelSourceOwnership(channelIdentity: SourceChannelIdentity(sourceID: source, nativeID: "same-native"),
                    accountKey: .unconfiguredSource(source), logicalChannelID: "smart:sports:fixture"))
        }
        let a = channel(sourceA), b = channel(sourceB)
        let player = try AccountCapacityLedger.shared.reserve(for: a, kind: .player, ownerID: UUID()).get()
        let refused = await manager.startLiveRecording(playlistID: logicalPlaylist, channel: a, program: nil)
        check(refused == nil && manager.capacityErrorMessage != nil, "recording must explain an exhausted shared account")
        check(fixture_recorder_creates() == 0, "recording opened upstream before account reservation")
        _ = AccountCapacityLedger.shared.confirmTeardown(lease: player)

        fixture_recorder_hold(1)
        let pending = Task { await manager.startLiveRecording(playlistID: logicalPlaylist, channel: a, program: nil) }
        await wait { fixture_recorder_creates() == 1 && manager.recordings.first?.status == .startingUp }
        let starting = manager.recordings.first!
        check(starting.playlistID == sourceA && starting.channelID == "same-native", "recording pin must use the physical source and native identity")
        check(starting.sourceOwnership?.logicalChannelID == a.id && starting.streamURL == a.streamURL,
            "logical metadata must retain chosen physical endpoint")
        manager.cancel(id: starting.id)
        check(AccountCapacityLedger.shared.snapshot(accountKey: .unconfiguredSource(sourceA)).localReservations == 1,
            "cancel while opening cannot release an unfinished recorder")
        fixture_recorder_hold(0)
        let cancelled = await pending.value
        check(cancelled == nil && fixture_recorder_frees() == 1, "cancelled startup must free its newly opened recorder")
        check(AccountCapacityLedger.shared.snapshot(accountKey: .unconfiguredSource(sourceA)).localReservations == 0,
            "recorder lease must release after the worker closes")

        let live = await manager.startLiveRecording(playlistID: logicalPlaylist, channel: b, program: nil)!
        check(live.playlistID == sourceB && live.sourceOwnership?.channelIdentity.sourceID == sourceB,
            "source switch cannot redirect a pinned recording")
        check(AccountCapacityLedger.shared.snapshot(accountKey: .unconfiguredSource(sourceB)).reservationsByKind[.recording] == 1,
            "active recorder must consume shared account capacity")
        manager.stopLiveRecording(id: live.id)
        check(AccountCapacityLedger.shared.snapshot(accountKey: .unconfiguredSource(sourceB)).localReservations == 0,
            "stopped recorder lease must release after actual free")

        let future = EPGProgram(id: "same-program", channelID: "same-guide", title: "Fixture", description: "",
            start: Date().addingTimeInterval(86400), end: Date().addingTimeInterval(90000))
        let scheduledA = manager.schedule(playlistID: logicalPlaylist, channel: a, program: future)!
        let scheduledB = manager.schedule(playlistID: logicalPlaylist, channel: b, program: future)!
        check(scheduledA.id != scheduledB.id && scheduledA.playlistID != scheduledB.playlistID,
            "native programme and channel ID collisions must not dedupe across physical sources")
        check(scheduledA.fileURL != scheduledB.fileURL,
            "source-specific schedules with identical channel/title/time must not overwrite the same recording file")
        let encoded = try JSONEncoder().encode(scheduledA)
        let restored = try JSONDecoder().decode(Recording.self, from: encoded)
        check(restored.sourceOwnership == scheduledA.sourceOwnership && restored.streamURL == a.streamURL,
            "recording persistence must preserve chosen source ownership")
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "sourceOwnership")
        let legacyDecoded = try JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(legacyDecoded.sourceOwnership == nil, "existing persisted recordings must remain readable")
        manager.cancel(id: scheduledA.id); manager.cancel(id: scheduledB.id); manager.stopAll()
        UserDefaults.standard.removeObject(forKey: "Buffer_recordings_v1")
        try? FileManager.default.removeItem(at: output)
        print("PASS \(checks) recording ownership/capacity checks against production RecordingManager and a local blocking recorder fixture")
    }
}
