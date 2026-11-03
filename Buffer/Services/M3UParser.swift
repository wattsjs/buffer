import CryptoKit
import Foundation
import Synchronization

/// M3U playlists parsed straight from the UTF-8 bytes: one pass finds line
/// separators, entries are classified from byte spans (attribute keys and
/// values are never materialized as a dictionary), and only the fields the
/// `Channel`/`VODItem` façades hold become `String`s. Large playlists are
/// split at `#EXTINF:` lines and parsed in parallel; a part whose start
/// assumption (no entry pending a URL) does not hold is parsed again with
/// the pending entry. Unicode-sensitive steps (grapheme-aware prefixes,
/// Unicode attribute keys, case mapping) defer to the original `String`
/// code whenever non-ASCII bytes touch them.
nonisolated struct M3UParser {
    struct PlaylistContent: Sendable {
        let channels: [Channel]
        let vodItems: [VODItem]
    }

    static func parse(_ content: String) -> [Channel] {
        parseContent(content, includeVOD: false).channels
    }

    static func parseContent(_ content: String, includeVOD: Bool = true) -> PlaylistContent {
        parseContent(content, cancellation: nil, includeVOD: includeVOD)
    }

    private static func parseContent(_ content: String, cancellation: M3UCancellation?, includeVOD: Bool) -> PlaylistContent {
        var contiguous = content
        return contiguous.withUTF8 { bytes in
            guard let base = bytes.baseAddress, bytes.count > 0 else { return PlaylistContent(channels: [], vodItems: []) }
            return M3UScan.parse(M3UBytes(base: base, count: bytes.count), includeVOD: includeVOD, cancellation: cancellation)
        }
    }

    static func parse(from url: URL) async throws -> [Channel] {
        try await parseContent(from: url, includeVOD: false).channels
    }

    static func parseContent(from url: URL, includeVOD: Bool = true) async throws -> PlaylistContent {
        // For local files, perform the (potentially large) read inside the
        // detached task so we never block the main thread (Agent 03 Critical).
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data: Data
            if url.isFileURL {
                data = try Data(contentsOf: url)
            } else {
                data = try await fetchRemotePlaylistData(from: url)
            }
            try Task.checkCancellation()
            guard let content = String(data: data, encoding: .utf8) else {
                return PlaylistContent(channels: [], vodItems: [])
            }
            let cancellation = M3UCancellation()
            let result = await withTaskCancellationHandler {
                parseContent(content, cancellation: cancellation, includeVOD: includeVOD)
            } onCancel: {
                cancellation.cancel()
            }
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    // MARK: String-level rules (the reference semantics)

    // Unicode attribute keys keep the regular-expression grammar.
    fileprivate static let attrRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"([\w-]+)="([^"]*)""#)
    }()

    fileprivate static func parseDisplayName(_ line: String) -> String {
        // Display name is after the last comma in the EXTINF line
        if let commaRange = line.range(of: ",", options: .backwards) {
            return String(line[commaRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return "Unknown"
    }

    fileprivate static func parseDuration(_ line: String) -> Int? {
        guard line.hasPrefix("#EXTINF:") else { return nil }
        let afterPrefix = line.dropFirst("#EXTINF:".count)
        let token = afterPrefix.split(whereSeparator: { $0 == " " || $0 == "," }).first
        return token.flatMap { Int($0) }
    }

    fileprivate static func parseCatchup(_ attrs: M3UAttributes) -> CatchupInfo? {
        let rawType = (attrs["catchup"] ?? attrs["catchup-type"])?
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        let days = Int(attrs["catchup-days"] ?? attrs["timeshift"] ?? "") ?? 0
        guard rawType != nil || days > 0 else { return nil }

        let source = attrs["catchup-source"]
        let kind: CatchupInfo.Kind
        switch rawType {
        case "append":
            kind = .append
        case "shift", "timeshift":
            kind = .shift
        case "xc", "flussonic", "flussonic-hls", "flussonic-ts":
            // Flussonic servers use template-based URLs similar to standard
            // catchup; treat them as `.standard` if a source is given,
            // otherwise fall through to `.shift` as a conservative default.
            kind = source != nil ? .standard : .shift
        default:
            kind = source != nil ? .standard : .shift
        }

        return CatchupInfo(kind: kind, days: max(days, 1), source: source)
    }

    fileprivate static let vodTypes: Set<String> = ["movie", "movies", "vod", "video", "tvshow", "tvshows", "series"]
    fileprivate static let vodFileExtensions: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "webm"]

    fileprivate static func isVODEntry(type: String, url: URL, duration: Int?) -> Bool {
        if vodTypes.contains(type) { return true }
        let path = url.path.lowercased()
        if path.contains("/movie/") || path.contains("/series/") || path.contains("/vod/") {
            return true
        }
        if vodFileExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        if let duration, duration > 0 {
            return true
        }
        return false
    }

    fileprivate static func vodKind(type: String, url: URL) -> VODItem.Kind {
        if ["tvshow", "tvshows", "series"].contains(type) || url.path.lowercased().contains("/series/") {
            return .seriesEpisode
        }
        if ["movie", "movies", "vod", "video"].contains(type) || url.path.lowercased().contains("/movie/") {
            return .movie
        }
        return .unknown
    }

    fileprivate static func stableID(for url: URL) -> String {
        url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
    }

    /// Names, logos and groups change independently from stream identity.
    /// Hash the full URL so distinct URL variants stay distinct and IDs do
    /// not expose embedded credentials. Authentication/token changes also
    /// change fallback identity; stripping arbitrary query items could merge
    /// different streams. Providers should supply tvg-id for that case.
    fileprivate static func fallbackChannelID(for url: URL) -> String {
        var source = url.absoluteString
        var hash = SHA256()
        source.withUTF8 { hash.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        let digest = hash.finalize()
        return digest.withUnsafeBytes { bytes in
            String(unsafeUninitializedCapacity: 47) { output in
                buffer_encode_channel_digest(bytes.bindMemory(to: UInt8.self).baseAddress!, output.baseAddress!)
            }
        }
    }

    fileprivate static func vodID(attrs: M3UAttributes, url: URL) -> String {
        let urlID = stableID(for: url)
        guard let tvgID = attrs["tvg-id"], !tvgID.isEmpty else {
            return urlID
        }
        return "\(tvgID)|\(urlID)"
    }

    fileprivate static func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

private extension M3UParser {
    static func fetchRemotePlaylistData(from url: URL) async throws -> Data {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 60
        )
        request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let (data, response) = try await playlistSession.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<400).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static let playlistSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()
}

nonisolated final class M3UCancellation: Sendable {
    private let flag = Atomic<Bool>(false)
    func cancel() { flag.store(true, ordering: .relaxed) }
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

// MARK: - Byte-level scan

/// The playlist bytes (valid UTF-8: they come from a `String`).
nonisolated private struct M3UBytes: @unchecked Sendable {
    let base: UnsafePointer<UInt8>
    let count: Int

    @inline(__always) subscript(_ i: Int) -> UInt8 { base[i] }

    func string(_ lo: Int, _ hi: Int) -> String {
        String(decoding: UnsafeBufferPointer(start: base + lo, count: hi - lo), as: UTF8.self)
    }

    /// Length of the line separator at `i` (\n \v \f \r, U+0085, U+2028,
    /// U+2029: `CharacterSet.newlines`), or 0.
    @inline(__always) func separator(at i: Int) -> Int {
        let b = base[i]
        if b >= 0x0A && b <= 0x0D { return 1 }
        if b == 0xC2 { return i + 1 < count && base[i + 1] == 0x85 ? 2 : 0 }
        if b == 0xE2 { return i + 2 < count && base[i + 1] == 0x80 && (base[i + 2] == 0xA8 || base[i + 2] == 0xA9) ? 3 : 0 }
        return 0
    }

    /// The next separator at or after `i` (or `count`) and its length.
    @inline(__always) func lineEnd(from i: Int) -> (Int, Int) {
        let raw = UnsafeRawPointer(base)
        var i = i
        while i + 8 <= count {
            let w = raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)
            // No byte >= 0x80 and none in 0x0A...0x0D: no separator here.
            if w & 0x8080_8080_8080_8080 == 0 {
                let belowE = ~((w &+ 0x7272_7272_7272_7272) & 0x8080_8080_8080_8080) & 0x8080_8080_8080_8080
                let atLeastA = (w &+ 0x7676_7676_7676_7676) & 0x8080_8080_8080_8080
                if belowE & atLeastA == 0 { i += 8; continue }
            }
            break
        }
        while i < count {
            let length = separator(at: i)
            if length > 0 { return (i, length) }
            i += 1
        }
        return (count, 0)
    }

    /// Trims `CharacterSet.whitespaces` (Zs and tab) scalars from both ends.
    func trimmed(_ lo: Int, _ hi: Int) -> (Int, Int) {
        var lo = lo, hi = hi
        while lo < hi {
            let n = whitespaceLength(at: lo, limit: hi)
            if n == 0 { break }
            lo += n
        }
        while hi > lo {
            let b = base[hi - 1]
            if b == 0x20 || b == 0x09 { hi -= 1; continue }
            if hi - lo >= 2, base[hi - 2] == 0xC2, b == 0xA0 { hi -= 2; continue }
            if hi - lo >= 3, whitespaceLength(at: hi - 3, limit: hi) == 3 { hi -= 3; continue }
            break
        }
        return (lo, hi)
    }

    @inline(__always) private func whitespaceLength(at i: Int, limit: Int) -> Int {
        let b = base[i]
        if b == 0x20 || b == 0x09 { return 1 }
        if b < 0xC2 { return 0 }
        if b == 0xC2 { return i + 1 < limit && base[i + 1] == 0xA0 ? 2 : 0 }
        guard i + 2 < limit else { return 0 }
        let b1 = base[i + 1], b2 = base[i + 2]
        switch b {
        case 0xE1: return b1 == 0x9A && b2 == 0x80 ? 3 : 0                       // U+1680
        case 0xE2:
            if b1 == 0x80 && (b2 <= 0x8A || b2 == 0xAF) { return 3 }               // U+2000-200A, U+202F
            return b1 == 0x81 && b2 == 0x9F ? 3 : 0                                 // U+205F
        case 0xE3: return b1 == 0x80 && b2 == 0x80 ? 3 : 0                       // U+3000
        default: return 0
        }
    }

    /// `String.hasPrefix` for an ASCII prefix: the bytes must match and the
    /// prefix must end on a grapheme boundary.
    func hasPrefix(_ lo: Int, _ hi: Int, _ prefix: StaticString) -> Bool {
        let n = prefix.utf8CodeUnitCount
        guard hi - lo >= n, memcmp(base + lo, prefix.utf8Start, n) == 0 else { return false }
        if hi - lo == n || base[lo + n] < 0x80 { return true }
        return string(lo, hi).hasPrefix(prefix.description)
    }
}

/// Attribute spans of one `#EXTINF` line; lookups follow dictionary
/// semantics (the last occurrence of a key wins).
nonisolated private struct M3UAttributes {
    let bytes: M3UBytes
    /// keyStart, keyEnd, valueStart, valueEnd per attribute.
    var spans: [Int] = []
    /// Lines whose keys need the Unicode regex keep its results directly.
    var regexValues: [String: String]?

    subscript(_ key: StaticString) -> String? {
        if let regexValues { return regexValues[key.description] }
        let n = key.utf8CodeUnitCount
        var i = spans.count - 4
        while i >= 0 {
            if spans[i + 1] - spans[i] == n && memcmp(bytes.base + spans[i], key.utf8Start, n) == 0 {
                return bytes.string(spans[i + 2], spans[i + 3])
            }
            i -= 4
        }
        return nil
    }

    /// The value of `key` as an ASCII-lowercased, trimmed byte comparison
    /// key, or nil when the value is absent; `unicode` when non-ASCII bytes
    /// require `String` case mapping.
    func span(_ key: StaticString) -> (Int, Int)? {
        guard regexValues == nil else { return nil }
        let n = key.utf8CodeUnitCount
        var i = spans.count - 4
        while i >= 0 {
            if spans[i + 1] - spans[i] == n && memcmp(bytes.base + spans[i], key.utf8Start, n) == 0 {
                return (spans[i + 2], spans[i + 3])
            }
            i -= 4
        }
        return nil
    }

    init(bytes: M3UBytes, line lo: Int, _ hi: Int) {
        self.bytes = bytes
        var ascii = true
        for i in lo..<hi where bytes[i] >= 0x80 { ascii = false; break }
        if !ascii && Self.keysNeedUnicode(bytes, lo, hi) {
            regexValues = Self.regexAttributes(bytes.string(lo, hi))
            return
        }
        // `([\w-]+)="([^"]*)"` over ASCII keys: a maximal key run followed
        // by `="`, then everything up to the next quote. Non-ASCII bytes
        // never touch a key here (checked above), so they act as
        // separators exactly as for the regular expression.
        var offset = lo
        while offset < hi {
            guard Self.isKeyByte(bytes[offset]) else { offset += 1; continue }
            let keyStart = offset
            while offset < hi && Self.isKeyByte(bytes[offset]) { offset += 1 }
            guard offset + 1 < hi, bytes[offset] == 0x3D, bytes[offset + 1] == 0x22 else { continue }
            let valueStart = offset + 2
            guard let quote = memchr(bytes.base + valueStart, 0x22, hi - valueStart) else { break }
            let valueEnd = bytes.base.distance(to: quote.assumingMemoryBound(to: UInt8.self))
            spans.append(keyStart)
            spans.append(valueStart - 2)
            spans.append(valueStart)
            spans.append(valueEnd)
            offset = valueEnd + 1
        }
    }

    @inline(__always) static func isKeyByte(_ byte: UInt8) -> Bool {
        byte == 0x2d || byte == 0x5f || byte >= 0x30 && byte <= 0x39
            || byte >= 0x41 && byte <= 0x5a || byte >= 0x61 && byte <= 0x7a
    }

    /// True when a non-ASCII scalar could belong to a key: a run of key
    /// bytes ending at `="` is preceded directly by a non-ASCII byte.
    static func keysNeedUnicode(_ bytes: M3UBytes, _ lo: Int, _ hi: Int) -> Bool {
        var i = lo
        while i + 1 < hi {
            if bytes[i] == 0x3D && bytes[i + 1] == 0x22 {
                var k = i
                while k > lo && isKeyByte(bytes[k - 1]) { k -= 1 }
                if k > lo && bytes[k - 1] >= 0x80 { return true }
            }
            i += 1
        }
        return false
    }

    static func regexAttributes(_ line: String) -> [String: String] {
        var attrs: [String: String] = [:]
        guard let regex = M3UParser.attrRegex else { return attrs }
        let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        for match in matches {
            if let keyRange = Range(match.range(at: 1), in: line),
               let valueRange = Range(match.range(at: 2), in: line) {
                attrs[String(line[keyRange])] = String(line[valueRange])
            }
        }
        return attrs
    }
}

/// A live entry before its fallback identity occurrence is known.
nonisolated private struct M3ULiveEntry {
    var name: String
    var logoURL: URL?
    var group: String
    var streamURL: URL
    var epgID: String?
    var catchup: CatchupInfo?
    /// URL hash identity, when there is no tvg-id.
    var fallbackBase: String?
}

nonisolated private struct M3UPartResult {
    var live: [M3ULiveEntry] = []
    var vod: [VODItem] = []
    /// Trimmed `#EXTINF` line still waiting for its URL at the part end.
    var pending: (Int, Int)?
    var cancelled = false
}

nonisolated private enum M3UScan {
    static func parse(_ bytes: M3UBytes, includeVOD: Bool, cancellation: M3UCancellation?) -> M3UParser.PlaylistContent {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        var boundaries = [0]
        if bytes.count >= 512 * 1024 && cores > 1 {
            let parts = min(cores * 2, bytes.count / (128 * 1024))
            for part in 1..<parts {
                if let start = nextEntryLine(bytes, from: bytes.count / parts * part), start > boundaries.last! {
                    boundaries.append(start)
                }
            }
        }
        boundaries.append(bytes.count)
        let partCount = boundaries.count - 1
        let results = UnsafeMutableBufferPointer<M3UPartResult>.allocate(capacity: partCount)
        results.initialize(repeating: M3UPartResult())
        defer { results.deinitialize(); results.deallocate() }
        let slots = M3UUnchecked(results), bounds = boundaries
        if partCount == 1 {
            results[0] = parseRange(bytes, bounds[0], bounds[1], pending: nil, includeVOD: includeVOD, cancellation: cancellation)
        } else {
            DispatchQueue.concurrentPerform(iterations: partCount) { index in
                slots.value[index] = parseRange(bytes, bounds[index], bounds[index + 1], pending: nil,
                                                includeVOD: includeVOD, cancellation: cancellation)
            }
        }
        // A part parsed without the entry its predecessor left pending is
        // parsed again with it.
        for index in 1..<max(1, partCount) where results[index - 1].pending != nil {
            results[index] = parseRange(bytes, bounds[index], bounds[index + 1], pending: results[index - 1].pending,
                                        includeVOD: includeVOD, cancellation: cancellation)
        }
        var occurrences: [String: Int] = [:]
        var channels: [Channel] = []
        var vodItems: [VODItem] = []
        channels.reserveCapacity(results.reduce(0) { $0 + $1.live.count })
        for result in results {
            if result.cancelled { break }
            vodItems += result.vod
            for entry in result.live {
                let channelID: String
                if let epgID = entry.epgID {
                    channelID = epgID
                } else {
                    let base = entry.fallbackBase!
                    let occurrence = (occurrences[base] ?? 0) + 1
                    occurrences[base] = occurrence
                    channelID = occurrence == 1 ? base : "\(base):\(occurrence)"
                }
                channels.append(Channel(id: channelID, name: entry.name, logoURL: entry.logoURL, group: entry.group,
                                        streamURL: entry.streamURL, epgChannelID: entry.epgID, catchup: entry.catchup))
            }
        }
        return M3UParser.PlaylistContent(channels: channels, vodItems: vodItems)
    }

    /// The start of the next line at or after `from` whose bytes begin
    /// with `#EXTINF:`.
    static func nextEntryLine(_ bytes: M3UBytes, from: Int) -> Int? {
        var i = from
        while i < bytes.count {
            let (end, length) = bytes.lineEnd(from: i)
            guard length > 0 else { return nil }
            i = end + length
            if bytes.count - i >= 8 && memcmp(bytes.base + i, "#EXTINF:", 8) == 0 { return i }
        }
        return nil
    }

    static func parseRange(_ bytes: M3UBytes, _ lo: Int, _ hi: Int, pending initial: (Int, Int)?,
                           includeVOD: Bool, cancellation: M3UCancellation?) -> M3UPartResult {
        var result = M3UPartResult()
        var pending = initial
        var offset = lo
        var lines = 0
        while offset < hi {
            lines += 1
            if lines & 1023 == 0, let cancellation, cancellation.isCancelled { result.cancelled = true; break }
            let (end, length) = bytes.lineEnd(from: offset)
            let lineEnd = min(end, hi)
            let (s, e) = bytes.trimmed(offset, lineEnd)
            if let entry = pending {
                if s < e && !bytes.hasPrefix(s, e, "#") {
                    pending = nil
                    consume(bytes, entry: entry, urlLine: (s, e), includeVOD: includeVOD, into: &result)
                }
            } else if bytes.hasPrefix(s, e, "#EXTINF:") {
                pending = (s, e)
            }
            offset = end + length
            if length == 0 { break }
        }
        result.pending = pending
        return result
    }

    /// Builds the entry for `#EXTINF` line `entry` and its URL line.
    static func consume(_ bytes: M3UBytes, entry: (Int, Int), urlLine: (Int, Int), includeVOD: Bool, into result: inout M3UPartResult) {
        guard let url = URL(string: bytes.string(urlLine.0, urlLine.1)) else { return }
        let (lo, hi) = entry
        let attrs = M3UAttributes(bytes: bytes, line: lo, hi)
        let duration = parseDuration(bytes, lo, hi)
            ?? Int(M3UParser.firstNonEmpty(attrs["duration"], attrs["runtime"]) ?? "")
        let type = typeKey(attrs)
        if M3UParser.isVODEntry(type: type, url: url, duration: duration) {
            guard includeVOD else { return }
            let name = displayName(bytes, attrs, lo, hi)
            result.vod.append(
                VODItem(
                    id: M3UParser.vodID(attrs: attrs, url: url),
                    name: name,
                    posterURL: attrs["tvg-logo"].flatMap { URL(string: $0) },
                    group: attrs["group-title"] ?? "Movies",
                    streamURL: url,
                    kind: M3UParser.vodKind(type: type, url: url),
                    genre: attrs["genre"] ?? attrs["group-title"],
                    durationSeconds: duration,
                    rating: attrs["rating"],
                    releaseDate: M3UParser.firstNonEmpty(attrs["release-date"], attrs["releasedate"], attrs["date"], attrs["year"]),
                    containerExtension: url.pathExtension.isEmpty ? nil : url.pathExtension,
                    summary: M3UParser.firstNonEmpty(attrs["description"], attrs["desc"], attrs["plot"], attrs["synopsis"]),
                    director: attrs["director"],
                    cast: attrs["cast"],
                    country: attrs["country"],
                    seasonNumber: Int(attrs["season"] ?? ""),
                    episodeNumber: Int(attrs["episode"] ?? attrs["episode-num"] ?? "")
                )
            )
            return
        }
        var epgID: String?
        if let (vs, ve) = attrs.span("tvg-id") {
            let (ts, te) = bytes.trimmed(vs, ve)
            if ts < te { epgID = bytes.string(vs, ve) }
        } else if attrs.regexValues != nil {
            epgID = attrs["tvg-id"].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        result.live.append(M3ULiveEntry(
            name: displayName(bytes, attrs, lo, hi),
            logoURL: attrs["tvg-logo"].flatMap { URL(string: $0) },
            group: attrs["group-title"] ?? "Uncategorized",
            streamURL: url,
            epgID: epgID,
            catchup: hasCatchupAttributes(attrs) ? M3UParser.parseCatchup(attrs) : nil,
            fallbackBase: epgID == nil ? M3UParser.fallbackChannelID(for: url) : nil
        ))
    }

    static func hasCatchupAttributes(_ attrs: M3UAttributes) -> Bool {
        if attrs.regexValues != nil { return true }
        return attrs.span("catchup") != nil || attrs.span("catchup-type") != nil
            || attrs.span("catchup-days") != nil || attrs.span("timeshift") != nil
    }

    /// `(tvg-type ?? type ?? "")` trimmed and lowercased.
    static func typeKey(_ attrs: M3UAttributes) -> String {
        guard let (vs, ve) = attrs.span("tvg-type") ?? attrs.span("type") else {
            let raw = attrs["tvg-type"] ?? attrs["type"] ?? ""
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let (s, e) = attrs.bytes.trimmed(vs, ve)
        if s == e { return "" }
        for i in s..<e where attrs.bytes[i] >= 0x80 {
            return attrs.bytes.string(vs, ve).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return String(unsafeUninitializedCapacity: e - s) { out in
            for i in s..<e {
                let b = attrs.bytes[i]
                out[i - s] = b >= 0x41 && b <= 0x5A ? b | 0x20 : b
            }
            return e - s
        }
    }

    /// `firstNonEmpty(tvg-name, name, parseDisplayName(line)) ?? "Unknown"`.
    static func displayName(_ bytes: M3UBytes, _ attrs: M3UAttributes, _ lo: Int, _ hi: Int) -> String {
        for key: StaticString in ["tvg-name", "name"] {
            if let (vs, ve) = attrs.span(key) {
                let (s, e) = bytes.trimmed(vs, ve)
                if s < e { return bytes.string(s, e) }
            } else if attrs.regexValues != nil, let value = attrs[key] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        // The last comma, unless a non-ASCII neighbour could join it into a
        // larger grapheme (then Foundation's search decides).
        var comma = hi - 1
        while comma >= lo && bytes[comma] != 0x2C { comma -= 1 }
        let name: String
        if comma < lo {
            name = "Unknown"
        } else if (comma + 1 < hi && bytes[comma + 1] >= 0x80) || (comma > lo && bytes[comma - 1] >= 0x80) {
            name = M3UParser.parseDisplayName(bytes.string(lo, hi))
        } else {
            let (s, e) = bytes.trimmed(comma + 1, hi)
            name = bytes.string(s, e)
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown" : name
    }

    /// `parseDuration`: the first token after `#EXTINF:` split on spaces and
    /// commas, as `Int`.
    static func parseDuration(_ bytes: M3UBytes, _ lo: Int, _ hi: Int) -> Int? {
        var i = lo + 8
        while i < hi && (bytes[i] == 0x20 || bytes[i] == 0x2C) {
            if i + 1 < hi && bytes[i + 1] >= 0x80 { return M3UParser.parseDuration(bytes.string(lo, hi)) }
            i += 1
        }
        let start = i
        while i < hi && bytes[i] != 0x20 && bytes[i] != 0x2C {
            if bytes[i] >= 0x80 { return nil }  // Int rejects non-ASCII tokens
            i += 1
        }
        if i < hi && i + 1 < hi && bytes[i + 1] >= 0x80 { return M3UParser.parseDuration(bytes.string(lo, hi)) }
        guard i > start else { return nil }
        var j = start
        var negative = false
        if bytes[j] == 0x2B || bytes[j] == 0x2D { negative = bytes[j] == 0x2D; j += 1 }
        guard j < i else { return nil }
        var value = 0
        while j < i {
            let b = bytes[j]
            guard b >= 0x30 && b <= 0x39 else { return nil }
            let digit = Int(b - 0x30)
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (a, o2) = negative ? m.subtractingReportingOverflow(digit) : m.addingReportingOverflow(digit)
            if o1 || o2 { return nil }
            value = a
            j += 1
        }
        return value
    }
}

nonisolated private struct M3UUnchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
