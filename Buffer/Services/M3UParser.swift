import Foundation

nonisolated struct M3UParser {
    static func parse(_ content: String) -> [Channel] {
        let lines = content.components(separatedBy: .newlines)
        var channels: [Channel] = []
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#EXTINF:") {
                let attrs = parseAttributes(line)
                let name = parseDisplayName(line)

                // Next non-empty, non-comment line is the URL
                i += 1
                while i < lines.count {
                    let urlLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if !urlLine.isEmpty && !urlLine.hasPrefix("#") {
                        if let url = URL(string: urlLine) {
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
        return channels
    }

    static func parse(from url: URL) async throws -> [Channel] {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (fetched, _) = try await URLSession.shared.data(from: url)
            data = fetched
        }
        return await Task.detached(priority: .userInitiated) {
            guard let content = String(data: data, encoding: .utf8) else {
                return []
            }
            return parse(content)
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
}
