import Foundation

/// One live-session policy layered into PlayerSlot's existing reconnect owner.
/// Warnings and cached buffering do not enter this policy: only terminal
/// failures or the measured liveness watchdog can request recovery.
nonisolated struct SmartLiveRecoveryPolicy: Sendable {
    enum Decision: Equatable { case sameSource, alternate(String), suspended }

    var minimumFailureSeconds: TimeInterval = 8
    var switchCooldownSeconds: TimeInterval = 30
    var maximumSwitches = 2
    private(set) var failureCount = 0
    private(set) var firstFailureAt: TimeInterval?
    private(set) var lastSwitchAt: TimeInterval?
    private(set) var switchCount = 0
    private var attemptedSources: Set<String> = []

    mutating func noteFailure(now: TimeInterval) {
        failureCount += 1
        if firstFailureAt == nil { firstFailureAt = now }
    }

    mutating func noteHealthy() {
        failureCount = 0
        firstFailureAt = nil
    }

    func decision(current: String, alternatives: [String], now: TimeInterval,
                  playbackRequested: Bool, suspended: Bool, epochMatches: Bool) -> Decision {
        guard playbackRequested, !suspended, epochMatches else { return .suspended }
        guard failureCount >= 2, let firstFailureAt,
              now - firstFailureAt >= minimumFailureSeconds,
              switchCount < maximumSwitches,
              lastSwitchAt.map({ now - $0 >= switchCooldownSeconds }) ?? true,
              let next = alternatives.first(where: { $0 != current && !attemptedSources.contains($0) })
        else { return .sameSource }
        return .alternate(next)
    }

    mutating func didSwitch(from old: String, to new: String, now: TimeInterval) {
        attemptedSources.insert(old)
        attemptedSources.insert(new)
        switchCount += 1
        lastSwitchAt = now
        noteHealthy()
    }
}
