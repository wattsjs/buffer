import Foundation

@main struct BackgroundSourceRefreshTests {
    static func main() {
        let now = Date()
        let hour: TimeInterval = 3600
        typealias R = BackgroundRefreshPolicy

        // Scheduling follows the user's intervals; Never disables a lane.
        precondition(R.plan(channelsSavedAt: nil, guideRefreshedAt: nil, channelInterval: 24 * hour, guideInterval: hour, now: now)
            == .init(channels: true, guide: true), "Uncached source was not fully refreshed")
        precondition(R.plan(channelsSavedAt: now.addingTimeInterval(-2 * hour), guideRefreshedAt: now.addingTimeInterval(-10 * 60),
            channelInterval: 24 * hour, guideInterval: hour, now: now).isEmpty, "Fresh source was refreshed")
        precondition(R.plan(channelsSavedAt: now.addingTimeInterval(-2 * hour), guideRefreshedAt: now.addingTimeInterval(-2 * hour),
            channelInterval: 24 * hour, guideInterval: hour, now: now) == .init(channels: false, guide: true))
        precondition(R.plan(channelsSavedAt: now.addingTimeInterval(-25 * hour), guideRefreshedAt: now,
            channelInterval: 24 * hour, guideInterval: hour, now: now) == .init(channels: true, guide: true),
            "New channel catalog did not refresh its guide")
        precondition(R.plan(channelsSavedAt: nil, guideRefreshedAt: nil, channelInterval: nil, guideInterval: nil, now: now).isEmpty,
            "Never intervals still refreshed")

        // Merge keeps retained history, replaces refreshed rows and drops
        // guides for channels the source no longer offers.
        func program(_ id: String, _ guide: String, _ offset: TimeInterval, _ title: String = "Show") -> EPGProgram {
            EPGProgram(id: id, channelID: guide, title: title, description: "",
                       start: now.addingTimeInterval(offset), end: now.addingTimeInterval(offset + hour))
        }
        let channels = [Channel(id: "1", name: "One", logoURL: nil, group: "G",
                                streamURL: URL(string: "http://127.0.0.1/1")!, epgChannelID: "one")]
        let existing = [
            "one": [program("old", "one", -20 * hour), program("now-old", "one", 0, "Stale")],
            "gone": [program("gone", "gone", 0)],
        ]
        let merged = R.merge(existing: existing, incoming: [program("now-new", "one", 0, "Fresh")], channels: channels, now: now)
        precondition(merged["gone"] == nil, "Removed channel kept its guide")
        let rows = merged["one"] ?? []
        precondition(rows.contains { $0.id == "old" }, "Retained history was lost")
        precondition(rows.contains { $0.title == "Fresh" } && !rows.contains { $0.title == "Stale" }, "Refreshed slot kept stale row")
        print("PASS background source refresh: interval scheduling, Never, catalog-driven guide refresh, history-preserving merge")
    }
}
