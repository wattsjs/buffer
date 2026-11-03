import Foundation

@main struct SportsFixtureCacheTests {
    static func main() async throws {
        let now = Date()
        let league = League.all.first { $0.slug == "nfl" }!
        func event(_ id: String, start: Date = now, status: EventStatus = .scheduled,
                   title: String? = nil) -> SportEvent {
            SportEvent(id: id, sport: .football, league: league, title: title ?? id, shortTitle: id,
                       homeTeam: nil, awayTeam: nil, startDate: start, status: status,
                       broadcast: ["Fixture TV"], venue: nil, detail: nil, tournamentName: nil, leader: nil)
        }
        func snapshot(_ events: [SportEvent], confirmed: Date = now, refreshed: Date = now) -> SportsFixtureCache.Snapshot {
            SportsFixtureCache.Snapshot(events: events,
                confirmedAt: Dictionary(events.map { (SportsFixtureCache.eventKey($0), confirmed) }, uniquingKeysWith: { first, _ in first }),
                refreshedAt: refreshed)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buffer-sports-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixtures.json")
        let cache = SportsFixtureCache(fileURL: url)
        let empty = await cache.load()
        precondition(empty == nil)
        let live = event("live", status: .live(detail: "First quarter"))
        let todayFinal = event("today-final", status: .final_(detail: "Final"))
        let tomorrow = event("tomorrow", start: now.addingTimeInterval(86_400))
        cache.enqueueSave(snapshot([live, todayFinal, tomorrow]))
        await cache.flush()
        let restarted = SportsFixtureCache(fileURL: url)
        let loaded = await restarted.load(now: now)
        precondition(loaded?.events.count == 3 && loaded?.refreshedAt == now)
        precondition(loaded?.events.first?.status.label == "First quarter")
        precondition(loaded?.confirmedAt[SportsFixtureCache.eventKey(tomorrow)] == now)

        let multiDayLive = event("test-cricket", start: now.addingTimeInterval(-3 * 86_400), status: .live(detail: "Day 4"))
        let liveSnapshot = snapshot([multiDayLive])
        precondition(SportsFixtureCache.retained(events: liveSnapshot.events,
            confirmedAt: liveSnapshot.confirmedAt, refreshedAt: now, now: now).events.count == 1,
            "Fresh multi-day live fixtures were discarded by start date")

        let expiredLive = await restarted.load(now: now.addingTimeInterval(16 * 60))
        precondition(expiredLive?.events.contains { $0.id == "live" } == false,
                     "Stale cached live scores still appeared live")
        let nextDay = await restarted.load(now: Calendar.current.startOfDay(for: now).addingTimeInterval(86_400))
        precondition(nextDay?.events.contains { $0.id == "today-final" } == false,
                     "Yesterday's finished fixtures survived midnight")
        let tooOld = await restarted.load(now: now.addingTimeInterval(49 * 3_600))
        precondition(tooOld == nil)
        let yesterday = event("yesterday", start: Calendar.current.startOfDay(for: now).addingTimeInterval(-1), status: .final_(detail: nil))
        let farFuture = event("far-future", start: now.addingTimeInterval(8 * 86_400))
        let staleScheduled = event("stale-scheduled", start: now.addingTimeInterval(-13 * 3_600))
        let bounded = SportsFixtureCache.retained(events: [yesterday, farFuture, staleScheduled, tomorrow],
                                                  confirmedAt: snapshot([yesterday, farFuture, staleScheduled, tomorrow]).confirmedAt,
                                                  refreshedAt: now, now: now)
        precondition(bounded.events.map(\.id) == ["tomorrow"])
        let unconfirmed = SportsFixtureCache.retained(events: [tomorrow], confirmedAt: [:], refreshedAt: now, now: now)
        precondition(unconfirmed.events.isEmpty)
        let futureConfirmation = snapshot([tomorrow], confirmed: now.addingTimeInterval(600))
        precondition(SportsFixtureCache.retained(events: futureConfirmation.events,
            confirmedAt: futureConfirmation.confirmedAt, refreshedAt: now, now: now).events.isEmpty)

        // Queued writers coalesce and serialize; the final publication must
        // survive restart even when earlier snapshots are still being encoded.
        for index in 0..<200 { cache.enqueueSave(snapshot([event("ordered-\(index)")])) }
        await cache.flush()
        let ordered = await restarted.load(now: now)
        precondition(ordered?.events.map(\.id) == ["ordered-199"])
        let many = (0..<6_000).map { event("bounded-\($0)", start: now.addingTimeInterval(Double($0))) }
        cache.enqueueSave(snapshot(many))
        await cache.flush()
        let capped = await restarted.load(now: now)
        precondition(capped?.events.count == SportsFixtureCache.maximumEvents)
        let huge = (0..<100).map { event("large-\($0)", title: String(repeating: "a", count: 100_000)) }
        cache.enqueueSave(snapshot(huge))
        await cache.flush()
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        precondition(fileSize <= SportsFixtureCache.maximumBytes)
        let bytesBounded = await restarted.load(now: now)
        precondition(bytesBounded?.events.isEmpty == false && bytesBounded!.events.count < huge.count)

        // Version 2 writes flat parallel columns; a version 1 record file
        // saved by an earlier build still loads.
        cache.enqueueSave(snapshot([live, tomorrow]))
        await cache.flush()
        let flat = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        precondition(flat["version"] as? Int == 2 && (flat["events"] as? [Any])?.count == 2
                     && (flat["confirmedAt"] as? [Any])?.count == 2 && flat["records"] == nil, "Fixture store is not flat")
        struct LegacyRecord: Encodable { let event: SportEvent; let confirmedAt: Date }
        struct LegacyEnvelope: Encodable { let version: Int; let refreshedAt: Date; let records: [LegacyRecord] }
        try JSONEncoder().encode(LegacyEnvelope(version: 1, refreshedAt: now,
            records: [LegacyRecord(event: tomorrow, confirmedAt: now)])).write(to: url)
        let migrated = await restarted.load(now: now)
        precondition(migrated?.events.map(\.id) == ["tomorrow"] && migrated?.confirmedAt[SportsFixtureCache.eventKey(tomorrow)] == now,
                     "Version 1 fixture store did not load")

        try Data("{malformed".utf8).write(to: url)
        let malformed = await restarted.load()
        precondition(malformed == nil)
        try Data(repeating: 0, count: SportsFixtureCache.maximumBytes + 1).write(to: url)
        let oversized = await restarted.load()
        precondition(oversized == nil)
        cache.enqueueSave(snapshot([]))
        await cache.flush()
        let cleared = await restarted.load()
        precondition(cleared == nil, "Fresh successful empty feed left a prior cache visible")
        print("PASS sports fixture restart persistence, live/finished/schedule expiry, confirmation bounds, ordered/coalesced writes, record/byte bounds, malformed/oversized rejection, empty replacement, flat v2 columns, v1 record migration")
    }
}
