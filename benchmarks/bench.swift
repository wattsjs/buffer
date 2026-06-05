#!/usr/bin/env swift

// Benchmark: Xtream feed JSON parsing

import Foundation

// MARK: - Types

struct CatchupInfo: Codable, Hashable {
    enum Kind: String, Codable { case xc, standard, append, shift }
    let kind: Kind; let days: Int; let source: String?
}

struct Channel {
    let id: String; let name: String; let logoURL: URL?; let group: String
    let streamURL: URL; let epgChannelID: String?
    let catchup: CatchupInfo?
}

// MARK: - Approach A: Current (flexString with try? decode)

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

struct StreamA: Decodable {
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

func parseA(data: Data, categoriesMap: [String: String], streamBase: URL) -> [Channel] {
    let streams = try! JSONDecoder().decode([StreamA].self, from: data)
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
            catchup: { () -> CatchupInfo? in
                guard let tvA = stream.tv_archive, (Int(tvA) ?? 0) > 0 else { return nil }
                return CatchupInfo(kind: .xc, days: max(Int(stream.tv_archive_duration ?? "") ?? 0, 1), source: nil)
            }()
        ))
    }
    return channels
}

// MARK: - Approach B: Single decode with type check (avoids try? error creation)

/// A decodable wrapper that avoids try? by using a singledecode + type check
struct FlexValue: Decodable {
    let string: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try String first (most common case for Xtream)
        if let s = try? container.decode(String.self) {
            string = s
        } else if let i = try? container.decode(Int.self) {
            string = String(i)
        } else if container.decodeNil() {
            string = ""
        } else {
            string = ""
        }
    }
}

struct FlexOptValue: Decodable {
    let string: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            string = nil
        } else if let s = try? container.decode(String.self) {
            string = s
        } else if let i = try? container.decode(Int.self) {
            string = String(i)
        } else {
            string = nil
        }
    }
}

// MARK: - Approach C: Everything as Optional<String> with fallback

// The insight: Xtream APIs almost always send these as Strings.
// If we just try to decode as String, we'll succeed 99% of the time.
// The fallback to Int almost never triggers.
// So we can optimize by trying String decodeIfPresent first.

extension KeyedDecodingContainer {
    func flexStr(forKey key: Key) -> String {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s ?? "" }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i.map(String.init) ?? "" }
        return ""
    }
    func flexStrOpt(forKey key: Key) -> String? {
        if !contains(key) { return nil }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i.map(String.init) }
        return nil
    }
}

struct StreamC: Decodable {
    let name: String; let stream_id: String; let stream_icon: String?
    let epg_channel_id: String?; let category_id: String?
    let tv_archive: String?; let tv_archive_duration: String?

    enum CodingKeys: String, CodingKey {
        case name, stream_id, stream_icon, epg_channel_id, category_id, tv_archive, tv_archive_duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stream_id = c.flexStr(forKey: .stream_id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Unknown"
        stream_icon = try? c.decodeIfPresent(String.self, forKey: .stream_icon)
        epg_channel_id = try? c.decodeIfPresent(String.self, forKey: .epg_channel_id)
        category_id = c.flexStrOpt(forKey: .category_id)
        tv_archive = c.flexStrOpt(forKey: .tv_archive)
        tv_archive_duration = c.flexStrOpt(forKey: .tv_archive_duration)
    }
}

func parseC(data: Data, categoriesMap: [String: String], streamBase: URL) -> [Channel] {
    let streams: [StreamC] = try! JSONDecoder().decode([StreamC].self, from: data)
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
            catchup: { () -> CatchupInfo? in
                guard let tvA = stream.tv_archive, (Int(tvA) ?? 0) > 0 else { return nil }
                return CatchupInfo(kind: .xc, days: max(Int(stream.tv_archive_duration ?? "") ?? 0, 1), source: nil)
            }()
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
let iterations = 30

var categoriesMap: [String: String] = [:]
for i in 1...20 { categoriesMap[String(i)] = "Category \(i)" }
let streamBase = URL(string: "http://example.com/live/user/pass")!

let data = generateSampleJSON(count: count)

// Warmup
_ = parseA(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
_ = parseC(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
usleep(100000)

var totalA: Double = 0
var totalC: Double = 0

for _ in 0..<iterations {
    let t0 = CFAbsoluteTimeGetCurrent()
    let r1 = parseA(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
    totalA += CFAbsoluteTimeGetCurrent() - t0
    _ = r1.count

    let t1 = CFAbsoluteTimeGetCurrent()
    let r2 = parseC(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
    totalC += CFAbsoluteTimeGetCurrent() - t1
    _ = r2.count
}

let avgA = totalA / Double(iterations) * 1_000_000
let avgC = totalC / Double(iterations) * 1_000_000

// Verify
let ref = parseA(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
let alt = parseC(data: data, categoriesMap: categoriesMap, streamBase: streamBase)

print("count=\(count) iterations=\(iterations)")
print("A (current flexString): \(Int(avgA)) µs")
print("C (contains check first): \(Int(avgC)) µs")
print("ref=\(ref.count) alt=\(alt.count) ids_match=\(ref.map(\.id) == alt.map(\.id))")
print("")
print("METRIC parse_µs=\(Int(avgA))")
print("METRIC alt_µs=\(Int(avgC))")
