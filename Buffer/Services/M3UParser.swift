import Foundation

nonisolated struct M3UParser {
    struct PlaylistContent: Sendable {
        let channels: [Channel]
        let vodItems: [VODItem]
    }

    static func parse(_ content: String) -> [Channel] {
        parseContent(content).channels
    }

    static func parseContent(_ content: String) -> PlaylistContent {
        let lines = content.components(separatedBy: .newlines)
        var channels: [Channel] = []
        var vodItems: [VODItem] = []
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#EXTINF:") {
                let attrs = parseAttributes(line)
                let name = firstNonEmpty(attrs["tvg-name"], attrs["name"], parseDisplayName(line)) ?? "Unknown"
                let duration = parseDuration(line) ?? Int(firstNonEmpty(attrs["duration"], attrs["runtime"]) ?? "")

                // Next non-empty, non-comment line is the URL
                i += 1
                while i < lines.count {
                    let urlLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if !urlLine.isEmpty && !urlLine.hasPrefix("#") {
                        if let url = URL(string: urlLine) {
                            if isVODEntry(attrs: attrs, url: url, duration: duration) {
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
                                break
                            }
                            let channel = Channel(
                                id: attrs["tvg-id"] ?? UUID().uuidString,
                                name: name,
                                logoURL: attrs["tvg-logo"].flatMap { URL(string: $0) },
                                group: attrs["group-title"] ?? "Uncategorized",
                                streamURL: url,
                                epgChannelID: attrs["tvg-id"],
                                catchup: parseCatchup(attrs: attrs)
                            )
                            channels.append(channel)
                        }
                        break
                    }
                    i += 1
                }
            }
            i += 1
        }
        return PlaylistContent(channels: channels, vodItems: vodItems)
    }

    static func parse(from url: URL) async throws -> [Channel] {
        try await parseContent(from: url).channels
    }

    static func parseContent(from url: URL) async throws -> PlaylistContent {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (fetched, _) = try await URLSession.shared.data(from: url)
            data = fetched
        }
        return await Task.detached(priority: .userInitiated) {
            guard let content = String(data: data, encoding: .utf8) else {
                return PlaylistContent(channels: [], vodItems: [])
            }
            return parseContent(content)
        }.value
    }

    private static func parseAttributes(_ line: String) -> [String: String] {
        var attrs: [String: String] = [:]
        let pattern = #"([\w-]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attrs }

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
