import Foundation

@main struct ImageFailureTests {
    static func main() {
        let now = ContinuousClock.Instant.now
        let a = URL(string: "http://127.0.0.1/a.png")!
        let b = URL(string: "http://127.0.0.1/b.png")!
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
        // Accessing a different URL expires A without revisiting A.
        precondition(!expiry.contains(b, now: now.advanced(by: .seconds(601))))
        precondition(expiry.count == 0)

        let bounded = RecentImageFailures(countLimit: 64, ttl: .seconds(600))
        for index in 0..<50_000 {
            bounded.insert(URL(string: "http://127.0.0.1/\(index).png")!, now: now.advanced(by: .milliseconds(index)))
            precondition(bounded.count <= 64)
        }
        precondition(!bounded.contains(a, now: now))
        precondition(bounded.contains(URL(string: "http://127.0.0.1/49999.png")!, now: now.advanced(by: .seconds(50))))
        precondition(!bounded.contains(b, now: now.advanced(by: .seconds(700))))
        precondition(bounded.count == 0)

        let concurrent = RecentImageFailures(countLimit: 128)
        DispatchQueue.concurrentPerform(iterations: 10_000) { index in
            let url = URL(string: "http://127.0.0.1/\(index % 256).png")!
            concurrent.insert(url)
            _ = concurrent.contains(url)
        }
        precondition(concurrent.count <= 128)
        print("PASS image failure expiry, refresh, 50000 unique URLs, concurrent access and capacity")
    }
}
