import Foundation

@main
struct RenderInvalidationTests {
    static func main() {
        let gate = RenderInvalidationGate()
        let accepted = Counter()
        // Simultaneous mpv callbacks may schedule only one main-thread pass.
        for _ in 0..<100 {
            DispatchQueue.concurrentPerform(iterations: 100) { _ in
                if gate.schedule() { accepted.increment() }
            }
            gate.complete()
        }
        precondition(accepted.value == 100)
        precondition(gate.schedule())
        precondition(!gate.schedule())
        // Clearing at dispatch time permits another pass even when Core
        // Animation drops the draw (for example during fullscreen changes).
        gate.complete()
        precondition(gate.schedule())
        print("PASS renderer invalidation coalescing: 10,000 concurrent callbacks, no lost rearm")
    }
}

private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }
}
