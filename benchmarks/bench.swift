#!/usr/bin/env swift

// Final benchmark: Xtream feed JSON parsing with int-first flex decode

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
    func flexInt(forKey key: Key) throws -> String {
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        if let s = try? decode(String.self, forKey: key) { return s }
        return ""
    }
    func flexIntIfPresent(forKey key: Key) throws -> String? {
        if contains(key) {
            if let i = try? decode(Int.self, forKey: key) { return String(i) }
            if let s = try? decode(String.self, forKey: key) { return s }
        }
        return nil
    }
}

struct Stream: Decodable {
    let name: String; let stream_id: String; let stream_icon: String?
    let epg_channel_id: String?; let category_id: String?
    let tv_archive: String?; let tv_archive_duration: String?

    enum CodingKeys: String, CodingKey {
        case name, stream_id, stream_icon, epg_channel_id, category_id, tv_archive, tv_archive_duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stream_id = try c.flexInt(forKey: .stream_id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
        stream_icon = try c.decodeIfPresent(String.self, forKey: .stream_icon)
        epg_channel_id = try c.decodeIfPresent(String.self, forKey: .epg_channel_id)
        category_id = try c.flexIntIfPresent(forKey: .category_id)
        tv_archive = try c.flexIntIfPresent(forKey: .tv_archive)
        tv_archive_duration = try c.flexIntIfPresent(forKey: .tv_archive_duration)
    }
}

func parseChannels(data: Data, categoriesMap: [String: String], streamBase: URL) -> [Channel] {
    let streams = try! JSONDecoder().decode([Stream].self, from: data)
    var channels: [Channel] = []
    channels.reserveCapacity(streams.count)
    let baseStr = streamBase.absoluteString
    for stream in streams {
        guard let streamURL = URL(string: "\(baseStr)/\(stream.stream_id).m3u8") else { continue }
        let categoryName = stream.category_id.flatMap { categoriesMap[$0] } ?? "Uncategorized"
        let logoURL: URL? = stream.stream_icon.flatMap { URL(string: $0) }
        let catchup: CatchupInfo? = {
            guard let tvA = stream.tv_archive, tvA == "1" else { return nil }
            let days: Int
            if let dur = stream.tv_archive_duration, let d = Int(dur), d > 0 { days = d }
            else { days = 1 }
            return CatchupInfo(kind: .xc, days: days, source: nil)
        }()
        channels.append(Channel(
            id: stream.stream_id, name: stream.name,
            logoURL: logoURL, group: categoryName, streamURL: streamURL,
            epgChannelID: stream.epg_channel_id, catchup: catchup
        ))
    }
    return channels
}

/// Realistic Xtream: integers for stream_id, category_id, tv_archive, tv_archive_duration
func generateRealisticJSON(count: Int) -> Data {
    var streams: [[String: Any]] = []
    for i in 0..<count {
        let archive = i % 3 == 0
        streams.append([
            "num": i + 1,
            "name": "Channel \(i) HD",
            "stream_id": 1000 + i,
            "stream_icon": "https://example.com/logos/\(i).png",
            "epg_channel_id": "epg-\(i).example.com",
            "category_id": (i % 20) + 1,
            "tv_archive": archive ? 1 : 0,
            "tv_archive_duration": archive ? 7 : 0
        ])
    }
    return try! JSONSerialization.data(withJSONObject: streams, options: [])
}

let count = 5000
let iterations = 100

var categoriesMap: [String: String] = [:]
for i in 1...20 { categoriesMap[String(i)] = "Category \(i)" }
let streamBase = URL(string: "http://example.com/live/user/pass")!
let data = generateRealisticJSON(count: count)

// Warmup
_ = parseChannels(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
usleep(100000)

var total: Double = 0
for _ in 0..<iterations {
    let t0 = CFAbsoluteTimeGetCurrent()
    let r = parseChannels(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
    total += CFAbsoluteTimeGetCurrent() - t0
    _ = r.count
}

let avg = total / Double(iterations) * 1_000_000

let result = parseChannels(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
print("count=\(count) iterations=\(iterations)")
print("parse_ch:     \(Int(avg)) µs")
print("result_count: \(result.count)")
print("")
print("METRIC parse_µs=\(Int(avg))")
