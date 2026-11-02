/// A raw clock observation with a bounded receipt age. UI rounding and update
/// thresholds must not determine continuity evidence. Finite negative source
/// positions remain evidence; unavailable/nonfinite values retire the sample.
nonisolated struct PlaybackClockSample: Sendable {
    struct Reading: Equatable, Sendable {
        let seconds: Double
        let ageMilliseconds: Double
    }

    private var sample: (seconds: Double, generation: Int, receivedAt: Double)?

    mutating func observe(_ seconds: Double?, generation: Int, at time: Double) {
        guard let seconds, seconds.isFinite, time.isFinite else {
            sample = nil
            return
        }
        sample = (seconds, generation, time)
    }

    func current(generation: Int, at time: Double) -> Reading? {
        guard let sample, sample.generation == generation, time.isFinite,
              time >= sample.receivedAt, time - sample.receivedAt <= 2.5 else { return nil }
        return Reading(seconds: sample.seconds, ageMilliseconds: (time - sample.receivedAt) * 1_000)
    }

    mutating func reset() { sample = nil }
}
