import Foundation

@main struct ImageFailureTests {
    static func bitsetTests() {
        var bits = HandleBitset()
        precondition(!bits.contains(0) && !bits.contains(1_000_000) && bits.count == 0)
        precondition(bits.insert(0) && !bits.insert(0))
        precondition(bits.insert(63) && bits.insert(64) && bits.insert(130_001))
        precondition(bits.contains(0) && bits.contains(63) && bits.contains(64) && bits.contains(130_001))
        precondition(!bits.contains(1) && !bits.contains(65) && !bits.contains(130_000))
        precondition(bits.count == 4)
        var seen: [LogoHandle] = []
        bits.forEach { seen.append($0) }
        precondition(seen == [0, 63, 64, 130_001], "forEach must visit set bits in ascending order")
        precondition(bits.remove(63) && !bits.remove(63) && !bits.remove(9_999_999))
        bits.clearWord(1)
        precondition(!bits.contains(64) && bits.contains(0) && bits.count == 2)
        // Randomised agreement with Set<UInt32>.
        var reference = Set<LogoHandle>()
        var random = HandleBitset()
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<200_000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let handle = LogoHandle(truncatingIfNeeded: state >> 40) % 50_000
            if state & 1 == 0 {
                precondition(random.insert(handle) == reference.insert(handle).inserted)
            } else {
                precondition(random.remove(handle) == (reference.remove(handle) != nil))
            }
        }
        precondition(random.count == reference.count)
        var visited = 0
        random.forEach { precondition(reference.contains($0)); visited += 1 }
        precondition(visited == reference.count)
    }

    static func main() {
        bitsetTests()
        let now = ContinuousClock.Instant.now
        let a: LogoHandle = 3
        let b: LogoHandle = 70
        let memo = RecentImageFailures(countLimit: 8, ttl: .seconds(600))
        precondition(!memo.contains(a, now: now))
        memo.insert(a, now: now)
        precondition(memo.contains(a, now: now.advanced(by: .seconds(599))))
        precondition(!memo.contains(a, now: now.advanced(by: .seconds(600))))
        precondition(memo.count == 0)

        memo.insert(a, now: now)
        memo.insert(a, now: now.advanced(by: .seconds(500)))
        precondition(memo.contains(a, now: now.advanced(by: .seconds(700))))
        precondition(!memo.contains(a, now: now.advanced(by: .seconds(1100))))

        let expiry = RecentImageFailures(countLimit: 8, ttl: .seconds(600))
        expiry.insert(a, now: now)
        // Accessing a different handle expires A without revisiting A.
        precondition(!expiry.contains(b, now: now.advanced(by: .seconds(601))))
        precondition(expiry.count == 0)

        let bounded = RecentImageFailures(countLimit: 64, ttl: .seconds(600))
        for index in 0..<50_000 {
            bounded.insert(LogoHandle(100 + index), now: now.advanced(by: .milliseconds(index)))
            precondition(bounded.count <= 64)
        }
        precondition(!bounded.contains(a, now: now))
        precondition(bounded.contains(LogoHandle(100 + 49_999), now: now.advanced(by: .seconds(50))))
        precondition(!bounded.contains(LogoHandle(100), now: now.advanced(by: .seconds(50))), "oldest failure must be evicted")
        precondition(!bounded.contains(b, now: now.advanced(by: .seconds(700))))
        precondition(bounded.count == 0)

        let concurrent = RecentImageFailures(countLimit: 128)
        DispatchQueue.concurrentPerform(iterations: 10_000) { index in
            let handle = LogoHandle(index % 256)
            concurrent.insert(handle)
            _ = concurrent.contains(handle)
        }
        precondition(concurrent.count <= 128)

        // Lookup cost on the scroll path: 60 handles, 10% failed.
        let large = RecentImageFailures(countLimit: 4096)
        for handle in stride(from: LogoHandle(0), to: 5_000, by: 10) { large.insert(handle) }
        let start = ContinuousClock.now
        var hits = 0
        for round in 0..<20_000 {
            let base = LogoHandle(round % 80 * 60)
            for handle in base..<(base + 60) where large.contains(handle) { hits += 1 }
        }
        let ns = Double((ContinuousClock.now - start) / .nanoseconds(1)) / Double(20_000 * 60)
        precondition(hits == 20_000 * 6)
        print("PASS bitset ops vs Set, image failure expiry, refresh, 50000 unique handles, concurrent access and capacity; contains() \(String(format: "%.1f", ns)) ns/handle")
    }
}
