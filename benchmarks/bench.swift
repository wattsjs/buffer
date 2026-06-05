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

// MARK: - FlexibleString (current approach)

struct FlexibleString: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = ""; return }
        if let str = try? container.decode(String.self) { value = str; return }
        if let int = try? container.decode(Int.self) { value = String(int); return }
        if let double = try? container.decode(Double.self) { value = String(Int(double)); return }
        value = ""
    }
}

// MARK: - Approach A: Current (FlexibleString + compactMap)

struct StreamA: Decodable {
    let num: FlexibleString?; let name: String?; let stream_id: FlexibleString
    let stream_icon: String?; let epg_channel_id: String?
    let category_id: FlexibleString?; let tv_archive: FlexibleString?
    let tv_archive_duration: FlexibleString?
    enum CodingKeys: String, CodingKey {
        case num, name, stream_id, stream_icon, epg_channel_id, category_id, tv_archive, tv_archive_duration
    }
}

func parseApproachA(data: Data, categoriesMap: [String: String], streamBase: URL) -> [Channel] {
    let streams = try! JSONDecoder().decode([StreamA].self, from: data)
    var channels: [Channel] = []
    channels.reserveCapacity(streams.count)
    for stream in streams {
        let streamURL = streamBase.appendingPathComponent("\(stream.stream_id.value).m3u8")
        let categoryName = stream.category_id.flatMap { categoriesMap[$0.value] } ?? "Uncategorized"
        channels.append(Channel(
            id: stream.stream_id.value, name: stream.name ?? "Unknown",
            logoURL: stream.stream_icon.flatMap { URL(string: $0) },
            group: categoryName, streamURL: streamURL,
            epgChannelID: stream.epg_channel_id,
            catchup: makeCatchupA(stream: stream)
        ))
    }
    return channels
}

func makeCatchupA(stream: StreamA) -> CatchupInfo? {
    guard (Int(stream.tv_archive?.value ?? "") ?? 0) > 0 else { return nil }
    return CatchupInfo(kind: .xc, days: max(Int(stream.tv_archive_duration?.value ?? "") ?? 0, 1), source: nil)
}

// MARK: - Approach B: Direct flex decode, no FlexibleString struct

/// Helper: decode a value that could be String or Int, always returning String
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

struct StreamB: Decodable {
    let streamID: String; let name: String; let streamIcon: String?
    let categoryID: String?; let epgChannelID: String?
    let tvArchive: String?; let tvArchiveDuration: String?

    enum CodingKeys: String, CodingKey {
        case name, stream_id, stream_icon, epg_channel_id, category_id, tv_archive, tv_archive_duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streamID = try c.flexString(forKey: .stream_id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
        streamIcon = try c.decodeIfPresent(String.self, forKey: .stream_icon)
        epgChannelID = try c.decodeIfPresent(String.self, forKey: .epg_channel_id)
        categoryID = try c.flexStringIfPresent(forKey: .category_id)
        tvArchive = try c.flexStringIfPresent(forKey: .tv_archive)
        tvArchiveDuration = try c.flexStringIfPresent(forKey: .tv_archive_duration)
    }
}

func parseApproachB(data: Data, categoriesMap: [String: String], streamBase: URL) -> [Channel] {
    let streams = try! JSONDecoder().decode([StreamB].self, from: data)
    var channels: [Channel] = []
    channels.reserveCapacity(streams.count)
    for stream in streams {
        let streamURL = streamBase.appendingPathComponent("\(stream.streamID).m3u8")
        let categoryName = stream.categoryID.flatMap { categoriesMap[$0] } ?? "Uncategorized"
        channels.append(Channel(
            id: stream.streamID, name: stream.name,
            logoURL: stream.streamIcon.flatMap { URL(string: $0) },
            group: categoryName, streamURL: streamURL,
            epgChannelID: stream.epgChannelID,
            catchup: makeCatchupB(stream: stream)
        ))
    }
    return channels
}

func makeCatchupB(stream: StreamB) -> CatchupInfo? {
    guard let tvArchive = stream.tvArchive, (Int(tvArchive) ?? 0) > 0 else { return nil }
    return CatchupInfo(kind: .xc, days: max(Int(stream.tvArchiveDuration ?? "") ?? 0, 1), source: nil)
}

// MARK: - Approach C: Skip intermediate struct, decode flat

struct StreamC: Decodable {
    let id: String; let name: String; let logoURL: URL?; let group: String
    let streamURL: URL; let epgChannelID: String?
    let catchup: CatchupInfo?

    enum CodingKeys: String, CodingKey {
        case stream_id, name, stream_icon, category_id, epg_channel_id, tv_archive, tv_archive_duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let streamID = try c.flexString(forKey: .stream_id)
        id = streamID
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
        logoURL = try c.decodeIfPresent(String.self, forKey: .stream_icon).flatMap(URL.init(string:))
        let catID = try c.flexStringIfPresent(forKey: .category_id)
        let categoriesMap = decoder.userInfo[.catMapKey] as! [String: String]
        group = catID.flatMap { categoriesMap[$0] } ?? "Uncategorized"
        let base = decoder.userInfo[.streamBaseKey] as! URL
        streamURL = base.appendingPathComponent("\(streamID).m3u8")
        epgChannelID = try c.decodeIfPresent(String.self, forKey: .epg_channel_id)

        let tvArchive = try c.flexStringIfPresent(forKey: .tv_archive)
        if let tvArchive, (Int(tvArchive) ?? 0) > 0 {
            let dur = try c.flexStringIfPresent(forKey: .tv_archive_duration)
            catchup = CatchupInfo(kind: .xc, days: max(Int(dur ?? "") ?? 0, 1), source: nil)
        } else {
            catchup = nil
        }
    }
}

extension CodingUserInfoKey {
    static let catMapKey = CodingUserInfoKey(rawValue: "catMap")!
    static let streamBaseKey = CodingUserInfoKey(rawValue: "streamBase")!
}

func parseApproachC(data: Data, categoriesMap: [String: String], streamBase: URL) -> [Channel] {
    let decoder = JSONDecoder()
    decoder.userInfo[.catMapKey] = categoriesMap
    decoder.userInfo[.streamBaseKey] = streamBase
    let channels = try! decoder.decode([StreamC].self, from: data)
    return channels.map { Channel(id: $0.id, name: $0.name, logoURL: $0.logoURL, group: $0.group,
                                  streamURL: $0.streamURL, epgChannelID: $0.epgChannelID, catchup: $0.catchup) }
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
let iterations = 20

var categoriesMap: [String: String] = [:]
for i in 1...20 { categoriesMap[String(i)] = "Category \(i)" }
let streamBase = URL(string: "http://example.com/live/user/pass")!

let data = generateSampleJSON(count: count)

// Warmup
_ = parseApproachA(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
_ = parseApproachB(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
_ = parseApproachC(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
usleep(100000)

// Benchmark all three
struct Result { var a: Double = 0; var b: Double = 0; var c: Double = 0 }
var results = Result()

for _ in 0..<iterations {
    let t0 = CFAbsoluteTimeGetCurrent()
    let ra = parseApproachA(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
    results.a += CFAbsoluteTimeGetCurrent() - t0
    _ = ra.count

    let t1 = CFAbsoluteTimeGetCurrent()
    let rb = parseApproachB(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
    results.b += CFAbsoluteTimeGetCurrent() - t1
    _ = rb.count

    let t2 = CFAbsoluteTimeGetCurrent()
    let rc = parseApproachC(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
    results.c += CFAbsoluteTimeGetCurrent() - t2
    _ = rc.count
}

let avgA = results.a / Double(iterations) * 1_000_000
let avgB = results.b / Double(iterations) * 1_000_000
let avgC = results.c / Double(iterations) * 1_000_000

print("size=\(count) iterations=\(iterations)")
print("A (current FlexibleString):  \(Int(avgA)) µs")
print("B (direct flex decode):      \(Int(avgB)) µs")
print("C (decode to final struct):  \(Int(avgC)) µs")
print("")
print("METRIC parse_µs=\(Int(avgA))")
print("METRIC approachB_µs=\(Int(avgB))")
print("METRIC approachC_µs=\(Int(avgC))")
