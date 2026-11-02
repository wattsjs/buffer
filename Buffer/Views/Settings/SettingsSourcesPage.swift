import SwiftUI

struct SourcesSettingsPage: View {
    @Bindable var viewModel: EPGViewModel
    @Bindable var workspace: SettingsSourceWorkspace
    @State private var sourceToRemove: UUID?

    var body: some View {
        HSplitView {
            List(selection: $workspace.selectedSourceID) {
                if !viewModel.playlists.isEmpty {
                    Section("Saved sources") {
                        ForEach(viewModel.playlists) { config in
                            if let session = workspace.sessions[config.id] {
                                sourceRow(session, active: config.id == viewModel.activePlaylistID && !viewModel.isSmartSportsActive)
                                    .tag(config.id)
                            }
                        }
                    }
                }
                if !workspace.newSourceIDs.isEmpty {
                    Section("New sources") {
                        ForEach(workspace.newSourceIDs, id: \.self) { id in
                            if let session = workspace.sessions[id] { sourceRow(session, active: false).tag(id) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 175, idealWidth: 200, maxWidth: 260)

            Group {
                if let id = workspace.selectedSourceID, let session = workspace.sessions[id] {
                    SettingsSourceEditor(viewModel: viewModel, session: session)
                        .id(id)
                } else {
                    ContentUnavailableView {
                        Label("Add a source", systemImage: "tv.badge.wifi")
                    } description: {
                        Text("Connect an Xtream Codes account, Stalker portal or M3U playlist.")
                    } actions: {
                        Button("Add Source") { workspace.addSource() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { workspace.addSource() } label: { Label("Add Source", systemImage: "plus") }
                    .help("Add a source")
                Button { sourceToRemove = workspace.selectedSourceID } label: { Label("Remove Source", systemImage: "minus") }
                    .disabled(workspace.selectedSourceID == nil).help("Remove the selected source")
            }
        }
        .confirmationDialog("Remove this source?", isPresented: Binding(
            get: { sourceToRemove != nil }, set: { if !$0 { sourceToRemove = nil } }), titleVisibility: .visible) {
                Button("Remove Source", role: .destructive) { removeSelectedSource() }
                Button("Cancel", role: .cancel) { sourceToRemove = nil }
            } message: {
                Text("A saved source’s credentials are removed. Existing recordings are kept. A new draft is discarded.")
            }
    }

    private func sourceRow(_ session: SettingsSourceSession, active: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: session.isNew ? "plus.circle" : "server.rack").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.draft.name.isEmpty ? "Untitled source" : session.draft.name).lineLimit(1)
                Text(session.isNew ? "Unsaved draft" : session.hasChanges ? "Unsaved changes" : active ? "In use" : session.draft.type.settingsTitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func removeSelectedSource() {
        guard let id = sourceToRemove else { return }
        sourceToRemove = nil
        if workspace.sessions[id]?.isNew == true { workspace.discardNewSource(id) }
        else { viewModel.removePlaylist(id: id) }
        workspace.reconcile(viewModel.playlists, activeID: viewModel.activePlaylistID)
    }
}

extension ServerType {
    var settingsTitle: String {
        switch self {
        case .xtream: "Xtream Codes"
        case .stalker: "Stalker / MAG"
        case .m3u: "M3U playlist"
        }
    }
}
