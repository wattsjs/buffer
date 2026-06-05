#!/usr/bin/env swift

// Benchmark: Xtream feed JSON parsing
// Measures time to decode Xtream API stream responses and map to channel objects.

import Foundation

// MARK: - Replicated types (self-contained)

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

// MARK: - Current approach: decode to XtreamStream then map to Channel

struct XtreamStream: Decodable {
    let num: FlexibleString?; let name: String?; let stream_id: FlexibleString
    let stream_icon: String?; let epg_channel_id: String?
    let category_id: FlexibleString?; let tv_archive: FlexibleString?
    let tv_archive_duration: FlexibleString?
    enum CodingKeys: String, CodingKey {
        case num, name, stream_id, stream_icon, epg_channel_id, category_id, tv_archive, tv_archive_duration
    }
}

func parseCurrent(data: Data, categoriesMap: [String: String], streamBase: URL) -> [Channel] {
    let streams = try! JSONDecoder().decode([XtreamStream].self, from: data)
    return streams.compactMap { stream in
        let streamURL = streamBase.appendingPathComponent("\(stream.stream_id.value).m3u8")
        let categoryName = stream.category_id.flatMap { categoriesMap[$0.value] } ?? "Uncategorized"
        return Channel(
            id: stream.stream_id.value, name: stream.name ?? "Unknown",
            logoURL: stream.stream_icon.flatMap { URL(string: $0) },
            group: categoryName, streamURL: streamURL,
            epgChannelID: stream.epg_channel_id,
            catchup: makeCatchup(streamID: stream.stream_id.value, archive: stream)
        )
    }
}

func makeCatchup(streamID: String, archive: XtreamStream) -> CatchupInfo? {
    guard (Int(archive.tv_archive?.value ?? "") ?? 0) > 0 else { return nil }
    return CatchupInfo(kind: .xc, days: max(Int(archive.tv_archive_duration?.value ?? "") ?? 0, 1), source: nil)
}

// MARK: - Generate test data (JSON strings for stream_id/category_id like real Xtream)

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
_ = parseCurrent(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
usleep(50000)

// Benchmark
var totalCurrent: Double = 0

for _ in 0..<iterations {
    let t0 = CFAbsoluteTimeGetCurrent()
    let cResult = parseCurrent(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
    totalCurrent += CFAbsoluteTimeGetCurrent() - t0
    _ = cResult.count
}

let avgCurrent = totalCurrent / Double(iterations) * 1_000_000

print("size=\(count) iterations=\(iterations)")
print("current parse+map: \(Int(avgCurrent)) µs")
print("")
print("METRIC parse_µs=\(Int(avgCurrent))")
