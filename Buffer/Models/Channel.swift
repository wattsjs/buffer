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

nonisolated enum CatchupLookbackSetting: Int, CaseIterable, Identifiable {
    case allAvailable = 0
    case threeDays = 72
    case sevenDays = 168
    case fourteenDays = 336

    static let appStorageKey = "buffer_catchup_lookback_hours"
    static let `default`: CatchupLookbackSetting = .allAvailable

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .allAvailable: return "All available"
        case .threeDays: return "3 days"
        case .sevenDays: return "7 days"
        case .fourteenDays: return "14 days"
        }
    }

    var limitHours: Int? {
        switch self {
        case .allAvailable: return nil
        case .threeDays, .sevenDays, .fourteenDays: return rawValue
        }
    }

    static func stored(rawValue: Int) -> CatchupLookbackSetting {
        CatchupLookbackSetting(rawValue: rawValue) ?? `default`
    }
}

nonisolated enum ChannelContentType: String, Codable, Sendable {
    case live
    case vod
}

nonisolated struct Channel: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let logoURL: URL?
    let group: String
    let streamURL: URL
    let epgChannelID: String?
    let catchup: CatchupInfo?
    let contentType: ChannelContentType

    init(
        id: String,
        name: String,
        logoURL: URL?,
        group: String,
        streamURL: URL,
        epgChannelID: String?,
        catchup: CatchupInfo? = nil,
        contentType: ChannelContentType = .live
    ) {
        self.id = id
        self.name = name
        self.logoURL = logoURL
        self.group = group
        self.streamURL = streamURL
        self.epgChannelID = epgChannelID
        self.catchup = catchup
        self.contentType = contentType
    }

    var supportsRewind: Bool {
        contentType == .live && (catchup?.days ?? 0) > 0
    }

    var isOnDemand: Bool { contentType == .vod }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Channel, rhs: Channel) -> Bool {
        lhs.id == rhs.id
    }
}
