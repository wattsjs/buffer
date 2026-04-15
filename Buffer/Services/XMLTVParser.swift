import Foundation
import SwiftLibxml2

/// XMLTV parser built directly on libxml2's push SAX API. NSXMLParser was
/// spending ~80% of sync time in its Obj-C callback trampolines on large
/// guide files (see trace 2026-04-14). Driving libxml2 directly and keeping
/// the entire parse loop in Swift eliminates that overhead.
nonisolated struct XMLTVParser {
    static func parse(from url: URL) async throws -> [EPGProgram] {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (fetched, _) = try await URLSession.shared.data(from: url)
            data = fetched
        }
        return await Task.detached(priority: .userInitiated) {
            parse(data: data)
        }.value
    }

    static func parse(data: Data) -> [EPGProgram] {
        let context = XMLTVSAXContext()
        let ctxPtr = Unmanaged.passUnretained(context).toOpaque()
        var sax = makeSAXHandler()

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard raw.count > 0, let base = raw.baseAddress else { return }
            let chars = base.assumingMemoryBound(to: CChar.self)

            withUnsafeMutablePointer(to: &sax) { saxPtr in
                // Seed the push parser with the first slice — libxml2 needs at
                // least a few bytes up front to sniff the encoding, and giving
                // it the whole buffer in one shot is both legal and cheapest.
                let seedLen = Int32(min(raw.count, Int(Int32.max)))
                guard let parserCtxt = xmlCreatePushParserCtxt(
                    saxPtr,
                    ctxPtr,
                    chars,
                    seedLen,
                    nil
                ) else { return }
                defer { xmlFreeParserCtxt(parserCtxt) }

                let options = kXMLParseRecover
                    | kXMLParseNoError
                    | kXMLParseNoWarning
                    | kXMLParseNoNet
                _ = xmlCtxtUseOptions(parserCtxt, options)

                _ = xmlParseChunk(parserCtxt, nil, 0, 1)
            }
        }

        return context.programs
    }
}

// MARK: - libxml2 parser options (subset we care about)
//
// Hardcoded rather than imported from the xmlParserOption enum so this file
// stays decoupled from however the ClangImporter decides to surface that
// particular C enum. These bit values are stable across libxml2 versions.

nonisolated private let kXMLParseRecover: Int32   = 1 << 0
nonisolated private let kXMLParseNoError: Int32   = 1 << 5
nonisolated private let kXMLParseNoWarning: Int32 = 1 << 6
nonisolated private let kXMLParseNoNet: Int32     = 1 << 11

// MARK: - SAX handler

nonisolated private func makeSAXHandler() -> xmlSAXHandler {
    var sax = xmlSAXHandler()
    sax.initialized = XML_SAX2_MAGIC

    sax.startElementNs = { ctx, localname, _, _, _, _, nbAttributes, _, attributes in
        guard let ctx, let localname else { return }
        Unmanaged<XMLTVSAXContext>.fromOpaque(ctx)
            .takeUnretainedValue()
            .startElement(
                localname: localname,
                nbAttributes: Int(nbAttributes),
                attributes: attributes
            )
    }

    sax.endElementNs = { ctx, localname, _, _ in
        guard let ctx, let localname else { return }
        Unmanaged<XMLTVSAXContext>.fromOpaque(ctx)
            .takeUnretainedValue()
            .endElement(localname: localname)
    }

    sax.characters = { ctx, ch, len in
        guard let ctx, let ch, len > 0 else { return }
        Unmanaged<XMLTVSAXContext>.fromOpaque(ctx)
            .takeUnretainedValue()
            .characters(ch: ch, length: Int(len))
    }

    return sax
}

// MARK: - Parser state

nonisolated private final class XMLTVSAXContext: @unchecked Sendable {
    var programs: [EPGProgram] = []

    private var inProgramme = false
    private var currentChannelID = ""
    private var currentStart: Date?
    private var currentEnd: Date?

    private enum Field { case none, title, desc }
    private var field: Field = .none
    private var titleBytes: [UInt8] = []
    private var descBytes: [UInt8] = []

    init() {
        programs.reserveCapacity(4096)
        titleBytes.reserveCapacity(128)
        descBytes.reserveCapacity(512)
    }

    func startElement(
        localname: UnsafePointer<xmlChar>,
        nbAttributes: Int,
        attributes: UnsafePointer<UnsafePointer<xmlChar>?>?
    ) {
        if cstrEquals(localname, "programme") {
            inProgramme = true
            currentChannelID = ""
            currentStart = nil
            currentEnd = nil
            field = .none
            titleBytes.removeAll(keepingCapacity: true)
            descBytes.removeAll(keepingCapacity: true)

            guard let attributes, nbAttributes > 0 else { return }

            // SAX2 attribute layout: 5 entries per attribute —
            // (localname, prefix, URI, value_start, value_end).
            for i in 0..<nbAttributes {
                let base = i * 5
                guard let keyPtr = attributes[base],
                      let valStart = attributes[base + 3],
                      let valEnd = attributes[base + 4] else { continue }
                let valLen = valEnd - valStart
                if valLen <= 0 { continue }

                if cstrEquals(keyPtr, "channel") {
                    currentChannelID = decodeUTF8(valStart, length: valLen)
                } else if cstrEquals(keyPtr, "start") {
                    currentStart = parseXMLTVDate(valStart, length: valLen)
                } else if cstrEquals(keyPtr, "stop") {
                    currentEnd = parseXMLTVDate(valStart, length: valLen)
                }
            }
            return
        }

        guard inProgramme else { return }
        if cstrEquals(localname, "title") {
            field = .title
        } else if cstrEquals(localname, "desc") {
            field = .desc
        } else {
            field = .none
        }
    }

    func endElement(localname: UnsafePointer<xmlChar>) {
        if cstrEquals(localname, "programme") {
            defer {
                inProgramme = false
                field = .none
            }
            guard let start = currentStart, let end = currentEnd else { return }
            let title = trimmedUTF8String(titleBytes)
            let desc = trimmedUTF8String(descBytes)
            programs.append(
                EPGProgram(
                    id: "\(currentChannelID)_\(Int(start.timeIntervalSince1970))",
                    channelID: currentChannelID,
                    title: title,
                    description: desc,
                    start: start,
                    end: end
                )
            )
            return
        }
        if inProgramme {
            field = .none
        }
    }

    func characters(ch: UnsafePointer<xmlChar>, length: Int) {
        switch field {
        case .title:
            titleBytes.append(contentsOf: UnsafeBufferPointer(start: ch, count: length))
        case .desc:
            descBytes.append(contentsOf: UnsafeBufferPointer(start: ch, count: length))
        case .none:
            break
        }
    }
}

// MARK: - Helpers

@inline(__always)
nonisolated private func cstrEquals(_ a: UnsafePointer<xmlChar>, _ b: StaticString) -> Bool {
    let bLen = b.utf8CodeUnitCount
    let bPtr = b.utf8Start
    for i in 0..<bLen {
        if a[i] != bPtr[i] { return false }
    }
    return a[bLen] == 0
}

@inline(__always)
nonisolated private func decodeUTF8(_ ptr: UnsafePointer<xmlChar>, length: Int) -> String {
    String(decoding: UnsafeBufferPointer(start: ptr, count: length), as: UTF8.self)
}

@inline(__always)
nonisolated private func isASCIIWhitespace(_ b: xmlChar) -> Bool {
    b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
}

@inline(__always)
nonisolated private func trimmedUTF8String(_ bytes: [xmlChar]) -> String {
    var start = 0
    var end = bytes.count
    while start < end && isASCIIWhitespace(bytes[start]) { start += 1 }
    while end > start && isASCIIWhitespace(bytes[end - 1]) { end -= 1 }
    if start == end { return "" }
    return bytes.withUnsafeBufferPointer { buf in
        guard let base = buf.baseAddress else { return "" }
        return String(
            decoding: UnsafeBufferPointer(start: base + start, count: end - start),
            as: UTF8.self
        )
    }
}

/// Parse an XMLTV timestamp like `20240114193000 +0000` (or the same without
/// an offset — treated as UTC) straight out of its raw byte slice. An order
/// of magnitude faster than DateFormatter and allocation-free.
@inline(__always)
nonisolated private func parseXMLTVDate(_ ptr: UnsafePointer<xmlChar>, length: Int) -> Date? {
    guard length >= 14 else { return nil }

    // Validate the leading 14 digits.
    for i in 0..<14 {
        let c = ptr[i]
        if c < 0x30 || c > 0x39 { return nil }
    }

    @inline(__always) func d(_ i: Int) -> Int { Int(ptr[i]) - 0x30 }
    @inline(__always) func d2(_ i: Int) -> Int { d(i) * 10 + d(i + 1) }

    let year   = d(0) * 1000 + d(1) * 100 + d(2) * 10 + d(3)
    let month  = d2(4)
    let day    = d2(6)
    let hour   = d2(8)
    let minute = d2(10)
    let second = d2(12)

    guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }

    // Optional " ±HHMM" offset (skip at most one leading space).
    var tzSeconds = 0
    var p = 14
    if p < length, ptr[p] == 0x20 { p += 1 }
    if p + 5 <= length {
        let signByte = ptr[p]
        if signByte == 0x2B || signByte == 0x2D {
            for i in (p + 1)..<(p + 5) {
                let c = ptr[i]
                if c < 0x30 || c > 0x39 { return nil }
            }
            let sign = signByte == 0x2D ? -1 : 1
            let tzH = Int(ptr[p + 1] - 0x30) * 10 + Int(ptr[p + 2] - 0x30)
            let tzM = Int(ptr[p + 3] - 0x30) * 10 + Int(ptr[p + 4] - 0x30)
            tzSeconds = sign * (tzH * 3600 + tzM * 60)
        }
    }

    // Howard Hinnant days-from-civil — converts a proleptic Gregorian date
    // to days since 1970-01-01 in O(1) with no lookup tables.
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let m = month + (month > 2 ? -3 : 9)
    let doy = (153 * m + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let daysSinceEpoch = era * 146097 + doe - 719468

    let epoch = daysSinceEpoch * 86400
        + hour * 3600
        + minute * 60
        + second
        - tzSeconds
    return Date(timeIntervalSince1970: TimeInterval(epoch))
}
