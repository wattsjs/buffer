import Foundation

enum CatchupURLBuilder {
    /// Build a catchup URL to play the segment starting at `start` for `duration` seconds.
    /// Returns nil if the channel has no catchup info or the template can't be satisfied.
    static func url(for channel: Channel, start: Date, duration: TimeInterval) -> URL? {
        guard let catchup = channel.catchup else { return nil }
        let clamped = max(duration, 60)

        switch catchup.kind {
        case .shift:
            return shiftURL(liveURL: channel.streamURL, start: start, duration: clamped)
        case .append:
            guard let source = catchup.source, !source.isEmpty else { return nil }
            let combined = channel.streamURL.absoluteString + source
            return URL(string: substitute(template: combined, start: start, duration: clamped, kind: .append))
        case .standard, .xc:
            guard let source = catchup.source, !source.isEmpty else { return nil }
            return URL(string: substitute(template: source, start: start, duration: clamped, kind: catchup.kind))
        }
    }

    private static func shiftURL(liveURL: URL, start: Date, duration: TimeInterval) -> URL? {
        guard var comps = URLComponents(url: liveURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let startTs = Int(start.timeIntervalSince1970)
        let endTs = Int(start.addingTimeInterval(duration).timeIntervalSince1970)
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "utcstart", value: "\(startTs)"))
        items.append(URLQueryItem(name: "utcend", value: "\(endTs)"))
        comps.queryItems = items
        return comps.url
    }

    private static func substitute(template: String, start: Date, duration: TimeInterval, kind: CatchupInfo.Kind) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)

        let durSecs = Int(duration)
        let durMins = max(1, Int(duration / 60))
        let startTs = Int(start.timeIntervalSince1970)
        let endTs = Int(start.addingTimeInterval(duration).timeIntervalSince1970)
        let nowTs = Int(Date().timeIntervalSince1970)
        let offset = max(0, nowTs - startTs)

        let year = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%02d", parts.month ?? 0)
        let day = String(format: "%02d", parts.day ?? 0)
        let hour = String(format: "%02d", parts.hour ?? 0)
        let minute = String(format: "%02d", parts.minute ?? 0)
        let second = String(format: "%02d", parts.second ?? 0)

        // Xtream catchup URLs expect `${duration}` in minutes; the standard
        // M3U `default` scheme expects seconds.
        let durationValue = kind == .xc ? "\(durMins)" : "\(durSecs)"
        let replacements: [(String, String)] = [
            ("${Y}", year), ("{Y}", year),
            ("${m}", month), ("{m}", month),
            ("${d}", day), ("{d}", day),
            ("${H}", hour), ("{H}", hour),
            ("${M}", minute), ("{M}", minute),
            ("${S}", second), ("{S}", second),
            ("${start}", "\(startTs)"),
            ("${end}", "\(endTs)"),
            ("${timestamp}", "\(nowTs)"),
            ("${offset}", "\(offset)"),
            ("${duration}", durationValue),
            ("${duration_min}", "\(durMins)"),
        ]

        var out = template
        for (key, value) in replacements {
            out = out.replacingOccurrences(of: key, with: value)
        }
        return out
    }
}
