import CryptoKit
import Foundation

nonisolated struct M3UParser {
    struct PlaylistContent: Sendable {
        let channels: [Channel]
        let vodItems: [VODItem]
    }

    static func parse(_ content: String) -> [Channel] {
        parseContent(content, includeVOD: false).channels
    }

    static func parseContent(_ content: String, includeVOD: Bool = true) -> PlaylistContent {
        parseContent(content, cancellationEnabled: false, includeVOD: includeVOD)
    }

    private static func parseContent(_ content: String, cancellationEnabled: Bool, includeVOD: Bool = true) -> PlaylistContent {
        var channels: [Channel] = []
        var vodItems: [VODItem] = []
        var pendingAttributes: [String: String]?
        var pendingName = ""
        var pendingDuration: Int?
        var fallbackIDOccurrences: [String: Int] = [:]

        func nextOccurrence(_ count: inout Int) -> Int {
            count += 1
            return count
        }

        func consumeLine(_ rawLine: String) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let attrs = pendingAttributes {
                guard !line.isEmpty, !line.hasPrefix("#") else { return }
                pendingAttributes = nil
                let name = pendingName
                let duration = pendingDuration
                let urlLine = line
                if let url = URL(string: urlLine) {
                    if isVODEntry(attrs: attrs, url: url, duration: duration) {
                        guard includeVOD else { return }
                        vodItems.append(
                            VODItem(
                                id: vodID(attrs: attrs, url: url),
                                name: name,
                                posterURL: attrs["tvg-logo"].flatMap { URL(string: $0) },
                                group: attrs["group-title"] ?? "Movies",
                                streamURL: url,
                                kind: vodKind(attrs: attrs, url: url),
                                genre: attrs["genre"] ?? attrs["group-title"],
                                durationSeconds: duration,
                                rating: attrs["rating"],
                                releaseDate: firstNonEmpty(attrs["release-date"], attrs["releasedate"], attrs["date"], attrs["year"]),
                                containerExtension: url.pathExtension.isEmpty ? nil : url.pathExtension,
                                summary: firstNonEmpty(attrs["description"], attrs["desc"], attrs["plot"], attrs["synopsis"]),
                                director: attrs["director"],
                                cast: attrs["cast"],
                                country: attrs["country"],
                                seasonNumber: Int(attrs["season"] ?? ""),
                                episodeNumber: Int(attrs["episode"] ?? attrs["episode-num"] ?? "")
                            )
                        )
                        return
                    }
                    let epgID = attrs["tvg-id"].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                    let channelID: String
                    if let epgID {
                        channelID = epgID
                    } else {
                        let baseID = fallbackChannelID(for: url)
                        let occurrence = nextOccurrence(&fallbackIDOccurrences[baseID, default: 0])
                        channelID = occurrence == 1 ? baseID : "\(baseID):\(occurrence)"
                    }
                    let channel = Channel(
                        id: channelID,
                        name: name,
                        logoURL: attrs["tvg-logo"].flatMap { URL(string: $0) },
                        group: attrs["group-title"] ?? "Uncategorized",
                        streamURL: url,
                        epgChannelID: epgID,
                        catchup: parseCatchup(attrs: attrs)
                    )
                    channels.append(channel)
                }
            } else if line.hasPrefix("#EXTINF:") {
                let attrs = parseAttributes(line)
                pendingAttributes = attrs
                pendingName = firstNonEmpty(attrs["tvg-name"], attrs["name"], parseDisplayName(line)) ?? "Unknown"
                pendingDuration = parseDuration(line) ?? Int(firstNonEmpty(attrs["duration"], attrs["runtime"]) ?? "")
            }
        }
        // Keep the low-overhead Foundation path for small playlists. For
        // large lists, consume one UTF-8 line at a time so all line Strings
        // and their backing storage are not retained during entry parsing.
        if content.utf8.count <= 128 * 1024 {
            for line in content.components(separatedBy: .newlines) {
                if cancellationEnabled && Task.isCancelled { break }
                consumeLine(line)
            }
            return PlaylistContent(channels: channels, vodItems: vodItems)
        }
        var contiguousContent = content
        contiguousContent.withUTF8 { bytes in
            var offset = 0
            while offset < bytes.count {
                if cancellationEnabled && Task.isCancelled { break }
                let start = offset
                var separatorLength = 0
                while offset < bytes.count {
                    let byte = bytes[offset]
                    if byte == 0x0a || byte == 0x0d || byte == 0x0b || byte == 0x0c {
                        separatorLength = 1
                        break
                    }
                    if byte == 0xc2, offset + 1 < bytes.count, bytes[offset + 1] == 0x85 {
                        separatorLength = 2
                        break
                    }
                    if byte == 0xe2, offset + 2 < bytes.count, bytes[offset + 1] == 0x80,
                       bytes[offset + 2] == 0xa8 || bytes[offset + 2] == 0xa9 {
                        separatorLength = 3
                        break
                    }
                    offset += 1
                }
                consumeLine(String(decoding: bytes[start..<offset], as: UTF8.self))
                offset += separatorLength
            }
        }
        return PlaylistContent(channels: channels, vodItems: vodItems)
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
            let result = parseContent(content, cancellationEnabled: true, includeVOD: includeVOD)
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

    // Precompiled once (Agent 03 critical perf fix). Creating a fresh
    // NSRegularExpression on every #EXTINF line was dominating parse time
    // for 5k–50k line M3U playlists.
    private static let attrRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"([\w-]+)="([^"]*)""#)
    }()

    private static func parseAttributes(_ line: String) -> [String: String] {
        var attrs: [String: String] = [:]
        var contiguousLine = line
        let asciiAttributes = contiguousLine.withUTF8 { bytes -> [String: String]? in
            // Match the regex's ASCII word/hyphen keys and quoted values.
            // Unicode keys or values keep the established Unicode regex path.
            guard !bytes.contains(where: { $0 >= 0x80 }) else { return nil }
            @inline(__always) func isKeyByte(_ byte: UInt8) -> Bool {
                byte == 0x2d || byte == 0x5f || byte >= 0x30 && byte <= 0x39
                    || byte >= 0x41 && byte <= 0x5a || byte >= 0x61 && byte <= 0x7a
            }
            var result: [String: String] = [:]
            var offset = 0
            while offset < bytes.count {
                guard isKeyByte(bytes[offset]) else { offset += 1; continue }
                let keyStart = offset
                while offset < bytes.count && isKeyByte(bytes[offset]) { offset += 1 }
                guard offset + 1 < bytes.count, bytes[offset] == 0x3d, bytes[offset + 1] == 0x22 else { continue }
                let valueStart = offset + 2
                offset = valueStart
                while offset < bytes.count && bytes[offset] != 0x22 { offset += 1 }
                guard offset < bytes.count else { break }
                result[String(decoding: bytes[keyStart..<(valueStart - 2)], as: UTF8.self)] = String(decoding: bytes[valueStart..<offset], as: UTF8.self)
                offset += 1
            }
            return result
        }
        if let asciiAttributes { return asciiAttributes }
        guard let regex = attrRegex else { return attrs }

        let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        for match in matches {
            if let keyRange = Range(match.range(at: 1), in: line),
               let valueRange = Range(match.range(at: 2), in: line) {
                attrs[String(line[keyRange])] = String(line[valueRange])
            }
        }
        return attrs
    }

    private static func parseCatchup(attrs: [String: String]) -> CatchupInfo? {
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

    private static func parseDisplayName(_ line: String) -> String {
        // Display name is after the last comma in the EXTINF line
        if let commaRange = line.range(of: ",", options: .backwards) {
            return String(line[commaRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return "Unknown"
    }

    private static func parseDuration(_ line: String) -> Int? {
        guard line.hasPrefix("#EXTINF:") else { return nil }
        let afterPrefix = line.dropFirst("#EXTINF:".count)
        let token = afterPrefix.split(whereSeparator: { $0 == " " || $0 == "," }).first
        return token.flatMap { Int($0) }
    }

    private static func isVODEntry(attrs: [String: String], url: URL, duration: Int?) -> Bool {
        let type = (attrs["tvg-type"] ?? attrs["type"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["movie", "movies", "vod", "video", "tvshow", "tvshows", "series"].contains(type) {
            return true
        }

        let path = url.path.lowercased()
        if path.contains("/movie/") || path.contains("/series/") || path.contains("/vod/") {
            return true
        }

        let fileExtensions = ["mp4", "mkv", "avi", "mov", "m4v", "webm"]
        if fileExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }

        if let duration, duration > 0 {
            return true
        }

        return false
    }

    private static func vodKind(attrs: [String: String], url: URL) -> VODItem.Kind {
        let type = (attrs["tvg-type"] ?? attrs["type"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["tvshow", "tvshows", "series"].contains(type) || url.path.lowercased().contains("/series/") {
            return .seriesEpisode
        }
        if ["movie", "movies", "vod", "video"].contains(type) || url.path.lowercased().contains("/movie/") {
            return .movie
        }
        return .unknown
    }

    private static func stableID(for url: URL) -> String {
        url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
    }

    /// Names, logos and groups change independently from stream identity.
    /// Hash the full URL so distinct URL variants stay distinct and IDs do
    /// not expose embedded credentials. Authentication/token changes also
    /// change fallback identity; stripping arbitrary query items could merge
    /// different streams. Providers should supply tvg-id for that case.
    private static func fallbackChannelID(for url: URL) -> String {
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

    private static func vodID(attrs: [String: String], url: URL) -> String {
        let urlID = stableID(for: url)
        guard let tvgID = attrs["tvg-id"], !tvgID.isEmpty else {
            return urlID
        }
        return "\(tvgID)|\(urlID)"
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
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
