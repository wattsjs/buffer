import Foundation

/// Dense image handle: an index into the logo/artwork columns owned by
/// `LogoAtlas`. Interned once per distinct URL.
typealias LogoHandle = UInt32

/// Growable bitset over handles (`[UInt64]` words). Membership, insert and
/// remove are a shift and a mask; `count` is a popcount over the words.
nonisolated struct HandleBitset: Sendable {
    private(set) var words: [UInt64] = []

    @inline(__always)
    func contains(_ handle: LogoHandle) -> Bool {
        let word = Int(handle &>> 6)
        return word < words.count && words[word] & (1 &<< UInt64(handle & 63)) != 0
    }

    /// Returns true when the bit was newly set.
    @inline(__always) @discardableResult
    mutating func insert(_ handle: LogoHandle) -> Bool {
        let word = Int(handle &>> 6)
        if word >= words.count { words.append(contentsOf: repeatElement(0, count: max(word + 1 - words.count, words.count))) }
        let mask: UInt64 = 1 &<< UInt64(handle & 63)
        let wasSet = words[word] & mask != 0
        words[word] |= mask
        return !wasSet
    }

    /// Returns true when the bit was previously set.
    @inline(__always) @discardableResult
    mutating func remove(_ handle: LogoHandle) -> Bool {
        let word = Int(handle &>> 6)
        guard word < words.count else { return false }
        let mask: UInt64 = 1 &<< UInt64(handle & 63)
        let wasSet = words[word] & mask != 0
        words[word] &= ~mask
        return wasSet
    }

    /// Clears the 64 handles of one aligned word (one atlas page).
    mutating func clearWord(_ index: Int) {
        if index < words.count { words[index] = 0 }
    }

    var count: Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }

    /// Calls `body` for every set handle in ascending order.
    func forEach(_ body: (LogoHandle) -> Void) {
        for (index, word) in words.enumerated() where word != 0 {
            var bits = word
            while bits != 0 {
                body(LogoHandle(index &<< 6 | bits.trailingZeroBitCount))
                bits &= bits &- 1
            }
        }
    }
}

/// Bounded failure suppression for virtualized image grids, keyed by image
/// handle. A bitset marks failed handles and a parallel expiry column holds
/// the deadline in nanoseconds; no per-URL dictionary or hashing. Expired
/// handles are swept even when that particular handle is never visited again.
nonisolated final class RecentImageFailures: @unchecked Sendable {
    private let lock = NSLock()
    private let countLimit: Int
    private let ttlNanos: Int64
    private let sweepNanos: Int64
    private let origin = ContinuousClock.Instant.now
    private var failed = HandleBitset()
    private var expiry: [Int64] = []
    private var liveCount = 0
    private var nextSweep: Int64 = .min

    init(countLimit: Int = 4096, ttl: Duration = .seconds(600)) {
        precondition(countLimit > 0 && ttl > .zero)
        self.countLimit = countLimit
        self.ttlNanos = Self.nanos(ttl)
        self.sweepNanos = Self.nanos(min(ttl, .seconds(60)))
    }

    func insert(_ handle: LogoHandle, now: ContinuousClock.Instant = .now) {
        let t = offset(now)
        lock.lock()
        defer { lock.unlock() }
        sweepIfNeeded(t)
        let index = Int(handle)
        if index >= expiry.count {
            expiry.append(contentsOf: repeatElement(0, count: max(index + 1 - expiry.count, expiry.count)))
        }
        expiry[index] = t &+ ttlNanos
        if failed.insert(handle) { liveCount += 1 }
        if liveCount > countLimit { evictOldest() }
    }

    func contains(_ handle: LogoHandle, now: ContinuousClock.Instant = .now) -> Bool {
        let t = offset(now)
        lock.lock()
        defer { lock.unlock() }
        sweepIfNeeded(t)
        guard failed.contains(handle) else { return false }
        guard t < expiry[Int(handle)] else {
            failed.remove(handle)
            liveCount -= 1
            return false
        }
        return true
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return liveCount
    }

    /// Evicts a batch of the oldest failures so a long run of new dead logos
    /// does not sort the set on every insert.
    private func evictOldest() {
        let retained = max(1, countLimit - max(1, countLimit / 8))
        var live: [(Int64, LogoHandle)] = []
        live.reserveCapacity(liveCount)
        failed.forEach { live.append((expiry[Int($0)], $0)) }
        live.sort { $0.0 < $1.0 }
        for (_, handle) in live.prefix(liveCount - retained) { failed.remove(handle) }
        liveCount = retained
    }

    private func sweepIfNeeded(_ t: Int64) {
        guard t >= nextSweep else { return }
        var expired: [LogoHandle] = []
        failed.forEach { if t >= expiry[Int($0)] { expired.append($0) } }
        for handle in expired { failed.remove(handle) }
        liveCount -= expired.count
        nextSweep = t &+ sweepNanos
    }

    private func offset(_ instant: ContinuousClock.Instant) -> Int64 { Self.nanos(instant - origin) }

    private static func nanos(_ duration: Duration) -> Int64 {
        let c = duration.components
        return c.seconds &* 1_000_000_000 &+ c.attoseconds / 1_000_000_000
    }
}
