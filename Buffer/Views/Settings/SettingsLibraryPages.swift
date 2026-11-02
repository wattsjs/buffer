import SwiftUI

struct LibrarySettingsPage: View {
    @Bindable var viewModel: EPGViewModel
    @AppStorage(EPGViewModel.disableVODKey) private var disableVOD = false
    @AppStorage(SyncInterval.playlistStorageKey) private var refreshHours = SyncInterval.playlistDefault.hours

    var body: some View {
        SettingsFormPage(title: "Library", detail: "Choose what appears in your library and keep source channels current.") {
            Section {
                Toggle("Movies and TV", isOn: Binding(get: { !disableVOD }, set: { disableVOD = !$0 }))
                Text("Includes movies and series in the library, search and source refreshes.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Visible content") }

            Section {
                Picker("Refresh source channels", selection: $refreshHours) {
                    ForEach(SyncInterval.allCases) { interval in Text(interval.title).tag(interval.hours) }
                }
                SettingsRefreshRow(viewModel: viewModel, scope: .all)
            } header: { Text("Source refresh") } footer: {
                Text("Automatic refresh runs while Buffer is open. Never also disables refresh on launch.")
            }

            Section {
                LabeledContent("Recently watched", value: "\(viewModel.recentChannelIDs.count) channels")
                Button("Clear Recently Watched", role: .destructive) { viewModel.clearRecentlyWatched() }
                    .disabled(viewModel.recentChannelIDs.isEmpty)
                Button("Reset Recommendations", role: .destructive) { viewModel.resetRecommendations() }
                    .disabled(viewModel.recentChannelIDs.isEmpty && viewModel.channelUsageCounts.isEmpty && viewModel.groupUsageCounts.isEmpty)
            } header: { Text("History and suggestions") } footer: {
                Text("These actions apply to the selected playlist. Favorites are kept.")
            }
        }
        .onChange(of: disableVOD) { _, disabled in viewModel.applyVODPreference(disabled: disabled) }
        .onChange(of: refreshHours) { _, _ in viewModel.startSyncScheduler() }
    }
}

struct GuideSportsSettingsPage: View {
    @Bindable var viewModel: EPGViewModel
    @AppStorage("hideSport") private var hideSport = false
    @AppStorage(CatchupLookbackSetting.appStorageKey) private var lookback = CatchupLookbackSetting.default.rawValue
    @AppStorage(SyncInterval.epgStorageKey) private var refreshHours = SyncInterval.epgDefault.hours

    var body: some View {
        SettingsFormPage(title: "Guide & Sports", detail: "Set guide history, live sports visibility and channel folder organization.") {
            Section {
                Picker("Archive history", selection: Binding(
                    get: { CatchupLookbackSetting.stored(rawValue: lookback).rawValue }, set: { lookback = $0 })) {
                    ForEach(CatchupLookbackSetting.allCases) { option in Text(option.title).tag(option.rawValue) }
                }
                Picker("Refresh programme guide", selection: $refreshHours) {
                    ForEach(SyncInterval.allCases) { interval in Text(interval.title).tag(interval.hours) }
                }
                SettingsRefreshRow(viewModel: viewModel, scope: .epg)
            } header: { Text("Programme guide") } footer: {
                Text("Archive history applies to channels with catchup. Source-provided programme times are preserved.")
            }

            Section {
                Toggle("Live sports scores", isOn: Binding(get: { !hideSport }, set: { hideSport = !$0 }))
            } header: { Text("Sports") } footer: {
                Text("Shows live fixtures and scores on Home and in Sports. Turning this off stops background sports refreshes.")
            }

            Section {
                LabeledContent("Hidden folders", value: "\(viewModel.hiddenGroups.count)")
                Button("Show All Hidden Folders") { viewModel.showAllGroups() }.disabled(viewModel.hiddenGroups.isEmpty)
                Button("Reset Folder Order") { viewModel.resetGroupOrder() }.disabled(viewModel.storedGroupOrder.isEmpty)
            } header: { Text("Channel folders") } footer: {
                Text("Restore hidden folders or return this playlist to its default ordering.")
            }
        }
        .onChange(of: refreshHours) { _, _ in viewModel.startSyncScheduler() }
    }
}

struct SettingsRefreshRow: View {
    let viewModel: EPGViewModel
    let scope: EPGViewModel.SyncScope

    var body: some View {
        HStack {
            if viewModel.isRefreshing || viewModel.smartSports.isLoading {
                ProgressView().controlSize(.small)
                Text(viewModel.loadingStage ?? "Refreshing…").foregroundStyle(.secondary)
            } else if viewModel.isSmartSportsActive {
                Text("Refresh original sources to update their listings.").foregroundStyle(.secondary)
            } else if let updated = viewModel.lastUpdated {
                Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
            } else {
                Text("Not refreshed yet").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh Now") { viewModel.sync(scope: scope) }
                .disabled(viewModel.isRefreshing || viewModel.smartSports.isLoading || viewModel.activePlaylist == nil)
        }
    }
}
