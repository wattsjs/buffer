import Foundation

/// Stored credentials may arrive after the editor appears. Adopt only fields
/// the user has not changed since the preceding stored snapshot.
nonisolated enum SettingsSourceDraft {
    static func fingerprint(_ config: ServerConfig) -> [String] {
        [config.id.uuidString, config.name, config.type.rawValue, config.serverURL,
         config.username, config.password, config.m3uURL, config.epgURL]
    }

    static func merging(_ incoming: ServerConfig, into draft: ServerConfig,
                        previouslyStored previous: ServerConfig) -> ServerConfig {
        guard incoming.id == draft.id, previous.id == draft.id else { return draft }
        var result = draft
        if draft.name == previous.name { result.name = incoming.name }
        if draft.type == previous.type { result.type = incoming.type }
        if draft.serverURL == previous.serverURL { result.serverURL = incoming.serverURL }
        if draft.username == previous.username { result.username = incoming.username }
        if draft.password == previous.password { result.password = incoming.password }
        if draft.m3uURL == previous.m3uURL { result.m3uURL = incoming.m3uURL }
        if draft.epgURL == previous.epgURL { result.epgURL = incoming.epgURL }
        return result
    }
}
