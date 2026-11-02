import Foundation

@main
@MainActor
enum SettingsWorkspaceTests {
    static func main() {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
        let a = ServerConfig(name: "Fixture A", type: .xtream, serverURL: "http://127.0.0.1/a", username: "fixture", password: "")
        let b = ServerConfig(name: "Fixture B", type: .m3u, m3uURL: "http://127.0.0.1/b.m3u")
        let workspace = SettingsSourceWorkspace()
        let untouchedWorkspace = SettingsSourceWorkspace()
        untouchedWorkspace.reconcile([a], activeID: a.id)
        var loadedCredentials = a; loadedCredentials.password = "fixture-loaded-password"
        untouchedWorkspace.reconcile([loadedCredentials], activeID: a.id)
        expect(untouchedWorkspace.sessions[a.id]?.draft.password == loadedCredentials.password &&
            untouchedWorkspace.sessions[a.id]?.hasChanges == false,
            "A late password read updates an untouched draft without marking it dirty")
        workspace.reconcile([a, b], activeID: b.id)
        expect(workspace.selectedSourceID == b.id && workspace.sessions.count == 2, "Saved sources seed stable sessions and the current original source")
        let editorA = workspace.sessions[a.id]!
        workspace.selectedSourceID = a.id
        editorA.draft.name = "User-edited name"
        editorA.draft.serverURL = "http://127.0.0.1/edited"
        workspace.selectedSourceID = b.id
        workspace.selectedSourceID = a.id
        expect(workspace.sessions[a.id] === editorA && editorA.hasChanges, "Navigating between sources retains the same unsaved editor state")
        expect(editorA.draft.name == "User-edited name" && editorA.draft.serverURL.hasSuffix("edited"), "Navigation cannot silently revert source edits")
        var arrived = a; arrived.password = "fixture-keychain-password"; arrived.username = "updated-fixture"
        workspace.reconcile([arrived, b], activeID: b.id)
        expect(editorA.draft.password == arrived.password && editorA.draft.username == arrived.username,
            "Late stored credentials merge into fields the user has not edited")
        expect(editorA.draft.name == "User-edited name" && editorA.draft.serverURL.hasSuffix("edited"),
            "Late stored metadata does not overwrite dirty fields")
        editorA.draft.password = "user-password-edit"
        var later = arrived; later.password = "later-fixture-password"
        workspace.reconcile([later, b], activeID: b.id)
        expect(editorA.draft.password == "user-password-edit", "A later credential read cannot replace the user’s password draft")
        expect(a.password.isEmpty && a.name == "Fixture A", "Workspace editing does not mutate or persist the supplied saved configurations")
        editorA.revert()
        expect(!editorA.hasChanges && editorA.draft.password == later.password && editorA.draft.name == later.name,
            "Revert returns to the latest stored snapshot rather than an old initial value")

        let newEditor = workspace.addSource()
        let newID = newEditor.id
        newEditor.draft.name = "New fixture source"
        newEditor.draft.m3uURL = "http://127.0.0.1/new.m3u"
        newEditor.draft.type = .m3u
        workspace.selectedSourceID = b.id
        workspace.reconcile([later, b], activeID: b.id)
        expect(workspace.sessions[newID] === newEditor && workspace.newSourceIDs.contains(newID), "New source drafts survive other section/source activity")
        expect(newEditor.isNew && newEditor.hasChanges && newEditor.draft.id == newID, "Unsaved new source identity remains stable")
        newEditor.markApplied()
        workspace.reconcile([later, b, newEditor.draft], activeID: b.id)
        expect(workspace.sessions[newID] === newEditor && !newEditor.isNew && !newEditor.hasChanges && !workspace.newSourceIDs.contains(newID),
            "Explicit save moves the same draft session into saved sources without losing its UUID")
        workspace.selectedSourceID = a.id
        workspace.reconcile([b, newEditor.draft], activeID: b.id)
        expect(workspace.sessions[a.id] == nil && workspace.selectedSourceID == b.id, "Deleted source metadata cannot resurrect an obsolete editor")
        let discard = workspace.addSource()
        workspace.discardNewSource(discard.id)
        expect(workspace.sessions[discard.id] == nil && !workspace.newSourceIDs.contains(discard.id), "Explicit draft discard removes only that new session")
        let oldSnapshot = editorA.draft
        editorA.mergeStored(b)
        expect(SettingsSourceDraft.fingerprint(editorA.draft) == SettingsSourceDraft.fingerprint(oldSnapshot),
            "Cross-source metadata cannot merge into an existing draft")
        print("Settings workspace checks: \(checks) passed")
    }
}
