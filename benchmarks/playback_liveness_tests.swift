@main
enum PlaybackLivenessTests {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        func sample(
            _ monitor: inout PlaybackLivenessMonitor,
            _ position: Double,
            _ now: Double,
            requested: Bool = true,
            playing: Bool = true,
            loading: Bool = false,
            buffering: Bool = false,
            focused: Bool = true,
            asleep: Bool = false
        ) -> PlaybackLivenessMonitor.Signal? {
            monitor.sample(position: position, now: now, playbackRequested: requested,
                           isPlaying: playing, isLoading: loading, isBuffering: buffering,
                           focused: focused, systemSuspended: asleep)
        }

        // Short/long outages are evaluated independently of any number of
        // transient HTTP warnings: only terminal events or lost progress reload.
        for (loading, buffering, threshold) in [(true, false, 15), (false, true, 12), (false, false, 6)] {
            var m = PlaybackLivenessMonitor(position: 20, now: 100)
            for second in 1..<threshold {
                expect(sample(&m, 20, Double(100 + second), loading: loading, buffering: buffering) == nil,
                       "must allow bounded demuxer recovery before replacing cached media")
            }
            expect(sample(&m, 20, Double(100 + threshold), loading: loading, buffering: buffering) == .stalled,
                   "actual stalled state must eventually reload")
        }

        // Owner pause must dominate transient loading/buffering flags.
        var paused = PlaybackLivenessMonitor(position: 0, now: 0)
        for second in 1...60 {
            expect(sample(&paused, 0, Double(second), requested: false, loading: true, buffering: true) == nil,
                   "paused unresolved load must not create a recovery loop")
        }
        expect(sample(&paused, 0, 61) == nil, "resume starts a fresh stall window")
        expect(sample(&paused, 0, 66) == .stalled, "resume must still recover a real freeze")

        for (focused, asleep) in [(false, false), (true, true), (false, true)] {
            var m = PlaybackLivenessMonitor(position: 4, now: 0)
            expect(sample(&m, 4, 120, focused: focused, asleep: asleep) == nil,
                   "system/focus suspension cannot be mistaken for a stall")
            expect(sample(&m, 4, 121) == nil, "promotion/wake starts a fresh observation window")
        }

        // Healthy reset requires observed continuous progress, not a seek or
        // the cumulative position from before a user pause or rebuffering gap.
        var healthy = PlaybackLivenessMonitor(position: 0, now: 0)
        for second in 1...5 {
            expect(sample(&healthy, Double(second), Double(second)) == nil, "five healthy seconds must be observed")
        }
        expect(sample(&healthy, 6, 6) == .healthy, "sustained playback clears failure backoff")
        expect(sample(&healthy, 7, 7) == nil, "healthy event should be emitted once per streak")
        expect(sample(&healthy, 100, 8) == nil, "forward seek must not count as healthy playback")
        expect(sample(&healthy, 20, 9) == nil, "backward seek starts a fresh observation window")
        for second in 10...14 {
            expect(sample(&healthy, Double(second + 11), Double(second)) == nil, "post-seek health must be measured")
        }
        expect(sample(&healthy, 26, 15) == .healthy, "post-seek sustained playback may reset backoff")

        var rebuffer = PlaybackLivenessMonitor(position: 0, now: 0)
        for second in 1...4 { _ = sample(&rebuffer, Double(second), Double(second)) }
        expect(sample(&rebuffer, 4, 5, buffering: true) == nil, "brief cache refill is not a terminal stall")
        for second in 6...10 {
            expect(sample(&rebuffer, Double(second - 1), Double(second)) == nil, "rebuffer interrupts healthy streak")
        }
        expect(sample(&rebuffer, 10, 11) == .healthy, "health recovers after a measured stable streak")

        var delayed = PlaybackLivenessMonitor(position: 0, now: 0)
        _ = sample(&delayed, 1, 1)
        expect(sample(&delayed, 20, 20) == nil, "missed samples cannot establish continuous health")

        var slow = PlaybackLivenessMonitor(position: 0, now: 0)
        for second in 1...30 {
            expect(sample(&slow, Double(second) * 0.1, Double(second)) != .stalled,
                   "small accumulated playhead movement must prevent false stalls")
        }

        var invalid = PlaybackLivenessMonitor(position: 1, now: 0)
        expect(sample(&invalid, .nan, 1) == nil, "invalid position must be ignored")
        expect(sample(&invalid, 2, .nan) == nil, "invalid clock must be ignored")
        expect(sample(&invalid, 2, -1) == nil, "clock rollback must be ignored")
        expect(sample(&invalid, 1, 6) == .stalled, "invalid telemetry must not poison actual stall detection")
        print("Playback liveness regression checks: \(checks) passed")
    }
}
