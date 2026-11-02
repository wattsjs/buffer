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
    @State private var sportsMatchingChannels: [Channel] = []
    @State private var sportsMatchingCatalogVersion = 0
    @State private var sportsMatchingUsesSmart = false
    @State private var sportsQualityCache: [String: StreamMatchQuality] = [:]
    @State private var sportsQualityProbeVersion = -1
    @State private var sportsQualityCatalogVersion = -1
    @State private var sportsQualityUpdatedAt = Date.distantPast
    @State private var sportsPreferencesCache: (favorites: Set<String>, scores: [String: Double]) = ([], [:])
    @State private var sportsPreferencesCatalogVersion = -1
    @State private var sportsPreferencesSourceVersion = -1
    @State private var sportsPreferencesScoreVersion = -1
    @State private var sportsPreferencesFavorites: Set<String> = []
    @State private var sportsPreferencesLogicalBindings: [String: String] = [:]
    @State private var appFeedback = AppFeedbackCenter.shared
    @State private var selectionBeforeSearch: SidebarSelection?
    @State private var didSchedulePlayerPrewarm = false
    @FocusState private var searchFieldFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @AppStorage(ExternalPlayer.selectedPlayerKey) private var selectedPlayer: ExternalPlayerKind = .none
    @AppStorage("hideSport") private var hideSport = false
    @AppStorage(EPGViewModel.disableVODKey) private var disableVOD = false
    @AppStorage(CatchupLookbackSetting.appStorageKey) private var catchupLookbackRawValue = CatchupLookbackSetting.default.rawValue

    private func openChannel(_ channel: Channel) {
        open(.live(channel))
    }

    private func openCatchup(_ channel: Channel, program: EPGProgram) {
        open(.catchup(channel, from: program.start))
    }

    private func open(_ request: PlaybackRequest) {
        if selectedPlayer != .none, request.channel.sourceOwnership?.logicalChannelID != nil {
            viewModel.showSmartActionUnavailable("Smart Sports needs Buffer’s player to manage account connection limits and live source recovery. Choose Buffer in Settings → Playback, or select an original source playlist to use your external player.")
            return
        }
        guard let request = viewModel.resolvePlaybackRequest(request) else { return }
        let channel = request.channel
        if selectedPlayer != .none {
            guard let url = externalPlayerURL(for: request) else {
                viewModel.showSmartActionUnavailable("This source cannot provide the requested archive.")
                return
            }
            viewModel.addRecent(channel)
            updateSportsMatchingPreferences()
            AppLog.playback.info("Opening channel externally name=\(channel.name, privacy: .public) player=\(selectedPlayer.displayName, privacy: .public)")
            ExternalPlayer.launch(streamURL: url, using: selectedPlayer)
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
    private func externalPlayerURL(for request: PlaybackRequest) -> URL? {
        let channel = request.channel
        if case .catchup(let start) = request.intent {
            let program = viewModel.program(for: channel, at: start)
            let duration = program.map(\.duration) ?? 2 * 3600
            if let url = CatchupURLBuilder.url(for: channel, start: start, duration: duration) {
                return url
            }
            return nil
        }
        return channel.streamURL
    }

    private func openVODItem(_ item: VODItem, resumePosition: Double? = nil, sourceID: UUID?) {
        Task {
            do {
                guard let sourceID else { throw VODPlaybackSourceError.unavailable }
                let resolved = try await viewModel.resolveVODPlaybackChannel(item, sourceID: sourceID)
                let playableItem = resolved.item
                let channel = resolved.channel
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
        let snapshot = viewModel.isSmartSportsActive
            ? viewModel.smartSports.sportsMatchingSnapshot(activeConfig: viewModel.serverConfig,
                activeChannels: viewModel.channels, activePrograms: viewModel.programs,
                activeCatalogVersion: viewModel.channelCatalogVersion)
            : (channels: viewModel.channels, programs: viewModel.programs)
        let unchanged = sportsMatchingUsesSmart == viewModel.isSmartSportsActive
            && sportsMatchingChannels.count == snapshot.channels.count
            && zip(sportsMatchingChannels, snapshot.channels).allSatisfy { lhs, rhs in
                lhs.id == rhs.id && lhs.name == rhs.name && lhs.group == rhs.group
                    && lhs.streamURL == rhs.streamURL && lhs.epgChannelID == rhs.epgChannelID
                    && lhs.catchup == rhs.catchup && lhs.contentType == rhs.contentType && lhs.sourceOwnership == rhs.sourceOwnership
            }
        if !unchanged {
            sportsMatchingChannels = snapshot.channels
            sportsMatchingUsesSmart = viewModel.isSmartSportsActive
            sportsMatchingCatalogVersion &+= 1
        }
        let preferences = sportsMatchingPreferences()
        sportsViewModel.updateStreamMatchingContext(
            channels: snapshot.channels,
            programs: snapshot.programs,
            favoriteChannelIDs: preferences.favorites,
            channelPreferenceScores: preferences.scores,
            groupPreferenceScores: viewModel.groupPreferenceScores,
            hiddenGroups: viewModel.hiddenGroupNames,
            guideVersion: viewModel.guideVersion,
            channelSetVersion: sportsMatchingCatalogVersion,
            deferGuideIndex: viewModel.isGuideEnriching || (viewModel.isSmartSportsActive && viewModel.smartSports.isLoading),
            qualityByChannel: sportsMatchingQuality()
        )
    }

    private func updateSportsMatchingPreferences() {
        let preferences = sportsMatchingPreferences()
        sportsViewModel.updateStreamMatchingPreferences(
            favoriteChannelIDs: preferences.favorites,
            channelPreferenceScores: preferences.scores,
            groupPreferenceScores: viewModel.groupPreferenceScores,
            qualityByChannel: sportsMatchingQuality()
        )
    }

    /// Ordinary preference IDs belong to their active playlist. Logical Smart
    /// favorites may prefer each eligible physical variant without changing
    /// the endpoint's action ownership or copying a guide to another source.
    private func sportsMatchingPreferences() -> (favorites: Set<String>, scores: [String: Double]) {
        var logicalByPhysical: [String: String] = [:]
        if viewModel.isSmartSportsActive {
            for feed in viewModel.smartSports.catalog?.feeds ?? [] {
                for variant in feed.variants { logicalByPhysical[variant.key.rawValue] = feed.id }
            }
        }
        if sportsPreferencesCatalogVersion == sportsMatchingCatalogVersion,
           sportsPreferencesSourceVersion == viewModel.channelCatalogVersion,
           sportsPreferencesScoreVersion == viewModel.preferenceScoresVersion,
           sportsPreferencesFavorites == viewModel.favoriteChannelIDs,
           sportsPreferencesLogicalBindings == logicalByPhysical { return sportsPreferencesCache }
        var favorites = Set<String>()
        var scores: [String: Double] = [:]
        for channel in sportsMatchingChannels {
            let key = channel.preferenceIdentity
            let preferenceKey: String?
            if viewModel.isSmartSportsActive { preferenceKey = logicalByPhysical[key] }
            else if channel.sourceChannelIdentity?.sourceID == viewModel.activePlaylistID || channel.sourceChannelIdentity == nil {
                preferenceKey = channel.id
            } else { preferenceKey = nil }
            guard let preferenceKey else { continue }
            if viewModel.favoriteChannelIDs.contains(preferenceKey) { favorites.insert(key) }
            if let score = viewModel.channelPreferenceScores[preferenceKey] { scores[key] = score }
        }
        sportsPreferencesCache = (favorites, scores)
        sportsPreferencesCatalogVersion = sportsMatchingCatalogVersion
        sportsPreferencesSourceVersion = viewModel.channelCatalogVersion
        sportsPreferencesScoreVersion = viewModel.preferenceScoresVersion
        sportsPreferencesFavorites = viewModel.favoriteChannelIDs
        sportsPreferencesLogicalBindings = logicalByPhysical
        return sportsPreferencesCache
    }

    private func sportsMatchingQuality(now: Date = Date()) -> [String: StreamMatchQuality] {
        let probeVersion = StreamProbeService.shared.version
        if sportsQualityProbeVersion == probeVersion,
           sportsQualityCatalogVersion == sportsMatchingCatalogVersion,
           now.timeIntervalSince(sportsQualityUpdatedAt) < 60 { return sportsQualityCache }
        var result: [String: StreamMatchQuality] = [:]
        for channel in sportsMatchingChannels {
            guard let probe = StreamProbeService.shared.probe(for: channel),
                  probe.endpointFingerprint == StreamProbe.endpointFingerprint(for: channel.streamURL) else { continue }
            var quality = StreamMatchQuality()
            let probeAge = now.timeIntervalSince(probe.probedAt)
            if probeAge >= -60 && probeAge <= 15 * 60 {
                if probe.status != .ok { quality.availability = .failed }
                quality.isUnstable = probe.streamHealth.isUnstable
            }
            if let evidence = probe.passivePlaybackEvidence, evidence.ordinaryLive == true {
                let age = now.timeIntervalSince(evidence.lastObservedAt)
                if age >= -60 && age <= 24 * 3600, evidence.healthySeconds.isFinite, evidence.healthySeconds >= 0,
                   evidence.bufferingSeconds.isFinite, evidence.bufferingSeconds >= 0 {
                    quality.healthySeconds = evidence.healthySeconds
                    quality.observedSeconds = evidence.healthySeconds + evidence.bufferingSeconds
                    quality.bufferingSeconds = evidence.bufferingSeconds
                    if evidence.bufferingSeconds > 3 { quality.availability = .failed }
                    else if quality.availability != .failed && evidence.healthySeconds >= 180 && evidence.bufferingSeconds <= 0.5 {
                        quality.availability = .observedAvailable
                    }
                }
            }
            if probe.metadataProvenance != nil, let date = probe.metadataObservedAt {
                let age = now.timeIntervalSince(date)
                if age >= -60 && age <= 14 * 86400 {
                    quality.observedHeight = max(0, probe.height)
                    quality.observedFPS = probe.fps.isFinite ? max(0, probe.fps) : 0
                    quality.observedBitRate = max(0, probe.bitRate)
                }
            }
            result[channel.preferenceIdentity] = quality
        }
        sportsQualityCache = result
        sportsQualityProbeVersion = probeVersion
        sportsQualityCatalogVersion = sportsMatchingCatalogVersion
        sportsQualityUpdatedAt = now
        return result
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
        let vodSourceID = viewModel.activePlaylistID
        switch viewModel.selection {
        case .home:
            HomeView(
                recentChannels: viewModel.recentChannels,
                favoriteChannels: viewModel.favoriteChannels,
                inProgressVOD: disableVOD ? [] : viewModel.inProgressVODEntries,
                currentProgram: { viewModel.currentProgram(for: $0) },
                onChannelSelected: { openChannel($0) },
                onVODSelected: { openVODItem($0.item, resumePosition: $0.positionSeconds, sourceID: vodSourceID) },
                onVODRemoved: { viewModel.removeVODResumeEntry(id: $0.id) },
                sportsViewModel: sportsViewModel
            )
        case .sports:
            SportsView(
                viewModel: sportsViewModel,
                channels: viewModel.displayedChannels,
                programs: viewModel.displayedPrograms,
                favoriteChannelIDs: viewModel.favoriteChannelIDs,
                hiddenGroups: viewModel.hiddenGroupNames,
                onChannelSelected: { openChannel($0) },
                onCatchup: { channel, program in openCatchup(channel, program: program) }
            )
        case .reminders:
            RemindersView(
                channels: viewModel.displayedChannels,
                onPlayReminder: { openReminder($0) }
            )
        case .recordings:
            RecordingsView(
                channels: viewModel.displayedChannels,
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
                        openVODItem(item, resumePosition: resumePosition, sourceID: vodSourceID)
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
                        openVODItem(viewModel.detailItem(for: item), resumePosition: resumePosition, sourceID: vodSourceID)
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
                        openVODItem(episode, resumePosition: resumePosition, sourceID: vodSourceID)
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
                        openVODItem(episode, resumePosition: resumePosition, sourceID: vodSourceID)
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
                channelSetVersion: viewModel.filteredChannelSetVersion,
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
                },
                onPlayFromStart: { channel, program in openCatchup(channel, program: program) }
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
                        if viewModel.isRefreshing || viewModel.isLoadingSourceCredentials || viewModel.smartSports.isLoading {
                            AppFeedbackBanner(message: .sync(stage: viewModel.smartSports.isLoading ? "Loading Smart Sports from saved sources…" :
                                (viewModel.isLoadingSourceCredentials ? "Unlocking saved source…" : viewModel.loadingStage)))
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
                        if viewModel.isSmartSportsActive, !viewModel.smartSports.isLoading,
                           !viewModel.smartSports.sourceIssues.isEmpty {
                            AppFeedbackBanner(message: .init(title: "Some Smart Sports sources are unavailable",
                                message: "Open an original source and refresh it, or check its saved credentials in Settings.",
                                symbol: "exclamationmark.triangle", tone: .warning, showsActivity: false))
                        }
                    }
                    .padding(.bottom, 16)
                }
                .animation(BufferMotion.bannerIn, value: viewModel.isRefreshing)
                .animation(BufferMotion.bannerIn, value: viewModel.isLoadingSourceCredentials)
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
            programStore: viewModel.programSearchStore,
            channels: viewModel.displayedChannels,
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
        .environment(\.activePlaylistID, viewModel.displayedPlaylistID)
        .environment(\.epgActionModel, viewModel)
        .onChange(of: viewModel.smartSportsInspectorFeedID) { _, feedID in
            guard let feedID else { return }
            openWindow(id: "smart-sports-sources", value: feedID)
            viewModel.smartSportsInspectorFeedID = nil
        }
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
        .onChange(of: viewModel.smartSports.errorMessage) { _, message in
            if viewModel.isSmartSportsActive, let message { viewModel.showSmartActionUnavailable(message) }
        }
        .onChange(of: RecordingManager.shared.capacityErrorMessage) { _, message in
            if let message { viewModel.showSmartActionUnavailable(message) }
        }
        .onChange(of: StreamProbeService.shared.version) { _, _ in
            updateSportsMatchingPreferences()
        }
        .onChange(of: viewModel.smartSports.revision) { _, _ in
            if viewModel.isSmartSportsActive { updateSportsMatchingContext() }
        }
        .onChange(of: viewModel.smartSports.isLoading) { _, _ in
            if viewModel.isSmartSportsActive { updateSportsMatchingContext() }
        }
        .onChange(of: viewModel.channelCatalogVersion) { _, _ in
            updateSportsMatchingContext()
        }
        .onChange(of: viewModel.guideVersion) { _, _ in
            updateSportsMatchingContext()
        }
        .onChange(of: viewModel.isGuideEnriching) { _, _ in
            updateSportsMatchingContext()
        }
        .onChange(of: viewModel.favoriteChannelIDs) { _, _ in
            updateSportsMatchingPreferences()
        }
        .onChange(of: viewModel.preferenceScoresVersion) { _, _ in
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
            if let request = PlaybackValidation.request() {
                // Validate Buffer's actual renderer, regardless of the saved
                // external-player preference. Do not write synthetic recents.
                #if DEBUG
                DiagnosticPlayerWindowHost.open(request: request, viewModel: viewModel)
                #else
                openWindow(value: request)
                #endif
                PlaybackValidation.run(open: request)
                return
            }
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
            viewModel.restoreSmartChannelsIfPreferred()
#if DEBUG
            // Diagnostic: open a channel folder directly, e.g. for scroll profiling.
            if let index = CommandLine.arguments.firstIndex(of: "--select-group"),
               CommandLine.arguments.indices.contains(index + 1) {
                let wanted = CommandLine.arguments[index + 1].lowercased()
                Task { @MainActor in
                    // After the initial navigation and Smart restore settle.
                    try? await Task.sleep(for: .seconds(3))
                    // "busiest" picks the sports folder with the most channels.
                    let busiest = wanted == "busiest" ? Dictionary(grouping: viewModel.displayedChannels, by: \.group)
                        .filter { $0.key.lowercased().contains("sport") }
                        .max { $0.value.count < $1.value.count }?.key : nil
                    if let group = busiest ?? viewModel.groups.first(where: { $0.lowercased() == wanted })
                        ?? viewModel.groups.first(where: { $0.lowercased().contains(wanted) }) {
                        viewModel.selection = .group(group)
                        if let autoscroll = CommandLine.arguments.firstIndex(of: "--autoscroll-epg"),
                           CommandLine.arguments.indices.contains(autoscroll + 1),
                           let seconds = Double(CommandLine.arguments[autoscroll + 1]) {
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(8))
                                NotificationCenter.default.post(name: EPGContainerView.diagnosticAutoscrollNotification,
                                                                object: nil, userInfo: ["seconds": seconds])
                            }
                        }
                        AppLog.app.info("Diagnostic folder selected group=\(group, privacy: .public) channels=\(viewModel.displayedChannels.filter { $0.group == group }.count, privacy: .public)")
                    } else {
                        AppLog.app.info("Diagnostic folder not found wanted=\(wanted, privacy: .public) groups=\(viewModel.groups.count, privacy: .public)")
                    }
                }
            }
#endif
            SavedPlaybackScenario.start(viewModel: viewModel) { request in
                PlayerSession.noteOpen(channel: request.channel)
                #if DEBUG
                DiagnosticPlayerWindowHost.open(request: request, viewModel: viewModel)
                #else
                openWindow(value: request)
                #endif
            }

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
