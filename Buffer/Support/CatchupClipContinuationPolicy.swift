import Foundation

/// An archive EOF can advance its archive, reach live, or exhaust a bounded
/// sequence of empty clips. Empty clips never establish that replay reached live.
nonisolated enum CatchupClipContinuationPolicy {
    enum Action: Equatable, Sendable {
        case continueArchive
        case returnToLive
        case replayUnavailable
    }

    struct Decision: Equatable, Sendable {
        let action: Action
        let consecutiveImmediateEOFs: Int
    }

    static func decision(previousImmediateEOFs: Int, positionSeconds: Double,
                         timelineEnd: Date, now: Date = Date()) -> Decision {
        let immediate = !positionSeconds.isFinite || positionSeconds < 5
        let count = immediate ? min(max(previousImmediateEOFs, 0), 2) + 1 : 0
        if count >= 3 {
            return .init(action: .replayUnavailable, consecutiveImmediateEOFs: count)
        }
        if !immediate, timelineEnd >= now.addingTimeInterval(-90) {
            return .init(action: .returnToLive, consecutiveImmediateEOFs: 0)
        }
        return .init(action: .continueArchive, consecutiveImmediateEOFs: count)
    }
}
