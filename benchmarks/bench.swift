#!/usr/bin/env swift

// Benchmark: Specialized Xtream scanner vs JSONDecoder

import Foundation

struct CatchupInfo: Hashable {
    enum Kind: String { case xc }; let kind: Kind; let days: Int; let source: String?
}
struct Channel {
    let id: String; let name: String; let logoURL: URL?; let group: String
    let streamURL: URL; let epgChannelID: String?
    let catchup: CatchupInfo?
}

// MARK: - JSONDecoder (current)
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
}
struct Stream: Decodable {
    let name: String; let stream_id: String; let stream_icon: String?
    let epg_channel_id: String?; let category_id: String?; let tv_archive: String?; let tv_archive_duration: String?
    enum CodingKeys: String, CodingKey {
        case name, stream_id, stream_icon, epg_channel_id, category_id, tv_archive, tv_archive_duration
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        stream_id = try c.flexInt(forKey: .stream_id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
        stream_icon = try c.decodeIfPresent(String.self, forKey: .stream_icon)
        epg_channel_id = try c.decodeIfPresent(String.self, forKey: .epg_channel_id)
        category_id = try c.flexIntIfPresent(forKey: .category_id)
        tv_archive = try c.flexIntIfPresent(forKey: .tv_archive)
        tv_archive_duration = try c.flexIntIfPresent(forKey: .tv_archive_duration)
    }
}

func parseDecoder(data: Data, catMap: [String: String], sb: URL) -> [Channel] {
    let streams = try! JSONDecoder().decode([Stream].self, from: data)
    var out: [Channel] = []; out.reserveCapacity(streams.count)
    let b = sb.absoluteString
    for s in streams {
        guard let u = URL(string: "\(b)/\(s.stream_id).m3u8") else { continue }
        let cc: CatchupInfo? = s.tv_archive == "1" ? CatchupInfo(kind: .xc, days: max(Int(s.tv_archive_duration ?? "") ?? 0, 1), source: nil) : nil
        out.append(Channel(id: s.stream_id, name: s.name, logoURL: s.stream_icon.flatMap(URL.init), group: s.category_id.flatMap{catMap[$0]} ?? "Uncategorized", streamURL: u, epgChannelID: s.epg_channel_id, catchup: cc))
    }
    return out
}

// MARK: - Specialized scanner
func parseScanner(data: Data, catMap: [String: String], sb: URL) -> [Channel] {
    return data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress, raw.count > 0 else { return [] }
        let buf = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: raw.count)
        var p = 0; let end = raw.count
        let bstr = sb.absoluteString

        @inline(__always) func skipWS() { while p < end { let b = buf[p]; if b != 0x20 && b != 0x09 && b != 0x0A && b != 0x0D { break }; p += 1 } }
        @inline(__always) func readStr() -> String? {
            guard p < end, buf[p] == 0x22 else { return nil }
            p += 1; let s = p
            while p < end, buf[p] != 0x22 { p += 1 }
            let r = String(decoding: buf[s..<p], as: UTF8.self)
            if p < end { p += 1 }; return r
        }
        @inline(__always) func readNum() -> String? {
            let s = p
            while p < end { let b = buf[p]; if b >= 0x30 && b <= 0x39 { p += 1 } else { break } }
            return p > s ? String(decoding: buf[s..<p], as: UTF8.self) : nil
        }
        @inline(__always) func readVal() -> String? {
            skipWS(); guard p < end else { return nil }
            if buf[p] == 0x22 { return readStr() }
            if buf[p] == 0x6E { p += 4; return nil }
            return readNum()
        }
        @inline(__always) func skipVal() {
            skipWS(); guard p < end else { return }
            let b = buf[p]
            if b == 0x22 { p += 1; while p < end, buf[p] != 0x22 { p += 1 }; if p < end { p += 1 } }
            else if b == 0x6E { p += 4 }
            else if b == 0x7B { var d = 1; p += 1; while p < end, d > 0 { if buf[p] == 0x7B { d += 1 } else if buf[p] == 0x7D { d -= 1 }; p += 1 } }
            else if b == 0x5B { var d = 1; p += 1; while p < end, d > 0 { if buf[p] == 0x5B { d += 1 } else if buf[p] == 0x5D { d -= 1 }; p += 1 } }
            else { while p < end { let b = buf[p]; if b >= 0x30 && b <= 0x39 { p += 1 } else { break } } }
        }

        /// Match key by first char + length. Returns 0-6 for known keys, 7 for unknown.
        @inline(__always) func keyCode(_ ch: UInt8, _ len: Int) -> Int {
            switch ch {
            case 0x73: return len == 9 ? 0 : len == 11 ? 2 : 7   // stream_id(0), stream_icon(2)
            case 0x6E: return len == 4 ? 1 : 7                     // name(1)
            case 0x63: return len == 11 ? 3 : 7                    // category_id(3)
            case 0x65: return len == 14 ? 4 : 7                    // epg_channel_id(4)
            case 0x74: return len == 10 ? 5 : len == 20 ? 6 : 7    // tv_archive(5), tv_archive_duration(6)
            default: return 7
            }
        }

        skipWS(); guard p < end, buf[p] == 0x5B else { return [] }; p += 1
        var out: [Channel] = []; out.reserveCapacity(2048)

        while p < end {
            skipWS(); if p >= end { break }
            if buf[p] == 0x5D { p += 1; break }
            if buf[p] == 0x2C { p += 1; continue }
            guard buf[p] == 0x7B else { p += 1; continue }
            p += 1 // enter object

            var fields: [String?] = ["", "Unknown", nil, nil, nil, nil, nil] // stream_id, name, icon, cat, epg, archive, duration

            while p < end {
                skipWS(); if p >= end { break }
                if buf[p] == 0x7D { p += 1; break }
                if buf[p] == 0x2C { p += 1; continue }
                guard buf[p] == 0x22 else { p += 1; continue }
                p += 1; let ks = p
                while p < end, buf[p] != 0x22 { p += 1 }
                let kLen = p - ks; if p < end { p += 1 }
                skipWS(); if p < end, buf[p] == 0x3A { p += 1 }

                let kc = keyCode(buf[ks], kLen)
                if kc < 7 { fields[kc] = readVal() }
                else { skipVal() }
            }

            guard let sid = fields[0], !sid.isEmpty, let u = URL(string: "\(bstr)/\(sid).m3u8") else { continue }
            let cat = fields[3].flatMap { catMap[$0] } ?? "Uncategorized"
            let cc: CatchupInfo? = fields[5] == "1" ? CatchupInfo(kind: .xc, days: max(Int(fields[6] ?? "") ?? 0, 1), source: nil) : nil
            out.append(Channel(id: sid, name: fields[1]!, logoURL: fields[2].flatMap(URL.init), group: cat, streamURL: u, epgChannelID: fields[4], catchup: cc))
        }
        return out
    }
}

// MARK: - Generate
func gen(_ count: Int) -> Data {
    var arr = [[String:Any]]()
    for i in 0..<count {
        let a = i%3==0
        arr.append(["num":i+1,"name":"Channel \(i) HD","stream_id":1000+i,"stream_icon":"https://x.com/\(i).png","epg_channel_id":"epg-\(i).x.com","category_id":(i%20)+1,"tv_archive":a ? 1 : 0,"tv_archive_duration":a ? 7 : 0])
    }
    return try! JSONSerialization.data(withJSONObject: arr)
}

// MARK: - Run
let count = 5000; let iters = 50
var catMap: [String:String] = [:]; for i in 1...20 { catMap[String(i)] = "Category \(i)" }
let sb = URL(string: "http://x.com/live/u/p")!
let data = gen(count)

// Verify
let refCh = parseDecoder(data: data, catMap: catMap, sb: sb)
let scnCh = parseScanner(data: data, catMap: catMap, sb: sb)
guard refCh.count == scnCh.count, refCh.map(\.id) == scnCh.map(\.id) else {
    print("MISMATCH: ref=\(refCh.count) scn=\(scnCh.count)")
    for i in 0..<min(refCh.count, scnCh.count) where refCh[i].id != scnCh[i].id {
        print("  [\(i)] ref=\(refCh[i].id) scn=\(scnCh[i].id)")
    }
    exit(1)
}

// Warmup
_ = parseDecoder(data: data, catMap: catMap, sb: sb)
_ = parseScanner(data: data, catMap: catMap, sb: sb)
usleep(100000)

var tDec: Double = 0; var tScn: Double = 0
for _ in 0..<iters {
    let t0 = CFAbsoluteTimeGetCurrent()
    let r1 = parseDecoder(data: data, catMap: catMap, sb: sb)
    tDec += CFAbsoluteTimeGetCurrent() - t0; _ = r1.count
    let t1 = CFAbsoluteTimeGetCurrent()
    let r2 = parseScanner(data: data, catMap: catMap, sb: sb)
    tScn += CFAbsoluteTimeGetCurrent() - t1; _ = r2.count
}

let aDec = tDec / Double(iters) * 1_000_000
let aScn = tScn / Double(iters) * 1_000_000
print("count=\(count) iters=\(iters)")
print("decoder:     \(Int(aDec)) µs")
print("specialized: \(Int(aScn)) µs")
print("match=true")
print("METRIC parse_µs=\(Int(min(aDec, aScn)))")
print("METRIC decoder_µs=\(Int(aDec))")
print("METRIC specialized_µs=\(Int(aScn))")
