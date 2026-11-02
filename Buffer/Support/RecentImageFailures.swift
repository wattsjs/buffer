import Foundation

/// Bounded failure suppression for virtualized image grids. Expired URLs are
/// swept even when that particular URL is never visited again.
nonisolated final class RecentImageFailures: @unchecked Sendable {
    private let lock = NSLock()
    private let countLimit: Int
    private let ttl: Duration
    private var entries: [URL: ContinuousClock.Instant] = [:]
    private var nextSweep = ContinuousClock.Instant.now

    init(countLimit: Int = 4096, ttl: Duration = .seconds(600)) {
        precondition(countLimit > 0 && ttl > .zero)
        self.countLimit = countLimit
        self.ttl = ttl
    }

    func insert(_ url: URL, now: ContinuousClock.Instant = .now) {
        lock.lock()
        defer { lock.unlock() }
        sweepIfNeeded(now: now)
        entries[url] = now.advanced(by: ttl)
        if entries.count > countLimit {
            // Evict a small batch of the oldest failures so a long sequence
            // of new dead logos does not sort the entire cache on every URL.
            let retainedCount = max(1, countLimit - max(1, countLimit / 8))
            let victims = entries.sorted { $0.value < $1.value }
                .prefix(entries.count - retainedCount)
                .map(\.key)
            for key in victims { entries.removeValue(forKey: key) }
        }
    }

    func contains(_ url: URL, now: ContinuousClock.Instant = .now) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sweepIfNeeded(now: now)
        guard let expires = entries[url] else { return false }
        guard now < expires else {
            entries.removeValue(forKey: url)
            return false
        }
        return true
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private func sweepIfNeeded(now: ContinuousClock.Instant) {
        guard now >= nextSweep else { return }
        entries = entries.filter { now < $0.value }
        nextSweep = now.advanced(by: min(ttl, .seconds(60)))
    }
}
