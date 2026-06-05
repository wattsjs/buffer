#!/usr/bin/env swift

// Benchmark: mapping optimization (full pipeline)

import Foundation

struct CatchupInfo: Codable, Hashable {
    enum Kind: String, Codable { case xc, standard, append, shift }
    let kind: Kind; let days: Int; let source: String?
}

struct Channel {
    let id: String; let name: String; let logoURL: URL?; let group: String
    let streamURL: URL; let epgChannelID: String?
    let catchup: CatchupInfo?
}

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

struct XtreamStream: Decodable {
    let name: String; let stream_id: String; let stream_icon: String?
    let epg_channel_id: String?; let category_id: String?
    let tv_archive: String?; let tv_archive_duration: String?

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

// MARK: - Current full pipeline

func parseCurrent(data: Data, categoriesMap: [String: String], streamBase: URL) -> [Channel] {
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
            catchup: {
                guard let tvA = stream.tv_archive, (Int(tvA) ?? 0) > 0 else { return nil }
                return CatchupInfo(kind: .xc, days: max(Int(stream.tv_archive_duration ?? "") ?? 0, 1), source: nil)
            }()
        ))
    }
    return channels
}

// MARK: - Optimized full pipeline

func parseOptimized(data: Data, categoriesMap: [String: String], streamBase: URL) -> [Channel] {
    let streams = try! JSONDecoder().decode([XtreamStream].self, from: data)
    var channels: [Channel] = []
    channels.reserveCapacity(streams.count)

    let baseStr = streamBase.absoluteString

    for stream in streams {
        guard let streamURL = URL(string: "\(baseStr)/\(stream.stream_id).m3u8") else { continue }
        let categoryName = stream.category_id.flatMap { categoriesMap[$0] } ?? "Uncategorized"

        let logoURL: URL? = stream.stream_icon.flatMap { URL(string: $0) }

        let catchup: CatchupInfo?
        if let tvA = stream.tv_archive, tvA == "1" {
            let days: Int
            if let dur = stream.tv_archive_duration, let d = Int(dur), d > 0 { days = d }
            else { days = 1 }
            catchup = CatchupInfo(kind: .xc, days: days, source: nil)
        } else {
            catchup = nil
        }

        channels.append(Channel(
            id: stream.stream_id, name: stream.name,
            logoURL: logoURL, group: categoryName, streamURL: streamURL,
            epgChannelID: stream.epg_channel_id, catchup: catchup
        ))
    }
    return channels
}

// MARK: - Generate test data

func generateSampleJSON(count: Int) -> Data {
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
    return try! JSONSerialization.data(withJSONObject: streams, options: [])
}

// MARK: - Benchmark

let count = 5000
let iterations = 50

var categoriesMap: [String: String] = [:]
for i in 1...20 { categoriesMap[String(i)] = "Category \(i)" }
let streamBase = URL(string: "http://example.com/live/user/pass")!
let data = generateSampleJSON(count: count)

// Warmup
_ = parseCurrent(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
_ = parseOptimized(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
usleep(100000)

var totalCurrent: Double = 0
var totalOptimized: Double = 0

for _ in 0..<iterations {
    let t0 = CFAbsoluteTimeGetCurrent()
    let r1 = parseCurrent(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
    totalCurrent += CFAbsoluteTimeGetCurrent() - t0
    _ = r1.count

    let t1 = CFAbsoluteTimeGetCurrent()
    let r2 = parseOptimized(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
    totalOptimized += CFAbsoluteTimeGetCurrent() - t1
    _ = r2.count
}

let avgCurrent = totalCurrent / Double(iterations) * 1_000_000
let avgOptimized = totalOptimized / Double(iterations) * 1_000_000

// Verify
let ref = parseCurrent(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
let opt = parseOptimized(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
let idsMatch = ref.map(\.id) == opt.map(\.id)

print("count=\(count) iterations=\(iterations)")
print("current:   \(Int(avgCurrent)) µs")
print("optimized: \(Int(avgOptimized)) µs")
print("ids_match=\(idsMatch)")
print("")
print("METRIC parse_µs=\(Int(avgOptimized))")
print("METRIC current_µs=\(Int(avgCurrent))")
