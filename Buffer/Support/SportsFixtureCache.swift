import Foundation
import OSLog

/// Public ESPN fixtures only: network-only data, persisted as the Sports
/// tab's store (not a memo of any computation). Disk access and encoding
/// stay on the utility queue; queued snapshots coalesce so rapid refreshes
/// retain bounded memory. Version 2 stores flat parallel columns
/// (`events[i]` was confirmed at `confirmedAt[i]`); version 1 record files
/// still load.
nonisolated final class SportsFixtureCache: @unchecked Sendable {
    struct Snapshot: Sendable {
        let events: [SportEvent]
        let confirmedAt: [String: Date]
        let refreshedAt: Date
    }
    private struct Record: Codable, Sendable {
        let event: SportEvent
        let confirmedAt: Date
    }
    /// Legacy (version 1) array-of-records layout; read only.
    private struct Envelope: Codable {
        let version: Int
        let refreshedAt: Date
        let records: [Record]
    }
    /// Version 2: structure-of-arrays columns.
    private struct FlatEnvelope: Codable {
        let version: Int
        let refreshedAt: Date
        let events: [SportEvent]
        let confirmedAt: [Date]
    }
    private struct VersionProbe: Decodable {
        let version: Int
    }
    static let currentVersion = 2
    static let maximumEvents = 5_000
    static let maximumBytes = 4 * 1_024 * 1_024
    static let maximumAge: TimeInterval = 48 * 3_600
    static let liveMaximumAge: TimeInterval = 15 * 60
    static let disabled = SportsFixtureCache(fileURL: nil)
    static let shared: SportsFixtureCache = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return SportsFixtureCache(fileURL: base?.appendingPathComponent("buffer", isDirectory: true)
            .appendingPathComponent("sports-fixtures-v1.json"))
    }()
    private let fileURL: URL?
    private let queue = DispatchQueue(label: "com.wattsjs.buffer.sports-fixture-cache", qos: .utility)
    private let lock = NSLock()
    private var pending: Snapshot?
    private var writerScheduled = false

    init(fileURL: URL?) { self.fileURL = fileURL }

    static func eventKey(_ event: SportEvent) -> String { "\(event.league.id):\(event.id)" }

    /// Expire cached scores much sooner than schedules. Never relabel an old
    /// live score as final or claim an unconfirmed fixture is freshly updated.
    static func retained(events: [SportEvent], confirmedAt: [String: Date],
                         refreshedAt: Date, now: Date = Date()) -> Snapshot {
        let today = Calendar.current.startOfDay(for: now)
        let horizon = now.addingTimeInterval(7 * 86_400)
        var seen = Set<String>()
        let retained = events.filter { event in
            let key = eventKey(event)
            guard let confirmed = confirmedAt[key], confirmed.timeIntervalSince1970.isFinite,
                  event.startDate.timeIntervalSince1970.isFinite,
                  now.timeIntervalSince(confirmed) >= -300,
                  now.timeIntervalSince(confirmed) <= maximumAge,
                  event.startDate <= horizon, seen.insert(key).inserted else { return false }
            if event.status.isLive {
                return now.timeIntervalSince(confirmed) <= liveMaximumAge
                    && event.startDate >= now.addingTimeInterval(-7 * 86_400)
            }
            if event.status.isFinished { return event.startDate >= today }
            return event.startDate >= now.addingTimeInterval(-12 * 3_600)
        }.sorted { lhs, rhs in
            if lhs.status.isLive != rhs.status.isLive { return lhs.status.isLive }
            if lhs.status.isFinished != rhs.status.isFinished { return !lhs.status.isFinished }
            return lhs.startDate < rhs.startDate
        }.prefix(maximumEvents)
        let result = Array(retained)
        let keys = Set(result.map(eventKey))
        return Snapshot(events: result, confirmedAt: confirmedAt.filter { keys.contains($0.key) }, refreshedAt: refreshedAt)
    }

    func load(now: Date = Date()) async -> Snapshot? {
        guard fileURL != nil else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: read(now: now)) }
        }
    }

    func enqueueSave(_ snapshot: Snapshot) {
        guard fileURL != nil else { return }
        let shouldSchedule = lock.withLock {
            pending = snapshot
            guard !writerScheduled else { return false }
            writerScheduled = true
            return true
        }
        if shouldSchedule { queue.async { [self] in drainWrites() } }
    }

    /// Asynchronous test/shutdown barrier; UI callers never block on IO.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func read(now: Date) -> Snapshot? {
        guard let fileURL,
              let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= Self.maximumBytes,
              let data = try? Data(contentsOf: fileURL), data.count <= Self.maximumBytes,
              let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else { return nil }
        let refreshedAt: Date
        let events: [SportEvent]
        let confirmed: [Date]
        switch probe.version {
        case Self.currentVersion:
            guard let flat = try? JSONDecoder().decode(FlatEnvelope.self, from: data),
                  flat.events.count == flat.confirmedAt.count else { return nil }
            (refreshedAt, events, confirmed) = (flat.refreshedAt, flat.events, flat.confirmedAt)
        case 1:
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
            (refreshedAt, events, confirmed) = (envelope.refreshedAt, envelope.records.map(\.event), envelope.records.map(\.confirmedAt))
        default:
            return nil
        }
        guard events.count <= Self.maximumEvents,
              refreshedAt.timeIntervalSince1970.isFinite,
              now.timeIntervalSince(refreshedAt) >= -300,
              now.timeIntervalSince(refreshedAt) <= Self.maximumAge else { return nil }
        var dates: [String: Date] = [:]
        for (event, date) in zip(events, confirmed) { dates[Self.eventKey(event)] = date }
        let snapshot = Self.retained(events: events, confirmedAt: dates, refreshedAt: refreshedAt, now: now)
        return snapshot.events.isEmpty ? nil : snapshot
    }

    private func drainWrites() {
        while let snapshot = lock.withLock({ () -> Snapshot? in
            guard let next = pending else { writerScheduled = false; return nil }
            pending = nil
            return next
        }) { write(snapshot) }
    }

    private func write(_ snapshot: Snapshot) {
        guard let fileURL else { return }
        let bounded = Self.retained(events: snapshot.events, confirmedAt: snapshot.confirmedAt,
                                    refreshedAt: snapshot.refreshedAt)
        var events: [SportEvent] = []
        var confirmed: [Date] = []
        for event in bounded.events {
            guard let date = bounded.confirmedAt[Self.eventKey(event)] else { continue }
            events.append(event)
            confirmed.append(date)
        }
        // Large titles/descriptions cannot grow the file past the byte cap.
        // Shrink on the utility queue, retaining the highest-priority records.
        for _ in 0..<3 {
            let envelope = FlatEnvelope(version: Self.currentVersion, refreshedAt: bounded.refreshedAt,
                                        events: events, confirmedAt: confirmed)
            guard let data = try? JSONEncoder().encode(envelope) else { return }
            if data.count <= Self.maximumBytes {
                do {
                    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: fileURL, options: .atomic)
                } catch { AppLog.sports.error("Sports fixture cache write unavailable") }
                return
            }
            let count = max(0, events.count * Self.maximumBytes / data.count - 1)
            events = Array(events.prefix(count))
            confirmed = Array(confirmed.prefix(count))
        }
    }
}
