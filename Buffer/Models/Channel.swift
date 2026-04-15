import Foundation

nonisolated struct CatchupInfo: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case xc        // Xtream-style: /timeshift/user/pass/{mins}/{Y-m-d:H-M}/{id}.ts
        case standard  // M3U catchup="default" — ${start}/${end}/${duration}/... placeholders
        case append    // M3U catchup="append" — source is appended to live URL
        case shift     // M3U catchup="shift" — adds ?utcstart=&utcend=
    }

    let kind: Kind
    let days: Int
    let source: String?
}

nonisolated struct Channel: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let logoURL: URL?
    let group: String
    let streamURL: URL
    let epgChannelID: String?
    let catchup: CatchupInfo?

    init(
        id: String,
        name: String,
        logoURL: URL?,
        group: String,
        streamURL: URL,
        epgChannelID: String?,
        catchup: CatchupInfo? = nil
    ) {
        self.id = id
        self.name = name
        self.logoURL = logoURL
        self.group = group
        self.streamURL = streamURL
        self.epgChannelID = epgChannelID
        self.catchup = catchup
    }

    var supportsRewind: Bool {
        (catchup?.days ?? 0) > 0
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Channel, rhs: Channel) -> Bool {
        lhs.id == rhs.id
    }
}
