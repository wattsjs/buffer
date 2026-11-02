import Foundation

typealias SmartSportsEndpointKey = SourceChannelIdentity

/// Only display metadata lives in the bundled proposal and persisted overrides.
/// Authenticated endpoints are always resolved from a current configured source.
nonisolated struct SmartSportsMetadataIdentity: Codable, Hashable, Sendable {
    let name: String
    let group: String
    let epgChannelID: String?

    init(name: String, group: String, epgChannelID: String?) {
        self.name = name
        self.group = group
        self.epgChannelID = epgChannelID
    }

    init(channel: Channel) {
        self.init(name: channel.name, group: channel.group, epgChannelID: channel.epgChannelID)
    }

    func matches(_ other: Self) -> Bool {
        Self.normalized(name) == Self.normalized(other.name)
            && Self.normalized(group) == Self.normalized(other.group)
            && epgChannelID?.trimmingCharacters(in: .whitespacesAndNewlines)
                == other.epgChannelID?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

nonisolated struct SmartSportsVariantDefinition: Codable, Sendable {
    let sourceID: UUID
    let sourceName: String
    let nativeID: String
    let identity: SmartSportsMetadataIdentity
    let advertisedFormat: String
    let advertisedFPS: Double?
    let width: Int?
    let height: Int?
    let fps: Double?
    let measuredAt: String?
    let measurementContext: String

    var key: SmartSportsEndpointKey { .init(sourceID: sourceID, nativeID: nativeID) }
}

nonisolated struct SmartSportsFeedDefinition: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let country: String
    let language: String
    let edition: String
    let guideStatus: String
    let caveats: [String]
    let variants: [SmartSportsVariantDefinition]
}

nonisolated struct SmartSportsHeldEndpoint: Codable, Sendable {
    let sourceID: UUID
    let nativeID: String
    let reason: String
    var key: SmartSportsEndpointKey { .init(sourceID: sourceID, nativeID: nativeID) }
}

nonisolated struct SmartSportsDefinition: Codable, Sendable {
    let schemaVersion: Int
    let playlistID: String
    let name: String
    let provenance: String
    let feeds: [SmartSportsFeedDefinition]
    let heldEndpoints: [SmartSportsHeldEndpoint]

    func reconcile(
        snapshots: [SmartSportsSourceSnapshot],
        overrides: SmartSportsOverrides = .init(),
        observations: [SmartSportsEndpointKey: SmartSportsObservation] = [:]
    ) -> SmartSportsCatalog {
        SmartSportsCatalog.reconcile(definition: self, snapshots: snapshots,
                                     overrides: overrides, observations: observations)
    }
}

nonisolated struct SmartSportsSourceSnapshot: Sendable {
    let sourceID: UUID
    let sourceName: String
    let channels: [Channel]
}

nonisolated struct SmartSportsManualFeed: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    var country: String
    var language: String
    var edition: String
}

nonisolated struct SmartSportsManualLink: Codable, Sendable {
    let feedID: String
    let identity: SmartSportsMetadataIdentity
}

nonisolated struct SmartSportsOverrides: Codable, Sendable {
    var schemaVersion = 1
    /// A split is a manual feed plus an explicit link of an endpoint to it.
    /// Keys are source-scoped. A later refresh can never silently undo a split.
    var customFeeds: [SmartSportsManualFeed] = []
    var links: [String: SmartSportsManualLink] = [:]
    var rejectedEndpointKeys: Set<String> = []
    var acceptedIdentities: [String: SmartSportsMetadataIdentity] = [:]
    var preferredVariants: [String: String] = [:]
    var preferredGuides: [String: String] = [:]

    mutating func link(_ key: SmartSportsEndpointKey, to feedID: String,
                       identity: SmartSportsMetadataIdentity) {
        links[key.rawValue] = .init(feedID: feedID, identity: identity)
        rejectedEndpointKeys.remove(key.rawValue)
    }

    @discardableResult
    mutating func split(_ key: SmartSportsEndpointKey, name: String, country: String,
                        language: String, edition: String,
                        identity: SmartSportsMetadataIdentity) -> String {
        let id = "smart:sports:manual:\(UUID().uuidString.lowercased())"
        customFeeds.append(.init(id: id, name: name, country: country,
                                 language: language, edition: edition))
        link(key, to: id, identity: identity)
        return id
    }

    mutating func reject(_ key: SmartSportsEndpointKey) {
        rejectedEndpointKeys.insert(key.rawValue)
    }
}

nonisolated enum SmartSportsMembershipState: String, Sendable {
    case metadataCandidate
    case manuallyReviewed
    case changedIdentity
    case missing
    case duplicateNativeID
    case rejected
    case heldForReview

    var isPlayable: Bool { self == .metadataCandidate || self == .manuallyReviewed }
}

nonisolated struct SmartSportsVariant: Identifiable, Sendable {
    let key: SmartSportsEndpointKey
    let feedID: String
    let sourceName: String
    let expectedIdentity: SmartSportsMetadataIdentity
    let physicalChannel: Channel?
    let state: SmartSportsMembershipState
    let advertisedFormat: String
    let advertisedFPS: Double?
    let observation: SmartSportsObservation?

    var id: String { key.rawValue }
    var isPlayable: Bool { state.isPlayable && physicalChannel != nil }
    var guideBinding: SourceGuideBinding? {
        guard isPlayable, let guideID = physicalChannel?.epgChannelID,
              !guideID.isEmpty else { return nil }
        return .init(sourceID: key.sourceID, epgChannelID: guideID)
    }
}

nonisolated struct SmartSportsFeed: Identifiable, Sendable {
    let id: String
    let name: String
    let country: String
    let language: String
    let edition: String
    let guideStatus: String
    let caveats: [String]
    let variants: [SmartSportsVariant]

    var availableVariants: [SmartSportsVariant] { variants.filter(\.isPlayable) }
}

nonisolated struct SmartSportsReviewItem: Identifiable, Sendable {
    let key: SmartSportsEndpointKey
    let feedID: String?
    let reason: String
    let state: SmartSportsMembershipState
    var id: String { key.rawValue }
}

/// Observed format and reliability are deliberately separate. A successful
/// short probe tells us format; it does not establish sustained reliability.
nonisolated struct SmartSportsObservation: Codable, Sendable {
    enum Provenance: String, Codable, Sendable {
        case passivePlayback
        case shortPlayback
        case formatProbe
        case legacyCachedFormat
    }
    let observedAt: Date
    let provenance: Provenance
    /// A one-way endpoint digest ties an observation to the URL revision that
    /// actually played. The URL itself never enters the observations store.
    var endpointFingerprint: String?
    var playedSeconds: Double = 0
    var startupSeconds: Double?
    var stalledSeconds: Double = 0
    var failures: Int = 0
    var droppedFrames: Int?
    var renderedFrames: Int?
    var width: Int?
    var height: Int?
    var fps: Double?
    var videoCodec: String?
    var hdr: Bool?
    /// Measured distance behind the live edge; lower reaches the action first.
    var liveDelaySeconds: Double? = nil
    /// Probed transport bitrate in bits/sec.
    var bitRate: Int64? = nil

    func isFresh(now: Date, maximumAge: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= -60 && age <= maximumAge
    }

    /// Unknown sits between recently failed and sustained clean playback.
    /// This is a measured evidence category, never a fabricated quality score.
    func reliabilityClass(now: Date) -> Int {
        guard provenance != .formatProbe, provenance != .legacyCachedFormat,
              isFresh(now: now, maximumAge: 24 * 3600) else { return 1 }
        if failures > 0 || stalledSeconds > 3 { return 0 }
        if let droppedFrames, let renderedFrames, renderedFrames > 0,
           Double(droppedFrames) / Double(renderedFrames) > 0.02 { return 0 }
        if provenance == .passivePlayback && playedSeconds >= 180 && stalledSeconds <= 0.5 { return 2 }
        return 1
    }
}

nonisolated struct SmartSportsSelectionContext: Sendable {
    enum Mode: String, Sendable { case live, catchup, recording }
    var mode: Mode = .live
    var now: Date = Date()
    /// These exclusions are supplied by the actual account/device owner.
    var unavailableSources: Set<UUID> = []
    var unavailableEndpoints: Set<SmartSportsEndpointKey> = []
    /// Fresh, endpoint-bound failed probes are a soft initial-selection signal.
    /// They do not remove membership or erase a user's saved preference.
    var recentFailedEndpoints: Set<SmartSportsEndpointKey> = []
    var unsupportedVideoCodecs: Set<String> = []
    var supportsHDR = true
    var usefulHeight = 2160
    var requestedArchiveStart: Date?
    /// Only endpoints with checked programme timing may satisfy an archive action.
    /// A provider's advertised days alone never enters this set.
    var validatedArchiveKeys: Set<SmartSportsEndpointKey> = []
}

nonisolated struct SmartSportsAvailability: Sendable {
    enum State: Equatable, Sendable { case unavailable, busy, observedAvailable, uncertain, observedFailures }
    let state: State
    let variantCount: Int
    let observedAvailableCount: Int
    let uncertainCount: Int
    let observedFailureCount: Int

    var message: String {
        switch state {
        case .unavailable: "No current source is available; check membership reviews."
        case .busy: "Current source accounts are busy."
        case .observedAvailable: "A current source has a recent successful observation."
        case .uncertain: "Current source availability is unmeasured."
        case .observedFailures: "Current sources have recent failed observations; retry is still possible."
        }
    }
}

nonisolated struct SmartSportsSelection: Sendable {
    let feedID: String
    let selected: SmartSportsVariant
    let alternatives: [SmartSportsVariant]
    let reasons: [String]
    let uncertainty: [String]
}

nonisolated struct SmartSportsGuideSelection: Sendable {
    let key: SmartSportsEndpointKey
    let binding: SourceGuideBinding
    let programs: [EPGProgram]
    let timingNeedsReview: Bool
}
