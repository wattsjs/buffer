#!/usr/bin/env swift

// Benchmark: XMLTV EPG parsing — libxml2 SAX vs optimized approaches
// Link against libxml2: swiftc -I/usr/include/libxml2 -lxml2 bench.swift

import Foundation

// Bridge libxml2 types
typealias xmlChar = UInt8

// MARK: - SAX context (replicates XMLTVParser.XMLTVSAXContext)

final class Ctx {
    var count = 0
    var inProgramme = false
    var channelID = ""
    var startDate: Double = 0
    var endDate: Double = 0
    enum Field { case none, title, desc }
    var field: Field = .none
    var titleBuf = ContiguousArray<UInt8>()
    var descBuf = ContiguousArray<UInt8>()

    init() {
        titleBuf.reserveCapacity(128)
        descBuf.reserveCapacity(512)
    }
}

// MARK: - memcmp-based cstrEquals

@inline(__always)
func cstrEq(_ a: UnsafePointer<xmlChar>, _ s: StaticString) -> Bool {
    let len = s.utf8CodeUnitCount
    return memcmp(a, s.utf8Start, len) == 0 && a[len] == 0
}

@inline(__always)
func isWS(_ b: xmlChar) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

func trimmedStr(_ bytes: ContiguousArray<UInt8>) -> String {
    var s = 0; var e = bytes.count
    while s < e && isWS(bytes[s]) { s += 1 }
    while e > s && isWS(bytes[e - 1]) { e -= 1 }
    if s == e { return "" }
    return bytes.withUnsafeBufferPointer { String(decoding: $0[s..<e], as: UTF8.self) }
}

// MARK: - Approach A: Current (loop attributes, byte-by-byte cstrEquals)

func parseA(path: String) -> Int {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    let ctx = Ctx()
    let ctxPtr = Unmanaged.passUnretained(ctx).toOpaque()

    return data.withUnsafeBytes { raw in
        guard raw.count > 0, let base = raw.baseAddress else { return 0 }
        let chars = base.assumingMemoryBound(to: CChar.self)

        // Build SAX handler
        var sax = xmlSAXHandler()
        sax.initialized = XML_SAX2_MAGIC

        sax.startElementNs = { ctxPtr, localname, _, _, _, _, nbAttributes, _, attributes in
            guard let ctxPtr, let localname else { return }
            let c = Unmanaged<Ctx>.fromOpaque(ctxPtr).takeUnretainedValue()

            // Byte-by-byte compare for "programme"
            let p: StaticString = "programme"
            let plen = p.utf8CodeUnitCount
            let pp = p.utf8Start
            var isProg = true
            for i in 0..<plen { if localname[i] != pp[i] { isProg = false; break } }
            if isProg && localname[plen] == 0 {
                c.inProgramme = true; c.channelID = ""; c.startDate = 0; c.endDate = 0
                c.field = .none; c.titleBuf.removeAll(keepingCapacity: true); c.descBuf.removeAll(keepingCapacity: true)

                // Loop attributes
                guard let attributes, nbAttributes > 0 else { return }
                let n = Int(nbAttributes)
                for i in 0..<n {
                    let bi = i * 5
                    guard let kp = attributes[bi], let vs = attributes[bi + 3], let ve = attributes[bi + 4], ve > vs else { continue }
                    let vlen = ve - vs

                    // Check key: "channel", "start", "stop"
                    let ch: StaticString = "channel"
                    if memcmp(kp, ch.utf8Start, 7) == 0 && kp[7] == 0 {
                        c.channelID = String(decoding: UnsafeBufferPointer(start: vs, count: vlen), as: UTF8.self)
                    } else {
                        let st: StaticString = "start"
                        if memcmp(kp, st.utf8Start, 5) == 0 && kp[5] == 0 {
                            c.startDate = parseDate(vs, vlen)
                        } else {
                            let sp: StaticString = "stop"
                            if memcmp(kp, sp.utf8Start, 4) == 0 && kp[4] == 0 {
                                c.endDate = parseDate(vs, vlen)
                            }
                        }
                    }
                }
                return
            }

            guard c.inProgramme else { return }
            let t: StaticString = "title"
            if memcmp(localname, t.utf8Start, 5) == 0 && localname[5] == 0 { c.field = .title; return }
            let d: StaticString = "desc"
            if memcmp(localname, d.utf8Start, 4) == 0 && localname[4] == 0 { c.field = .desc; return }
            c.field = .none
        }

        sax.endElementNs = { ctxPtr, localname, _, _ in
            guard let ctxPtr, let localname else { return }
            let c = Unmanaged<Ctx>.fromOpaque(ctxPtr).takeUnretainedValue()
            let p: StaticString = "programme"
            if memcmp(localname, p.utf8Start, 9) == 0 && localname[9] == 0 {
                defer { c.inProgramme = false; c.field = .none }
                if c.startDate > 0 && c.endDate > 0 {
                    c.count += 1
                    _ = trimmedStr(c.titleBuf)
                    _ = trimmedStr(c.descBuf)
                }
                return
            }
            if c.inProgramme { c.field = .none }
        }

        sax.characters = { ctxPtr, ch, len in
            guard let ctxPtr, let ch, len > 0 else { return }
            let c = Unmanaged<Ctx>.fromOpaque(ctxPtr).takeUnretainedValue()
            switch c.field {
            case .title: c.titleBuf.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(len)))
            case .desc: c.descBuf.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(len)))
            case .none: break
            }
        }

        var saxCopy = sax
        let seedLen = Int32(min(raw.count, Int(Int32.max)))
        guard let pc = xmlCreatePushParserCtxt(&saxCopy, ctxPtr, chars, seedLen, nil) else { return 0 }
        defer { xmlFreeParserCtxt(pc) }
        let opts: Int32 = 1 | (1<<5) | (1<<6) | (1<<11)
        xmlCtxtUseOptions(pc, opts)
        xmlParseChunk(pc, nil, 0, 1)
        return ctx.count
    }
}

// MARK: - Approach B: Optimized (direct attribute indexing, memcmp elements)

func parseB(path: String) -> Int {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    let ctx = Ctx()
    let ctxPtr = Unmanaged.passUnretained(ctx).toOpaque()

    return data.withUnsafeBytes { raw in
        guard raw.count > 0, let base = raw.baseAddress else { return 0 }
        let chars = base.assumingMemoryBound(to: CChar.self)

        var sax = xmlSAXHandler()
        sax.initialized = XML_SAX2_MAGIC

        // Pre-compute StaticString pointers for fast comparison
        let progPtr: StaticString = "programme"
        let titlePtr: StaticString = "title"
        let descPtr: StaticString = "desc"

        sax.startElementNs = { ctxPtr, localname, _, _, _, _, nbAttributes, _, attributes in
            guard let ctxPtr, let localname else { return }
            let c = Unmanaged<Ctx>.fromOpaque(ctxPtr).takeUnretainedValue()

            // memcmp-based element matching
            if memcmp(localname, progPtr.utf8Start, 9) == 0 && localname[9] == 0 {
                c.inProgramme = true; c.channelID = ""; c.startDate = 0; c.endDate = 0
                c.field = .none; c.titleBuf.removeAll(keepingCapacity: true); c.descBuf.removeAll(keepingCapacity: true)

                // Direct attribute indexing (order: start, stop, channel)
                guard let attributes, nbAttributes >= 3 else { return }
                let sVal = attributes[3], sEnd = attributes[4]
                let pVal = attributes[8], pEnd = attributes[9]
                let cVal = attributes[13], cEnd = attributes[14]
                if let vs = sVal, let ve = sEnd, ve > vs { c.startDate = parseDate(vs, ve - vs) }
                if let vs = pVal, let ve = pEnd, ve > vs { c.endDate = parseDate(vs, ve - vs) }
                if let vs = cVal, let ve = cEnd, ve > vs { c.channelID = String(decoding: UnsafeBufferPointer(start: vs, count: ve - vs), as: UTF8.self) }
                return
            }

            guard c.inProgramme else { return }
            if memcmp(localname, titlePtr.utf8Start, 5) == 0 && localname[5] == 0 { c.field = .title; return }
            if memcmp(localname, descPtr.utf8Start, 4) == 0 && localname[4] == 0 { c.field = .desc; return }
            c.field = .none
        }

        sax.endElementNs = { ctxPtr, localname, _, _ in
            guard let ctxPtr, let localname else { return }
            let c = Unmanaged<Ctx>.fromOpaque(ctxPtr).takeUnretainedValue()
            if memcmp(localname, progPtr.utf8Start, 9) == 0 && localname[9] == 0 {
                defer { c.inProgramme = false; c.field = .none }
                if c.startDate > 0 && c.endDate > 0 { c.count += 1; _ = trimmedStr(c.titleBuf); _ = trimmedStr(c.descBuf) }
                return
            }
            if c.inProgramme { c.field = .none }
        }

        sax.characters = { ctxPtr, ch, len in
            guard let ctxPtr, let ch, len > 0 else { return }
            let c = Unmanaged<Ctx>.fromOpaque(ctxPtr).takeUnretainedValue()
            switch c.field {
            case .title: c.titleBuf.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(len)))
            case .desc: c.descBuf.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(len)))
            case .none: break
            }
        }

        var saxCopy = sax
        let seedLen = Int32(min(raw.count, Int(Int32.max)))
        guard let pc = xmlCreatePushParserCtxt(&saxCopy, ctxPtr, chars, seedLen, nil) else { return 0 }
        defer { xmlFreeParserCtxt(pc) }
        let opts: Int32 = 1 | (1<<5) | (1<<6) | (1<<11)
        xmlCtxtUseOptions(pc, opts)
        xmlParseChunk(pc, nil, 0, 1)
        return ctx.count
    }
}

// MARK: - Date parser (replicates parseXMLTVDate)

@inline(__always)
func parseDate(_ ptr: UnsafePointer<xmlChar>, _ length: Int) -> Double {
    guard length >= 14 else { return 0 }
    for i in 0..<14 { if ptr[i] < 0x30 || ptr[i] > 0x39 { return 0 } }
    func d(_ i: Int) -> Int { Int(ptr[i]) - 0x30 }
    func d2(_ i: Int) -> Int { d(i) * 10 + d(i+1) }
    let yr = d(0)*1000 + d(1)*100 + d(2)*10 + d(3)
    let mo = d2(4); let da = d2(6); let hr = d2(8); let mi = d2(10); let se = d2(12)
    guard mo >= 1 && mo <= 12 && da >= 1 && da <= 31 else { return 0 }

    var tz = 0; var p = 14
    if p < length, ptr[p] == 0x20 { p += 1 }
    if p + 5 <= length {
        let sb = ptr[p]
        if sb == 0x2B || sb == 0x2D {
            for i in (p+1)..<(p+5) { if ptr[i] < 0x30 || ptr[i] > 0x39 { return 0 } }
            let sign = sb == 0x2D ? -1 : 1
            tz = sign * ((Int(ptr[p+1])-0x30)*10 + Int(ptr[p+2])-0x30) * 3600
            tz += sign * ((Int(ptr[p+3])-0x30)*10 + Int(ptr[p+4])-0x30) * 60
        }
    }

    let y = mo <= 2 ? yr - 1 : yr
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let m = mo + (mo > 2 ? -3 : 9)
    let doy = (153*m + 2)/5 + da - 1
    let doe = yoe*365 + yoe/4 - yoe/100 + doy
    let days = era*146097 + doe - 719468
    return Double(days*86400 + hr*3600 + mi*60 + se - tz)
}

// MARK: - Benchmark

let path = "/tmp/xtream_epg.xml"
let fileSize = Double(try! Data(contentsOf: URL(fileURLWithPath: path)).count) / 1_000_000

// Quick verify both produce same count
let countA = parseA(path: path)
let countB = parseB(path: path)
print("File: \(String(format: "%.1f", fileSize)) MB")
print("Approach A count: \(countA)")
print("Approach B count: \(countB)")
guard countA == countB else { print("COUNT MISMATCH!"); exit(1) }

// Run benchmarks
let iters = 3
var tA = 0.0; var tB = 0.0
for _ in 0..<iters {
    let t0 = CFAbsoluteTimeGetCurrent()
    _ = parseA(path: path)
    tA += CFAbsoluteTimeGetCurrent() - t0
    let t1 = CFAbsoluteTimeGetCurrent()
    _ = parseB(path: path)
    tB += CFAbsoluteTimeGetCurrent() - t1
}
let msA = tA / Double(iters) * 1000
let msB = tB / Double(iters) * 1000
print("")
print("A (current style):     \(String(format: "%.0f", msA)) ms")
print("B (optimized):         \(String(format: "%.0f", msB)) ms")
print("speedup: \(String(format: "%.1f", msA/msB))x")
print("")
print("METRIC parse_µs=\(Int(msB * 1000))")
print("METRIC current_ms=\(Int(msA))")
print("METRIC optimized_ms=\(Int(msB))")
