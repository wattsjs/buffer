import Foundation

/// The mpv callback runs on its render thread; the display pass runs on main.
/// Only this scheduling bit crosses that boundary, protected by a short lock.
nonisolated final class RenderInvalidationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false

    func schedule() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !pending else { return false }
        pending = true
        return true
    }

    func complete() {
        lock.lock()
        pending = false
        lock.unlock()
    }
}
