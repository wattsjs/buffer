import Foundation

@main
struct CacheWriteTests {
    static func main() throws {
        let key = "perf-test-" + UUID().uuidString
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("buffer", isDirectory: true)
        defer {
            for prefix in ["channels", "programs", "vod", "vod_series", "probes"] {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(prefix)_\(key).json"))
            }
        }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        for generation in 0..<100 {
            let channels = (0..<100).map { i in
                Channel(id: "\(generation)-\(i)", name: "Fixture", logoURL: nil, group: "Fixture",
                        streamURL: URL(string: "http://127.0.0.1/fixture")!, epgChannelID: nil)
            }
            let program = EPGProgram(id: "\(generation)", channelID: "fixture", title: "Fixture",
                description: "", start: origin, end: origin.addingTimeInterval(1800))
            DataCache.enqueueSaveChannels(channels, key: key)
            DataCache.enqueueSavePrograms(["fixture": [program]], key: key)
            DataCache.enqueueSaveVODItems([], key: key)
            DataCache.enqueueSaveVODSeries([], key: key)
        }
        DataCache.flushPendingWrites()
        precondition(DataCache.loadChannels(key: key)?.channels.first?.id == "99-0")
        precondition(DataCache.loadPrograms(key: key)?.programs["fixture"]?.first?.id == "99")
        precondition(DataCache.loadVODItems(key: key)?.items == [])
        precondition(DataCache.loadVODSeries(key: key)?.series == [])
        let config = ServerConfig(serverURL: "http://127.0.0.1", username: "fixture", password: "fixture-one")
        var changedPassword = config
        changedPassword.password = "fixture-two"
        var changedGuide = config
        changedGuide.epgURL = "http://127.0.0.1/other-guide.xml"
        precondition(DataCache.cacheKey(for: config) != DataCache.cacheKey(for: changedPassword))
        precondition(DataCache.cacheKey(for: config) != DataCache.cacheKey(for: changedGuide))
        precondition(DataCache.preferenceKey(for: config) == DataCache.preferenceKey(for: changedPassword))
        precondition(DataCache.preferenceKey(for: config) == DataCache.preferenceKey(for: changedGuide))
        print("PASS ordered cache writes: latest published snapshot survives 400 queued writes across four resource types")
    }
}
