import Foundation
import OSLog
import SwiftLibxml2

/// XMLTV parser built directly on libxml2's push SAX API. NSXMLParser was
/// spending ~80% of sync time in its Obj-C callback trampolines on large
/// guide files (see trace 2026-04-14). Driving libxml2 directly and keeping
/// the entire parse loop in Swift eliminates that overhead.
nonisolated struct XMLTVParser {
    static func parse(from url: URL) async throws -> [EPGProgram] {
        // Perform local file reads inside the detached task (Agent 03) so
        // large XMLTV guides never block the main thread on import/switch.
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let fetchStarted = ContinuousClock.now
            guard url.isFileURL else {
                // Remote guides parse while they download; parse time is
                // hidden behind the transfer instead of following it.
                let result = try await StreamingGuideParse.run(url: url, configuration: guideSessionConfiguration)
                try Task.checkCancellation()
                let totalMs = AppLog.elapsedMilliseconds(since: fetchStarted)
                PerfMetrics.shared.record("guide.xmltv.fetchAndParseMs", Double(totalMs))
                PerfMetrics.shared.record("guide.xmltv.firstByteMs", Double(result.firstByteMs))
                PerfMetrics.shared.record("guide.xmltv.parseCpuMs", Double(result.parseMs))
                AppLog.sync.info("XMLTV loaded bytes=\(result.bytes, privacy: .public) fetchMs=\(totalMs, privacy: .public) parseMs=\(result.parseMs, privacy: .public) firstByteMs=\(result.firstByteMs, privacy: .public) tailParseMs=\(result.tailParseMs, privacy: .public) streamed=true programs=\(result.programs.count, privacy: .public)")
                return result.programs
            }
            let data = try Data(contentsOf: url)
            try Task.checkCancellation()
            let fetchMs = AppLog.elapsedMilliseconds(since: fetchStarted)
            let parseStarted = ContinuousClock.now
            let programs = parseData(data, cancellationEnabled: true)
            try Task.checkCancellation()
            AppLog.sync.info("XMLTV loaded bytes=\(data.count, privacy: .public) fetchMs=\(fetchMs, privacy: .public) parseMs=\(AppLog.elapsedMilliseconds(since: parseStarted), privacy: .public) programs=\(programs.count, privacy: .public)")
            return programs
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    static func parse(data: Data) -> [EPGProgram] {
        parseData(data, cancellationEnabled: false)
    }

    private static func parseData(_ data: Data, cancellationEnabled: Bool) -> [EPGProgram] {
        let context = XMLTVSAXContext(initialCapacity: min(data.count / 256, 524288))
        let ctxPtr = Unmanaged.passUnretained(context).toOpaque()
        var sax = saxHandler

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard raw.count > 0, let base = raw.baseAddress else { return }
            let chars = base.assumingMemoryBound(to: CChar.self)

            withUnsafeMutablePointer(to: &sax) { saxPtr in
                // Async imports use bounded slices so a source switch can
                // stop CPU work as well as its network request. Synchronous
                // callers keep the existing single-buffer fast path.
                let chunkSize = cancellationEnabled ? 64 * 1024 : Int(Int32.max)
                let seedLen = Int32(min(raw.count, chunkSize))
                guard !cancellationEnabled || !Task.isCancelled else { return }
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

                var offset = Int(seedLen)
                while offset < raw.count {
                    guard !cancellationEnabled || !Task.isCancelled else { return }
                    let length = min(raw.count - offset, chunkSize)
                    _ = xmlParseChunk(parserCtxt, chars.advanced(by: offset), Int32(length), 0)
                    offset += length
                }
                guard !cancellationEnabled || !Task.isCancelled else { return }
                _ = xmlParseChunk(parserCtxt, nil, 0, 1)
            }
        }

        return context.programs
    }
}

private extension XMLTVParser {
    static var guideSessionConfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 180
        return config
    }
}

/// Feeds each received network chunk straight into a libxml2 push parser on
/// the session's serial delegate queue. Produces the same programmes as
/// buffering the whole document and parsing it afterwards.
nonisolated private final class StreamingGuideParse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result: Sendable {
        let programs: [EPGProgram]
        let bytes: Int
        let firstByteMs: Int
        let parseMs: Int
        let tailParseMs: Int
    }

    private let started = ContinuousClock.now
    private let context = XMLTVSAXContext(initialCapacity: 65_536)
    private var parser: xmlParserCtxtPtr?
    private var bytes = 0
    private var firstByteMs = -1
    private var parseDuration: Duration = .zero
    private var failure: Error?
    private var continuation: CheckedContinuation<Result, Error>?

    static func run(url: URL, configuration: URLSessionConfiguration) async throws -> Result {
        let delegate = StreamingGuideParse()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 90)
        request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    delegate.continuation = continuation
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    deinit {
        if let parser { xmlFreeParserCtxt(parser) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            failure = URLError(.badServerResponse)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, !data.isEmpty else { return }
        if firstByteMs < 0 { firstByteMs = AppLog.elapsedMilliseconds(since: started) }
        bytes += data.count
        let parseStarted = ContinuousClock.now
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let chars = base.assumingMemoryBound(to: CChar.self)
            if let parser {
                _ = xmlParseChunk(parser, chars, Int32(raw.count), 0)
                return
            }
            var sax = saxHandler
            let ctxPtr = Unmanaged.passUnretained(context).toOpaque()
            // libxml2 copies the handler table into the new context.
            parser = withUnsafeMutablePointer(to: &sax) { saxPtr in
                xmlCreatePushParserCtxt(saxPtr, ctxPtr, chars, Int32(raw.count), nil)
            }
            if let parser {
                _ = xmlCtxtUseOptions(parser, kXMLParseRecover | kXMLParseNoError | kXMLParseNoWarning | kXMLParseNoNet)
            }
        }
        parseDuration += parseStarted.duration(to: .now)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error = failure ?? error {
            continuation.resume(throwing: error)
            return
        }
        let tailStarted = ContinuousClock.now
        if let parser { _ = xmlParseChunk(parser, nil, 0, 1) }
        let tail = tailStarted.duration(to: .now)
        parseDuration += tail
        continuation.resume(returning: Result(
            programs: context.programs,
            bytes: bytes,
            firstByteMs: max(0, firstByteMs),
            parseMs: Self.milliseconds(parseDuration),
            tailParseMs: Self.milliseconds(tail)
        ))
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
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

// MARK: - SAX handler (cached — closure thunks created once, not per parse)

nonisolated private let saxHandler: xmlSAXHandler = {
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
}()

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

    init(initialCapacity: Int) {
        // Size the initial buffer to the input, rather than reserving 512K
        // entries even for a small guide. EPGProgram's four Strings and two
        // Dates occupy 80 bytes per entry on arm64, before String payloads.
        // This is a growth hint; compact or namespaced XML can grow normally.
        programs.reserveCapacity(initialCapacity)
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

            guard let attributes, nbAttributes >= 3 else { return }

            // SAX2 attribute layout: 5 entries per attribute —
            // (localname, prefix, URI, value_start, value_end).
            // Attribute order is not significant in XML. Providers also add
            // optional attributes, so positions cannot identify these fields.
            // Verify the common three-attribute order before taking its fast
            // path; reordered/extra/namespaced fields retain the general loop.
            if nbAttributes == 3,
               attributes[1] == nil, attributes[6] == nil, attributes[11] == nil,
               let startName = attributes[0], let stopName = attributes[5], let channelName = attributes[10],
               cstrEquals(startName, "start"), cstrEquals(stopName, "stop"), cstrEquals(channelName, "channel") {
                if let s = attributes[3], let e = attributes[4], e > s {
                    currentStart = parseXMLTVDate(s, length: e - s)
                }
                if let s = attributes[8], let e = attributes[9], e > s {
                    currentEnd = parseXMLTVDate(s, length: e - s)
                }
                if let s = attributes[13], let e = attributes[14], e > s {
                    currentChannelID = decodeUTF8(s, length: e - s)
                }
                return
            }
            for index in 0..<nbAttributes {
                let base = index * 5
                guard let name = attributes[base], attributes[base + 1] == nil,
                      let s = attributes[base + 3], let e = attributes[base + 4], e > s else { continue }
                if cstrEquals(name, "start") {
                    currentStart = parseXMLTVDate(s, length: e - s)
                } else if cstrEquals(name, "stop") {
                    currentEnd = parseXMLTVDate(s, length: e - s)
                } else if cstrEquals(name, "channel") {
                    currentChannelID = decodeUTF8(s, length: e - s)
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
            guard let start = currentStart, let end = currentEnd, !currentChannelID.isEmpty else { return }
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

/// Check length before memcmp so short/unknown names never read beyond their
/// terminating byte (including optional attributes in provider XML).
@inline(__always)
nonisolated private func cstrEquals(_ a: UnsafePointer<xmlChar>, _ b: StaticString) -> Bool {
    let bLen = b.utf8CodeUnitCount
    guard a[0] == b.utf8Start[0] else { return false }
    return xmlStrlen(a) == bLen && memcmp(a, b.utf8Start, bLen) == 0
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
