import Foundation

@main
struct CacheWriteTests {
    static func main() throws {
        let key = "perf-test-" + UUID().uuidString
        let root = ProcessInfo.processInfo.environment["BUFFER_CACHE_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = root.appendingPathComponent("buffer", isDirectory: true)
        defer {
            for prefix in ["channels", "programs", "vod", "vod_series", "probes"] {
                for ext in ["json", "bin"] {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(prefix)_\(key).\(ext)"))
                }
            }
        }
        try columnarRoundTrip(folder: folder)
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

    static func same(_ a: EPGProgram, _ b: EPGProgram) -> Bool {
        a.id == b.id && a.channelID == b.channelID && a.title == b.title && a.description == b.description
            && a.start == b.start && a.end == b.end
    }

    static func same(_ a: Channel, _ b: Channel) -> Bool {
        a.id == b.id && a.name == b.name && a.logoURL == b.logoURL && a.group == b.group && a.streamURL == b.streamURL
            && a.epgChannelID == b.epgChannelID && a.catchup == b.catchup && a.contentType == b.contentType
            && a.sourceOwnership == b.sourceOwnership
    }

    /// Columnar slots: lossless round trip of every field, interning and
    /// derived IDs, exact fallback for unrepresentable times, rejection of
    /// corrupt files, and one-time migration from the legacy JSON slot.
    static func columnarRoundTrip(folder: URL) throws {
        let origin = Date(timeIntervalSince1970: 1_780_000_000)
        func at(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }
        let guide: [String: [EPGProgram]] = [
            "bbc.one": [
                EPGProgram(id: "bbc.one_\(Int(at(0).timeIntervalSince1970))", channelID: "bbc.one", title: "News",
                           description: "Shared", start: at(0), end: at(1800)),
                EPGProgram(id: "bbc.one_0042", channelID: "bbc.one", title: "News", description: "Shared", start: at(1800), end: at(3600)),
                EPGProgram(id: "xtream-simple-7-abc", channelID: "bbc.one", title: "Été — 日本", description: "", start: at(3600), end: at(3600.5)),
                EPGProgram(id: "far", channelID: "bbc.one", title: "Far", description: "", start: Date(timeIntervalSince1970: 1e11), end: Date(timeIntervalSince1970: 1e11 + 1)),
            ],
            "itv": [EPGProgram(id: "itv_1", channelID: "itv-other", title: "Odd channel", description: "x", start: at(-90), end: at(0))],
            "empty": [],
        ]
        let encoded = ColumnarCache.encodePrograms(guide, savedAt: origin)!
        let decoded = encoded.withUnsafeBytes { ColumnarCache.decodePrograms($0) }!
        precondition(decoded.savedAt == origin)
        precondition(Set(decoded.programs.keys) == Set(guide.keys))
        for (key, list) in guide {
            let other = decoded.programs[key]!
            precondition(other.count == list.count && zip(list, other).allSatisfy(same), "programme round trip changed \(key)")
        }
        precondition(decoded.programs["bbc.one"]![0].hasChannelStartID && !decoded.programs["bbc.one"]![1].hasChannelStartID)
        // A derived ID is stored without its string.
        let derivedOnly = ColumnarCache.encodePrograms(["c": [EPGProgram(id: "c_\(Int(at(0).timeIntervalSince1970))", channelID: "c", title: "t", description: "d", start: at(0), end: at(1))]], savedAt: origin)!
        precondition(!String(decoding: derivedOnly, as: UTF8.self).contains("c_17"), "derived ID was persisted")

        // Large enough for the parallel chunked decode, with exact-time rows
        // scattered across chunk boundaries.
        var large: [String: [EPGProgram]] = [:]
        for c in 0..<400 {
            let key = "ch\(c)"
            large[key] = (0..<200).map { i in
                let start = at(Double(i * 1800) + ((c * 200 + i) % 997 == 0 ? 0.5 : 0))
                return EPGProgram(id: i % 3 == 0 ? "lit-\(c)-\(i)" : "\(key)_\(Int(start.timeIntervalSince1970))", channelID: key,
                                  title: "T\(i % 50)", description: "D\(c % 7)", start: start, end: start.addingTimeInterval(1800))
            }
        }
        let largeBack = ColumnarCache.encodePrograms(large, savedAt: origin)!.withUnsafeBytes { ColumnarCache.decodePrograms($0) }!
        precondition(largeBack.programs.count == 400 && large.allSatisfy { key, list in
            let other = largeBack.programs[key]!
            return other.count == list.count && zip(list, other).allSatisfy(same)
        }, "parallel decode changed the guide")

        let sourceID = UUID(), guideSource = UUID()
        let channels = [
            Channel(id: "1", name: "One", logoURL: URL(string: "http://img/1.png?a=b c"), group: "UK", streamURL: URL(string: "http://h/1.ts")!,
                    epgChannelID: "bbc.one", catchup: CatchupInfo(kind: .xc, days: 7, source: nil)),
            Channel(id: "2", name: "Two", logoURL: nil, group: "UK", streamURL: URL(string: "http://h/2.ts")!, epgChannelID: nil,
                    catchup: CatchupInfo(kind: .standard, days: -3, source: "?s=${start}"), contentType: .vod,
                    sourceOwnership: ChannelSourceOwnership(channelIdentity: SourceChannelIdentity(sourceID: sourceID, nativeID: "2"),
                        accountKey: SourceAccountKey(opaqueValue: "acct"), logicalChannelID: "logical",
                        guideBinding: SourceGuideBinding(sourceID: guideSource, epgChannelID: "g"))),
            Channel(id: "3", name: "", logoURL: nil, group: "", streamURL: URL(string: "http://h/3.ts")!, epgChannelID: "",
                    sourceOwnership: ChannelSourceOwnership(channelIdentity: SourceChannelIdentity(sourceID: sourceID, nativeID: "3"),
                        accountKey: .unconfiguredSource(sourceID))),
        ]
        let channelBytes = ColumnarCache.encodeChannels(channels, savedAt: origin)!
        let channelsBack = channelBytes.withUnsafeBytes { ColumnarCache.decodeChannels($0) }!
        precondition(channelsBack.savedAt == origin && channelsBack.channels.count == 3
            && zip(channels, channelsBack.channels).allSatisfy(same), "channel round trip changed a field")

        // Corruption: truncation, magic, wrong slot kind, out-of-range string ID.
        precondition(Array(encoded.dropLast(8)).withUnsafeBytes { ColumnarCache.decodePrograms($0) } == nil)
        var badMagic = encoded; badMagic[0] ^= 0xFF
        precondition(badMagic.withUnsafeBytes { ColumnarCache.decodePrograms($0) } == nil)
        precondition(encoded.withUnsafeBytes { ColumnarCache.decodeChannels($0) } == nil)
        var badID = encoded
        for index in stride(from: badID.count - 4, to: 64, by: -4) where badID[index..<(index + 4)].allSatisfy({ $0 == 0 }) {
            badID.replaceSubrange(index..<(index + 4), with: [0xFE, 0xFF, 0xFF, 0x7F]); break
        }
        _ = badID.withUnsafeBytes { ColumnarCache.decodePrograms($0) } // must not trap
        for cut in stride(from: 0, to: encoded.count, by: 97) {
            _ = Array(encoded.prefix(cut)).withUnsafeBytes { ColumnarCache.decodePrograms($0) }
            _ = Array(channelBytes.prefix(cut)).withUnsafeBytes { ColumnarCache.decodeChannels($0) }
        }

        // Legacy JSON slot is read when no columnar slot exists, then replaced.
        let key = "legacy-" + UUID().uuidString
        let legacy = folder.appendingPathComponent("programs_\(key).json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(DataCache.CachedPrograms(savedAt: origin, programs: guide)).write(to: legacy)
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("programs_\(key).bin"))
        }
        precondition(DataCache.loadPrograms(key: key)?.programs["itv"]?.first?.id == "itv_1", "legacy guide was not migrated")
        DataCache.savePrograms(guide, key: key)
        precondition(!FileManager.default.fileExists(atPath: legacy.path), "legacy JSON slot survived a columnar write")
        precondition(DataCache.loadPrograms(key: key)?.programs["bbc.one"]?.count == 4)
        print("PASS columnar guide/channel cache: lossless round trip, derived IDs, exact-time fallback, corruption rejected, legacy migration")
    }
}
