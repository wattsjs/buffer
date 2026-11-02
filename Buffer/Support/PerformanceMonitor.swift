import Foundation
import OSLog

#if DEBUG
/// Debug-only heartbeat that measures how long work waits for the main queue.
/// It runs off-main so a blocked UI cannot block the detector itself.
nonisolated final class PerformanceMonitor: @unchecked Sendable {
    static let shared = PerformanceMonitor()

    private enum Tuning {
        static let heartbeatMilliseconds = 500
        static let summaryMilliseconds = 10_000
        static let lagWarningMilliseconds = 250
        static let repeatedWarningMilliseconds = 1_000
        static let sampleCapacity = 40
    }

    private let queue = DispatchQueue(label: "com.wattsjs.buffer.performance-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pingSentAt: ContinuousClock.Instant?
    private var lastSummaryAt: ContinuousClock.Instant?
    private var lastWarningAt: ContinuousClock.Instant?
    private var warnedForPendingPing = false
    private var samples = Array(repeating: 0, count: Tuning.sampleCapacity)
    private var sampleCount = 0
    private var nextSampleIndex = 0

    private init() {}

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + .milliseconds(Tuning.heartbeatMilliseconds),
                repeating: .milliseconds(Tuning.heartbeatMilliseconds),
                leeway: .milliseconds(50)
            )
            timer.setEventHandler { [weak self] in
                self?.tick(at: .now)
            }
            self.timer = timer
            self.lastSummaryAt = .now
            timer.resume()
            AppLog.performance.info("instrumentation loop started heartbeatMs=\(Tuning.heartbeatMilliseconds, privacy: .public) summaryMs=\(Tuning.summaryMilliseconds, privacy: .public) lagWarningMs=\(Tuning.lagWarningMilliseconds, privacy: .public)")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.pingSentAt = nil
            AppLog.performance.info("instrumentation loop stopped")
        }
    }

    private func tick(at now: ContinuousClock.Instant) {
        if let lastSummaryAt,
           AppLog.elapsedMilliseconds(since: lastSummaryAt, now: now) >= Tuning.summaryMilliseconds {
            emitSummary(at: now)
        }

        if let pingSentAt {
            let blockedMilliseconds = AppLog.elapsedMilliseconds(since: pingSentAt, now: now)
            let shouldWarnAgain = lastWarningAt.map {
                AppLog.elapsedMilliseconds(since: $0, now: now) >= Tuning.repeatedWarningMilliseconds
            } ?? true
            if blockedMilliseconds >= Tuning.lagWarningMilliseconds, shouldWarnAgain {
                warnedForPendingPing = true
                lastWarningAt = now
                AppLog.performance.warning("ui-lag blocked mainQueueMs=\(blockedMilliseconds, privacy: .public)")
            }
        } else {
            pingSentAt = now
            DispatchQueue.main.async { [weak self] in
                let respondedAt = ContinuousClock.now
                self?.queue.async { [weak self] in
                    self?.recordMainQueueResponse(at: respondedAt)
                }
            }
        }
    }

    private func recordMainQueueResponse(at respondedAt: ContinuousClock.Instant) {
        guard let pingSentAt else { return }
        let lagMilliseconds = max(0, AppLog.elapsedMilliseconds(since: pingSentAt, now: respondedAt))
        self.pingSentAt = nil

        samples[nextSampleIndex] = lagMilliseconds
        nextSampleIndex = (nextSampleIndex + 1) % samples.count
        sampleCount = min(sampleCount + 1, samples.count)

        if warnedForPendingPing {
            AppLog.performance.info("ui-lag recovered mainQueueMs=\(lagMilliseconds, privacy: .public)")
        }
        warnedForPendingPing = false
        lastWarningAt = nil
    }

    private func emitSummary(at now: ContinuousClock.Instant) {
        lastSummaryAt = now
        PerfMetrics.shared.emitSummary()
        guard sampleCount > 0 else {
            AppLog.performance.info("ui-lag heartbeat samples=0 mainQueuePending=\(self.pingSentAt != nil, privacy: .public)")
            return
        }

        let recentSamples = Array(samples.prefix(sampleCount)).sorted()
        let total = recentSamples.reduce(0, +)
        let average = total / recentSamples.count
        let percentileIndex = max(0, Int(ceil(Double(recentSamples.count) * 0.95)) - 1)
        let p95 = recentSamples[percentileIndex]
        let maximum = recentSamples[recentSamples.count - 1]
        AppLog.performance.info("ui-lag heartbeat samples=\(recentSamples.count, privacy: .public) avgMs=\(average, privacy: .public) p95Ms=\(p95, privacy: .public) maxMs=\(maximum, privacy: .public) mainQueuePending=\(self.pingSentAt != nil, privacy: .public)")

        sampleCount = 0
        nextSampleIndex = 0
    }
}
#endif
