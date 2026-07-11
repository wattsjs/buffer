//
//  ContentView.swift
//  Buffer
//
//  Created by Jamie Watts on 14/4/2026.
//

import OSLog
import SwiftUI

struct ContentView: View {
    @State var viewModel: EPGViewModel
    @State private var searchController = ProgramSearchController()
    @State private var sportsViewModel = SportsViewModel()
    @State private var appFeedback = AppFeedbackCenter.shared
    @State private var selectionBeforeSearch: SidebarSelection?
    @State private var didSchedulePlayerPrewarm = false
    @FocusState private var searchFieldFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @AppStorage(ExternalPlayer.selectedPlayerKey) private var selectedPlayer: ExternalPlayerKind = .none
    @AppStorage("hideSport") private var hideSport = false
    @AppStorage(EPGViewModel.disableVODKey) private var disableVOD = false
    @AppStorage(CatchupLookbackSetting.appStorageKey) private var catchupLookbackRawValue = CatchupLookbackSetting.default.rawValue

    private var playlistSelectionBinding: Binding<UUID> {
        Binding(
            get: { viewModel.activePlaylistID ?? viewModel.playlists.first?.id ?? UUID() },
            set: { viewModel.setActivePlaylist(id: $0) }
        )
    }

    private func openChannel(_ channel: Channel) {
        open(.live(channel))
    }

    private func openCatchup(_ channel: Channel, program: EPGProgram) {
        open(.catchup(channel, from: program.start))
    }

    private func open(_ request: PlaybackRequest) {
        let channel = request.channel
        if selectedPlayer != .none {
            viewModel.addRecent(channel)
            updateSportsMatchingPreferences()
            AppLog.playback.info("Opening channel externally name=\(channel.name, privacy: .public) player=\(selectedPlayer.displayName, privacy: .public)")
            ExternalPlayer.launch(streamURL: externalPlayerURL(for: request), using: selectedPlayer)
            return
        }

        AppLog.playback.info("Opening channel in Buffer name=\(channel.name, privacy: .public)")
        // An already-open window for this channel takes the request in
        // place (and comes to front) instead of spawning a duplicate.
        if !PlayerSessionRegistry.shared.deliver(request) {
            PlayerSession.noteOpen(channel: channel)
            openWindow(value: request)
        }
        Task { @MainActor in
            await Task.yield()
            viewModel.addRecent(channel)
            updateSportsMatchingPreferences()
            scheduleInternalPlayerPrewarm()
        }
    }

    /// External players can't be handed playback intents — resolve the
    /// request to the best matching URL up front.
    private func externalPlayerURL(for request: PlaybackRequest) -> URL {
        let channel = request.channel
        if case .catchup(let start) = request.intent {
            let program = viewModel.program(for: channel, at: start)
            let duration = program.map(\.duration) ?? 2 * 3600
            if let url = CatchupURLBuilder.url(for: channel, start: start, duration: duration) {
                return url
            }
        }
        return channel.streamURL
    }

    private func openVODItem(_ item: VODItem, resumePosition: Double? = nil) {
        Task {
            do {
                let playableItem = try await viewModel.resolveVODItemForPlayback(item)
                let channel = playableItem.playbackChannel
                viewModel.noteVODOpened(playableItem)
                if selectedPlayer != .none {
                    AppLog.playback.info("Opening VOD externally name=\(playableItem.name, privacy: .public) player=\(selectedPlayer.displayName, privacy: .public)")
                    ExternalPlayer.launch(streamURL: playableItem.streamURL, using: selectedPlayer)
                } else {
                    AppLog.playback.info("Opening VOD in Buffer name=\(playableItem.name, privacy: .public)")
                    let request: PlaybackRequest = if let resumePosition, resumePosition > 0 {
                        .resume(channel, at: resumePosition)
                    } else {
                        .live(channel)
                    }
                    if !PlayerSessionRegistry.shared.deliver(request) {
                        openWindow(value: request)
                    }
                }
            } catch {
                AppLog.playback.error("Failed to resolve VOD playback URL error=\(error.localizedDescription, privacy: .public)")
                appFeedback.show(
                    AppFeedbackMessage(
                        title: "Couldn’t start video",
                        message: error.localizedDescription,
                        symbol: "exclamationmark.triangle.fill",
                        tone: .warning,
                        showsActivity: false
                    )
                )
            }
        }
    }

    private func updateSportsMatchingContext() {
        sportsViewModel.updateStreamMatchingContext(
            channels: viewModel.channels,
            programs: viewModel.programs,
            favoriteChannelIDs: viewModel.favoriteChannelIDs,
            channelPreferenceScores: viewModel.channelPreferenceScores,
            groupPreferenceScores: viewModel.groupPreferenceScores,
            hiddenGroups: viewModel.hiddenGroupNames
        )
    }

    private func updateSportsMatchingPreferences() {
        sportsViewModel.updateStreamMatchingPreferences(
            favoriteChannelIDs: viewModel.favoriteChannelIDs,
            channelPreferenceScores: viewModel.channelPreferenceScores,
            groupPreferenceScores: viewModel.groupPreferenceScores
        )
    }

    private func handleSidebarSelectionChange(from oldValue: SidebarSelection, to newValue: SidebarSelection) {
        if newValue != .search && searchController.hasQuery {
            searchController.clear()
        }
        if newValue == .search && !searchController.hasQuery {
            searchFieldFocused = true
        }
        if oldValue == .search && newValue != .search {
            selectionBeforeSearch = nil
        }
    }

    private func handleSearchQueryStateChange(hasQuery: Bool) {
        if hasQuery && viewModel.selection != .search {
            selectionBeforeSearch = viewModel.selection
            viewModel.selection = .search
        } else if !hasQuery && viewModel.selection == .search {
            viewModel.selection = selectionBeforeSearch ?? .home
            selectionBeforeSearch = nil
        }
    }

    private func handleSportsVisibilityChange(hidden: Bool) {
        if hidden {
            AppLog.sports.info("Sports surface hidden")
            sportsViewModel.stopAutoRefresh()
            if viewModel.selection == .sports {
                viewModel.selection = .home
            }
        } else {
            AppLog.sports.info("Sports surface enabled")
            updateSportsMatchingContext()
            sportsViewModel.refresh()
            sportsViewModel.startAutoRefresh()
        }
    }

    private func openReminder(_ reminder: ProgramReminder) {
        Task { @MainActor in
            if let channel = await viewModel.resolveReminder(reminder) {
                openChannel(channel)
            } else {
                appFeedback.show(
                    .reminderChannelMissing(
                        playlistName: viewModel.activePlaylist?.name ?? "",
                        channelName: reminder.channelName
                    )
                )
            }
        }
    }

    private func handleFiredReminder(_ note: Notification) {
        guard let reminder = note.object as? ProgramReminder else { return }
        openReminder(reminder)
    }

    private var pageTitle: String {
        switch viewModel.selection {
        case .home:        return "Home"
        case .sports:      return "Sports"
        case .reminders:   return "Reminders"
        case .recordings:  return "Recordings"
        case .movies:      return "Movies"
        case .movieGroup(let g): return g
        case .movieDetail(let item): return item.name
        case .series:      return "TV"
        case .seriesGroup(let g): return g
        case .seriesDetail(let series): return series.name
        case .search:      return "Search"
        case .favorites:   return "Favorites"
        case .allChannels: return "All Channels"
        case .group(let g): return g
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch viewModel.selection {
        case .home:
            HomeView(
                recentChannels: viewModel.recentChannels,
                favoriteChannels: viewModel.favoriteChannels,
                inProgressVOD: disableVOD ? [] : viewModel.inProgressVODEntries,
                currentProgram: { viewModel.currentProgram(for: $0) },
                onChannelSelected: { openChannel($0) },
                onVODSelected: { openVODItem($0.item, resumePosition: $0.positionSeconds) },
                onVODRemoved: { viewModel.removeVODResumeEntry(id: $0.id) },
                sportsViewModel: sportsViewModel
            )
        case .sports:
            SportsView(
                viewModel: sportsViewModel,
                channels: viewModel.channels,
                programs: viewModel.programs,
                favoriteChannelIDs: viewModel.favoriteChannelIDs,
                hiddenGroups: viewModel.hiddenGroupNames,
                onChannelSelected: { openChannel($0) }
            )
        case .reminders:
            RemindersView(
                channels: viewModel.channels,
                onPlayReminder: { openReminder($0) }
            )
        case .recordings:
            RecordingsView(
                channels: viewModel.channels,
                onPlayChannel: { openChannel($0) }
            )
        case .movies, .movieGroup:
            if disableVOD {
                ContentUnavailableView("VOD Disabled", systemImage: "film")
            } else {
                VODLibraryView(
                    items: viewModel.filteredMovieItems,
                    itemProvider: { viewModel.detailItem(for: $0) },
                    isItemLoading: { viewModel.loadingVODItemIDs.contains($0.id) },
                    itemLoadError: { viewModel.vodItemDetailLoadErrors[$0.id] },
                    resumeProvider: { viewModel.resumeEntry(for: $0) },
                    hasLoadedOnce: viewModel.hasLoadedOnce,
                    onItemFocused: { item in
                        Task { await viewModel.loadDetails(for: item) }
                    },
                    onItemSelected: { item, resumePosition in
                        openVODItem(item, resumePosition: resumePosition)
                    }
                )
            }
        case .movieDetail(let item):
            if disableVOD {
                ContentUnavailableView("VOD Disabled", systemImage: "film")
            } else {
                VODItemDetailPage(
                    item: viewModel.detailItem(for: item),
                    isLoadingMetadata: viewModel.loadingVODItemIDs.contains(item.id),
                    metadataLoadError: viewModel.vodItemDetailLoadErrors[item.id],
                    resumeEntry: viewModel.resumeEntry(for: viewModel.detailItem(for: item)),
                    backTitle: "Search",
                    onBack: { viewModel.selection = .search },
                    onPlay: { resumePosition in
                        openVODItem(viewModel.detailItem(for: item), resumePosition: resumePosition)
                    }
                )
                .task(id: item.id) {
                    await viewModel.loadDetails(for: item)
                }
            }
        case .series, .seriesGroup:
            if disableVOD {
                ContentUnavailableView("VOD Disabled", systemImage: "rectangle.stack")
            } else {
                SeriesLibraryView(
                    series: viewModel.filteredSeries,
                    episodesProvider: { viewModel.episodes(for: $0) },
                    isLoading: { viewModel.loadingSeriesIDs.contains($0.id) },
                    loadError: { viewModel.seriesEpisodeLoadErrors[$0.id] },
                    resumeProvider: { viewModel.resumeEntry(for: $0) },
                    hasLoadedOnce: viewModel.hasLoadedOnce,
                    onSeriesSelected: { series in
                        Task { await viewModel.loadEpisodes(for: series) }
                    },
                    onEpisodeSelected: { episode, resumePosition in
                        openVODItem(episode, resumePosition: resumePosition)
                    }
                )
            }
        case .seriesDetail(let series):
            if disableVOD {
                ContentUnavailableView("VOD Disabled", systemImage: "rectangle.stack")
            } else {
                SeriesDetailPage(
                    series: series,
                    episodes: viewModel.episodes(for: series),
                    isLoading: viewModel.loadingSeriesIDs.contains(series.id),
                    loadError: viewModel.seriesEpisodeLoadErrors[series.id],
                    resumeProvider: { viewModel.resumeEntry(for: $0) },
                    backTitle: "Search",
                    onBack: { viewModel.selection = .search },
                    onEpisodeSelected: { episode, resumePosition in
                        openVODItem(episode, resumePosition: resumePosition)
                    }
                )
                .task {
                    await viewModel.loadEpisodes(for: series)
                }
            }
        case .search:
            ProgramSearchResultsPage(
                controller: searchController,
                totalIndexed: viewModel.searchEntries.count,
                currentProgram: { viewModel.currentProgram(for: $0) },
                onSelect: { openChannel($0) },
                onPlayFromStart: { channel, program in openCatchup(channel, program: program) },
                onSelectVOD: { viewModel.selection = .movieDetail($0) },
                onOpenSeries: { series in
                    viewModel.selection = .seriesDetail(series)
                    Task { await viewModel.loadEpisodes(for: series) }
                },
                onShowInEPG: { channel in
                    searchController.clear()
                    let group = channel.group
                    viewModel.selection = group.isEmpty ? .allChannels : .group(group)
                    viewModel.revealChannelID = channel.id
                }
            )
        case .favorites, .allChannels, .group:
            EPGGridView(
                channels: viewModel.filteredChannels,
                hasLoadedOnce: viewModel.hasLoadedOnce,
                revealChannelID: viewModel.revealChannelID,
                catchupLookback: CatchupLookbackSetting.stored(rawValue: catchupLookbackRawValue),
                guideVersion: viewModel.guideVersion,
                programsProvider: { viewModel.programsForChannel($0) },
                rangedProgramsProvider: { ch, start, end in viewModel.programsForChannel(ch, between: start, and: end) },
                onCatchupGuideNeeded: { channels in viewModel.syncCatchupGuideIfNeeded(for: channels) },
                isFavorite: { viewModel.isFavorite($0) },
                onToggleFavorite: { viewModel.toggleFavorite($0) },
                onChannelSelected: { channel in
                    openChannel(channel)
                }
            )
            .onChange(of: viewModel.revealChannelID) { _, newValue in
                if newValue != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        viewModel.revealChannelID = nil
                    }
                }
            }
        }
    }

    private var mainNavigation: some View {
        NavigationSplitView {
            ChannelSidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)
        } detail: {
            detailView
                .navigationTitle(pageTitle)
                .overlay {
                    if let error = viewModel.errorMessage {
                        ContentUnavailableView(
                            "Error",
                            systemImage: "exclamationmark.triangle",
                            description: Text(error)
                        )
                    }
                }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 8) {
                        if viewModel.isRefreshing {
                            AppFeedbackBanner(message: .sync(stage: viewModel.loadingStage))
                                .allowsHitTesting(false)
                                .transition(
                                    .asymmetric(
                                        insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity
                                    )
                                )
                        }

                        if let toast = appFeedback.toast {
                            AppFeedbackBanner(message: toast) {
                                appFeedback.dismiss()
                            }
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                )
                            )
                        }
                    }
                    .padding(.bottom, 16)
                }
                .animation(BufferMotion.bannerIn, value: viewModel.isRefreshing)
                .animation(BufferMotion.bannerIn, value: appFeedback.toast)
        }
        .searchable(
            text: Binding(
                get: { searchController.query },
                set: { searchController.setQuery($0) }
            ),
            placement: .toolbar,
            prompt: "Search programs, channels, movies…"
        )
        .searchFocused($searchFieldFocused)
        .background {
            Button("") {
                searchFieldFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    private var welcomeView: some View {
        ContentUnavailableView {
            Label("Welcome to Buffer", systemImage: "tv.badge.wifi")
        } description: {
            Text("Add an IPTV source, then click Apply & Sync.")
                .multilineTextAlignment(.center)
        } actions: {
            VStack(spacing: 12) {
                Button {
                    openWindow(id: "settings")
                } label: {
                    Label("Add Source", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)

                Text("Xtream Codes, Stalker/MAG, and M3U supported")
                    .font(BufferFont.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bufferPageBackground()
    }

    private func updateSearchIndex() {
        let vodItems: [VODItem] = disableVOD ? [] : viewModel.movieItems + viewModel.seriesEpisodes.values.flatMap { $0 }
        let vodSeries: [VODSeries] = disableVOD ? [] : viewModel.vodSeries
        searchController.updateIndex(
            programs: viewModel.searchEntries,
            programStore: viewModel.programs,
            channels: viewModel.channels,
            vodItems: vodItems,
            vodSeries: vodSeries
        )
    }

    private func scheduleInternalPlayerPrewarm() {
        guard selectedPlayer == .none, !didSchedulePlayerPrewarm else { return }
        didSchedulePlayerPrewarm = true
        Task { @MainActor in
            await Task.yield()
            PlayerSession.prewarmPlayerPool()
        }
    }

    var body: some View {
        Group {
            if viewModel.playlists.isEmpty {
                welcomeView
            } else {
                mainNavigation
            }
        }
        .environment(\.activePlaylistID, viewModel.activePlaylistID)
        .toolbar {
            if viewModel.activePlaylist != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.sync()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: "settings")
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
        .onAppear {
            updateSearchIndex()
            updateSportsMatchingContext()
            scheduleInternalPlayerPrewarm()
        }
        .onChange(of: viewModel.channels.count) { _, _ in
            updateSportsMatchingContext()
        }
        .onChange(of: viewModel.programs.count) { _, _ in
            updateSportsMatchingContext()
        }
        .onChange(of: viewModel.favoriteChannelIDs) { _, _ in
            updateSportsMatchingPreferences()
        }
        .onChange(of: viewModel.recentChannelIDs) { _, _ in
            updateSportsMatchingPreferences()
        }
        .onChange(of: viewModel.hiddenGroupNames) { _, _ in
            updateSportsMatchingContext()
        }
        .onChange(of: hideSport) { _, hidden in
            handleSportsVisibilityChange(hidden: hidden)
        }
        .onChange(of: disableVOD) { _, disabled in
            viewModel.applyVODPreference(disabled: disabled)
            updateSearchIndex()
        }
        .onChange(of: catchupLookbackRawValue) { _, _ in
            viewModel.syncGuideForLookbackChange()
        }
        .onChange(of: viewModel.searchIndexVersion) { _, _ in
            updateSearchIndex()
            updateSportsMatchingContext()
        }
        .onChange(of: viewModel.selection) { oldValue, newValue in
            handleSidebarSelectionChange(from: oldValue, to: newValue)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NotificationManager.openStreamNotification
            )
        ) { note in
            handleFiredReminder(note)
        }
        .onChange(of: searchController.hasQuery) { _, hasQuery in
            handleSearchQueryStateChange(hasQuery: hasQuery)
        }
        .task {
            let hydrationSignpostID = AppLog.appSignposter.makeSignpostID()
            let hydrationState = AppLog.appSignposter.beginInterval(
                "LaunchHydration",
                id: hydrationSignpostID
            )
            let launchHydrateStarted = ContinuousClock.now
            await viewModel.hydrate()
            AppLog.appSignposter.endInterval("LaunchHydration", hydrationState)
            let launchHydrateElapsed = launchHydrateStarted.duration(to: .now).components.seconds
            AppLog.sync.info("Launch hydration finished seconds=\(launchHydrateElapsed, privacy: .public) channels=\(viewModel.channels.count, privacy: .public)")
            // Launch refreshes follow the user's automatic refresh settings.
            viewModel.syncOnLaunchIfNeeded()
            viewModel.startSyncScheduler()

            scheduleInternalPlayerPrewarm()

            // Pre-load sports data so live events show on the Home page.
            // Deferred by a short delay so app-launch paint + initial EPG sync
            // aren't competing with the ESPN fetch + refresh timer start on
            // the same runloop tick.
            if !hideSport {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    updateSportsMatchingContext()
                    sportsViewModel.refresh()
                    sportsViewModel.startAutoRefresh()
                }
            }
        }
    }
}
