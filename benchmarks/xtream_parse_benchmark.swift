#!/usr/bin/env swift

// Benchmark: Xtream feed JSON parsing
// Measures time to decode Xtream API stream responses and map to channel objects.

import Foundation

// MARK: - Replicated types (self-contained, no project imports)

struct CatchupInfo: Codable, Hashable {
    enum Kind: String, Codable {
        case xc, standard, append, shift
    }
    let kind: Kind
    let days: Int
    let source: String?
}

enum ChannelContentType: String, Codable {
    case live, vod
}

struct Channel: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let logoURL: URL?
    let group: String
    let streamURL: URL
    let epgChannelID: String?
    let catchup: CatchupInfo?
    let contentType: ChannelContentType

    init(id: String, name: String, logoURL: URL?, group: String, streamURL: URL, epgChannelID: String?, catchup: CatchupInfo? = nil, contentType: ChannelContentType = .live) {
        self.id = id
        self.name = name
        self.logoURL = logoURL
        self.group = group
        self.streamURL = streamURL
        self.epgChannelID = epgChannelID
        self.catchup = catchup
        self.contentType = contentType
    }
}

// MARK: - FlexibleString (handles Xtream's inconsistent number/string fields)

struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = ""
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(Int(double))
        } else {
            value = ""
        }
    }
}

// MARK: - XtreamStream (mirrors the app's DTO)

struct XtreamStream: Decodable {
    let num: FlexibleString?
    let name: String?
    let stream_id: FlexibleString
    let stream_icon: String?
    let epg_channel_id: String?
    let category_id: FlexibleString?
    let tv_archive: FlexibleString?
    let tv_archive_duration: FlexibleString?

    enum CodingKeys: String, CodingKey {
        case num, name, stream_id, stream_icon, epg_channel_id, category_id, tv_archive, tv_archive_duration
    }
}

// MARK: - XtreamCategory (for category maps)

struct XtreamCategory: Decodable {
    let category_id: FlexibleString
    let category_name: String?
}

// MARK: - Benchmark runner

func generateSampleJSON(count: Int) -> Data {
    var streams: [[String: Any]] = []
    for i in 0..<count {
        let stream: [String: Any] = [
            "num": i + 1,
            "name": "Channel \(i) HD",
            "stream_id": i + 1000,
            "stream_icon": "https://example.com/logos/\(i).png",
            "epg_channel_id": "epg-\(i).example.com",
            "category_id": (i % 20) + 1,
            "tv_archive": i % 3 == 0 ? 1 : 0,
            "tv_archive_duration": i % 3 == 0 ? 7 : 0
        ]
        streams.append(stream)
    }
    return try! JSONSerialization.data(withJSONObject: streams, options: [])
}

// MARK: - Parsing approaches

/// Original approach: decode to XtreamStream then map to Channel (current code path)
func parseOriginal(data: Data, categoriesMap: [String: String], streamBase: URL) -> [Channel] {
    let streams = try! JSONDecoder().decode([XtreamStream].self, from: data)
    return streams.compactMap { stream in
        let streamURL = streamBase.appendingPathComponent("\(stream.stream_id.value).m3u8")
        let categoryName = stream.category_id.flatMap { categoriesMap[$0.value] } ?? "Uncategorized"

        return Channel(
            id: stream.stream_id.value,
            name: stream.name ?? "Unknown",
            logoURL: stream.stream_icon.flatMap { URL(string: $0) },
            group: categoryName,
            streamURL: streamURL,
            epgChannelID: stream.epg_channel_id,
            catchup: makeCatchup(streamID: stream.stream_id.value, archive: stream)
        )
    }
}

func makeCatchup(streamID: String, archive: XtreamStream) -> CatchupInfo? {
    let isArchived = (Int(archive.tv_archive?.value ?? "") ?? 0) > 0
    guard isArchived else { return nil }
    let providerDays = Int(archive.tv_archive_duration?.value ?? "") ?? 0
    let days = max(providerDays, 1)
    return CatchupInfo(kind: .xc, days: days, source: nil)
}

// MARK: - Alternative: manual JSON parsing with JSONSerialization

func parseManualJSON(data: Data, categoriesMap: [String: String], streamBase: URL) -> [Channel] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return []
    }
    var channels: [Channel] = []
    channels.reserveCapacity(json.count)

    for obj in json {
        guard let streamID = flexibleStringValue(obj["stream_id"]) else { continue }
        let name = (obj["name"] as? String) ?? "Unknown"
        let logoURL = (obj["stream_icon"] as? String).flatMap { URL(string: $0) }
        let categoryID = flexibleStringValue(obj["category_id"])
        let categoryName = categoryID.flatMap { categoriesMap[$0] } ?? "Uncategorized"
        let streamURL = streamBase.appendingPathComponent("\(streamID).m3u8")
        let epgChannelID = obj["epg_channel_id"] as? String
        let tvArchive = flexibleStringValue(obj["tv_archive"])
        let tvArchiveDuration = flexibleStringValue(obj["tv_archive_duration"])

        let catchup: CatchupInfo? = {
            let isArchived = (Int(tvArchive ?? "") ?? 0) > 0
            guard isArchived else { return nil }
            let days = max(Int(tvArchiveDuration ?? "") ?? 0, 1)
            return CatchupInfo(kind: .xc, days: days, source: nil)
        }()

        channels.append(Channel(
            id: streamID,
            name: name,
            logoURL: logoURL,
            group: categoryName,
            streamURL: streamURL,
            epgChannelID: epgChannelID,
            catchup: catchup
        ))
    }
    return channels
}

func flexibleStringValue(_ value: Any?) -> String? {
    guard let value = value, !(value is NSNull) else { return nil }
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    return nil
}

// MARK: - Optimized: bulk decoder that decodes directly to Channel

func parseOptimized(data: Data, categoriesMap: [String: String], streamBase: URL) -> [Channel] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return []
    }
    var channels: [Channel] = []
    channels.reserveCapacity(json.count)

    for obj in json {
        guard let streamID = flexibleStringValue(obj["stream_id"]) else { continue }

        let name: String
        if let n = obj["name"] as? String { name = n } else { name = "Unknown" }

        let logoURL: URL?
        if let icon = obj["stream_icon"] as? String, let u = URL(string: icon) { logoURL = u } else { logoURL = nil }

        let categoryName: String
        if let cid = flexibleStringValue(obj["category_id"]), let cn = categoriesMap[cid] {
            categoryName = cn
        } else {
            categoryName = "Uncategorized"
        }

        let streamURL = streamBase.appendingPathComponent("\(streamID).m3u8")
        let epgChannelID = obj["epg_channel_id"] as? String

        let catchup: CatchupInfo?
        let tvArchive = flexibleStringValue(obj["tv_archive"])
        if let tvArchive, (Int(tvArchive) ?? 0) > 0 {
            let tvArchiveDuration = flexibleStringValue(obj["tv_archive_duration"])
            let days = max(Int(tvArchiveDuration ?? "") ?? 0, 1)
            catchup = CatchupInfo(kind: .xc, days: days, source: nil)
        } else {
            catchup = nil
        }

        channels.append(Channel(
            id: streamID,
            name: name,
            logoURL: logoURL,
            group: categoryName,
            streamURL: streamURL,
            epgChannelID: epgChannelID,
            catchup: catchup
        ))
    }
    return channels
}

// MARK: - Main

let sizes = [100, 500, 1000, 5000, 10000]
let iterations = 10

// Setup fake categories
var categoriesMap: [String: String] = [:]
for i in 1...20 {
    categoriesMap[String(i)] = "Category \(i)"
}
let streamBase = URL(string: "http://example.com/live/user/pass")!

print("=== Xtream Feed Parse Benchmark ===")
print("iterations=\(iterations) sizes=\(sizes)")
print("")

for count in sizes {
    let data = generateSampleJSON(count: count)
    print("--- size=\(count) ---")

    // Warm up JSONDecoder
    _ = try? JSONDecoder().decode([XtreamStream].self, from: data)

    // Approach 1: Original (JSONDecoder + compactMap)
    var totalOriginal: Double = 0
    for _ in 0..<iterations {
        let dataCopy = data // ensure fair comparison
        let start = CFAbsoluteTimeGetCurrent()
        let result = parseOriginal(data: dataCopy, categoriesMap: categoriesMap, streamBase: streamBase)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        totalOriginal += elapsed
        _ = result.count
        usleep(100) // tiny gap to reduce thermal/cache interactions
    }
    let avgOriginal = totalOriginal / Double(iterations) * 1_000_000

    // Approach 2: Manual JSONSerialization
    var totalManual: Double = 0
    for _ in 0..<iterations {
        let start = CFAbsoluteTimeGetCurrent()
        let result = parseManualJSON(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        totalManual += elapsed
        _ = result.count
        usleep(100)
    }
    let avgManual = totalManual / Double(iterations) * 1_000_000

    // Approach 3: Optimized manual (direct to Channel)
    var totalOptimized: Double = 0
    for _ in 0..<iterations {
        let start = CFAbsoluteTimeGetCurrent()
        let result = parseOptimized(data: data, categoriesMap: categoriesMap, streamBase: streamBase)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        totalOptimized += elapsed
        _ = result.count
        usleep(100)
    }
    let avgOptimized = totalOptimized / Double(iterations) * 1_000_000

    print("  original_deocde_map:  \(Int(avgOriginal)) µs")
    print("  manual_jsonserialization: \(Int(avgManual)) µs")
    print("  optimized_direct:      \(Int(avgOptimized)) µs")

    // Report primary metric (original approach at largest size, to track main optimization target)
    if count == 5000 {
        print("")
        print("METRIC original_5000_µs=\(Int(avgOriginal))")
        print("METRIC manual_5000_µs=\(Int(avgManual))")
        print("METRIC optimized_5000_µs=\(Int(avgOptimized))")
    }
}

print("")
let fullData = generateSampleJSON(count: 5000)
let start = CFAbsoluteTimeGetCurrent()
let result = parseOriginal(data: fullData, categoriesMap: categoriesMap, streamBase: streamBase)
let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000_000
print("FINAL: original=\(Int(elapsed))µs channels=\(result.count)")
