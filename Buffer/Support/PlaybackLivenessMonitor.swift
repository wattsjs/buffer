/// Evaluates progress from monotonic, caller-supplied timestamps. Transport
/// warnings alone cannot prove a failed stream: demuxer retries may still be
/// feeding usable cached media. One sampler owns both stall and healthy signals.
struct PlaybackLivenessMonitor {
    enum Signal: Equatable {
        case healthy
        case stalled
    }

    private(set) var lastPosition: Double
    private var lastProgressPosition: Double
    private var lastSampleAt: Double
    private var lastProgressAt: Double
    private var healthyProgressStartedAt: Double?
    private var reportedHealthy = false

    init(position: Double, now: Double) {
        lastPosition = position
        lastProgressPosition = position
        lastSampleAt = now
        lastProgressAt = now
    }

    mutating func sample(
        position: Double,
        now: Double,
        playbackRequested: Bool,
        isPlaying: Bool,
        isLoading: Bool,
        isBuffering: Bool,
        focused: Bool = true,
        systemSuspended: Bool = false
    ) -> Signal? {
        // Invalid telemetry must not poison the last usable clock/position.
        guard position.isFinite, now.isFinite, now >= lastSampleAt else { return nil }
        let elapsed = max(0, now - lastSampleAt)
        let delta = position - lastPosition
        lastSampleAt = now
        lastPosition = position

        guard playbackRequested, focused, !systemSuspended else {
            resetProgress(at: now)
            return nil
        }

        // A seek/discontinuity is a new position, not proof of five seconds of
        // healthy playback. Reset the observation window rather than counting
        // an arbitrarily large playhead jump as recovery.
        if delta < 0 || delta > max(5, elapsed * 3) {
            resetProgress(at: now)
            return nil
        }

        if elapsed > 2.5 {
            // A long sampling gap cannot prove uninterrupted playback.
            resetHealthyProgress()
        }
        if position - lastProgressPosition >= 0.25 {
            lastProgressAt = now
            lastProgressPosition = position
            if isPlaying, !isLoading, !isBuffering {
                if healthyProgressStartedAt == nil {
                    healthyProgressStartedAt = now
                }
                if !reportedHealthy, now - (healthyProgressStartedAt ?? now) >= 5 {
                    reportedHealthy = true
                    return .healthy
                }
            } else {
                resetHealthyProgress()
            }
            return nil
        }

        resetHealthyProgress()
        guard isPlaying || isLoading || isBuffering else {
            lastProgressAt = now
            return nil
        }
        let threshold: Double = isLoading ? 15 : (isBuffering ? 12 : 6)
        return now - lastProgressAt >= threshold ? .stalled : nil
    }

    private mutating func resetProgress(at now: Double) {
        lastProgressAt = now
        lastProgressPosition = lastPosition
        resetHealthyProgress()
    }

    private mutating func resetHealthyProgress() {
        healthyProgressStartedAt = nil
        reportedHealthy = false
    }
}
