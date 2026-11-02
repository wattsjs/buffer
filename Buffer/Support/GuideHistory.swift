import Foundation

/// Retains only provider-supplied listings. Sparse responses cannot prove that
/// omitted programmes were deleted, so they replace matching starts/IDs only.
nonisolated enum GuideHistory {
    static let maximumHistoryDays = 31
    static let maximumFutureDays = 14
    static let maximumProgramsPerChannel = 20_000

    private static func isUsable(_ program: EPGProgram, earliest: Date, latest: Date) -> Bool {
        let start = program.start.timeIntervalSinceReferenceDate
        let end = program.end.timeIntervalSinceReferenceDate
        return start.isFinite && end.isFinite && end > start
            && end - start <= Double(maximumHistoryDays + maximumFutureDays) * 86400
            && program.end > earliest && program.start < latest
            && !program.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func retentionStarts(channels: [Channel], now: Date) -> [String: Date] {
        var starts: [String: Date] = [:]
        for channel in channels {
            guard let id = channel.epgChannelID else { continue }
            let days = min(maximumHistoryDays, max(2, channel.catchup?.days ?? 0))
            let start = now.addingTimeInterval(-Double(days) * 86400)
            starts[id] = min(starts[id] ?? start, start)
        }
        return starts
    }

    static func merge(existing: [EPGProgram], incoming: [EPGProgram], earliest: Date, now: Date) -> [EPGProgram] {
        let latest = now.addingTimeInterval(Double(maximumFutureDays) * 86400)
        let usable = incoming.filter { isUsable($0, earliest: earliest, latest: latest) }
        let incomingIDs = Set(usable.map(\.id))
        let incomingStarts = Set(usable.map(\.start))
        var result = existing.filter {
            isUsable($0, earliest: earliest, latest: latest)
                && !incomingIDs.contains($0.id) && !incomingStarts.contains($0.start)
        }
        var seen = Set<String>()
        for program in usable where seen.insert(program.id).inserted { result.append(program) }
        // Preserve incoming precedence for duplicate starts, matching the
        // existing guide lookup's earliest-match semantics.
        if zip(result, result.dropFirst()).contains(where: { $0.start > $1.start }) {
            result.sort { $0.start < $1.start }
        }
        if result.count > maximumProgramsPerChannel {
            // A dense future schedule must not evict the currently playing
            // programme. Select nearest intervals, then keep source ordering.
            func distance(_ program: EPGProgram) -> TimeInterval {
                if program.end < now { return now.timeIntervalSince(program.end) }
                if program.start > now { return program.start.timeIntervalSince(now) }
                return 0
            }
            let retained = Set(result.indices.sorted {
                let lhs = distance(result[$0]), rhs = distance(result[$1])
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }.prefix(maximumProgramsPerChannel))
            result = result.enumerated().compactMap { retained.contains($0.offset) ? $0.element : nil }
        }
        return result
    }

    static func prune(_ programs: [String: [EPGProgram]], starts: [String: Date], now: Date) -> [String: [EPGProgram]] {
        var result: [String: [EPGProgram]] = [:]
        for (id, earliest) in starts {
            let retained = merge(existing: programs[id] ?? [], incoming: [], earliest: earliest, now: now)
            if !retained.isEmpty { result[id] = retained }
        }
        return result
    }

    static func needsCoverage(_ programs: [EPGProgram], since start: Date, until end: Date) -> Bool {
        guard end > start else { return false }
        var coveredUntil = start
        // Tolerate normal schedule breaks, but an old single listing cannot
        // make a channel with days of missing guide look complete.
        let tolerance: TimeInterval = 90 * 60
        for program in programs where isUsable(program, earliest: start, latest: end) {
            if program.start.timeIntervalSince(coveredUntil) > tolerance { return true }
            coveredUntil = max(coveredUntil, program.end)
            if coveredUntil >= end { return false }
        }
        return end.timeIntervalSince(coveredUntil) > tolerance
    }
}
