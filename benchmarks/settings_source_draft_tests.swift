import Foundation

@main struct SettingsSourceDraftTests {
    static func main() {
        let id = UUID()
        let original = ServerConfig(id: id, name: "Saved source", type: .xtream,
                                    serverURL: "https://old.invalid", username: "old-user", password: "",
                                    m3uURL: "https://old.invalid/list", epgURL: "https://old.invalid/guide")
        var incoming = original
        incoming.name = "Stored rename"
        incoming.type = .m3u
        incoming.serverURL = "https://new.invalid"
        incoming.username = "stored-user"
        incoming.password = "stored-fixture"
        incoming.m3uURL = "https://new.invalid/list"
        incoming.epgURL = "https://new.invalid/guide"

        // A keychain completion must update an untouched editor without
        // erasing any combination of fields typed while the read was pending.
        let stringFields: [WritableKeyPath<ServerConfig, String>] = [
            \.name, \.serverURL, \.username, \.password, \.m3uURL, \.epgURL
        ]
        var checks = 0
        for mask in 0..<(1 << (stringFields.count + 1)) {
            var draft = original
            for (index, field) in stringFields.enumerated() where mask & (1 << index) != 0 {
                draft[keyPath: field] = "Typed field \(index)"
            }
            if mask & (1 << stringFields.count) != 0 { draft.type = .stalker }
            let merged = SettingsSourceDraft.merging(incoming, into: draft, previouslyStored: original)
            precondition(merged.id == id)
            for (index, field) in stringFields.enumerated() {
                let expected = mask & (1 << index) != 0 ? draft[keyPath: field] : incoming[keyPath: field]
                precondition(merged[keyPath: field] == expected, "Asynchronous stored update overwrote a typed field")
                checks += 1
            }
            precondition(merged.type == (mask & (1 << stringFields.count) != 0 ? .stalker : .m3u))
            checks += 1
        }

        // Later snapshots must compare against the preceding stored value,
        // so an unchanged password follows a subsequent stored rotation.
        var adopted = SettingsSourceDraft.merging(incoming, into: original, previouslyStored: original)
        adopted.name = "Unsaved rename"
        var later = incoming
        later.password = "rotated-fixture"
        let second = SettingsSourceDraft.merging(later, into: adopted, previouslyStored: incoming)
        precondition(second.name == "Unsaved rename" && second.password == later.password)
        checks += 1

        // Explicit clearing is an edit too, even if the stored value arrives
        // from another window or an asynchronous read.
        var cleared = incoming
        cleared.password = ""
        let preserved = SettingsSourceDraft.merging(later, into: cleared, previouslyStored: incoming)
        precondition(preserved.password.isEmpty)
        checks += 1

        var other = incoming
        other = ServerConfig(id: UUID(), name: other.name, password: other.password)
        precondition(SettingsSourceDraft.fingerprint(SettingsSourceDraft.merging(other, into: adopted, previouslyStored: incoming)) == SettingsSourceDraft.fingerprint(adopted))
        precondition(SettingsSourceDraft.fingerprint(SettingsSourceDraft.merging(incoming, into: adopted, previouslyStored: other)) == SettingsSourceDraft.fingerprint(adopted))
        checks += 2
        precondition(SettingsSourceDraft.fingerprint(original) != SettingsSourceDraft.fingerprint(incoming))
        checks += 1
        print("PASS \(checks) source editor checks: pending stored updates, all field-edit combinations, subsequent rotations, explicit clearing, and source identity rejection")
    }
}
