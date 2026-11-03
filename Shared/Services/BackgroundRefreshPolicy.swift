import Foundation

/// Pure scheduling and guide-merge rules for refreshing inactive sources.
nonisolated enum BackgroundRefreshPolicy {
    struct Plan: Equatable, Sendable {
        var channels: Bool
        var guide: Bool
        var isEmpty: Bool { !channels && !guide }
    }

    /// Pure scheduling decision; `nil` intervals mean the user chose Never.
    static func plan(channelsSavedAt: Date?, guideRefreshedAt: Date?,
                     channelInterval: TimeInterval?, guideInterval: TimeInterval?, now: Date) -> Plan {
        func due(_ last: Date?, _ interval: TimeInterval?) -> Bool {
            guard let interval else { return false }
            guard let last else { return true }
            return now.timeIntervalSince(last) >= interval
        }
        let channels = due(channelsSavedAt, channelInterval)
        // A source with no cached channels cannot key its guide yet.
        return Plan(channels: channels, guide: due(guideRefreshedAt, guideInterval) || channels)
    }

    static func merge(existing: [String: [EPGProgram]], incoming: [EPGProgram],
                      channels: [Channel], now: Date) -> [String: [EPGProgram]] {
        var organized: [String: [EPGProgram]] = [:]
        for program in incoming { organized[program.channelID, default: []].append(program) }
        let starts = GuideHistory.retentionStarts(channels: channels, now: now)
        var merged: [String: [EPGProgram]] = [:]
        for epgID in Set(existing.keys).union(organized.keys) {
            guard let earliest = starts[epgID] else { continue }
            let rows = GuideHistory.merge(existing: existing[epgID] ?? [], incoming: organized[epgID] ?? [],
                                          earliest: earliest, now: now)
            if !rows.isEmpty { merged[epgID] = rows }
        }
        return merged
    }
}
