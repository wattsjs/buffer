import Foundation
import Observation

/// Window-owned drafts survive section and source navigation. This store does
/// not persist anything; only the editor's explicit save action does that.
@MainActor
@Observable
final class SettingsSourceWorkspace {
    var selectedSourceID: UUID?
    private(set) var sessions: [UUID: SettingsSourceSession] = [:]
    private(set) var newSourceIDs: [UUID] = []

    func reconcile(_ configurations: [ServerConfig], activeID: UUID?) {
        let savedIDs = Set(configurations.map(\.id))
        for config in configurations {
            if let session = sessions[config.id] { session.mergeStored(config) }
            else { sessions[config.id] = SettingsSourceSession(config: config, isNew: false) }
        }
        sessions = sessions.filter { savedIDs.contains($0.key) || $0.value.isNew }
        newSourceIDs.removeAll { savedIDs.contains($0) || sessions[$0] == nil }
        if let selectedSourceID, sessions[selectedSourceID] != nil { return }
        selectedSourceID = activeID.flatMap { sessions[$0] != nil ? $0 : nil }
            ?? configurations.first?.id ?? newSourceIDs.first
    }

    @discardableResult
    func addSource() -> SettingsSourceSession {
        let config = ServerConfig()
        let session = SettingsSourceSession(config: config, isNew: true)
        sessions[config.id] = session
        newSourceIDs.append(config.id)
        selectedSourceID = config.id
        return session
    }

    func discardNewSource(_ id: UUID) {
        guard sessions[id]?.isNew == true else { return }
        sessions.removeValue(forKey: id)
        newSourceIDs.removeAll { $0 == id }
        if selectedSourceID == id { selectedSourceID = nil }
    }
}

@MainActor
@Observable
final class SettingsSourceSession: Identifiable {
    let id: UUID
    var draft: ServerConfig
    private(set) var stored: ServerConfig
    private(set) var isNew: Bool

    init(config: ServerConfig, isNew: Bool) {
        id = config.id
        draft = config
        stored = config
        self.isNew = isNew
    }

    var hasChanges: Bool { isNew || SettingsSourceDraft.fingerprint(draft) != SettingsSourceDraft.fingerprint(stored) }

    func mergeStored(_ incoming: ServerConfig) {
        guard incoming.id == id else { return }
        draft = SettingsSourceDraft.merging(incoming, into: draft, previouslyStored: stored)
        stored = incoming
        isNew = false
    }

    func markApplied() {
        stored = draft
        isNew = false
    }

    func revert() { draft = stored }
}
