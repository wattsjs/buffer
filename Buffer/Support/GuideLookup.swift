import Foundation

/// Shared guide lookups used by the UI and the in-process benchmark.
/// Program lists published by `EPGViewModel.organize` are sorted by start.
enum GuideLookup {
    /// One prefix maximum per listing makes arbitrary overlapping end times
    /// searchable. The first maximum past the query belongs to the earliest
    /// matching listing, preserving the provider's ordering for duplicate starts.
    /// The program array shares its immutable storage with the guide snapshot.
    nonisolated struct Prepared: Sendable {
        private let programs: [EPGProgram]
        private let prefixMaximumEnds: [TimeInterval]

        init(programs: [EPGProgram]) {
            self.programs = programs
            var maximum = -Double.infinity
            var ends: [TimeInterval] = []
            ends.reserveCapacity(programs.count)
            for program in programs {
                let end = program.end.timeIntervalSinceReferenceDate
                if end > maximum { maximum = end }
                ends.append(maximum)
            }
            prefixMaximumEnds = ends
        }

        func program(containing date: Date) -> EPGProgram? {
            let timestamp = date.timeIntervalSinceReferenceDate
            var low = 0
            var high = prefixMaximumEnds.count
            while low < high {
                let mid = low + (high - low) / 2
                if prefixMaximumEnds[mid] <= timestamp {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            guard low < programs.count, programs[low].start <= date else { return nil }
            return programs[low]
        }
    }

    static func channelSetFingerprint(_ channels: [Channel]) -> Int {
        var hasher = Hasher()
        hasher.combine(channels.count)
        for channel in channels {
            hasher.combine(channel.id)
        }
        return hasher.finalize()
    }

    /// Joined identity used by the old EPG grid path. Kept so the benchmark
    /// can time the allocation the view used to do on every body pass.
    static func joinedChannelIdentity(_ channels: [Channel]) -> String {
        channels.map(\.id).joined(separator: "\u{1F}")
    }

    static func program(in programs: [EPGProgram], containing date: Date) -> EPGProgram? {
        guard !programs.isEmpty else { return nil }
        var low = 0
        var high = programs.count
        while low < high {
            let mid = (low + high) / 2
            if programs[mid].start <= date {
                low = mid + 1
            } else {
                high = mid
            }
        }

        // End times need not be sorted: providers emit overlapping and
        // duplicate listings. Preserve the existing first-match semantics.
        return programs[..<low].first { date < $0.end }
    }

    static func linearProgram(in programs: [EPGProgram], containing date: Date) -> EPGProgram? {
        programs.first { $0.start <= date && date < $0.end }
    }
}
