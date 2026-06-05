#!/usr/bin/env swift

// Benchmark with REALISTIC data: category_id as string (like real Xtream servers)

import Foundation

struct CatchupInfo: Hashable {
    enum Kind: String { case xc }; let kind: Kind; let days: Int; let source: String?
}
struct Channel {
    let id: String; let name: String; let logoURL: URL?; let group: String
    let streamURL: URL; let epgChannelID: String?
    let catchup: CatchupInfo?
}

// MARK: - Approach A: Int-first for category_id (current, overfitted to benchmark)
extension KeyedDecodingContainer {
    func flexInt(forKey key: Key) throws -> String {
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        if let s = try? decode(String.self, forKey: key) { return s }
        return ""
    }
    func flexIntIfPresent(forKey key: Key) throws -> String? {
        if contains(key) { if let i = try? decode(Int.self, forKey: key) { return String(i) }; if let s = try? decode(String.self, forKey: key) { return s } }
        return nil
    }
    func flexStrIfPresent(forKey key: Key) throws -> String? {
        if contains(key) { if let s = try? decode(String.self, forKey: key) { return s }; if let i = try? decode(Int.self, forKey: key) { return String(i) } }
        return nil
    }
}

// A: Int-first for category_id (current code)
struct StreamA: Decodable {
    let name: String; let stream_id: String; let stream_icon: String?
    let epg_channel_id: String?; let category_id: String?; let tv_archive: String?; let tv_archive_duration: String?
    enum CK: String, CodingKey { case name, stream_id, stream_icon, epg_channel_id, category_id, tv_archive, tv_archive_duration }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CK.self)
        stream_id = try c.flexInt(forKey: .stream_id); name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
        stream_icon = try c.decodeIfPresent(String.self, forKey: .stream_icon); epg_channel_id = try c.decodeIfPresent(String.self, forKey: .epg_channel_id)
        category_id = try c.flexIntIfPresent(forKey: .category_id) // ← overfitted! Real servers send strings
        tv_archive = try c.flexIntIfPresent(forKey: .tv_archive); tv_archive_duration = try c.flexIntIfPresent(forKey: .tv_archive_duration)
    }
}

// B: String-first for category_id (matches real server data)
struct StreamB: Decodable {
    let name: String; let stream_id: String; let stream_icon: String?
    let epg_channel_id: String?; let category_id: String?; let tv_archive: String?; let tv_archive_duration: String?
    enum CK: String, CodingKey { case name, stream_id, stream_icon, epg_channel_id, category_id, tv_archive, tv_archive_duration }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CK.self)
        stream_id = try c.flexInt(forKey: .stream_id); name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
        stream_icon = try c.decodeIfPresent(String.self, forKey: .stream_icon); epg_channel_id = try c.decodeIfPresent(String.self, forKey: .epg_channel_id)
        category_id = try c.flexStrIfPresent(forKey: .category_id) // ← String-first for real servers
        tv_archive = try c.flexIntIfPresent(forKey: .tv_archive); tv_archive_duration = try c.flexIntIfPresent(forKey: .tv_archive_duration)
    }
}

func parseA(data: Data, catMap: [String:String], sb: URL) -> [Channel] {
    let s = try! JSONDecoder().decode([StreamA].self, from: data)
    var out: [Channel] = []; out.reserveCapacity(s.count); let b = sb.absoluteString
    for x in s {
        guard let u = URL(string: "\(b)/\(x.stream_id).m3u8") else { continue }
        let cc: CatchupInfo? = x.tv_archive == "1" ? CatchupInfo(kind: .xc, days: max(Int(x.tv_archive_duration ?? "") ?? 0, 1), source: nil) : nil
        out.append(Channel(id: x.stream_id, name: x.name, logoURL: x.stream_icon.flatMap(URL.init), group: x.category_id.flatMap{catMap[$0]} ?? "Uncategorized", streamURL: u, epgChannelID: x.epg_channel_id, catchup: cc))
    }
    return out
}
func parseB(data: Data, catMap: [String:String], sb: URL) -> [Channel] {
    let s = try! JSONDecoder().decode([StreamB].self, from: data)
    var out: [Channel] = []; out.reserveCapacity(s.count); let b = sb.absoluteString
    for x in s {
        guard let u = URL(string: "\(b)/\(x.stream_id).m3u8") else { continue }
        let cc: CatchupInfo? = x.tv_archive == "1" ? CatchupInfo(kind: .xc, days: max(Int(x.tv_archive_duration ?? "") ?? 0, 1), source: nil) : nil
        out.append(Channel(id: x.stream_id, name: x.name, logoURL: x.stream_icon.flatMap(URL.init), group: x.category_id.flatMap{catMap[$0]} ?? "Uncategorized", streamURL: u, epgChannelID: x.epg_channel_id, catchup: cc))
    }
    return out
}

// Generate REALISTIC data: stream_id=int, tv_archive=int, category_id=STRING (like real Xtream)
func gen(count: Int) -> Data {
    var arr = [[String:Any]]()
    for i in 0..<count {
        let a = i%3==0
        arr.append([
            "num":i+1, "name":"Channel \(i) HD",
            "stream_id":1000+i,                             // int (real)
            "stream_icon":"https://x.com/\(i).png",
            "epg_channel_id":"epg-\(i).x.com",
            "category_id":String((i%20)+1),                 // STRING (real!)
            "tv_archive":a ? 1 : 0,                         // int (real)
            "tv_archive_duration":a ? 7 : 0                 // int (real)
        ])
    }
    return try! JSONSerialization.data(withJSONObject: arr)
}

// Also test with real data from the server
let realData = try! Data(contentsOf: URL(fileURLWithPath: "/tmp/xtream_live.json"))

let count = 5000; let iters = 50
var catMap: [String:String] = [:]; for i in 1...20 { catMap[String(i)] = "Category \(i)" }
let sb = URL(string: "http://x.com/live/u/p")!
let data = gen(count: count)

// Test on synthetic data
_ = parseA(data: data, catMap: catMap, sb: sb)
_ = parseB(data: data, catMap: catMap, sb: sb)
usleep(100000)

var tA: Double = 0; var tB: Double = 0
for _ in 0..<iters {
    let t0 = CFAbsoluteTimeGetCurrent(); _ = parseA(data: data, catMap: catMap, sb: sb).count; tA += CFAbsoluteTimeGetCurrent() - t0
    let t1 = CFAbsoluteTimeGetCurrent(); _ = parseB(data: data, catMap: catMap, sb: sb).count; tB += CFAbsoluteTimeGetCurrent() - t1
}
let aA = tA / Double(iters) * 1_000_000
let aB = tB / Double(iters) * 1_000_000
let match = parseA(data: data, catMap: catMap, sb: sb).map(\.id) == parseB(data: data, catMap: catMap, sb: sb).map(\.id)

print("=== Synthetic (5000 streams, cat_id=string) ===")
print("A (cat_id Int-first): \(Int(aA)) µs")
print("B (cat_id Str-first): \(Int(aB)) µs")
print("match=\(match)")

// Test on REAL server data (14,993 streams)
let realCatMap: [String:String] = [:]
_ = parseB(data: realData, catMap: realCatMap, sb: sb)
usleep(100000)

var tRealB: Double = 0
for _ in 0..<iters {
    let t0 = CFAbsoluteTimeGetCurrent(); let r = parseB(data: realData, catMap: realCatMap, sb: sb); tRealB += CFAbsoluteTimeGetCurrent() - t0; _ = r.count
}
let aRealB = tRealB / Double(iters) * 1_000_000

print("\n=== Real server data (14,993 streams) ===")
print("B (cat_id Str-first): \(Int(aRealB)) µs")
print("channels: \(parseB(data: realData, catMap: realCatMap, sb: sb).count)")
print("")
print("METRIC parse_µs=\(Int(aB))")
print("METRIC catid_int_first_µs=\(Int(aA))")
print("METRIC real_14993_µs=\(Int(aRealB))")
