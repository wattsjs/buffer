import Foundation

@main struct GuideHistoryTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func program(_ id: String, _ start: Double, _ end: Double, title: String = "Fixture") -> EPGProgram {
            EPGProgram(id: id, channelID: "guide", title: title, description: "", start: now.addingTimeInterval(start), end: now.addingTimeInterval(end))
        }
        let previous = [program("deep", -5 * 86400, -5 * 86400 + 3600), program("gap", -12 * 3600, -11 * 3600), program("current", -1800, 3600)]
        let sparse = [program("new-start", -2 * 86400, -2 * 86400 + 3600), program("current-new-id", -1800, 7200, title: "Updated")]
        let merged = GuideHistory.merge(existing: previous, incoming: sparse, earliest: now.addingTimeInterval(-7 * 86400), now: now)
        precondition(Set(merged.map(\.id)) == ["deep", "gap", "new-start", "current-new-id"], "sparse response erased a known gap or failed to replace same-start metadata")
        precondition(merged.last?.title == "Updated")
        precondition(GuideHistory.needsCoverage([program("single-old", -7 * 86400, -7 * 86400 + 3600)], since: now.addingTimeInterval(-7 * 86400), until: now), "one old listing falsely proved history coverage")
        precondition(!GuideHistory.needsCoverage([program("continuous", -7 * 86400, 7200)], since: now.addingTimeInterval(-7 * 86400), until: now.addingTimeInterval(3600)))
        let trimmed = GuideHistory.merge(existing: [program("expired", -40 * 86400, -40 * 86400 + 1), program("future", 15 * 86400, 16 * 86400), program("inverted", 10, 0)] + previous, incoming: [], earliest: now.addingTimeInterval(-31 * 86400), now: now)
        precondition(Set(trimmed.map(\.id)) == Set(previous.map(\.id)), "retention did not bound real history/future and invalid records")
        let duplicates = GuideHistory.merge(existing: [], incoming: [program("first", 0, 7200), program("second", 0, 3600)], earliest: now.addingTimeInterval(-86400), now: now)
        precondition(duplicates.first?.id == "first", "duplicate-start source precedence changed")
        let malformed = [program("century", -100 * 365 * 86400, 100 * 365 * 86400),
                         program("nonfinite", 0, .infinity), program("titleless", -1800, 7200, title: " ")]
        let protected = GuideHistory.merge(existing: [previous.last!], incoming: malformed, earliest: now.addingTimeInterval(-31 * 86400), now: now)
        precondition(protected.count == 1 && protected[0].id == "current", "malformed/titleless incoming rows destroyed useful current guide or created unbounded buckets")
        precondition(GuideHistory.needsCoverage([program("titleless", -7 * 86400, 7200, title: "")], since: now.addingTimeInterval(-7 * 86400), until: now))
        precondition(!GuideHistory.needsCoverage([program("explicit-empty", -7 * 86400, 7200, title: "No Event Today")], since: now.addingTimeInterval(-7 * 86400), until: now), "explicit provider No Event interval was confused with missing data")
        var dense = [program("keep-current", -60, 60)]
        dense += (0..<20_000).map { program("future-\($0)", Double($0 + 1), Double($0 + 2)) }
        let bounded = GuideHistory.merge(existing: dense, incoming: [], earliest: now.addingTimeInterval(-86400), now: now)
        precondition(bounded.count == 20_000 && bounded.contains { $0.id == "keep-current" }, "listing cap evicted current programme for dense future rows")
        var schedules: [String: [EPGProgram]] = [:]
        var starts: [String: Date] = [:]
        for channel in 0..<240 {
            let id = "guide-\(channel)"
            schedules[id] = (0..<1488).map { index in
                let start = now.addingTimeInterval(Double(index - 1488) * 1800)
                return EPGProgram(id: "\(channel)-\(index)", channelID: id, title: "Fixture", description: "", start: start, end: start.addingTimeInterval(1800))
            }
            starts[id] = now.addingTimeInterval(-31 * 86400)
        }
        let began = ContinuousClock.now
        let retained = GuideHistory.prune(schedules, starts: starts, now: now)
        let elapsed = began.duration(to: .now).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        precondition(retained.values.reduce(0) { $0 + $1.count } == 357_120)
        print("PASS sparse retention, coverage holes, bounds, duplicate precedence, 357120-listing scale")
        print("GUIDE_HISTORY_BENCH_JSON {\"fixture\":\"guide-history-240x1488-v1\",\"listings\":357120,\"pruneMs\":\(ms)}")
    }
}
