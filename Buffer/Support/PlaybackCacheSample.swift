/// An unrounded reported control sample, independent of the UI value.
/// An unavailable or invalid observation retires the earlier sample immediately.
nonisolated struct PlaybackCacheSample: Sendable {
    private var sample: (seconds: Double, generation: Int, at: Double)?

    mutating func observe(_ seconds: Double?, generation: Int, at time: Double) {
        guard let seconds, seconds.isFinite, seconds >= 0, time.isFinite else {
            sample = nil
            return
        }
        sample = (seconds, generation, time)
    }

    func currentSeconds(generation: Int, at time: Double) -> Double? {
        guard let sample, sample.generation == generation, time.isFinite,
              time >= sample.at, time - sample.at <= 2.5 else { return nil }
        return sample.seconds
    }

    mutating func reset() { sample = nil }
}
