import Foundation
import OSLog
import Synchronization

/// Named duration/value samples and counters, summarised with the Debug
/// ui-lag heartbeat as `perf metric` lines (count/avg/p50/p95/max). Safe to
/// call from render, decode and network threads. Release builds compile the
/// recording calls away; signposts at call sites remain for Instruments.
nonisolated final class PerfMetrics: Sendable {
    static let shared = PerfMetrics()

    struct Summary: Sendable {
        let name: String
        let count: Int
        let average: Double
        let p50: Double
        let p95: Double
        let maximum: Double
    }

    private struct Series {
        static let capacity = 512
        var samples: [Double] = []
        var next = 0
        var count = 0
        var total: Double = 0
        var maximum: Double = 0

        mutating func append(_ value: Double) {
            if samples.count < Self.capacity {
                samples.append(value)
            } else {
                samples[next] = value
            }
            next = (next + 1) % Self.capacity
            count += 1
            total += value
            maximum = max(maximum, value)
        }
    }

    private let series = Mutex<[String: Series]>([:])
    private let counters = Mutex<[String: Int]>([:])

    private init() {}

    /// Records one sample, normally milliseconds.
    func record(_ name: String, _ value: Double) {
#if DEBUG
        series.withLock { $0[name, default: Series()].append(value) }
#endif
    }

    func record(_ name: String, since start: ContinuousClock.Instant) {
#if DEBUG
        record(name, Self.milliseconds(since: start))
#endif
    }

    func increment(_ name: String, by amount: Int = 1) {
#if DEBUG
        counters.withLock { $0[name, default: 0] += amount }
#endif
    }

    @discardableResult
    func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
#if DEBUG
        let started = ContinuousClock.now
        defer { record(name, since: started) }
#endif
        return try body()
    }

    /// Returns and clears everything recorded since the previous drain.
    func drain() -> (series: [Summary], counters: [(name: String, total: Int)]) {
        let drained = series.withLock { current -> [String: Series] in
            defer { current.removeAll(keepingCapacity: true) }
            return current
        }
        let drainedCounters = counters.withLock { current -> [String: Int] in
            defer { current.removeAll(keepingCapacity: true) }
            return current
        }
        let summaries = drained.keys.sorted().compactMap { name -> Summary? in
            guard let entry = drained[name], entry.count > 0 else { return nil }
            let sorted = entry.samples.sorted()
            func percentile(_ fraction: Double) -> Double {
                sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
            }
            return Summary(name: name, count: entry.count, average: entry.total / Double(entry.count),
                           p50: percentile(0.5), p95: percentile(0.95), maximum: entry.maximum)
        }
        return (summaries, drainedCounters.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }

    func emitSummary(to logger: Logger = AppLog.performance) {
        let (summaries, totals) = drain()
        for s in summaries {
            logger.info("perf metric name=\(s.name, privacy: .public) count=\(s.count, privacy: .public) avg=\(s.average, format: .fixed(precision: 2), privacy: .public) p50=\(s.p50, format: .fixed(precision: 2), privacy: .public) p95=\(s.p95, format: .fixed(precision: 2), privacy: .public) max=\(s.maximum, format: .fixed(precision: 2), privacy: .public)")
        }
        for counter in totals {
            logger.info("perf counter name=\(counter.name, privacy: .public) total=\(counter.total, privacy: .public)")
        }
    }

    static func milliseconds(since start: ContinuousClock.Instant, now: ContinuousClock.Instant = .now) -> Double {
        let elapsed = start.duration(to: now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000
    }
}
