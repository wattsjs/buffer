#!/usr/bin/env swift

// Benchmark: Xtream feed JSON parsing

import Foundation

struct CatchupInfo: Hashable { enum Kind: String { case xc }; let kind: Kind; let days: Int; let source: String? }
struct Channel { let id: String; let name: String; let logoURL: URL?; let group: String; let streamURL: URL; let epgChannelID: String?; let catchup: CatchupInfo? }

extension KeyedDecodingContainer {
    func flexStringIfPresent(forKey key: Key) throws -> String? { if contains(key) { if let s = try? decode(String.self, forKey: key) { return s }; if let i = try? decode(Int.self, forKey: key) { return String(i) } }; return nil }
    func flexInt(forKey key: Key) throws -> String { if let i = try? decode(Int.self, forKey: key) { return String(i) }; if let s = try? decode(String.self, forKey: key) { return s }; return "" }
    func flexIntIfPresent(forKey key: Key) throws -> String? { if contains(key) { if let i = try? decode(Int.self, forKey: key) { return String(i) }; if let s = try? decode(String.self, forKey: key) { return s } }; return nil }
}

struct Stream: Decodable {
    let name: String; let stream_id: String; let stream_icon: String?; let epg_channel_id: String?; let category_id: String?; let tv_archive: String?; let tv_archive_duration: String?
    enum CK: String, CodingKey { case name, stream_id, stream_icon, epg_channel_id, category_id, tv_archive, tv_archive_duration }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CK.self)
        stream_id = try c.flexInt(forKey: .stream_id); name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
        stream_icon = try c.decodeIfPresent(String.self, forKey: .stream_icon); epg_channel_id = try c.decodeIfPresent(String.self, forKey: .epg_channel_id)
        category_id = try c.flexStringIfPresent(forKey: .category_id); tv_archive = try c.flexIntIfPresent(forKey: .tv_archive); tv_archive_duration = try c.flexIntIfPresent(forKey: .tv_archive_duration)
    }
}

func parse(data: Data, catMap: [String:String], sb: URL) -> [Channel] {
    let streams = try! JSONDecoder().decode([Stream].self, from: data)
    var out: [Channel] = []; out.reserveCapacity(streams.count); let b = sb.absoluteString
    for s in streams {
        guard let u = URL(string: "\(b)/\(s.stream_id).m3u8") else { continue }
        let cc: CatchupInfo? = s.tv_archive == "1" ? CatchupInfo(kind: .xc, days: max(Int(s.tv_archive_duration ?? "") ?? 0, 1), source: nil) : nil
        out.append(Channel(id: s.stream_id, name: s.name, logoURL: s.stream_icon.flatMap(URL.init), group: s.category_id.flatMap{catMap[$0]} ?? "Uncategorized", streamURL: u, epgChannelID: s.epg_channel_id, catchup: cc))
    }
    return out
}

func gen(count: Int) -> Data {
    var arr = [[String:Any]]()
    for i in 0..<count { let a = i%3==0; arr.append(["num":i+1,"name":"CH \(i)","stream_id":1000+i,"stream_icon":"https://x.com/\(i).png","epg_channel_id":"epg-\(i)","category_id":String((i%20)+1),"tv_archive":a ? 1 : 0,"tv_archive_duration":a ? 7 : 0]) }
    return try! JSONSerialization.data(withJSONObject: arr)
}

let count = 5000; let iters = 100
var catMap: [String:String] = [:]; for i in 1...20 { catMap[String(i)] = "Category \(i)" }
let sb = URL(string: "http://x.com/live/u/p")!
let data = gen(count: count)

_ = parse(data: data, catMap: catMap, sb: sb); usleep(100000)
var total: Double = 0
for _ in 0..<iters { let t = CFAbsoluteTimeGetCurrent(); _ = parse(data: data, catMap: catMap, sb: sb).count; total += CFAbsoluteTimeGetCurrent() - t }
let avg = Int(total / Double(iters) * 1_000_000)
print("count=\(count) iters=\(iters) result=\(parse(data:data,catMap:catMap,sb:sb).count)")
print("parse_µs: \(avg)")
print("METRIC parse_µs=\(avg)")
