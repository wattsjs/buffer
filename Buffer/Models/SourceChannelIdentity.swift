import Foundation

/// A provider's native ID is only meaningful within its configured source.
nonisolated struct SourceChannelIdentity: Codable, Hashable, Sendable {
    let sourceID: UUID
    let nativeID: String

    var rawValue: String { sourceID.uuidString.lowercased() + "|" + nativeID }
}

/// Only a digest or a source-scoped fallback is stored. Account credentials
/// and the canonical input used to derive this key must never be persisted.
nonisolated struct SourceAccountKey: Codable, Hashable, Sendable {
    let rawValue: String

    init(opaqueValue: String) {
        rawValue = opaqueValue
    }

    static func unconfiguredSource(_ sourceID: UUID) -> Self {
        Self(opaqueValue: "source:" + sourceID.uuidString.lowercased())
    }
}

/// Raw guide IDs remain source-specific; equality of these IDs is not proof
/// that two video feeds or their programme times are interchangeable.
nonisolated struct SourceGuideBinding: Codable, Hashable, Sendable {
    let sourceID: UUID
    let epgChannelID: String
}

nonisolated struct ChannelSourceOwnership: Codable, Hashable, Sendable {
    let channelIdentity: SourceChannelIdentity
    let accountKey: SourceAccountKey
    let logicalChannelID: String?
    let guideBinding: SourceGuideBinding?

    init(
        channelIdentity: SourceChannelIdentity,
        accountKey: SourceAccountKey,
        logicalChannelID: String? = nil,
        guideBinding: SourceGuideBinding? = nil
    ) {
        self.channelIdentity = channelIdentity
        self.accountKey = accountKey
        self.logicalChannelID = logicalChannelID
        self.guideBinding = guideBinding
    }

    var preferenceIdentity: String { logicalChannelID ?? channelIdentity.rawValue }
}
