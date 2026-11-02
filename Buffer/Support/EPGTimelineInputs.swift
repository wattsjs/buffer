import Foundation

/// Inputs that actually change the timeline's document origin. Channel names,
/// favorite badges and guide publication do not reset the user's scroll.
///
/// Computed in a single allocation-free pass over the channels: the ordered
/// channel identities are folded into a 64-bit fingerprint instead of being
/// copied into a `[String]`, so comparing two inputs is two integer compares.
nonisolated struct EPGTimelineInputs: Equatable {
    /// Ordered-identity fingerprint of the channel IDs (and their count).
    let channelFingerprint: UInt64
    let channelCount: Int
    let archiveHours: Int?

    init(channels: [Channel], lookback: CatchupLookbackSetting) {
        // FNV-1a over UTF-8 with a separator byte: deterministic, order
        // sensitive, and free of per-ID allocation.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var archiveDays = 0
        for channel in channels {
            for byte in channel.id.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
            hash = (hash ^ 0xff) &* 0x0000_0100_0000_01b3
            if channel.supportsRewind { archiveDays = max(archiveDays, channel.catchup?.days ?? 0) }
        }
        channelFingerprint = hash
        channelCount = channels.count
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
