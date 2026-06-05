#!/usr/bin/env swift

// Benchmark: Xtream feed JSON parsing
// Measures time to decode Xtream API stream responses and map to channel objects.

import Foundation

// MARK: - Types

struct CatchupInfo: Codable, Hashable {
    enum Kind: String, Codable { case xc, standard, append, shift }
    let kind: Kind; let days: Int; let source: String?
}

enum ChannelContentType: String, Codable { case live, vod }

struct Channel: Identifiable, Hashable, Codable {
    let id: String; let name: String; let logoURL: URL?; let group: String
    let streamURL: URL; let epgChannelID: String?
    let catchup: CatchupInfo?; let contentType: ChannelContentType
    init(id: String, name: String, logoURL: URL?, group: String, streamURL: URL, epgChannelID: String?, catchup: CatchupInfo? = nil, contentType: ChannelContentType = .live) {
        self.id = id; self.name = name; self.logoURL = logoURL; self.group = group
        self.streamURL = streamURL; self.epgChannelID = epgChannelID
        self.catchup = catchup; self.contentType = contentType
    }
}

// MARK: - Flexible string decoding helpers (matches deployed XtreamClient code)

extension KeyedDecodingContainer {
    func flexString(forKey key: Key) throws -> String {
        if let s = try? decode(String.self, forKey: key) { return s }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        return ""
    }
    func flexStringIfPresent(forKey key: Key) throws -> String? {
        if contains(key) {
            if let s = try? decode(String.self, forKey: key) { return s }
            if let i = try? decode(Int.self, forKey: key) { return String(i) }
        }
        return nil
    }
}

// MARK: - Optimized stream (matches deployed XtreamClient.XtreamStream)

struct XtreamStream: Decodable {
    let name: String
    let stream_id: String
    let stream_icon: String?
    let epg_channel_id: String?
    let category_id: String?
    let tv_archive: String?
    let tv_archive_duration: String?

    enum CodingKeys: String, CodingKey {
        case name, stream_id, stream_icon, epg_channel_id, category_id, tv_archive, tv_archive_duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stream_id = try c.flexString(forKey: .stream_id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
        stream_icon = try c.decodeIfPresent(String.self, forKey: .stream_icon)
        epg_channel_id = try c.decodeIfPresent(String.self, forKey: .epg_channel_id)
        category_id = try c.flexStringIfPresent(forKey: .category_id)
        tv_archive = try c.flexStringIfPresent(forKey: .tv_archive)
        tv_archive_duration = try c.flexStringIfPresent(forKey: .tv_archive_duration)
    }
}

func parseChannels(data: Data, categoriesMap: [String: String], streamBase: URL) -> [Channel] {
    let streams = try! JSONDecoder().decode([XtreamStream].self, from: data)
    var channels: [Channel] = []
    channels.reserveCapacity(streams.count)
    for stream in streams {
        let streamURL = streamBase.appendingPathComponent("\(stream.stream_id).m3u8")
        let categoryName = stream.category_id.flatMap { categoriesMap[$0] } ?? "Uncategorized"
        channels.append(Channel(
            id: stream.stream_id, name: stream.name,
            logoURL: stream.stream_icon.flatMap { URL(string: $0) },
            group: categoryName, streamURL: streamURL,
            epgChannelID: stream.epg_channel_id,
            catchup: makeCatchup(stream: stream)
        ))
    }
    return channels
}

func makeCatchup(stream: XtreamStream) -> CatchupInfo? {
    guard let tvArchive = stream.tv_archive, (Int(tvArchive) ?? 0) > 0 else { return nil }
    return CatchupInfo(kind: .xc, days: max(Int(stream.tv_archive_duration ?? "") ?? 0, 1), source: nil)
}

// MARK: - Category decoding (matches deployed)

struct XtreamCategory: Decodable {
    let category_id: String
    let category_name: String?
    enum CodingKeys: String, CodingKey { case category_id, category_name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category_id = try c.flexString(forKey: .category_id)
        category_name = try c.decodeIfPresent(String.self, forKey: .category_name)
    }
}

// MARK: - Full fetchChannels simulation (includes category fetch + stream parse)

func fetchChannelsSim(data: Data, categoriesData: Data, streamBase: URL) -> [Channel] {
    let categories = try! JSONDecoder().decode([XtreamCategory].self, from: categoriesData)
    var categoriesMap: [String: String] = [:]
    categoriesMap.reserveCapacity(categories.count)
    for cat in categories { categoriesMap[cat.category_id] = cat.category_name ?? "Unknown" }

    let streams = try! JSONDecoder().decode([XtreamStream].self, from: data)
    var channels: [Channel] = []
    channels.reserveCapacity(streams.count)
    for stream in streams {
        let streamURL = streamBase.appendingPathComponent("\(stream.stream_id).m3u8")
        let categoryName = stream.category_id.flatMap { categoriesMap[$0] } ?? "Uncategorized"
        channels.append(Channel(
            id: stream.stream_id, name: stream.name,
            logoURL: stream.stream_icon.flatMap { URL(string: $0) },
            group: categoryName, streamURL: streamURL,
            epgChannelID: stream.epg_channel_id,
            catchup: makeCatchup(stream: stream)
        ))
    }
    return channels
}

// MARK: - Generate test data (JSON strings for IDs like real Xtream)

func generateSampleJSON(count: Int) -> (streams: Data, categories: Data) {
    var streams: [[String: Any]] = []
    for i in 0..<count {
        let archive = i % 3 == 0
        streams.append([
            "num": i + 1,
            "name": "Channel \(i) HD",
            "stream_id": String(1000 + i),
            "stream_icon": "https://example.com/logos/\(i).png",
            "epg_channel_id": "epg-\(i).example.com",
            "category_id": String((i % 20) + 1),
            "tv_archive": archive ? "1" : "0",
            "tv_archive_duration": archive ? "7" : "0"
        ])
    }
    var cats: [[String: Any]] = []
    for i in 1...20 {
        cats.append(["category_id": String(i), "category_name": "Category \(i)"])
    }
    return (
        try! JSONSerialization.data(withJSONObject: streams, options: []),
        try! JSONSerialization.data(withJSONObject: cats, options: [])
    )
}

// MARK: - Benchmark

let count = 5000
let iterations = 30

let streamBase = URL(string: "http://example.com/live/user/pass")!
let (streamsData, categoriesData) = generateSampleJSON(count: count)
var categoriesMap: [String: String] = [:]
for i in 1...20 { categoriesMap[String(i)] = "Category \(i)" }

// Warmup
_ = parseChannels(data: streamsData, categoriesMap: categoriesMap, streamBase: streamBase)
_ = fetchChannelsSim(data: streamsData, categoriesData: categoriesData, streamBase: streamBase)
usleep(100000)

var totalStreams: Double = 0
var totalFull: Double = 0

for _ in 0..<iterations {
    let t0 = CFAbsoluteTimeGetCurrent()
    let r1 = parseChannels(data: streamsData, categoriesMap: categoriesMap, streamBase: streamBase)
    totalStreams += CFAbsoluteTimeGetCurrent() - t0
    _ = r1.count

    let t1 = CFAbsoluteTimeGetCurrent()
    let r2 = fetchChannelsSim(data: streamsData, categoriesData: categoriesData, streamBase: streamBase)
    totalFull += CFAbsoluteTimeGetCurrent() - t1
    _ = r2.count
}

let avgStreams = totalStreams / Double(iterations) * 1_000_000
let avgFull = totalFull / Double(iterations) * 1_000_000

print("count=\(count) iterations=\(iterations)")
print("stream_parse_only: \(Int(avgStreams)) µs")
print("full_fetch_channels: \(Int(avgFull)) µs")
print("")
print("METRIC parse_µs=\(Int(avgStreams))")
print("METRIC full_fetch_channels_µs=\(Int(avgFull))")
