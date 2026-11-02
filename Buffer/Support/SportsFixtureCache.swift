import Foundation
import OSLog

/// Public ESPN fixtures only. Disk access and encoding stay on the utility
/// queue; queued snapshots coalesce so rapid refreshes retain bounded memory.
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
    private struct Envelope: Codable {
        let version: Int
        let refreshedAt: Date
        let records: [Record]
    }
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
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1,
              envelope.records.count <= Self.maximumEvents,
              envelope.refreshedAt.timeIntervalSince1970.isFinite,
              now.timeIntervalSince(envelope.refreshedAt) >= -300,
              now.timeIntervalSince(envelope.refreshedAt) <= Self.maximumAge else { return nil }
        var dates: [String: Date] = [:]
        for record in envelope.records { dates[Self.eventKey(record.event)] = record.confirmedAt }
        let snapshot = Self.retained(events: envelope.records.map(\.event), confirmedAt: dates,
                                     refreshedAt: envelope.refreshedAt, now: now)
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
        var records = bounded.events.compactMap { event -> Record? in
            guard let date = bounded.confirmedAt[Self.eventKey(event)] else { return nil }
            return Record(event: event, confirmedAt: date)
        }
        // Large titles/descriptions cannot grow the file past the byte cap.
        // Shrink on the utility queue, retaining the highest-priority records.
        for _ in 0..<3 {
            let envelope = Envelope(version: 1, refreshedAt: bounded.refreshedAt, records: records)
            guard let data = try? JSONEncoder().encode(envelope) else { return }
            if data.count <= Self.maximumBytes {
                do {
                    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: fileURL, options: .atomic)
                } catch { AppLog.sports.error("Sports fixture cache write unavailable") }
                return
            }
            let count = max(0, records.count * Self.maximumBytes / data.count - 1)
            records = Array(records.prefix(count))
        }
    }
}
