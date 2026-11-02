import Foundation

/// Inputs that actually change the timeline's document origin. Channel names,
/// favorite badges and guide publication do not reset the user's scroll.
nonisolated struct EPGTimelineInputs: Equatable {
    let channelIDs: [String]
    let archiveHours: Int?

    init(channels: [Channel], lookback: CatchupLookbackSetting) {
        channelIDs = channels.map(\.id)
        let archiveDays = channels.reduce(0) { days, channel in
            channel.supportsRewind ? max(days, channel.catchup?.days ?? 0) : days
        }
        if archiveDays > 0 {
            // Clamp before multiplying: provider metadata can contain arbitrary
            // integers, and the grid intentionally displays at most 14 days.
            let availableHours = min(archiveDays, 14) * 24
            archiveHours = min(availableHours, lookback.limitHours ?? availableHours)
        } else {
            archiveHours = nil
        }
    }

    func archiveStart(anchor: Date) -> Date? {
        archiveHours.map { anchor.addingTimeInterval(-Double($0) * 3600) }
    }
}

/// A reference memo avoids publishing observable state from a SwiftUI body.
/// The source revision covers same-ID metadata changes, not just membership.
final class EPGTimelineInputCache {
    private var version: Int?
    private var lookback: CatchupLookbackSetting?
    private var inputs: EPGTimelineInputs?

    func inputs(channels: [Channel], version: Int, lookback: CatchupLookbackSetting) -> EPGTimelineInputs {
        if self.version == version, self.lookback == lookback, let inputs {
            return inputs
        }
        let next = EPGTimelineInputs(channels: channels, lookback: lookback)
        self.version = version
        self.lookback = lookback
        inputs = next
        return next
    }
}
