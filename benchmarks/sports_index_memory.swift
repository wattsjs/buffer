import Darwin
import Foundation

/// Resident-memory cost of one sports search index for the 60k-stream
/// fixture. `-D LEGACY_MATCHER` measures the pre-redesign index instead.
@main struct SportsIndexMemory {
    /// Live heap bytes across malloc zones (not the RSS high-water mark).
    static func residentBytes() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    static func main() {
        let fixture = SportsMatchingFixture.make()
        let before = residentBytes()
        #if LEGACY_MATCHER
        let index = LegacyStreamMatcher.buildIndex(channels: fixture.channels, programs: fixture.programs,
                                                   hiddenGroups: fixture.hiddenGroups, now: fixture.now)
        let entries = index.entries.count
        #else
        let index = StreamMatcher.buildIndex(channels: fixture.channels, programs: fixture.programs,
                                             hiddenGroups: fixture.hiddenGroups, now: fixture.now)
        let entries = index.entryCount
        #endif
        let after = residentBytes()
        withExtendedLifetime(index) {
            print("{\"entries\":\(entries),\"indexHeapMB\":\(Double(after - before) / 1_048_576)}")
        }
    }
}
