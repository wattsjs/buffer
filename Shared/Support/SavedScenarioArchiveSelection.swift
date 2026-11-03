import Foundation

/// Select only supplied guide programmes. Never invent an archive interval or
/// substitute a live stream when the requested past programme is unavailable.
nonisolated enum SavedScenarioArchiveSelection {
    static func programme(channel: Channel, programmes: [EPGProgram], offsetMinutes: Int,
                          minimumDurationSeconds: Int, now: Date = Date()) throws -> EPGProgram {
        let target = now.addingTimeInterval(-Double(offsetMinutes) * 60)
        guard offsetMinutes > 0, channel.archiveContains(target, now: now) else {
            throw SavedScenarioFailure.archiveUnavailable
        }
        let candidates = programmes.filter {
            $0.channelID == channel.epgChannelID && channel.canReplay($0, now: now) &&
                $0.start <= target && $0.end <= now && $0.duration >= Double(minimumDurationSeconds)
        }
        guard let selected = candidates.max(by: { $0.start < $1.start }) else {
            throw SavedScenarioFailure.catchupProgrammeUnavailable
        }
        return selected
    }
}
