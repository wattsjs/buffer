@MainActor
enum MPVStartupTarget {
    static func enabled(forLiveLoad live: Bool) -> Bool {
#if DEBUG
        enabled(forLiveLoad: live,
                validationActive: PlaybackValidation.isEnabled || SavedPlaybackScenario.isCapturing,
                flagRequested: CommandLine.arguments.contains("--validate-startup-target"))
#else
        false
#endif
    }

    nonisolated static func enabled(forLiveLoad live: Bool, validationActive: Bool, flagRequested: Bool) -> Bool {
#if DEBUG
        live && validationActive && flagRequested
#else
        false
#endif
    }
}

/// The app-owned trial waits for the reported cache-duration target after
/// FILE_LOADED. That unrounded value is still an approximation, not verified
/// packet coverage. Timeout never substitutes a lower reported target.
nonisolated struct StartupTargetHold: Sendable {
    enum Decision: Equatable { case waiting, ready(cacheSeconds: Double), timedOut }
    let generation: Int
    let targetSeconds: Double
    private var loadedAt: Double?
    private var completed = false

    init(generation: Int, targetSeconds: Double) {
        self.generation = generation
        self.targetSeconds = targetSeconds
    }

    mutating func fileLoaded(generation: Int, at time: Double) {
        guard self.generation == generation, time.isFinite, loadedAt == nil else { return }
        loadedAt = time
    }

    mutating func evaluate(cacheSeconds: Double?, generation: Int, at time: Double) -> Decision {
        guard !completed, self.generation == generation, let loadedAt,
              time.isFinite, time >= loadedAt else { return .waiting }
        if time - loadedAt > 12 {
            completed = true
            return .timedOut
        }
        if let cacheSeconds, cacheSeconds.isFinite, cacheSeconds >= 0,
           targetSeconds.isFinite, targetSeconds > 0, cacheSeconds >= targetSeconds {
            completed = true
            return .ready(cacheSeconds: cacheSeconds)
        }
        if time - loadedAt >= 12 {
            completed = true
            return .timedOut
        }
        return .waiting
    }
}
