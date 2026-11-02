import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: EPGViewModel
    @State private var section: SettingsSection = .sources
    @State private var searchText = ""
    @State private var sources = SettingsSourceWorkspace()
    @FocusState private var searchFocused: Bool

    private var sourceRevision: [[String]] { viewModel.playlists.map(SettingsSourceDraft.fingerprint) }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $section, query: searchText)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
        } detail: {
            if !SettingsSection.allCases.contains(where: { $0.matches(searchText) }) {
                ContentUnavailableView.search(text: searchText)
            } else {
                detail.navigationTitle(section.title)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Find a setting")
        .searchFocused($searchFocused)
        .frame(minWidth: 900, idealWidth: 1120, minHeight: 620, idealHeight: 760)
        .onAppear { sources.reconcile(viewModel.playlists, activeID: viewModel.activePlaylistID) }
        .onChange(of: sourceRevision) { _, _ in sources.reconcile(viewModel.playlists, activeID: viewModel.activePlaylistID) }
        .onChange(of: searchText) { _, query in
            let matches = SettingsSection.allCases.filter { $0.matches(query) }
            if !matches.contains(section), let first = matches.first { section = first }
        }
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0).hidden()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .sources: SourcesSettingsPage(viewModel: viewModel, workspace: sources)
        case .library: LibrarySettingsPage(viewModel: viewModel)
        case .guide: GuideSportsSettingsPage(viewModel: viewModel)
        case .playback: PlaybackSettingsPage()
        case .recordings: RecordingsSettingsPage()
        case .appearance: AppearanceSettingsPage()
        }
    }
}
