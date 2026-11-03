import Foundation

nonisolated struct EPGProgram: Identifiable, Codable, Sendable {
    /// Either the provider's literal ID, or `derivedIDMarker` when the ID is
    /// the XMLTV form `"<channelID>_<Int(start)>"`. The derived form keeps
    /// millions of unique, heap-allocated ID strings out of the guide store;
    /// `id` rebuilds the identical string on demand.
    private let storedID: String
    let channelID: String
    let title: String
    let description: String
    let start: Date
    let end: Date

    /// Origin of the guide store's Int32 second columns (2023-11-14 UTC);
    /// covers 1955...2091.
    static let columnEpoch: Int64 = 1_700_000_000

    /// NUL cannot occur in XMLTV, Xtream or Stalker identifiers.
    private static let derivedIDMarker = "\u{0}"

    var id: String {
        storedID == Self.derivedIDMarker ? channelID + "_" + String(Int(start.timeIntervalSince1970)) : storedID
    }

    init(id: String, channelID: String, title: String, description: String, start: Date, end: Date) {
        storedID = id
        self.channelID = channelID
        self.title = title
        self.description = description
        self.start = start
        self.end = end
    }

    /// Builds a programme whose ID is `"<channelID>_<Int(start)>"`.
    init(channelStartIDWithChannelID channelID: String, title: String, description: String, start: Date, end: Date) {
        storedID = Self.derivedIDMarker
        self.channelID = channelID
        self.title = title
        self.description = description
        self.start = start
        self.end = end
    }

    /// True when `id` equals `"<channelID>_<Int(start)>"`, checked without
    /// allocating the joined string.
    var hasChannelStartID: Bool {
        if storedID == Self.derivedIDMarker { return true }
        let seconds = start.timeIntervalSince1970
        guard seconds.isFinite, abs(seconds) < 1e15 else { return false }
        let epoch = Int(seconds)
        let id = storedID.utf8, channel = channelID.utf8
        guard id.count > channel.count + 1, id.starts(with: channel) else { return false }
        let separator = id.index(id.startIndex, offsetBy: channel.count)
        guard id[separator] == UInt8(ascii: "_") else { return false }
        let suffix = storedID[id.index(after: separator)...]
        // Same value and same length as the canonical spelling is canonical.
        return Int(suffix) == epoch && suffix.utf8.count == String(epoch).utf8.count
    }

    var duration: TimeInterval {
        end.timeIntervalSince(start)
    }

    var isNowPlaying: Bool {
        let now = Date()
        return start <= now && end > now
    }

    /// Guide retention applied while a persisted guide is decoded, so expired
    /// rows are dropped on the Int32 columns and never materialized.
    /// Built by `GuideHistory.retentionPolicy`; the result must equal
    /// `GuideHistory.prune` on the fully decoded guide.
    struct RetentionPolicy: Sendable {
        /// Earliest retained instant per guide ID; other IDs are dropped.
        let starts: [String: Date]
        /// Listings must start before this instant.
        let latest: Date
        let maximumDuration: TimeInterval
        let maximumCount: Int
        /// Exact per-listing check (used for rows without Int32 columns).
        let isUsable: @Sendable (EPGProgram, _ earliest: Date) -> Bool
        /// Title rule of `isUsable`, evaluated once per interned string.
        let hasVisibleTitle: @Sendable (String) -> Bool
        /// Sorting/capping for runs that are unsorted or over `maximumCount`.
        let normalize: @Sendable ([EPGProgram], _ earliest: Date) -> [EPGProgram]
    }

    private enum CodingKeys: String, CodingKey {
        case id, channelID, title, description, start, end
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storedID = try container.decode(String.self, forKey: .id)
        channelID = try container.decode(String.self, forKey: .channelID)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decode(String.self, forKey: .description)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(channelID, forKey: .channelID)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
    }
}
