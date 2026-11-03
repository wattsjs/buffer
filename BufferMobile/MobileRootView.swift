import SwiftUI

/// Adaptive root: a tab bar with stacks in compact width (iPhone, Slide
/// Over), and a sidebar + EPG grid split view in regular width (iPad), like
/// the Mac.
struct MobileRootView: View {
    let model: TouchAppModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var model = model
        Group {
            if model.viewModel.playlists.isEmpty {
                NavigationStack {
                    WelcomeView { model.isEditingSources = true }
                        .navigationDestination(isPresented: $model.isEditingSources) {
                            SourceEditorForm(viewModel: model.viewModel) { model.isEditingSources = false }
                        }
                }
            } else if sizeClass == .compact {
                CompactRootView(model: model)
            } else {
                RegularRootView(model: model)
            }
        }
        .modifier(TouchAppObservers(model: model))
        .overlay(alignment: .bottom) { SyncBanner(viewModel: model.viewModel) }
        .fullScreenCover(item: $model.player) { presentation in
            TouchPlayerView(request: presentation.request, viewModel: model.viewModel) { model.player = nil }
        }
    }
}

// MARK: - Compact (iPhone)

private struct CompactRootView: View {
    let model: TouchAppModel
    @State private var tab = Tab.guide

    enum Tab: Hashable { case guide, sports, search, settings }

    var body: some View {
        @Bindable var search = model.search
        TabView(selection: $tab) {
            SwiftUI.Tab("Guide", systemImage: "rectangle.grid.1x2", value: Tab.guide) {
                NavigationStack { GuideScreen(model: model, compact: true) }
            }
            SwiftUI.Tab("Sports", systemImage: "sportscourt", value: Tab.sports) {
                NavigationStack { SportsListView(model: model) }
            }
            SwiftUI.Tab("Settings", systemImage: "gear", value: Tab.settings) {
                NavigationStack { SettingsScreen(model: model) }
            }
            SwiftUI.Tab(value: Tab.search, role: .search) {
                NavigationStack {
                    TouchSearchResults(model: model)
                        .navigationTitle("Search")
                        .searchable(text: Binding(get: { search.query }, set: { search.setQuery($0) }),
                                    prompt: "Programmes, channels, movies")
                }
            }
        }
    }
}

// MARK: - Regular (iPad)

private struct RegularRootView: View {
    let model: TouchAppModel
    @State private var destination: Destination? = .guide(.allChannels)
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    enum Destination: Hashable { case guide(SidebarSelection), sports, search, settings }

    var body: some View {
        @Bindable var viewModel = model.viewModel
        @Bindable var search = model.search
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $destination) {
                SourcesList(viewModel: viewModel)
                Section {
                    CountryFilterRow(model: model)
                }
                Section("Browse") {
                    Label("Sports", systemImage: "sportscourt").tag(Destination.sports)
                    Label("Search", systemImage: "magnifyingglass").tag(Destination.search)
                    Label("Favorites", systemImage: "star").tag(Destination.guide(.favorites))
                    Label("All Channels", systemImage: "list.bullet").tag(Destination.guide(.allChannels))
                }
                Section("Groups") {
                    ForEach(viewModel.groups, id: \.self) { group in
                        Text(group).lineLimit(1).tag(Destination.guide(.group(group)))
                    }
                }
                Section {
                    Label("Settings", systemImage: "gear").tag(Destination.settings)
                }
            }
            .navigationTitle("Buffer")
        } detail: {
            NavigationStack {
                switch destination ?? .guide(.allChannels) {
                case .guide:
                    GuideScreen(model: model, compact: false)
                case .sports:
                    SportsListView(model: model)
                case .search:
                    TouchSearchResults(model: model)
                        .navigationTitle("Search")
                        .searchable(text: Binding(get: { search.query }, set: { search.setQuery($0) }),
                                    prompt: "Programmes, channels, movies")
                case .settings:
                    SettingsScreen(model: model)
                }
            }
        }
        .onChange(of: destination) { _, next in
            if case .guide(let selection) = next { viewModel.selection = selection }
        }
    }
}

// MARK: - Guide

/// The EPG grid for the current group, with the group, source and country
/// pickers in the toolbar.
struct GuideScreen: View {
    let model: TouchAppModel
    let compact: Bool

    var body: some View {
        @Bindable var viewModel = model.viewModel
        Group {
            if viewModel.filteredChannels.isEmpty {
                if viewModel.hasLoadedOnce {
                    ContentUnavailableView("No Channels", systemImage: "tv",
                                           description: Text("This source or group has no channels."))
                } else {
                    ProgressView(viewModel.loadingStage ?? "Loading channels…")
                }
            } else {
                GuideGrid(
                    channels: viewModel.filteredChannels,
                    channelSetVersion: viewModel.filteredChannelSetVersion,
                    guideVersion: viewModel.guideVersion,
                    compact: compact,
                    programs: { channel, start, end in viewModel.programsForChannel(channel, between: start, and: end) },
                    onSelectChannel: { model.openChannel($0) },
                    onSelectProgram: { channel, program in
                        if program.end < Date(), channel.canReplay(program) {
                            model.openCatchup(channel, program: program)
                        } else {
                            model.openChannel(channel)
                        }
                    },
                    onVisibleChannels: { viewModel.syncCatchupGuideIfNeeded(for: $0) }
                )
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if compact {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Group", selection: $viewModel.selection) {
                            Text("All Channels").tag(SidebarSelection.allChannels)
                            Text("Favorites").tag(SidebarSelection.favorites)
                            ForEach(viewModel.groups, id: \.self) { Text($0).tag(SidebarSelection.group($0)) }
                        }
                        Divider()
                        SourcesList(viewModel: viewModel)
                    } label: {
                        Label("Browse", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    CountryFilterButton(model: model)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { viewModel.sync() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .onAppear {
            if case .home = viewModel.selection { viewModel.selection = .allChannels }
        }
    }

    private var title: String {
        switch model.viewModel.selection {
        case .favorites: "Favorites"
        case .group(let group): group
        default: model.viewModel.isSmartSportsActive ? "Smart Channels" : (model.viewModel.activePlaylist?.name ?? "Guide")
        }
    }
}

// MARK: - Country filter

/// Sidebar row on iPad: opens the editor in a popover beside the sidebar.
private struct CountryFilterRow: View {
    let model: TouchAppModel

    var body: some View {
        @Bindable var model = model
        let viewModel = model.viewModel
        Button { model.isEditingCountryFilter = true } label: {
            HStack {
                Image(systemName: viewModel.smartSports.filter.isEnabled ? "globe.americas.fill" : "globe.americas")
                    .foregroundStyle(viewModel.smartSports.filter.isEnabled ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(CountryFilterSummary.title(viewModel.smartSports.filter)).lineLimit(1)
                    Text(CountryFilterSummary.counts(viewModel.countryFilterCounts, enabled: viewModel.smartSports.filter.isEnabled))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("country-filter")
        .popover(isPresented: $model.isEditingCountryFilter, arrowEdge: .trailing) {
            CountryFilterEditor(viewModel: viewModel)
                .frame(minWidth: 420, idealWidth: 460, minHeight: 560, idealHeight: 620)
        }
    }
}

/// Toolbar button on iPhone: the popover adapts to a sheet in compact width.
private struct CountryFilterButton: View {
    let model: TouchAppModel

    var body: some View {
        @Bindable var model = model
        Button { model.isEditingCountryFilter = true } label: {
            Label("Countries", systemImage: model.viewModel.smartSports.filter.isEnabled ? "globe.americas.fill" : "globe.americas")
        }
        .accessibilityIdentifier("country-filter")
        .sheet(isPresented: $model.isEditingCountryFilter) {
            NavigationStack {
                CountryFilterEditor(viewModel: model.viewModel)
                    .navigationTitle("Countries")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.isEditingCountryFilter = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Status

private struct SyncBanner: View {
    let viewModel: EPGViewModel

    var body: some View {
        if viewModel.isRefreshing || viewModel.smartSports.isLoading {
            HStack(spacing: 8) {
                ProgressView()
                Text(viewModel.smartSports.isLoading ? "Loading Smart Channels…" : (viewModel.loadingStage ?? "Syncing…"))
                    .font(.footnote)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect()
            .padding(.bottom, 60)
            .allowsHitTesting(false)
        }
    }
}
