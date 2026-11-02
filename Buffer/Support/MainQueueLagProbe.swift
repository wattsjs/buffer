import Foundation

#if DEBUG
/// Debug-only fine-grained main-queue latency probe for playback validation.
/// PerformanceMonitor pings every 500 ms, which cannot see the short hitches
/// that cost a 50 fps frame (20 ms budget). This pings every 10 ms while a
/// validation case is capturing and reports the window since the last read.
nonisolated final class MainQueueLagProbe: @unchecked Sendable {
    struct Window: Sendable {
        let samples: Int
        let maxMilliseconds: Int
        let over20Milliseconds: Int
    }

    private static let intervalMilliseconds = 10
    private let queue = DispatchQueue(label: "com.wattsjs.buffer.main-lag-probe", qos: .userInteractive)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var pending = false
    private var samples = 0
    private var maximum = 0
    private var over20 = 0

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(Self.intervalMilliseconds), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.ping() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// Returns and resets the lag observed since the previous call.
    func drain() -> Window {
        lock.withLock {
            defer { samples = 0; maximum = 0; over20 = 0 }
            return Window(samples: samples, maxMilliseconds: maximum, over20Milliseconds: over20)
        }
    }

    private func ping() {
        let alreadyPending = lock.withLock {
            let value = pending
            pending = true
            return value
        }
        guard !alreadyPending else { return }
        let sentAt = ContinuousClock.now
        DispatchQueue.main.async { [weak self] in
            let lag = AppLog.elapsedMilliseconds(since: sentAt)
            guard let self else { return }
            self.lock.withLock {
                self.pending = false
                self.samples += 1
                self.maximum = max(self.maximum, lag)
                if lag > 20 { self.over20 += 1 }
            }
        }
    }
}
#endif
