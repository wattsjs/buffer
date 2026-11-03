import Foundation
import OSLog
import SwiftUI

enum SidebarSelection: Hashable {
    case home
    case sports
    case reminders
    case recordings
    case movies
    case movieGroup(String)
    case movieDetail(VODItem)
    case series
    case seriesGroup(String)
    case seriesDetail(VODSeries)
    case search
    case favorites
    case allChannels
    case group(String)
}

nonisolated struct VODResumeEntry: Identifiable, Hashable, Codable, Sendable {
    let item: VODItem
    var positionSeconds: Double
    var durationSeconds: Double?
    var updatedAt: Date

    var id: String { item.id }

    var progressFraction: Double? {
        guard let durationSeconds, durationSeconds > 0, positionSeconds > 0 else { return nil }
        return min(max(positionSeconds / durationSeconds, 0), 1)
    }

    var isInProgress: Bool {
        guard positionSeconds >= 30 else { return false }
        guard let progressFraction else { return true }
        return progressFraction < 0.95
    }
}

nonisolated enum VODPlaybackSourceError: LocalizedError {
    case unavailable
    case changed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Open an original source with Movies and TV enabled to play this video."
        case .changed: "The source or video changed. Refresh the source and select the video again."
        }
    }
}

@MainActor
@Observable
class EPGViewModel {
    static let disableVODKey = "disableVOD"

    private(set) var channelCatalogVersion = 0
    var channels: [Channel] = [] {
        didSet {
            if serverConfig?.type == .m3u {
                migrateM3UChannelPreferences(from: oldValue, to: channels)
            }
            channelCatalogVersion &+= 1
            rebuildChannelDerivedState()
            // A running account sync refreshes Smart once when it finishes.
            if isSmartSportsActive, activeSyncTask == nil { refreshSmartSports() }
        }
    }
    var vodItems: [VODItem] = [] {
        didSet { rebuildVODDerivedState() }
    }
    var vodSeries: [VODSeries] = [] {
        didSet { rebuildVODDerivedState() }
    }
    var seriesEpisodes: [String: [VODItem]] = [:]
    var seriesEpisodeLoadErrors: [String: String] = [:]
    var loadingSeriesIDs: Set<String> = []
    var vodItemDetails: [String: VODItem] = [:]
    var vodItemDetailLoadErrors: [String: String] = [:]
    var loadingVODItemIDs: Set<String> = []
    var vodResumeEntries: [VODResumeEntry] = []
    private(set) var guideVersion = 0
    var programs: [String: [EPGProgram]] = [:] { // keyed by channel epgID
        didSet {
            guideVersion &+= 1
            // Publishers install the matching timeline right after assigning;
            // any other assignment falls back to the exact per-list search.
            guideTimeline = nil
            // A running account sync refreshes Smart once when it finishes.
            if isSmartSportsActive, activeSyncTask == nil { refreshSmartSports() }
        }
    }

    /// Flat start/end/max-end Int32 columns over `programs`, one contiguous
    /// run per guide ID (see `GuideTimeline`). Built off the main thread by
    /// the publishers; `nil` only between an unindexed assignment and the
    /// next publication.
    @ObservationIgnored private var guideTimeline: GuideTimeline?

    var storedGroupOrder: [String] = [] {
        didSet { rebuildGroupOrder() }
    }
    var hiddenGroupNames: Set<String> = [] {
        didSet { /* groups/hidden computed from it; direct observation in sidebar/sports */ }
    }
    var selection: SidebarSelection = .home {
        didSet { rebuildFilteredCaches() }
    }
    var revealChannelID: String?
    var searchText: String = "" {
        didSet { rebuildFilteredCaches() }
    }
    var recentChannelIDs: [String] = [] {
        didSet { rebuildRecentFavoriteAndScores() }
    }
    var favoriteChannelIDs: Set<String> = [] {
        didSet { rebuildRecentFavoriteAndScores() }
    }
    var channelUsageCounts: [String: Int] = [:] {
        didSet { rebuildRecentFavoriteAndScores() }
    }
    var groupUsageCounts: [String: Int] = [:] {
        didSet { rebuildRecentFavoriteAndScores() }
    }
    var hasLoadedOnce = false
    var isRefreshing = false
    @ObservationIgnored private var loadingStageStartedAt: ContinuousClock.Instant?
    var loadingStage: String? = nil {
        didSet { recordLoadingStageTransition(from: oldValue, to: loadingStage) }
    }
    var errorMessage: String?
    var playlists: [ServerConfig] = []
    var activePlaylistID: UUID?
    let smartSports: SmartSportsCoordinator
    private(set) var isSmartSportsActive = false
    var smartSportsInspectorFeedID: String?
    @ObservationIgnored private var smartRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var inactiveSourceRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var smartDisplayedCatalogSnapshot: [Channel]?
    var displayedChannels: [Channel] { isSmartSportsActive ? smartSports.displayedChannels : channels }
    var displayedPrograms: [String: [EPGProgram]] { isSmartSportsActive ? smartSports.displayedPrograms : programs }
    static let smartSportsReminderPlaylistID = UUID(uuidString: "AF314B3F-7111-49FC-9C25-8D548519DE96")!
    var displayedPlaylistID: UUID? { isSmartSportsActive ? Self.smartSportsReminderPlaylistID : activePlaylistID }
    private var unresolvedCredentialIDs: Set<UUID> = []
    private var loadingCredentialIDs: Set<UUID> = []
    @ObservationIgnored private var credentialLoadTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var credentialReadTokens: [UUID: UUID] = [:]

    var isLoadingSourceCredentials: Bool {
        activePlaylistID.map { loadingCredentialIDs.contains($0) } ?? false
    }
    var lastUpdated: Date? = nil
    var serverStatus: ServerAccountStatus?

    // MARK: - Indexed/Cached Derived State (Playlist Indexed State + Incremental Filters - Agent 03)
    // Real indexes and snapshots so hot getters (allGroups, filtered*, recent/favoriteChannels,
    // *PreferenceScores) no longer do full O(n) scans on every access. Updated only on
    // mutation of sources via didSet + targeted rebuilds.
    private var channelByID: [String: Channel] = [:]
    private var groupedChannels: [String: [Channel]] = [:]
    private var allGroupsCached: [String] = []
    private var recentChannelsCached: [Channel] = []
    private var favoriteChannelsCached: [Channel] = []
    private var groupPreferenceScoresCached: [String: Double] = [:]
    private var channelPreferenceScoresCached: [String: Double] = [:]
    /// Ranking inputs can change while recents/favorites remain identical,
    /// e.g. watching the current most-recent channel again or clearing usage.
    private(set) var preferenceScoresVersion = 0
    private var filteredChannelsCached: [Channel] = []
    private(set) var filteredChannelSetVersion = 0
    private var movieItemsCached: [VODItem] = []
    private var movieGroupsCached: [String] = []
    private var seriesGroupsCached: [String] = []
    private var filteredMovieItemsCached: [VODItem] = []
    private var filteredSeriesCached: [VODSeries] = []

    /// The currently active playlist, if any. Most existing code treats this as
    /// "the server config"; new code should prefer the explicit name.
    var serverConfig: ServerConfig? { activePlaylist }

    var activePlaylist: ServerConfig? {
        guard let id = activePlaylistID else { return nil }
        guard !unresolvedCredentialIDs.contains(id) else { return nil }
        return playlists.first(where: { $0.id == id })
    }

    /// Flat programme search index (interned titles/tokens, title-major SoA
    /// columns). Iterating it yields legacy `ProgramSearchEntry` values.
    var searchEntries = ProgramSearchIndex()
    /// Entries retain offsets into this exact guide snapshot. Progressive
    /// history publications can reorder the live arrays while search stays
    /// usable; they must not change the arrays behind an already built index.
    private(set) var programSearchStore: [String: [EPGProgram]] = [:]
    var searchIndexVersion: Int = 0
    private var indexBuildTask: Task<Void, Never>?
    @ObservationIgnored private var searchIndexNeedsRebuild = false
    @ObservationIgnored private var searchIndexBuildIsFirstColdSnapshot = false
    @ObservationIgnored private(set) var programSearchIndexBuildCount = 0
    @ObservationIgnored private(set) var programSearchIndexPublicationCount = 0
    private var playlistSchedulerTask: Task<Void, Never>?
    private var epgSchedulerTask: Task<Void, Never>?
    private var activeSyncTask: Task<Void, Never>?
    @ObservationIgnored private var activeSyncID: UUID?
    @ObservationIgnored private var activeSyncScope: SyncScope?
    @ObservationIgnored private var pendingSync: (scope: SyncScope, silent: Bool)?
    @ObservationIgnored private var sourceGeneration = UUID()
    @ObservationIgnored private var catalogGeneration = UUID()
    @ObservationIgnored private var lastAppliedVODDisabled: Bool?
    @ObservationIgnored private var searchBuildID = UUID()
    private var hydrationTask: Task<Void, Never>?
    private var catchupGuideSyncKeys: Set<String> = []
    @ObservationIgnored private var guidePublicationTask: Task<Void, Error>?
    @ObservationIgnored private var visibleGuidePriorityIDs: Set<String> = []
    @ObservationIgnored private var guideAttempts: [String: (start: Date, retryAfter: Date)] = [:]
    private(set) var isGuideEnriching = false
    @ObservationIgnored private var lastGuidePersistedAt: ContinuousClock.Instant?
    @ObservationIgnored private var guideProgressBuffer: GuideProgressBuffer?
    @ObservationIgnored private(set) var guideMaximumCommitMilliseconds = 0.0

    /// A generation also rejects A → B → A switches, where the playlist ID
    /// and cache key can match an obsolete operation again.
    private func isCurrentSource(_ generation: UUID, config: ServerConfig) -> Bool {
        guard generation == sourceGeneration, let current = serverConfig else { return false }
        return Self.hasSameSource(current, config)
    }

    private static func hasSameSource(_ lhs: ServerConfig, _ rhs: ServerConfig) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type && lhs.serverURL == rhs.serverURL
            && lhs.username == rhs.username && lhs.password == rhs.password
            && lhs.m3uURL == rhs.m3uURL && lhs.epgURL == rhs.epgURL
    }

    private func checkSync(_ id: UUID, generation: UUID, config: ServerConfig) throws {
        try Task.checkCancellation()
        guard activeSyncID == id, isCurrentSource(generation, config: config) else {
            throw CancellationError()
        }
    }

    init(smartSports: SmartSportsCoordinator? = nil) {
        self.smartSports = smartSports ?? SmartSportsCoordinator()
        self.smartSports.onChange = { [weak self] in self?.smartSportsDidChange() }
        if self.smartSports.probeLookup == nil {
            self.smartSports.probeLookup = { channel in StreamProbeService.shared.probe(for: channel) }
            self.smartSports.probeVersion = { StreamProbeService.shared.version }
            StreamProbeService.shared.onCapacityStatusStale = { [weak self] _ in self?.refreshAccountCapacityForProbing() }
        }
        // Synthetic performance runs must not read accounts or start real sync.
        guard !PerformanceBenchmark.shouldRun, !PlaybackValidation.isEnabled else { return }
        loadConfig()

        // Seed caches from any prefs loaded in loadConfig (groups, etc.) + empty data.
        rebuildChannelDerivedState()
        rebuildVODDerivedState()
    }

    /// Smart Channels is the launch view when several sources are configured,
    /// until the user explicitly picks one source from the source menus.
    static let smartChannelsPreferredKey = "buffer_smart_channels_preferred"

    var prefersSmartChannels: Bool {
        UserDefaults.standard.object(forKey: Self.smartChannelsPreferredKey) as? Bool ?? (playlists.count >= 2)
    }

    /// Called once after launch hydration so Smart builds on the hydrated
    /// active source instead of waiting behind it.
    func restoreSmartChannelsIfPreferred() {
        guard prefersSmartChannels, !isSmartSportsActive else { return }
        AppLog.app.info("Restoring Smart Channels as the launch view")
        activateSmartSports()
    }

    /// Saves the Smart Channels filter and regroups under it.
    func applySmartChannelFilter(_ filter: SmartChannelFilter) {
        smartSports.setFilter(filter)
        AppLog.app.info("Smart Channels filter applied enabled=\(filter.isEnabled, privacy: .public) regions=\(filter.regions.count, privacy: .public) alwaysInclude=\(filter.alwaysInclude.count, privacy: .public)")
        if isSmartSportsActive { refreshSmartSports(immediately: true) }
    }

    /// An explicit single-source choice from the source menus.
    func chooseSource(id: UUID) {
        UserDefaults.standard.set(false, forKey: Self.smartChannelsPreferredKey)
        setActivePlaylist(id: id)
    }

    func activateSmartSports() {
        guard !playlists.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: Self.smartChannelsPreferredKey)
        if !isSmartSportsActive {
            smartSports.invalidateAutoDiscovery()
            isSmartSportsActive = true
            smartDisplayedCatalogSnapshot = nil
            loadFavorites()
            loadRecents()
            loadChannelUsage()
            loadGroupUsage()
            loadGroupPreferences()
            selection = .allChannels
            errorMessage = nil
            smartSportsDidChange()
        }
        refreshSmartSports(immediately: true)
        scheduleInactiveSourceRefresh()
    }

    /// Smart Channels shows every source, but only the active one has an
    /// ordinary sync. Refresh the others in turn when their saved channels
    /// or guide are older than the user's sync intervals, then regroup.
    private func scheduleInactiveSourceRefresh() {
        guard isSmartSportsActive, inactiveSourceRefreshTask == nil else { return }
        inactiveSourceRefreshTask = Task { [weak self] in
            // Let the launch path (hydration, active sync, Smart build) go first.
            try? await Task.sleep(for: .seconds(5))
            var refreshedAny = false
            var index = 0
            while let self, !Task.isCancelled, self.isSmartSportsActive {
                let others = self.playlists.filter { $0.id != self.activePlaylistID }
                guard index < others.count else { break }
                let source = others[index]
                index += 1
                if AppLifecycleCoordinator.shared.shouldPauseBackgroundWork {
                    index -= 1
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
                // Credentials come from Smart's resolved snapshot; an
                // unresolved source waits for a later pass.
                guard let config = self.smartSports.config(for: source.id) ?? (source.type == .m3u ? source : nil) else { continue }
                let key = DataCache.cacheKey(for: config)
                let channelsSavedAt = await Task.detached(priority: .utility) { DataCache.loadChannels(key: key)?.savedAt }.value
                let plan = BackgroundRefreshPolicy.plan(
                    channelsSavedAt: channelsSavedAt,
                    guideRefreshedAt: UserDefaults.standard.object(forKey: BackgroundSourceRefresher.guideRefreshedKey(for: source.id)) as? Date,
                    channelInterval: SyncInterval.storedValue(for: SyncInterval.playlistStorageKey, default: SyncInterval.playlistDefault).timeInterval,
                    guideInterval: SyncInterval.storedValue(for: SyncInterval.epgStorageKey, default: SyncInterval.epgDefault).timeInterval,
                    now: Date())
                guard !plan.isEmpty else { continue }
                let worker = Task.detached(priority: .utility) {
                    try await BackgroundSourceRefresher.refresh(config: config, plan: plan)
                }
                do {
                    _ = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    refreshedAny = true
                } catch {
                    guard !Task.isCancelled else { break }
                    AppLog.sync.error("Background source refresh failed error=\(error.localizedDescription, privacy: .public)")
                }
            }
            if refreshedAny, !Task.isCancelled {
                // Guide writes are throttled; land them before Smart rereads.
                await Task.detached(priority: .utility) { DataCache.flushPendingWrites() }.value
            }
            // A cancelled pass was already detached; never clear a newer one.
            guard let self, !Task.isCancelled else { return }
            self.inactiveSourceRefreshTask = nil
            if refreshedAny, self.isSmartSportsActive {
                self.smartSports.invalidateAutoDiscovery()
                self.refreshSmartSports()
            }
        }
    }

    private func cancelInactiveSourceRefresh() {
        inactiveSourceRefreshTask?.cancel()
        inactiveSourceRefreshTask = nil
    }

    /// Smart refresh reads saved snapshots; it never replaces a source's
    /// channel/guide storage or launches a second provider refresh.
    func refreshSmartSports(immediately: Bool = false) {
        guard isSmartSportsActive else { return }
        smartRefreshTask?.cancel()
        smartRefreshTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled, let self, self.isSmartSportsActive else { return }
            await self.smartSports.refresh(configurations: self.playlists,
                activeConfig: self.serverConfig, activeChannels: self.channels, activePrograms: self.programs)
            guard !Task.isCancelled, self.isSmartSportsActive else { return }
            for source in self.playlists {
                if let config = self.smartSports.config(for: source.id) {
                    StreamProbeService.shared.registerSourceCacheKey(sourceID: source.id,
                        cacheKey: DataCache.preferenceKey(for: config))
                }
            }
            self.hasLoadedOnce = true
            // The coordinator publishes incrementally while loading, then
            // completes without another revision. Flush its final snapshot.
            self.rebuildSearchIndex()
        }
    }

    private func smartSportsDidChange() {
        guard isSmartSportsActive else { return }
        let changeStarted = ContinuousClock.now
        defer { AppLog.sync.info("Smart change applied channels=\(self.smartSports.displayedChannels.count, privacy: .public) mainMs=\(AppLog.elapsedMilliseconds(since: changeStarted), privacy: .public)") }
        let displayed = smartSports.displayedChannels
        let catalogChanged = smartDisplayedCatalogSnapshot.map { previous in
            previous.count != displayed.count || !zip(previous, displayed).allSatisfy { lhs, rhs in
                lhs.id == rhs.id && lhs.name == rhs.name && lhs.group == rhs.group
                    && lhs.logoURL == rhs.logoURL && lhs.streamURL == rhs.streamURL
                    && lhs.epgChannelID == rhs.epgChannelID && lhs.catchup == rhs.catchup
                    && lhs.contentType == rhs.contentType && lhs.sourceOwnership == rhs.sourceOwnership
            }
        } ?? true
        smartDisplayedCatalogSnapshot = displayed
        if catalogChanged {
            channelCatalogVersion &+= 1
            rebuildChannelDerivedState()
        }
        guideVersion &+= 1
        rebuildSearchIndex()
        scheduleSmartVariantProbes()
    }

    /// Measures every account's variant of the feeds most likely to be
    /// played, so selection ranks on observed resolution, frame rate and
    /// bitrate instead of names. The probe service skips fresh results, waits
    /// while anything plays, and respects each account's connection limit.
    @ObservationIgnored private var capacityStatusCheckedAt: [UUID: Date] = [:]

    /// The capacity ledger treats an account as single-connection unless its
    /// connection status is under two minutes old. Refresh it for every Xtream
    /// source before probing so spare connections can be used safely.
    private func refreshAccountCapacityForProbing() {
        let now = Date()
        for source in playlists where source.type == .xtream {
            guard let config = smartSports.config(for: source.id) ?? (source.id == activePlaylistID ? serverConfig : nil),
                  now.timeIntervalSince(capacityStatusCheckedAt[source.id] ?? .distantPast) > 90 else { continue }
            capacityStatusCheckedAt[source.id] = now
            Task.detached(priority: .utility) {
                guard let info = try? await XtreamClient(config: config).fetchAccountInfo() else { return }
                // Only the account's limit is fed in. Providers keep counting a
                // stream for a while after it closes, so their active count
                // must not make a play request look over capacity.
                AccountCapacityLedger.shared.updateStatus(accountKey: SourceAccountKey(config: config),
                    maxConnections: info.maxConnections, activeConnections: nil, observedAt: Date())
                AppLog.sync.info("Account capacity refreshed max=\(info.maxConnections ?? -1, privacy: .public) active=\(info.activeConnections ?? -1, privacy: .public)")
                await MainActor.run { StreamProbeService.shared.retryQueuedProbes() }
            }
        }
    }

    private func scheduleSmartVariantProbes() {
        guard isSmartSportsActive, let catalog = smartSports.catalog else { return }
        refreshAccountCapacityForProbing()
        let preferred = Set(recentChannelIDs).union(favoriteChannelIDs)
        let filtering = smartSports.filter.isEnabled
        // Preferred sport, other preferred, other sport, the rest; catalog
        // order within each class. One class byte per feed, computed once,
        // instead of hashing feed IDs in every sort comparison.
        let feeds = catalog.feeds
        var classes = [UInt8](repeating: 0, count: feeds.count)
        for (index, feed) in feeds.enumerated() {
            let sporting = !AutoChannelGrouper.isAutomatic(feedID: feed.id) || feed.edition == "Sports"
            classes[index] = (preferred.contains(feed.id) ? 0 : 2) + (sporting ? 0 : 1)
        }
        var requested = 0
        requesting: for rank in UInt8(0)...3 {
            for index in feeds.indices where classes[index] == rank {
                // Classes 0-2 are preferred or sporting; the rest need a filter.
                guard rank < 3 || filtering else { continue }
                for variant in feeds[index].availableVariants {
                    guard let channel = variant.physicalChannel else { continue }
                    StreamProbeService.shared.requestProbe(for: channel, priority: .utility)
                    requested += 1
                }
                if requested >= 600 { break requesting }
            }
        }
        PerfMetrics.shared.record("probe.smartRequested", Double(requested))
    }

    /// Resolve the current endpoint at the time of the action. A logical row
    /// carries a display guide, which is never sufficient archive evidence.
    func resolvePlaybackRequest(_ request: PlaybackRequest) -> PlaybackRequest? {
        // On-demand requests were resolved and source-stamped at the async
        // catalog boundary; the guide's live-channel table cannot resolve them.
        if request.channel.isOnDemand { return request }
        guard let feedID = request.channel.sourceOwnership?.logicalChannelID else {
            guard let ownership = request.channel.sourceOwnership else { return request }
            guard let current = pinnedSourceChannel(ownership: ownership, legacyID: request.channel.id,
                playlistID: ownership.channelIdentity.sourceID) else {
                AppFeedbackCenter.shared.show(.init(title: "Source unavailable",
                    message: "This source has changed or its channel is no longer available. Open the original source and refresh it.",
                    symbol: "info.circle", tone: .warning, showsActivity: false))
                return nil
            }
            return PlaybackRequest(channel: current, intent: request.intent)
        }
        switch request.intent {
        case .catchup:
            showSmartActionUnavailable("Catchup needs validated timing for this source. Open its original guide to use the source’s own archive.")
            return nil
        case .resume:
            return nil
        case .live:
            smartSports.refreshObservationsIfNeeded()
            let preferred = smartSports.preferredVariant(for: feedID)
            if let existing = PlayerSessionRegistry.shared.channel(matching: request.channel),
               let key = existing.sourceChannelIdentity,
               preferred == nil || preferred == key,
               let current = resolvedSmartChannel(key, feedID: feedID) {
                return .live(current)
            }
            // An explicit source request can reuse its own window's budget;
            // replacement releases its old lease before reserving the new one.
            if preferred != nil, PlayerSessionRegistry.shared.channel(matching: request.channel) != nil,
               let planned = smartSports.selection(for: feedID, ignoreCapacity: true),
               let current = resolvedSmartChannel(planned.selected.key, feedID: feedID) { return .live(current) }
            guard let channel = smartSports.playbackChannel(for: feedID),
                  let key = channel.sourceChannelIdentity,
                  let current = resolvedSmartChannel(key, feedID: feedID) else {
                let availability = smartSports.aggregateAvailability(for: feedID)
                if availability.state == .busy || availability.state == .unavailable {
                    showSmartActionUnavailable(availability.message)
                } else {
                    showSmartActionUnavailable("The current source inputs have changed or are still loading. Refresh Smart Channels or open an original source.")
                }
                return nil
            }
            return .live(current)
        }
    }

    private func resolvedSmartChannel(_ key: SourceChannelIdentity, feedID: String) -> Channel? {
        guard smartSports.variants(for: feedID).contains(where: { $0.key == key && $0.isPlayable }),
              let config = smartSports.config(for: key.sourceID),
              let saved = playlists.first(where: { $0.id == key.sourceID }),
              !unresolvedCredentialIDs.contains(key.sourceID), Self.hasSameSource(config, saved),
              let channel = smartSports.currentChannel(for: key) else { return nil }
        return smartSports.logicalPlaybackChannel(channel, feedID: feedID)
    }

    func configureSmartRecovery(for slot: PlayerSlot) {
        smartSports.refreshObservationsIfNeeded()
        guard let feedID = slot.channel.sourceOwnership?.logicalChannelID,
              let selection = smartSports.selection(for: feedID, ignoreCapacity: true) else {
            slot.configureLiveAlternatives([])
            return
        }
        let alternatives = ([selection.selected] + selection.alternatives).compactMap {
            resolvedSmartChannel($0.key, feedID: feedID)
        }
        slot.configureLiveAlternatives(alternatives) { [weak self] key in
            self?.resolvedSmartChannel(key, feedID: feedID)
        }
    }

    /// The namespaced programme ID retains its actual guide endpoint. Match
    /// the current raw programme; never transplant another source's times.
    func sourceProgramAction(channel: Channel, program: EPGProgram) -> (channel: Channel, program: EPGProgram)? {
        guard let feedID = channel.sourceOwnership?.logicalChannelID,
              channel.epgChannelID?.hasPrefix("smart-guide:") == true else { return (channel, program) }
        for variant in smartSports.variants(for: feedID) {
            let prefix = variant.key.rawValue + "|"
            guard program.id.hasPrefix(prefix), let physical = resolvedSmartChannel(variant.key, feedID: feedID),
                  let raw = smartSports.programs(for: physical).first(where: {
                      $0.id == String(program.id.dropFirst(prefix.count)) && $0.start == program.start && $0.end == program.end
                  }) else { continue }
            return (physical, raw)
        }
        return nil
    }

    func showOriginalSourceGuide(for channel: Channel) {
        guard let binding = channel.sourceOwnership?.guideBinding,
              let key = smartSports.variants(for: channel.sourceOwnership?.logicalChannelID ?? "").first(where: {
                  $0.key.sourceID == binding.sourceID && $0.guideBinding == binding && $0.isPlayable
              })?.key else { return }
        setActivePlaylist(id: key.sourceID)
        Task { [weak self] in
            guard let self else { return }
            await self.hydrate()
            guard !self.isSmartSportsActive, self.activePlaylistID == key.sourceID,
                  let original = self.channels.first(where: { $0.sourceChannelIdentity == key }) else { return }
            self.selection = original.group.isEmpty ? .allChannels : .group(original.group)
            self.revealChannelID = original.id
        }
    }

    func showSmartActionUnavailable(_ message: String) {
        AppFeedbackCenter.shared.show(.init(title: "Smart Channels", message: message,
            symbol: "info.circle", tone: .warning, showsActivity: false))
    }

    func pinnedSourceChannel(ownership: ChannelSourceOwnership?, legacyID: String, playlistID: UUID) -> Channel? {
        if let ownership {
            let key = ownership.channelIdentity
            if let channel = channels.first(where: { $0.sourceChannelIdentity == key }) { return channel }
            guard let config = smartSports.config(for: key.sourceID),
                  let saved = playlists.first(where: { $0.id == key.sourceID }),
                  !unresolvedCredentialIDs.contains(key.sourceID), Self.hasSameSource(config, saved) else { return nil }
            return smartSports.currentChannel(for: key)
        }
        guard activePlaylistID == playlistID else { return nil }
        return channels.first { $0.id == legacyID }
    }

    /// All known groups in user-preferred order. Stored order wins for known names;
    /// any newly-discovered groups are appended alphabetically at the end.
    var allGroups: [String] { allGroupsCached }

    /// Visible groups shown in the sidebar.
    var groups: [String] {
        allGroupsCached.filter { !hiddenGroupNames.contains($0) }
    }

    /// Hidden groups, in the same relative order as `allGroups`.
    var hiddenGroups: [String] {
        allGroupsCached.filter { hiddenGroupNames.contains($0) }
    }

    var movieGroups: [String] { movieGroupsCached }

    var seriesGroups: [String] { seriesGroupsCached }

    var movieItems: [VODItem] { movieItemsCached }

    var isVODDisabled: Bool {
        UserDefaults.standard.bool(forKey: Self.disableVODKey)
    }

    func moveGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
        var visible = groups
        visible.move(fromOffsets: source, toOffset: destination)
        // Preserve hidden groups at the end so they keep their relative order.
        let hidden = allGroups.filter { hiddenGroupNames.contains($0) }
        storedGroupOrder = visible + hidden
        saveGroupPreferences()
    }

    func hideGroup(_ name: String) {
        hiddenGroupNames.insert(name)
        if !storedGroupOrder.contains(name) {
            storedGroupOrder.append(name)
        }
        if case .group(let current) = selection, current == name {
            selection = .allChannels
        }
        saveGroupPreferences()
    }

    func showGroup(_ name: String) {
        hiddenGroupNames.remove(name)
        saveGroupPreferences()
    }

    func showAllGroups() {
        hiddenGroupNames.removeAll()
        saveGroupPreferences()
    }

    func resetGroupOrder() {
        storedGroupOrder = []
        saveGroupPreferences()
    }

    func clearRecentlyWatched() {
        recentChannelIDs = []
        saveRecents()
    }

    func resetRecommendations() {
        recentChannelIDs = []
        channelUsageCounts = [:]
        groupUsageCounts = [:]
        saveRecents()
        saveChannelUsage()
        saveGroupUsage()
    }

    var filteredChannels: [Channel] { filteredChannelsCached }

    var filteredMovieItems: [VODItem] { filteredMovieItemsCached }

    var filteredSeries: [VODSeries] { filteredSeriesCached }

    var recentChannels: [Channel] { recentChannelsCached }

    var favoriteChannels: [Channel] { favoriteChannelsCached }

    var inProgressVODEntries: [VODResumeEntry] {
        vodResumeEntries
            .filter(\.isInProgress)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func resumeEntry(for item: VODItem) -> VODResumeEntry? {
        vodResumeEntries.first { $0.id == item.id && $0.isInProgress }
    }

    func removeVODResumeEntry(id: String) {
        vodResumeEntries.removeAll { $0.id == id }
        saveVODResumeEntries()
    }

    var groupPreferenceScores: [String: Double] { groupPreferenceScoresCached }

    var channelPreferenceScores: [String: Double] { channelPreferenceScoresCached }

    func isFavorite(_ channel: Channel) -> Bool {
        if channel.sourceOwnership?.logicalChannelID != nil, !isSmartSportsActive {
            return (UserDefaults.standard.array(forKey: "buffer_favorites_smart_sports_v1") as? [String] ?? []).contains(channel.id)
        }
        return favoriteChannelIDs.contains(channel.id)
    }

    func toggleFavorite(_ channel: Channel) {
        if channel.sourceOwnership?.logicalChannelID != nil, !isSmartSportsActive {
            var ids = Set(UserDefaults.standard.array(forKey: "buffer_favorites_smart_sports_v1") as? [String] ?? [])
            if !ids.insert(channel.id).inserted { ids.remove(channel.id) }
            UserDefaults.standard.set(Array(ids), forKey: "buffer_favorites_smart_sports_v1")
            return
        }
        if favoriteChannelIDs.contains(channel.id) {
            favoriteChannelIDs.remove(channel.id)
        } else {
            favoriteChannelIDs.insert(channel.id)
        }
        saveFavorites()
    }

    func addRecent(_ channel: Channel) {
        if channel.sourceOwnership?.logicalChannelID != nil, !isSmartSportsActive {
            var ids = UserDefaults.standard.array(forKey: "buffer_recents_smart_sports_v1") as? [String] ?? []
            ids.removeAll { $0 == channel.id }
            ids.insert(channel.id, at: 0)
            UserDefaults.standard.set(Array(ids.prefix(Self.recentsLimit)), forKey: "buffer_recents_smart_sports_v1")
            return
        }
        var ids = recentChannelIDs
        ids.removeAll { $0 == channel.id }
        ids.insert(channel.id, at: 0)
        if ids.count > Self.recentsLimit {
            ids = Array(ids.prefix(Self.recentsLimit))
        }
        recentChannelIDs = ids
        channelUsageCounts[channel.id, default: 0] += 1
        trimChannelUsageCounts()
        saveChannelUsage()
        if !channel.group.isEmpty {
            groupUsageCounts[channel.group, default: 0] += 1
            trimGroupUsageCounts()
            saveGroupUsage()
        }
        saveRecents()
    }

    func noteVODOpened(_ item: VODItem) {
        updateVODResumeEntry(for: item, positionSeconds: nil, durationSeconds: nil)
    }

    func updateVODPlaybackProgress(channelID: String, positionSeconds: Double, durationSeconds: Double?) {
        guard channelID.hasPrefix("vod:") else { return }
        let itemID = String(channelID.dropFirst(4))
        guard let item = findVODItem(id: itemID) ?? vodResumeEntries.first(where: { $0.id == itemID })?.item else { return }
        updateVODResumeEntry(for: item, positionSeconds: positionSeconds, durationSeconds: durationSeconds)
    }

    private func updateVODResumeEntry(for item: VODItem, positionSeconds: Double?, durationSeconds: Double?) {
        var entries = vodResumeEntries.filter { $0.id != item.id }
        let previous = vodResumeEntries.first { $0.id == item.id }
        let nextPosition = positionSeconds ?? previous?.positionSeconds ?? 0
        let entry = VODResumeEntry(
            item: detailItem(for: item),
            positionSeconds: nextPosition <= 0 && previous != nil ? previous?.positionSeconds ?? 0 : max(nextPosition, 0),
            durationSeconds: durationSeconds.flatMap { $0 > 0 ? $0 : nil } ?? previous?.durationSeconds ?? item.durationSeconds.map(Double.init),
            updatedAt: Date()
        )
        entries.insert(entry, at: 0)
        vodResumeEntries = Array(entries.prefix(Self.vodResumeLimit))
        saveVODResumeEntries()
    }

    private func findVODItem(id: String) -> VODItem? {
        if let detailed = vodItemDetails[id] {
            return detailed
        }
        if let item = vodItems.first(where: { $0.id == id }) {
            return item
        }
        return seriesEpisodes.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    func programsForChannel(_ channel: Channel) -> [EPGProgram] {
        if channel.sourceOwnership?.logicalChannelID != nil {
            if channel.epgChannelID?.hasPrefix("smart-guide:") == true {
                return smartSports.displayedPrograms[channel.epgChannelID ?? ""] ?? []
            }
            return smartSports.programs(for: channel)
        }
        if let sourceID = channel.sourceChannelIdentity?.sourceID, sourceID != activePlaylistID {
            return smartSports.programs(for: channel)
        }
        guard let epgID = channel.epgChannelID else { return [] }
        return programs[epgID] ?? []
    }

    func currentProgram(for channel: Channel) -> EPGProgram? {
        program(for: channel, at: Date())
    }

    func program(for channel: Channel, at date: Date) -> EPGProgram? {
        if channel.sourceOwnership?.logicalChannelID != nil ||
            (channel.sourceChannelIdentity != nil && channel.sourceChannelIdentity?.sourceID != activePlaylistID) {
            return GuideLookup.program(in: programsForChannel(channel), containing: date)
        }
        _ = guideVersion
        guard let epgID = channel.epgChannelID else { return nil }
        if let timeline = guideTimeline {
            guard let handle = timeline.handle(for: epgID) else { return nil }
            return timeline.program(handle, at: date)
        }
        return GuideLookup.program(in: programs[epgID] ?? [], containing: date)
    }

    // MARK: - Indexed State Rebuilders (Agent 03 - incremental, not per-access)

    private func rebuildChannelDerivedState() {
        channelByID = Dictionary(displayedChannels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        groupedChannels = Dictionary(grouping: displayedChannels, by: \.group)
        rebuildGroupOrder()
        rebuildRecentAndFavoriteChannels()
        rebuildScoreMaps()
        rebuildFilteredCaches()
    }

    private func rebuildGroupOrder() {
        let raw = Set(groupedChannels.keys)
        let ordered = storedGroupOrder.filter { raw.contains($0) }
        let seen = Set(ordered)
        let newOnes = raw.subtracting(seen).sorted()
        allGroupsCached = ordered + newOnes
    }

    private func rebuildVODDerivedState() {
        movieItemsCached = vodItems.filter { $0.kind != .seriesEpisode }
        movieGroupsCached = Array(Set(movieItemsCached.map(\.group))).sorted()
        seriesGroupsCached = Array(Set(vodSeries.map(\.group))).sorted()
        rebuildFilteredCaches()
    }

    private func setActiveStreamProbeScope(for config: ServerConfig) {
        StreamProbeService.shared.setActiveCacheKey(
            DataCache.preferenceKey(for: config),
            legacyKeys: DataCache.legacyCacheKeys(for: config), sourceID: config.id
        )
    }

    private func rebuildRecentAndFavoriteChannels() {
        recentChannelsCached = recentChannelIDs.compactMap { channelByID[$0] }
        favoriteChannelsCached = favoriteChannelIDs.compactMap { channelByID[$0] }
    }

    private func rebuildRecentFavoriteAndScores() {
        rebuildRecentAndFavoriteChannels()
        rebuildScoreMaps()
        rebuildFilteredCaches()
    }

    private func rebuildScoreMaps() {
        // Group scores (preference for sidebar/home recommendations)
        var gScores: [String: Double] = [:]
        for (index, channelID) in recentChannelIDs.enumerated() {
            guard let group = channelByID[channelID]?.group, !group.isEmpty else { continue }
            gScores[group, default: 0] += max(0.2, 1.0 - (Double(index) * 0.035))
        }
        for channelID in favoriteChannelIDs {
            guard let group = channelByID[channelID]?.group, !group.isEmpty else { continue }
            gScores[group, default: 0] += 1.25
        }
        for (group, count) in groupUsageCounts where count > 0 {
            gScores[group, default: 0] += log1p(Double(count)) * 0.75
        }
        if let maxScore = gScores.values.max(), maxScore > 0 {
            gScores = gScores.mapValues { min(1.0, $0 / maxScore) }
        } else {
            gScores = [:]
        }
        // Channel scores
        var cScores: [String: Double] = [:]
        for (index, channelID) in recentChannelIDs.enumerated() {
            cScores[channelID, default: 0] += exp(-Double(index) / 8.0)
        }
        for channelID in favoriteChannelIDs {
            cScores[channelID, default: 0] += 1.5
        }
        for (channelID, count) in channelUsageCounts where count > 0 {
            cScores[channelID, default: 0] += log1p(Double(count)) * 0.75
        }
        if let maxScore = cScores.values.max(), maxScore > 0 {
            cScores = cScores.mapValues { min(1.0, $0 / maxScore) }
        } else {
            cScores = [:]
        }
        guard groupPreferenceScoresCached != gScores || channelPreferenceScoresCached != cScores else { return }
        groupPreferenceScoresCached = gScores
        channelPreferenceScoresCached = cScores
        preferenceScoresVersion &+= 1
    }

    private func rebuildFilteredCaches() {
        // Live channels: use groupedChannels for O(1) group case, cached lists for favs
        var chResult: [Channel]
        switch selection {
        case .group(let group):
            chResult = groupedChannels[group] ?? []
        case .favorites:
            chResult = favoriteChannelsCached
        default:
            chResult = displayedChannels
        }
        if !searchText.isEmpty {
            chResult = chResult.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        // Invalidate on metadata changes too (Channel equality is ID-only).
        // This runs on source mutations, never on a SwiftUI body pass.
        filteredChannelSetVersion &+= 1
        filteredChannelsCached = chResult

        // VOD movies
        var mResult = movieItemsCached
        if case .movieGroup(let group) = selection {
            mResult = mResult.filter { $0.group == group }
        }
        if !searchText.isEmpty {
            mResult = mResult.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        filteredMovieItemsCached = mResult

        // VOD series
        var sResult = vodSeries
        if case .seriesGroup(let group) = selection {
            sResult = sResult.filter { $0.group == group }
        }
        if !searchText.isEmpty {
            sResult = sResult.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        filteredSeriesCached = sResult
    }

    // MARK: - Hydrate

    /// Older M3U imports generated a fresh UUID for channels without tvg-id.
    /// Move their preferences once a refresh replaces those cached channels
    /// with URL-based IDs. Matching ignores mutable display metadata; repeated
    /// identical URLs retain their occurrence order because no provider ID can
    /// distinguish those rows.
    private func migrateM3UChannelPreferences(from previous: [Channel], to current: [Channel]) {
        let legacyChannels = previous.filter {
            ($0.epgChannelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && UUID(uuidString: $0.id) != nil
        }
        guard !legacyChannels.isEmpty else { return }
        var idsByURL: [URL: [String]] = [:]
        for channel in current where channel.epgChannelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            idsByURL[channel.streamURL, default: []].append(channel.id)
        }
        var occurrences: [URL: Int] = [:]
        var replacements: [String: String] = [:]
        for channel in legacyChannels {
            let occurrence = occurrences[channel.streamURL, default: 0]
            occurrences[channel.streamURL] = occurrence + 1
            guard let ids = idsByURL[channel.streamURL], ids.indices.contains(occurrence),
                  ids[occurrence] != channel.id else { continue }
            replacements[channel.id] = ids[occurrence]
        }
        guard !replacements.isEmpty else { return }

        let favorites = Set(favoriteChannelIDs.map { replacements[$0] ?? $0 })
        if favorites != favoriteChannelIDs {
            favoriteChannelIDs = favorites
            saveFavorites()
        }
        var seenRecents = Set<String>()
        let recents = recentChannelIDs.compactMap { id -> String? in
            let replacement = replacements[id] ?? id
            return seenRecents.insert(replacement).inserted ? replacement : nil
        }
        if recents != recentChannelIDs {
            recentChannelIDs = recents
            saveRecents()
        }
        var usage = channelUsageCounts
        for (oldID, newID) in replacements {
            if let count = usage.removeValue(forKey: oldID) { usage[newID, default: 0] += count }
        }
        if usage != channelUsageCounts {
            channelUsageCounts = usage
            saveChannelUsage()
        }
        if let id = revealChannelID, let replacement = replacements[id] { revealChannelID = replacement }
    }

    /// Await the on-launch cache hydration kicked off in init.
    func hydrate() async {
        await hydrationTask?.value
    }

    /// Actual cache loader. Runs once at startup from init. Channels are
    /// decoded first so the sidebar + home paint as soon as possible; the
    /// larger programs blob follows. Search index is only built once, after
    /// programs arrive, since building it on channels alone produces nothing.
    private func hydrateFromDisk() async {
        guard let config = serverConfig else {
            hasLoadedOnce = true
            return
        }
        let generation = sourceGeneration
        let catalogID = catalogGeneration
        let key = DataCache.cacheKey(for: config)
        let started = ContinuousClock.now

        let (channelsCache, channelsMs) = await Task.detached(priority: .userInitiated) {
            Self.timedCacheLoad { DataCache.loadChannels(key: key) }
        }.value
        guard !Task.isCancelled, isCurrentSource(generation, config: config) else { return }
        if let channelsCache, !channelsCache.channels.isEmpty {
            // Old same-schema caches may predate stream-specific fallback IDs.
            // Missing provider XMLTV IDs must not collapse unrelated rows or
            // prevent the channel API from supplying their actual schedule.
            let hydratedChannels = config.type == .xtream ? channelsCache.channels.map { channel in
                guard channel.epgChannelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return channel }
                return Channel(id: channel.id, name: channel.name, logoURL: channel.logoURL,
                    group: channel.group, streamURL: channel.streamURL, epgChannelID: "xtream-stream-\(channel.id)",
                    catchup: channel.catchup, contentType: channel.contentType)
            } : channelsCache.channels
            channels = hydratedChannels.map { SmartSportsSnapshotLoader.stamp($0, config: config) }
            lastUpdated = channelsCache.savedAt
        }
        let channelsPublishedMs = AppLog.elapsedMilliseconds(since: started)

        // The guide is the largest slot and is always read; decode it
        // alongside the catalog. The columnar slot needs only the channel
        // retention windows, which are applied on its Int32 columns so
        // expired listings are never materialized, then the flat timeline
        // is built on the same worker.
        let retentionChannels = channels
        let programsLoad = Task.detached(priority: .userInitiated) { () -> (PreparedGuideSnapshot?, Int, Int) in
            // A full channel scan; keep it off the main actor.
            let retention = GuideHistory.retentionPolicy(
                starts: GuideHistory.retentionStarts(channels: retentionChannels, now: Date()), now: Date())
            let (cache, loadMs) = Self.timedCacheLoad { DataCache.loadPrograms(key: key, retaining: retention) }
            guard let cache, !Task.isCancelled else { return (nil, loadMs, 0) }
            let prepareStarted = ContinuousClock.now
            let snapshot = Self.prepareGuideSnapshot(programs: cache.programs)
            return (snapshot, loadMs, AppLog.elapsedMilliseconds(since: prepareStarted))
        }
        defer { programsLoad.cancel() }

        // Disabled catalogs can be large. Check before disk IO/decoding and
        // again after each await; preference changes must not publish an old
        // catalog or schedule the next disabled cache read.
        var vodMs = 0
        if !isVODDisabled, catalogID == catalogGeneration {
            let (vodCache, ms) = await Task.detached(priority: .userInitiated, operation: {
                Self.timedCacheLoad { DataCache.loadVODItems(key: key) }
            }).value
            vodMs = ms
            guard !Task.isCancelled, isCurrentSource(generation, config: config) else { return }
            if let vodCache, !isVODDisabled, catalogID == catalogGeneration {
                vodItems = vodCache.items
                if lastUpdated == nil {
                    lastUpdated = vodCache.savedAt
                }
            }
        }
        var seriesMs = 0
        if !isVODDisabled, catalogID == catalogGeneration {
            let (seriesCache, ms) = await Task.detached(priority: .userInitiated, operation: {
                Self.timedCacheLoad { DataCache.loadVODSeries(key: key) }
            }).value
            seriesMs = ms
            guard !Task.isCancelled, isCurrentSource(generation, config: config) else { return }
            if let seriesCache, !isVODDisabled, catalogID == catalogGeneration {
                vodSeries = seriesCache.series
                if lastUpdated == nil {
                    lastUpdated = seriesCache.savedAt
                }
            }
        }
        searchIndexVersion &+= 1
        hasLoadedOnce = true

        let catalogPublishedMs = AppLog.elapsedMilliseconds(since: started)

        let (programsSnapshot, programsMs, prepareMs) = await programsLoad.value
        guard !Task.isCancelled, isCurrentSource(generation, config: config) else { return }
        if let programsSnapshot {
            // Historical rows remain useful even when the live/future window
            // has expired; live coverage is checked separately for refresh.
            publishPreparedGuide(programsSnapshot)
        }
        AppLog.sync.info("Hydration finished channels=\(self.channels.count, privacy: .public) programKeys=\(self.programs.count, privacy: .public) elapsedMs=\(AppLog.elapsedMilliseconds(since: started), privacy: .public) channelsLoadMs=\(channelsMs, privacy: .public) vodLoadMs=\(vodMs, privacy: .public) seriesLoadMs=\(seriesMs, privacy: .public) programsLoadMs=\(programsMs, privacy: .public) guidePrepareMs=\(prepareMs, privacy: .public) channelsPublishedMs=\(channelsPublishedMs, privacy: .public) catalogPublishedMs=\(catalogPublishedMs, privacy: .public)")
    }

    nonisolated private static func timedCacheLoad<T>(_ load: () -> T?) -> (T?, Int) {
        let started = ContinuousClock.now
        let value = load()
        return (value, AppLog.elapsedMilliseconds(since: started))
    }

    private func recordLoadingStageTransition(from previousStage: String?, to nextStage: String?) {
#if DEBUG
        guard previousStage != nextStage else { return }
        let now = ContinuousClock.now
        if let previousStage, let loadingStageStartedAt {
            AppLog.performance.info("content stage-finished stage=\(previousStage, privacy: .public) elapsedMs=\(AppLog.elapsedMilliseconds(since: loadingStageStartedAt, now: now), privacy: .public) channels=\(self.channels.count, privacy: .public) vod=\(self.vodItems.count, privacy: .public) series=\(self.vodSeries.count, privacy: .public) programKeys=\(self.programs.count, privacy: .public)")
        }

        if let nextStage {
            loadingStageStartedAt = now
            AppLog.performance.info("content stage-start stage=\(nextStage, privacy: .public)")
        } else {
            loadingStageStartedAt = nil
        }
#endif
    }

    // MARK: - Sync

    enum SyncScope {
        case all    // channels + EPG
        case epg    // EPG only
    }

    /// Fetch fresh channels + EPG. Fully async and non-blocking: parsing
    /// happens on background tasks, UI state only flips the small top banner.
    /// Pass `silent: true` for scheduled background syncs (no banner).
    func sync(silent: Bool = false, scope: SyncScope = .all) {
        var silent = silent
        if isSmartSportsActive {
            // Smart displays a catalogue built from saved source snapshots.
            // Keep the underlying active account fresh beneath it (quietly);
            // Smart rebuilds again when that refresh finishes.
            refreshSmartSports(immediately: !silent)
            scheduleInactiveSourceRefresh()
            silent = true
        }
        guard let config = serverConfig else {
            let credentialUnavailable = activePlaylistID.map { unresolvedCredentialIDs.contains($0) } ?? false
            if !credentialUnavailable {
                errorMessage = nil
                hasLoadedOnce = true
            }
            return
        }

        // Coalesce: if a sync is already running, leave it be.
        if let active = activeSyncTask, !active.isCancelled {
            // A guide-only refresh does not satisfy a manual full refresh.
            // Coalesce repeated full requests into one follow-up instead of
            // silently dropping the broader request or duplicating traffic.
            if activeSyncScope == .epg, scope == .all {
                pendingSync = (.all, (pendingSync?.silent ?? true) && silent)
            }
            AppLog.sync.info("Sync skipped already running scope=\(String(describing: scope), privacy: .public)")
            return
        }

        if !silent, scope == .all { guideAttempts = [:] }
        guideProgressBuffer = GuideProgressBuffer()
        guideMaximumCommitMilliseconds = 0
        let id = UUID()
        let generation = sourceGeneration
        activeSyncID = id
        activeSyncScope = scope
        activeSyncTask = Task { [weak self] in
            guard let self else { return }
            // A cache read already in progress must finish before fresh data
            // arrives, otherwise hydration can overwrite a successful refresh.
            await self.hydrationTask?.value
            await self.performSync(config: config, id: id, generation: generation, silent: silent, scope: scope)
        }
    }

    /// Await the current (or newly started) sync — used by the refresh button.
    func syncAndWait(silent: Bool = false, scope: SyncScope = .all) async {
        sync(silent: silent, scope: scope)
        if isSmartSportsActive {
            await smartRefreshTask?.value
            return
        }
        while let task = activeSyncTask {
            await task.value
        }
    }

    private func syncAfterInputChange(scope: SyncScope) {
        if let active = activeSyncTask, !active.isCancelled {
            let queuedScope: SyncScope = pendingSync?.scope == .all || scope == .all ? .all : .epg
            pendingSync = (queuedScope, false)
        } else {
            sync(scope: scope)
        }
    }

    private func performSync(config: ServerConfig, id: UUID, generation: UUID, silent: Bool, scope: SyncScope) async {
        guard !Task.isCancelled, activeSyncID == id, isCurrentSource(generation, config: config) else { return }
        let signpostID = AppLog.syncSignposter.makeSignpostID()
        let signpostState = AppLog.syncSignposter.beginInterval(
            "EPGSync",
            id: signpostID,
            "scope=\(String(describing: scope), privacy: .public) silent=\(silent, privacy: .public)"
        )
        AppLog.sync.info("Sync started scope=\(String(describing: scope), privacy: .public) silent=\(silent, privacy: .public) type=\(config.type.rawValue, privacy: .public) channels=\(self.channels.count, privacy: .public) programKeys=\(self.programs.count, privacy: .public)")
        let started = ContinuousClock.now
        let cacheKey = DataCache.cacheKey(for: config)
        var syncedStatus = ServerAccountStatus.initial(for: config, cacheKey: DataCache.preferenceKey(for: config))
        var refreshedGuide = false
        var refreshedCatalog = false

        if !silent {
            isRefreshing = true
            loadingStage = scope == .epg ? "Loading guide…" : "Loading channels…"
            errorMessage = nil
        }

        defer {
            AppLog.syncSignposter.endInterval("EPGSync", signpostState)
            // An obsolete task may finish after a new source's refresh starts.
            // It must never clear that task's handle or its loading indicator.
            if activeSyncID == id {
                finishGuideSearchEnrichment()
                if !silent {
                    isRefreshing = false
                    loadingStage = nil
                }
                hasLoadedOnce = true
                activeSyncTask = nil
                activeSyncID = nil
                activeSyncScope = nil
                if isSmartSportsActive { refreshSmartSports() }
                if let pending = pendingSync {
                    pendingSync = nil
                    sync(silent: pending.silent, scope: pending.scope)
                }
            }
        }

        do {
            // M3U EPG fetch is independent of channel metadata. Xtream XMLTV
            // needs channel catchup durations to request the full previous-days
            // window, so it must wait until channels are loaded/refreshed.
            let prefetchedEPG: Task<XMLTVGuide, any Error>?
            if scope == .all, config.type == .m3u, let epgURL = epgURL(for: config) {
                prefetchedEPG = Task { try await XMLTVParser.parseGuide(from: epgURL) }
            } else {
                prefetchedEPG = nil
            }
            defer { prefetchedEPG?.cancel() }

            if scope == .all {
                switch config.type {
                case .xtream:
                    if let accountInfo = try? await XtreamClient(config: config).fetchAccountInfo() {
                        syncedStatus.apply(accountInfo)
                    }
                case .stalker:
                    if let accountInfo = try? await StalkerClient(config: config).fetchAccountInfo() {
                        syncedStatus.apply(accountInfo)
                    }
                case .m3u:
                    break
                }
                try checkSync(id, generation: generation, config: config)

                let freshChannels = try await fetchChannels(config: config)
                try checkSync(id, generation: generation, config: config)
                syncedStatus.channelCount = freshChannels.count
                if !freshChannels.isEmpty {
                    // Older M3U content slots can supply the UUID-to-URL map
                    // for preferences during the v8 rollout. Freshly fetched
                    // channels are authoritative: legacy URLs are never made
                    // playable and legacy guides/catalogs are never hydrated.
                    if config.type == .m3u {
                        var legacyReferences = favoriteChannelIDs
                        legacyReferences.formUnion(recentChannelIDs)
                        legacyReferences.formUnion(channelUsageCounts.keys)
                        legacyReferences = legacyReferences.filter { UUID(uuidString: $0) != nil }
                        // Explicit provider UUIDs still present in the fresh
                        // catalog do not need a legacy disk lookup.
                        for channel in freshChannels { legacyReferences.remove(channel.id) }
                        if !legacyReferences.isEmpty {
                            let legacyKeys = DataCache.legacyCacheKeys(for: config).filter { $0 != cacheKey }
                            let previousChannels = await Task.detached(priority: .utility) {
                                for key in legacyKeys {
                                    if Task.isCancelled { return [Channel]() }
                                    if let cached = DataCache.loadChannels(key: key), !cached.channels.isEmpty {
                                        return cached.channels
                                    }
                                }
                                return [Channel]()
                            }.value
                            try checkSync(id, generation: generation, config: config)
                            migrateM3UChannelPreferences(from: previousChannels, to: freshChannels)
                        }
                    }
                    channels = freshChannels
                    rebuildSearchIndex()
                    refreshedCatalog = true

                    DataCache.enqueueSaveChannels(freshChannels, key: cacheKey)
                }
                if isVODDisabled {
                    vodItems = []
                    vodSeries = []
                    vodItemDetails = [:]
                    vodItemDetailLoadErrors = [:]
                    loadingVODItemIDs = []
                    searchIndexVersion &+= 1
                }
            } else {
                // EPG-only: preserve existing channel count in status
                syncedStatus.channelCount = channels.count
            }

            let catalogID = catalogGeneration
            let loadCatalog = scope == .all && !isVODDisabled
            // Structured children are cancelled with the sync and keep catalog
            // transport overlapped with guide loading/preparation.
            async let catalog = fetchCatalog(config: config, enabled: loadCatalog)

            isGuideEnriching = true
            if config.type == .stalker {
                let client = StalkerClient(config: config)
                // Current rows must not wait behind the extended historical
                // response, which providers may truncate or serve slowly.
                do {
                    let current = try await client.fetchEPG(periodHours: 24, channels: channels)
                    try await publishGuidePrograms(current, id: id, generation: generation,
                        config: config, cacheKey: cacheKey, stage: "current", forcePersist: true)
                    refreshedGuide = !current.isEmpty
                    syncedStatus.guideStatus = refreshedGuide ? "Reachable" : "Empty"
                } catch {
                    try checkSync(id, generation: generation, config: config)
                    AppLog.sync.error("Stalker current guide fetch failed error=\(error.localizedDescription, privacy: .public)")
                    syncedStatus.guideStatus = "Unavailable"
                }
                let hours = epgLookbackHours(for: channels)
                if hours > 24 {
                    if !silent { loadingStage = "Loading guide history…" }
                    do {
                        let history = try await client.fetchEPG(periodHours: hours, channels: channels)
                        try await publishGuidePrograms(history, id: id, generation: generation,
                            config: config, cacheKey: cacheKey, stage: "history", forcePersist: true)
                        refreshedGuide = refreshedGuide || !history.isEmpty
                    } catch {
                        try checkSync(id, generation: generation, config: config)
                        AppLog.sync.error("Stalker guide history fetch failed; retaining available guide error=\(error.localizedDescription, privacy: .public)")
                    }
                }
            } else if let epgURL = epgURL(for: config) {
                let priorityGuideTask: Task<Void, Never>?
                if config.type == .xtream {
                    priorityGuideTask = Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.enrichXtreamGuide(config: config, id: id, generation: generation,
                                cacheKey: cacheKey, silent: silent, priorityOnly: true)
                        } catch { /* owning sync handles cancellation */ }
                    }
                } else { priorityGuideTask = nil }
                defer { priorityGuideTask?.cancel() }
                var currentSignature: XtreamGuideSignature?
                do {
                    let current: XMLTVGuide
                    if let task = prefetchedEPG {
                        current = try await withTaskCancellationHandler {
                            try await task.value
                        } onCancel: { task.cancel() }
                    } else {
                        current = try await XMLTVParser.parseGuide(from: epgURL)
                    }
                    if config.type == .xtream { currentSignature = XtreamGuideSignature(current) }
                    try await publishGuidePrograms(current, id: id, generation: generation,
                        config: config, cacheKey: cacheKey, stage: "current", forcePersist: true)
                    refreshedGuide = !current.isEmpty
                    syncedStatus.guideStatus = refreshedGuide ? "Reachable" : "Empty"
                } catch {
                    try checkSync(id, generation: generation, config: config)
                    AppLog.sync.error("Current guide fetch failed; retaining available guide error=\(error.localizedDescription, privacy: .public)")
                    syncedStatus.guideStatus = "Unavailable"
                }

                if config.type == .xtream {
                    // Bulk XML and channel-specific history run together. Each
                    // publishes through the same ordered delta pipeline, so a
                    // fast visible channel never waits for the global tail.
                    let lookbackTask: Task<Void, Never>?
                    let redundancyKey = Self.xtreamLookbackRedundantKey(for: config)
                    let currentSignature = currentSignature
                    if xtreamLookbackDays() > 1,
                       catchupGuideNeedsHistory(for: channels, now: Date()),
                       !Self.isXtreamLookbackKnownRedundant(key: redundancyKey),
                       let url = xtreamLookbackEPGURL(for: config) {
                        lookbackTask = Task { [weak self] in
                            do {
                                let history = try await XMLTVParser.parseGuide(from: url)
                                try Task.checkCancellation()
                                // Some providers ignore prev_days and return
                                // the same document. Remember that so later
                                // syncs skip the duplicate bulk download.
                                if let currentSignature, XtreamGuideSignature(history) == currentSignature {
                                    UserDefaults.standard.set(Date(), forKey: redundancyKey)
                                    AppLog.sync.info("Xtream lookback matched current guide; skipping it for later syncs programs=\(history.count, privacy: .public)")
                                    return
                                }
                                UserDefaults.standard.removeObject(forKey: redundancyKey)
                                guard let self else { return }
                                try await self.publishGuidePrograms(history, id: id, generation: generation,
                                    config: config, cacheKey: cacheKey, stage: "lookback", forcePersist: true)
                            } catch {
                                guard !Task.isCancelled else { return }
                                AppLog.sync.error("Xtream lookback fetch failed; retaining available guide error=\(error.localizedDescription, privacy: .public)")
                            }
                        }
                    } else { lookbackTask = nil }
                    defer { lookbackTask?.cancel() }
                    if !silent { loadingStage = "Loading guide history…" }
                    if let priorityGuideTask {
                        await withTaskCancellationHandler {
                            await priorityGuideTask.value
                        } onCancel: { priorityGuideTask.cancel() }
                    }
                    try await enrichXtreamGuide(config: config, id: id, generation: generation,
                                                cacheKey: cacheKey, silent: silent)
                    if let lookbackTask {
                        await withTaskCancellationHandler {
                            await lookbackTask.value
                        } onCancel: { lookbackTask.cancel() }
                    }
                    try checkSync(id, generation: generation, config: config)
                    DataCache.enqueueSavePrograms(programs, key: cacheKey)
                    refreshedGuide = refreshedGuide || !programs.isEmpty
                    if !programs.isEmpty && syncedStatus.guideStatus != "Reachable" {
                        syncedStatus.guideStatus = "Partial"
                    }
                }
            } else {
                syncedStatus.guideStatus = "Not configured"
            }
            finishGuideSearchEnrichment()

            if refreshedGuide || (scope == .all && refreshedCatalog && syncedStatus.guideStatus == "Not configured") {
                lastUpdated = Date()
            }
            do {
                let catalogStarted = ContinuousClock.now
                let result = await catalog
                try checkSync(id, generation: generation, config: config)
                if catalogID == catalogGeneration, !isVODDisabled {
                    if case .success? = result.items {
                        catalogGeneration = UUID()
                        loadingVODItemIDs = []
                        loadingSeriesIDs = []
                    } else if case .success? = result.series {
                        catalogGeneration = UUID()
                        loadingVODItemIDs = []
                        loadingSeriesIDs = []
                    }
                    if let items = result.items {
                        switch items {
                        case .success(let freshItems):
                            vodItems = freshItems
                            vodItemDetails = [:]
                            vodItemDetailLoadErrors = [:]
                            loadingVODItemIDs = []
                            DataCache.enqueueSaveVODItems(freshItems, key: cacheKey)
                        case .failure(let error):
                            AppLog.sync.error("Movie catalog fetch failed; retaining cache error=\(error.localizedDescription, privacy: .public)")
                            if !silent { errorMessage = "Movies unavailable: \(error.localizedDescription)" }
                        }
                    }
                    if let series = result.series {
                        switch series {
                        case .success(let freshSeries):
                            vodSeries = freshSeries
                            seriesEpisodes = [:]
                            seriesEpisodeLoadErrors = [:]
                            loadingSeriesIDs = []
                            DataCache.enqueueSaveVODSeries(freshSeries, key: cacheKey)
                        case .failure(let error):
                            AppLog.sync.error("Series catalog fetch failed; retaining cache error=\(error.localizedDescription, privacy: .public)")
                            if !silent { errorMessage = "Series unavailable: \(error.localizedDescription)" }
                        }
                    }
                    if result.items != nil || result.series != nil { searchIndexVersion &+= 1 }
                }
                AppLog.sync.info("Playlist catalog joined vod=\(self.vodItems.count, privacy: .public) series=\(self.vodSeries.count, privacy: .public) waitMs=\(AppLog.elapsedMilliseconds(since: catalogStarted), privacy: .public)")
            }
            updateServerStatus(syncedStatus)
            let elapsed = started.duration(to: .now).components.seconds
            AppLog.sync.info("Sync finished scope=\(String(describing: scope), privacy: .public) silent=\(silent, privacy: .public) seconds=\(elapsed, privacy: .public) channels=\(self.channels.count, privacy: .public) groups=\(self.groups.count, privacy: .public) programKeys=\(self.programs.count, privacy: .public) guide=\(syncedStatus.guideStatus, privacy: .public)")

        } catch {
            guard !Task.isCancelled, isCurrentSource(generation, config: config), activeSyncID == id else { return }
            AppLog.sync.error("Sync failed scope=\(String(describing: scope), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if !silent && channels.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Current XML, bulk history and per-channel completions all join this
    /// ordered pipeline. Only changed guide IDs rebuild buckets/lookups.
    private func publishGuidePrograms(_ incoming: [EPGProgram], id: UUID, generation: UUID,
                                      config: ServerConfig, cacheKey: String, stage: String,
                                      forcePersist: Bool = false) async throws {
        try await publishGuide(incomingCount: incoming.count, organizeIncoming: { Self.organize(incoming) }, id: id,
                               generation: generation, config: config, cacheKey: cacheKey, stage: stage,
                               forcePersist: forcePersist)
    }

    /// XMLTV guides arrive as columns; the worker groups them per channel
    /// directly (`XMLTVGuide.programsByChannel` equals `organize` over the
    /// flat list) instead of materializing and regrouping a flat array.
    private func publishGuidePrograms(_ incoming: XMLTVGuide, id: UUID, generation: UUID,
                                      config: ServerConfig, cacheKey: String, stage: String,
                                      forcePersist: Bool = false) async throws {
        try await publishGuide(incomingCount: incoming.count, organizeIncoming: { incoming.programsByChannel() }, id: id,
                               generation: generation, config: config, cacheKey: cacheKey, stage: stage,
                               forcePersist: forcePersist)
    }

    private func publishGuide(incomingCount: Int, organizeIncoming: @escaping @Sendable () -> [String: [EPGProgram]],
                              id: UUID, generation: UUID, config: ServerConfig, cacheKey: String, stage: String,
                              forcePersist: Bool) async throws {
        let predecessor = guidePublicationTask
        let task = Task { [weak self] in
            _ = await predecessor?.result
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            try self.checkSync(id, generation: generation, config: config)
            let base = self.programs
            let channels = self.channels
            let baseVersion = self.guideVersion
            let baseTimeline = self.guideTimeline
            let now = Date()
            let pruneAll = stage == "current"
            // The worker merges the changed IDs into a complete guide and
            // builds its timeline; unchanged runs are column copies.
            let worker = Task.detached(priority: .userInitiated) { () -> (delta: [String: [EPGProgram]], snapshot: PreparedGuideSnapshot) in
                let started = ContinuousClock.now
                // A full channel scan per publication; keep it off the main actor.
                let starts = GuideHistory.retentionStarts(channels: channels, now: now)
                let organized = organizeIncoming()
                var delta: [String: [EPGProgram]] = [:]
                let ids = pruneAll ? Set(base.keys).union(organized.keys) : Set(organized.keys)
                for epgID in ids {
                    if Task.isCancelled { break }
                    guard let earliest = starts[epgID] else { delta[epgID] = []; continue }
                    delta[epgID] = GuideHistory.merge(existing: base[epgID] ?? [], incoming: organized[epgID] ?? [], earliest: earliest, now: now)
                }
                var full = base
                for (epgID, list) in delta { full[epgID] = list.isEmpty ? nil : list }
                let mergeMs = AppLog.elapsedMilliseconds(since: started)
                return (delta, Self.prepareGuideSnapshot(programs: full, reusing: baseTimeline, mergeMs: mergeMs))
            }
            let (delta, prepared) = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            try self.checkSync(id, generation: generation, config: config)
            let mainStarted = ContinuousClock.now
            let full: [String: [EPGProgram]]
            if self.guideVersion == baseVersion {
                full = prepared.programs
                self.programs = full
                self.guideTimeline = prepared.timeline
            } else {
                // The guide was replaced meanwhile (e.g. hydration); apply the
                // delta to the newer guide and leave it to the exact lookup.
                var merged = self.programs
                for (epgID, list) in delta { merged[epgID] = list.isEmpty ? nil : list }
                full = merged
                self.programs = full
            }
            self.rebuildSearchIndex()
            self.lastUpdated = now
            let elapsed = mainStarted.duration(to: .now).components
            let commitMs = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            self.guideMaximumCommitMilliseconds = max(self.guideMaximumCommitMilliseconds, commitMs)
            let persist = forcePersist || self.lastGuidePersistedAt.map { AppLog.elapsedMilliseconds(since: $0) >= 3000 } ?? true
            if persist {
                DataCache.enqueueSavePrograms(full, key: cacheKey)
                self.lastGuidePersistedAt = .now
            }
            AppLog.sync.info("Guide progressive publication stage=\(stage, privacy: .public) incoming=\(incomingCount, privacy: .public) changedKeys=\(delta.count, privacy: .public) totalKeys=\(full.count, privacy: .public) mergeMs=\(prepared.mergeMs, privacy: .public) bucketMs=\(prepared.bucketMs, privacy: .public) persisted=\(persist, privacy: .public) mainCommitMs=\(commitMs, privacy: .public)")
        }
        guidePublicationTask = task
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    @MainActor private final class GuideProgressBuffer {
        var programs: [EPGProgram] = []
        var lastPublication = ContinuousClock.now
        var published = false
        var totalReceived = 0
    }

    private func enrichXtreamGuide(config: ServerConfig, id: UUID, generation: UUID,
                                   cacheKey: String, silent: Bool, priorityOnly: Bool = false) async throws {
        let client = XtreamClient(config: config)
        var attempted: Set<String> = []
        var completed = 0
        var consecutiveFailures = 0
        var hasUsefulResults = false
        let started = ContinuousClock.now
        let progress = guideProgressBuffer ?? GuideProgressBuffer()
        guideProgressBuffer = progress
        // Batches arrive several times a second on the main actor, so the
        // catalog is indexed once and rewind candidates shrink as guides are
        // attempted or found covered, instead of rescanning every channel.
        var indexedCatalogVersion: Int?
        var guidedChannelsByID: [String: [(offset: Int, channel: Channel)]] = [:]
        var rewindCandidates: [(offset: Int, channel: Channel)] = []
        while true {
            try checkSync(id, generation: generation, config: config)
            if indexedCatalogVersion != channelCatalogVersion {
                indexedCatalogVersion = channelCatalogVersion
                guidedChannelsByID = [:]
                rewindCandidates = []
                for (offset, channel) in channels.enumerated() where channel.epgChannelID != nil {
                    guidedChannelsByID[channel.id, default: []].append((offset, channel))
                    if channel.supportsRewind { rewindCandidates.append((offset, channel)) }
                }
            }
            let now = Date()
            var priorities = visibleGuidePriorityIDs
            if priorities.isEmpty { priorities.formUnion(filteredChannels.prefix(24).map(\.id)) }
            let viewportGuideIDs = Set(priorities.flatMap { guidedChannelsByID[$0] ?? [] }.compactMap(\.channel.epgChannelID))
            priorities.formUnion(favoriteChannelIDs)
            priorities.formUnion(recentChannelIDs)
            let priorityChannels = priorities.flatMap { guidedChannelsByID[$0] ?? [] }
            let priorityGuideIDs = Set(priorityChannels.compactMap(\.channel.epgChannelID))
            var byGuide: [String: (offset: Int, channel: Channel)] = [:]
            // Keeps the earliest channel among those with the longest catchup.
            func consider(_ candidate: (offset: Int, channel: Channel), guide epgID: String) {
                if let existing = byGuide[epgID] {
                    let existingDays = existing.channel.catchup?.days ?? 0
                    let days = candidate.channel.catchup?.days ?? 0
                    guard days > existingDays || (days == existingDays && candidate.offset < existing.offset) else { return }
                }
                byGuide[epgID] = candidate
            }
            rewindCandidates.removeAll { candidate in
                guard let epgID = candidate.channel.epgChannelID, !attempted.contains(epgID) else { return true }
                guard !priorityOnly || priorityGuideIDs.contains(epgID) else { return false }
                guard needsGuideCoverage(for: candidate.channel, now: now) else {
                    // A failed attempt may become due again during this run.
                    return guideAttempts[epgID] == nil
                }
                consider(candidate, guide: epgID)
                return false
            }
            for candidate in priorityChannels where !candidate.channel.supportsRewind {
                guard let epgID = candidate.channel.epgChannelID, !attempted.contains(epgID),
                      needsGuideCoverage(for: candidate.channel, now: now) else { continue }
                consider(candidate, guide: epgID)
            }
            let ordered = byGuide.values.sorted {
                let leftID = $0.channel.epgChannelID ?? ""
                let rightID = $1.channel.epgChannelID ?? ""
                let lhs = viewportGuideIDs.contains(leftID) ? 0 : priorityGuideIDs.contains(leftID) ? 1 : 2
                let rhs = viewportGuideIDs.contains(rightID) ? 0 : priorityGuideIDs.contains(rightID) ? 1 : 2
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }
            guard !ordered.isEmpty else { break }
            let batchSize = !hasUsefulResults || ordered.prefix(8).contains { priorityGuideIDs.contains($0.channel.epgChannelID ?? "") } ? 8 : 32
            let batch = ordered.prefix(batchSize).map(\.channel)
            let minimumStart = batch.map { requiredCatchupGuideStart(for: $0, now: now) ?? now.addingTimeInterval(-30 * 60) }.min()
            for channel in batch {
                if let epgID = channel.epgChannelID {
                    attempted.insert(epgID)
                    guideAttempts[epgID] = (requiredCatchupGuideStart(for: channel, now: now) ?? now.addingTimeInterval(-30 * 60), now.addingTimeInterval(60))
                }
            }
            let previouslyReceived = progress.totalReceived
            do {
                _ = try await client.fetchCatchupEPG(for: batch, since: minimumStart, collectResults: false) { [weak self] result in
                    guard let self else { return }
                    await self.receiveGuideProgress(result, buffer: progress, config: config,
                        id: id, generation: generation, cacheKey: cacheKey)
                }
                hasUsefulResults = hasUsefulResults || progress.totalReceived > previouslyReceived
                consecutiveFailures = 0
            } catch {
                try checkSync(id, generation: generation, config: config)
                consecutiveFailures += 1
                AppLog.sync.error("Guide history batch failed; retaining available guide error=\(error.localizedDescription, privacy: .public)")
            }
            completed += batch.count
            if !silent { loadingStage = "Loading guide history (\(completed) channels)…" }
            if consecutiveFailures >= 2 { break }
        }
        try await flushGuideProgress(progress, config: config, id: id, generation: generation, cacheKey: cacheKey)
        AppLog.sync.info("Guide enrichment completed channels=\(completed, privacy: .public) elapsedMs=\(AppLog.elapsedMilliseconds(since: started), privacy: .public)")
    }

    private func receiveGuideProgress(_ result: XtreamClient.CatchupProgress, buffer: GuideProgressBuffer,
                                      config: ServerConfig, id: UUID, generation: UUID, cacheKey: String) async {
        guard !Task.isCancelled, activeSyncID == id, isCurrentSource(generation, config: config) else { return }
        let now = Date()
        if let attempt = guideAttempts[result.epgID] {
            guideAttempts[result.epgID] = (attempt.start, now.addingTimeInterval(result.failed ? 30 : 15 * 60))
        }
        buffer.programs.append(contentsOf: result.programs)
        buffer.totalReceived += result.programs.count
        let earliest = result.programs.map(\.start.timeIntervalSince1970).min() ?? 0
        let latest = result.programs.map(\.end.timeIntervalSince1970).max() ?? 0
        AppLog.sync.info("Guide channel response channelID=\(result.channelID, privacy: .public) programs=\(result.programs.count, privacy: .public) failed=\(result.failed, privacy: .public) receivedListings=\(result.receivedListings, privacy: .public) responseEarliestEpoch=\(result.responseEarliestEpoch, privacy: .public) responseLatestEpoch=\(result.responseLatestEpoch, privacy: .public) earliestEpoch=\(earliest, privacy: .public) latestEpoch=\(latest, privacy: .public)")
        let due = !buffer.published || AppLog.elapsedMilliseconds(since: buffer.lastPublication) >= 500
        guard !buffer.programs.isEmpty, due else { return }
        do {
            try await flushGuideProgress(buffer, config: config, id: id, generation: generation, cacheKey: cacheKey)
        } catch { /* source cancellation rejects publication */ }
    }

    private func flushGuideProgress(_ buffer: GuideProgressBuffer, config: ServerConfig,
                                    id: UUID, generation: UUID, cacheKey: String) async throws {
        guard !buffer.programs.isEmpty else { return }
        let incoming = buffer.programs
        buffer.programs = []
        buffer.published = true
        buffer.lastPublication = .now
        try await publishGuidePrograms(incoming, id: id, generation: generation, config: config,
            cacheKey: cacheKey, stage: "channel-history")
    }

    // MARK: - Scheduler

    /// Start (or restart) the periodic background sync timers.
    /// Playlist + EPG run on independent cadences. Each waits a full interval
    /// before its first fire — startup syncs are kicked off separately.
    func startSyncScheduler() {
        playlistSchedulerTask?.cancel()
        playlistSchedulerTask = nil
        if SyncInterval.automaticRefreshEnabled(for: SyncInterval.playlistStorageKey, default: SyncInterval.playlistDefault) {
            playlistSchedulerTask = Task { [weak self] in
                while !Task.isCancelled {
                    let interval = SyncInterval.storedValue(
                        for: SyncInterval.playlistStorageKey,
                        default: SyncInterval.playlistDefault
                    )
                    guard let timeInterval = interval.timeInterval else { return }
                    do {
                        try await Task.sleep(for: .seconds(timeInterval))
                    } catch {
                        return
                    }
                    if Task.isCancelled { return }

                    // Respect central lifecycle (Agent 09) — avoid heavy syncs while
                    // the app is sleeping or in the background.
                    if AppLifecycleCoordinator.shared.shouldPauseBackgroundWork {
                        try? await Task.sleep(for: .seconds(30))
                        continue
                    }

                    self?.sync(silent: true, scope: .all)
                }
            }
        }

        epgSchedulerTask?.cancel()
        epgSchedulerTask = nil
        if SyncInterval.automaticRefreshEnabled(for: SyncInterval.epgStorageKey, default: SyncInterval.epgDefault) {
            epgSchedulerTask = Task { [weak self] in
                while !Task.isCancelled {
                    let interval = SyncInterval.storedValue(
                        for: SyncInterval.epgStorageKey,
                        default: SyncInterval.epgDefault
                    )
                    guard let timeInterval = interval.timeInterval else { return }
                    do {
                        try await Task.sleep(for: .seconds(timeInterval))
                    } catch {
                        return
                    }
                    if Task.isCancelled { return }

                    if AppLifecycleCoordinator.shared.shouldPauseBackgroundWork {
                        try? await Task.sleep(for: .seconds(30))
                        continue
                    }

                    self?.sync(silent: true, scope: .epg)
                }
            }
        }
    }

    func automaticRefreshEnabled(scope: SyncScope) -> Bool {
        switch scope {
        case .all:
            SyncInterval.automaticRefreshEnabled(
                for: SyncInterval.playlistStorageKey,
                default: SyncInterval.playlistDefault
            )
        case .epg:
            SyncInterval.automaticRefreshEnabled(
                for: SyncInterval.epgStorageKey,
                default: SyncInterval.epgDefault
            )
        }
    }

    private func epgLookbackHours(for channels: [Channel]) -> Int {
        let archiveHours = channels
            .compactMap { channel -> Int? in
                guard channel.supportsRewind, let days = channel.catchup?.days, days > 0 else { return nil }
                return days * 24
            }
            .max() ?? 0
        guard archiveHours > 0 else { return 24 }

        let setting = CatchupLookbackSetting.stored(
            rawValue: UserDefaults.standard.integer(forKey: CatchupLookbackSetting.appStorageKey)
        )
        let requestedHours = setting.limitHours ?? archiveHours
        return min(archiveHours, requestedHours, GuideHistory.maximumHistoryDays * 24)
    }

    private func syncIfAutomatic(scope: SyncScope, silent: Bool = false) {
        if automaticRefreshEnabled(scope: scope) {
            sync(silent: silent, scope: scope)
        }
    }

    func syncOnLaunchIfNeeded() {
        guard activePlaylist != nil else { return }
        if channels.isEmpty {
            syncIfAutomatic(scope: .all)
        } else if guideNeedsInitialLoad() {
            sync(scope: .epg)
        } else {
            syncIfAutomatic(scope: .epg, silent: true)
        }
    }

    func syncGuideForLookbackChange() {
        guard !isSmartSportsActive else { return }
        guard activePlaylist != nil, !channels.isEmpty else { return }
        catchupGuideSyncKeys.removeAll()
        syncAfterInputChange(scope: .epg)
    }

    func syncCatchupGuideIfNeeded(for visibleChannels: [Channel], now: Date = Date()) {
        guard !isSmartSportsActive else { return }
        guard activePlaylist != nil, !visibleChannels.isEmpty else { return }
        visibleGuidePriorityIDs = Set(visibleChannels.map(\.id))
        guard visibleChannels.contains(where: { needsGuideCoverage(for: $0, now: now) }) else { return }
        // Active enrichment consumes these priorities at the next bounded
        // batch. A completed sweep can queue one follow-up for a new viewport.
        if activeSyncTask != nil {
            if !isGuideEnriching { syncAfterInputChange(scope: .epg) }
        } else { sync(scope: .epg) }
    }

    private func catchupGuideNeedsHistory(for visibleChannels: [Channel], now: Date) -> Bool {
        catchupGuideNeedsHistory(in: programs, for: visibleChannels, now: now)
    }

    private func catchupGuideNeedsHistory(in programStore: [String: [EPGProgram]], for visibleChannels: [Channel], now: Date) -> Bool {
        visibleChannels.contains { channel in
            guard channel.supportsRewind, let id = channel.epgChannelID,
                  let start = requiredCatchupGuideStart(for: channel, now: now) else { return false }
            return GuideHistory.needsCoverage(programStore[id] ?? [], since: start, until: now.addingTimeInterval(2 * 3600))
        }
    }

    private func requiredCatchupGuideStart(for channel: Channel, now: Date) -> Date? {
        guard let window = channel.archiveWindow(now: now) else { return nil }
        let limit = CatchupLookbackSetting.stored(rawValue: UserDefaults.standard.integer(forKey: CatchupLookbackSetting.appStorageKey)).limitHours
        let hours = min(limit ?? GuideHistory.maximumHistoryDays * 24, GuideHistory.maximumHistoryDays * 24)
        return max(window.start, now.addingTimeInterval(-Double(hours) * 3600))
    }

    private func needsGuideCoverage(for channel: Channel, now: Date) -> Bool {
        guard let id = channel.epgChannelID else { return false }
        let start = requiredCatchupGuideStart(for: channel, now: now) ?? now.addingTimeInterval(-30 * 60)
        if let attempt = guideAttempts[id], attempt.start <= start.addingTimeInterval(3600), attempt.retryAfter > now { return false }
        return GuideHistory.needsCoverage(programs[id] ?? [], since: start, until: now.addingTimeInterval(2 * 3600))
    }

    private func catchupGuideSyncKey(for visibleChannels: [Channel], now: Date) -> String {
        let ids = visibleChannels
            .filter(\.supportsRewind)
            .map(\.id)
            .sorted()
            .joined(separator: ",")
        let setting = CatchupLookbackSetting.stored(
            rawValue: UserDefaults.standard.integer(forKey: CatchupLookbackSetting.appStorageKey)
        ).rawValue
        let requiredHour = visibleChannels
            .compactMap { requiredCatchupGuideStart(for: $0, now: now) }
            .map { Int($0.timeIntervalSince1970 / 3600) }
            .min() ?? 0
        return "\(activePlaylistID?.uuidString ?? "")|\(setting)|\(requiredHour)|\(ids)"
    }

    private func guideNeedsInitialLoad(now: Date = Date()) -> Bool {
        guard Self.programsCoverCurrentWindow(programs, now: now) else { return true }

        guard !channels.isEmpty else { return false }
        return filteredChannels.prefix(24).contains { needsGuideCoverage(for: $0, now: now) }
    }

    private static func programsCoverCurrentWindow(_ programs: [String: [EPGProgram]], now: Date = Date()) -> Bool {
        guard !programs.isEmpty else { return false }
        let windowStart = now.addingTimeInterval(-30 * 60)
        let windowEnd = now.addingTimeInterval(2 * 3600)
        return programs.values.contains { channelPrograms in
            channelPrograms.contains { program in
                program.end > windowStart && program.start < windowEnd
            }
        }
    }

    private func syncAfterPlaylistSwapIfNeeded() {
        guard channels.isEmpty && serverConfig != nil else { return }
        syncIfAutomatic(scope: .all)
    }

    func stopSyncScheduler() {
        playlistSchedulerTask?.cancel()
        playlistSchedulerTask = nil
        epgSchedulerTask?.cancel()
        epgSchedulerTask = nil
    }

    func refreshServerStatus() async {
        guard let config = serverConfig else { return }
        let generation = sourceGeneration
        let statusKey = DataCache.preferenceKey(for: config)
        var refreshed = serverStatus?.cacheKey == statusKey
            ? (serverStatus ?? ServerAccountStatus.initial(for: config, cacheKey: statusKey))
            : ServerAccountStatus.initial(for: config, cacheKey: statusKey)
        refreshed.channelCount = channels.count
        if config.type == .m3u, epgURL(for: config) == nil {
            refreshed.guideStatus = "Not configured"
        }

        switch config.type {
        case .xtream:
            if let info = try? await XtreamClient(config: config).fetchAccountInfo() {
                refreshed.apply(info)
            }
        case .stalker:
            if let info = try? await StalkerClient(config: config).fetchAccountInfo() {
                refreshed.apply(info)
            }
        case .m3u:
            refreshed.lastChecked = .now
        }

        guard !Task.isCancelled, isCurrentSource(generation, config: config) else { return }
        updateServerStatus(refreshed)
    }

    private func fetchChannels(config: ServerConfig) async throws -> [Channel] {
        let fetched: [Channel]
        switch config.type {
        case .xtream:
            let client = XtreamClient(config: config)
            fetched = try await client.fetchChannels()
        case .stalker:
            fetched = try await StalkerClient(config: config).fetchChannels()
        case .m3u:
            guard let url = config.m3uSourceURL else {
                throw XtreamError.invalidURL
            }
            fetched = try await M3UParser.parse(from: url)
        }
        return fetched.map { SmartSportsSnapshotLoader.stamp($0, config: config) }
    }

    private func fetchVODItems(config: ServerConfig) async throws -> [VODItem] {
        switch config.type {
        case .xtream:
            let client = XtreamClient(config: config)
            return try await client.fetchVODItems()
        case .stalker:
            return try await StalkerClient(config: config).fetchVODItems()
        case .m3u:
            guard let url = config.m3uSourceURL else {
                throw XtreamError.invalidURL
            }
            return try await M3UParser.parseContent(from: url).vodItems
        }
    }

    private func fetchSeries(config: ServerConfig, vodItems: [VODItem]) async throws -> [VODSeries] {
        switch config.type {
        case .xtream:
            return try await XtreamClient(config: config).fetchSeries()
        case .stalker:
            return try await StalkerClient(config: config).fetchSeries()
        case .m3u:
            return seriesFromM3UEpisodes(vodItems)
        }
    }

    private struct CatalogRefresh: Sendable {
        let items: Result<[VODItem], any Error>?
        let series: Result<[VODSeries], any Error>?
    }

    private func fetchCatalog(config: ServerConfig, enabled: Bool) async -> CatalogRefresh {
        guard enabled, !Task.isCancelled else { return CatalogRefresh(items: nil, series: nil) }
        if config.type == .m3u {
            let items = await fetchCatalogItems(config: config)
            let series: Result<[VODSeries], any Error>
            switch items {
            case .success(let items): series = .success(seriesFromM3UEpisodes(items))
            case .failure(let error): series = .failure(error)
            }
            return CatalogRefresh(items: items, series: series)
        }
        async let items = fetchCatalogItems(config: config)
        async let series = fetchCatalogSeries(config: config)
        return await CatalogRefresh(items: items, series: series)
    }

    private func fetchCatalogItems(config: ServerConfig) async -> Result<[VODItem], any Error> {
        do {
            try Task.checkCancellation()
            let items = try await fetchVODItems(config: config)
            try Task.checkCancellation()
            return .success(items)
        } catch { return .failure(error) }
    }

    private func fetchCatalogSeries(config: ServerConfig) async -> Result<[VODSeries], any Error> {
        do {
            try Task.checkCancellation()
            let series = try await fetchSeries(config: config, vodItems: [])
            try Task.checkCancellation()
            return .success(series)
        } catch { return .failure(error) }
    }

    func episodes(for series: VODSeries) -> [VODItem] {
        seriesEpisodes[series.id] ?? []
    }

    func detailItem(for item: VODItem) -> VODItem {
        vodItemDetails[item.id] ?? item
    }

    func loadDetails(for item: VODItem) async {
        if isVODDisabled {
            return
        }

        if vodItemDetails[item.id] != nil || loadingVODItemIDs.contains(item.id) {
            return
        }

        guard let config = serverConfig, config.type == .xtream, item.kind == .movie else {
            vodItemDetails[item.id] = item
            vodItemDetailLoadErrors[item.id] = nil
            return
        }

        let generation = sourceGeneration
        let catalogID = catalogGeneration

        loadingVODItemIDs.insert(item.id)
        defer {
            if isCurrentSource(generation, config: config), catalogID == catalogGeneration {
                loadingVODItemIDs.remove(item.id)
            }
        }

        do {
            let detailed = try await XtreamClient(config: config).fetchVODItemDetails(item: item)
            guard !Task.isCancelled, !isVODDisabled,
                  isCurrentSource(generation, config: config), catalogID == catalogGeneration else { return }
            vodItemDetails[item.id] = detailed
            vodItemDetailLoadErrors[item.id] = nil
            searchIndexVersion &+= 1
        } catch {
            guard !Task.isCancelled, !isVODDisabled,
                  isCurrentSource(generation, config: config), catalogID == catalogGeneration else { return }
            vodItemDetailLoadErrors[item.id] = error.localizedDescription
        }
    }

    func loadEpisodes(for series: VODSeries) async {
        if isVODDisabled {
            seriesEpisodes[series.id] = []
            seriesEpisodeLoadErrors[series.id] = nil
            return
        }

        if seriesEpisodes[series.id] != nil || loadingSeriesIDs.contains(series.id) {
            return
        }

        let generation = sourceGeneration
        let catalogID = catalogGeneration
        loadingSeriesIDs.insert(series.id)
        defer {
            if generation == sourceGeneration, catalogID == catalogGeneration {
                loadingSeriesIDs.remove(series.id)
            }
        }

        if let local = localEpisodes(for: series), !local.isEmpty {
            seriesEpisodes[series.id] = local
            seriesEpisodeLoadErrors[series.id] = nil
            searchIndexVersion &+= 1
            return
        }

        guard let config = serverConfig, config.type == .xtream || config.type == .stalker else {
            seriesEpisodes[series.id] = []
            seriesEpisodeLoadErrors[series.id] = nil
            return
        }

        do {
            let episodes: [VODItem]
            switch config.type {
            case .xtream:
                episodes = try await XtreamClient(config: config).fetchSeriesEpisodes(series: series)
            case .stalker:
                episodes = try await StalkerClient(config: config).fetchSeriesEpisodes(series: series)
            case .m3u:
                episodes = []
            }
            guard !Task.isCancelled, !isVODDisabled,
                  isCurrentSource(generation, config: config), catalogID == catalogGeneration else { return }
            seriesEpisodes[series.id] = episodes
            seriesEpisodeLoadErrors[series.id] = nil
            searchIndexVersion &+= 1
        } catch {
            guard !Task.isCancelled, !isVODDisabled,
                  isCurrentSource(generation, config: config), catalogID == catalogGeneration else { return }
            seriesEpisodeLoadErrors[series.id] = error.localizedDescription
        }
    }

    private func localEpisodes(for series: VODSeries) -> [VODItem]? {
        let episodes = vodItems.filter { $0.kind == .seriesEpisode && $0.group == series.name }
        return episodes.isEmpty ? nil : episodes.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func seriesFromM3UEpisodes(_ items: [VODItem]) -> [VODSeries] {
        let episodes = items.filter { $0.kind == .seriesEpisode }
        let byGroup = Dictionary(grouping: episodes, by: \.group)
        return byGroup.map { group, episodes in
            let first = episodes.sorted { $0.name < $1.name }.first
            return VODSeries(
                id: "m3u:\(group)",
                name: group,
                posterURL: first?.posterURL,
                group: first?.genre ?? "Series",
                genre: first?.genre,
                rating: first?.rating,
                releaseDate: first?.releaseDate,
                summary: first?.summary,
                director: first?.director,
                cast: first?.cast,
                episodeCount: episodes.count
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func applyVODPreference(disabled: Bool) {
        // Settings and the library can observe the same preference change.
        // Apply it once so the second observer cannot invalidate the first
        // catalogue request or queue an unnecessary full refresh.
        guard lastAppliedVODDisabled != disabled else { return }
        lastAppliedVODDisabled = disabled
        catalogGeneration = UUID()
        if disabled {
            vodItems = []
            vodSeries = []
            seriesEpisodes = [:]
            seriesEpisodeLoadErrors = [:]
            loadingSeriesIDs = []
            vodItemDetails = [:]
            vodItemDetailLoadErrors = [:]
            loadingVODItemIDs = []
            if case .movies = selection {
                selection = .allChannels
            } else if case .movieGroup = selection {
                selection = .allChannels
            } else if case .movieDetail = selection {
                selection = .allChannels
            } else if case .series = selection {
                selection = .allChannels
            } else if case .seriesGroup = selection {
                selection = .allChannels
            } else if case .seriesDetail = selection {
                selection = .allChannels
            }
            searchIndexVersion &+= 1
        } else if vodItems.isEmpty && vodSeries.isEmpty {
            syncAfterInputChange(scope: .all)
        } else {
            searchIndexVersion &+= 1
        }
    }

    private func epgURL(for config: ServerConfig) -> URL? {
        switch config.type {
        case .xtream:
            return xtreamEPGURL(for: config, previousDays: 1)
        case .stalker:
            return nil
        case .m3u:
            return config.epgSourceURL
        }
    }

    private func xtreamLookbackEPGURL(for config: ServerConfig) -> URL? {
        xtreamEPGURL(for: config, previousDays: xtreamLookbackDays())
    }

    /// Count and bounds are enough to recognise a provider returning the same
    /// document for different prev_days values.
    nonisolated private struct XtreamGuideSignature: Equatable, Sendable {
        let count: Int
        let earliestStart: Date?
        let latestEnd: Date?

        init(_ programs: [EPGProgram]) {
            count = programs.count
            earliestStart = programs.lazy.map(\.start).min()
            latestEnd = programs.lazy.map(\.end).max()
        }

        init(_ guide: XMLTVGuide) {
            count = guide.count
            earliestStart = guide.earliestStart
            latestEnd = guide.latestEnd
        }
    }

    // Recheck periodically in case the provider starts honouring prev_days.
    private static let xtreamLookbackRedundancyLifetime: TimeInterval = 7 * 24 * 3600

    private static func xtreamLookbackRedundantKey(for config: ServerConfig) -> String {
        "buffer_xtream_lookback_redundant_\(DataCache.preferenceKey(for: config))"
    }

    private static func isXtreamLookbackKnownRedundant(key: String) -> Bool {
        guard let recordedAt = UserDefaults.standard.object(forKey: key) as? Date else { return false }
        return Date().timeIntervalSince(recordedAt) < xtreamLookbackRedundancyLifetime
    }

    private func xtreamLookbackDays() -> Int {
        let lookbackHours = max(24, epgLookbackHours(for: channels))
        return max(1, Int(ceil(Double(lookbackHours) / 24.0)))
    }

    private func xtreamEPGURL(for config: ServerConfig, previousDays: Int) -> URL? {
        guard let baseURL = config.xtreamEPGURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return config.xtreamEPGURL
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { item in
            item.name == "prev_days" || item.name == "next_days"
        }
        queryItems.append(URLQueryItem(name: "prev_days", value: "\(max(1, previousDays))"))
        queryItems.append(URLQueryItem(name: "next_days", value: "1"))
        components.queryItems = queryItems
        return components.url
    }

    /// A VOD native ID is source-scoped too. Only the current loaded catalog
    /// can establish ownership; persisted resume URLs cannot establish it.
    func resolveVODPlaybackChannel(_ item: VODItem, sourceID: UUID) async throws -> (item: VODItem, channel: Channel) {
        guard let config = serverConfig, !isVODDisabled else { throw VODPlaybackSourceError.unavailable }
        guard config.id == sourceID, let currentItem = findVODItem(id: item.id),
              currentItem.kind == item.kind else { throw VODPlaybackSourceError.changed }
        let generation = sourceGeneration
        let playable = try await resolveVODItemForPlayback(currentItem)
        guard !Task.isCancelled, isCurrentSource(generation, config: config), !isVODDisabled,
              findVODItem(id: item.id)?.streamURL == currentItem.streamURL else { throw VODPlaybackSourceError.changed }
        let base = playable.playbackChannel
        let channel = Channel(id: base.id, name: base.name, logoURL: base.logoURL,
            group: base.group, streamURL: base.streamURL, epgChannelID: base.epgChannelID,
            catchup: base.catchup, contentType: base.contentType,
            sourceOwnership: .init(channelIdentity: .init(sourceID: config.id, nativeID: base.id),
                accountKey: .init(config: config)))
        return (playable, channel)
    }

    func resolveVODItemForPlayback(_ item: VODItem) async throws -> VODItem {
        guard let config = serverConfig,
              config.type == .stalker,
              StalkerClient.isPlaceholderURL(item.streamURL) else {
            return item
        }

        let resolvedURL = try await StalkerClient(config: config).resolvePlaybackURL(for: item)
        return VODItem(
            id: item.id,
            name: item.name,
            posterURL: item.posterURL,
            group: item.group,
            streamURL: resolvedURL,
            kind: item.kind,
            genre: item.genre,
            durationSeconds: item.durationSeconds,
            rating: item.rating,
            releaseDate: item.releaseDate,
            containerExtension: item.containerExtension,
            summary: item.summary,
            director: item.director,
            cast: item.cast,
            country: item.country,
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber
        )
    }

    // MARK: - Search index

    private func rebuildSearchIndex() {
        searchIndexNeedsRebuild = true
        // A warm index is already useful. On a cold start allow its first
        // useful worker to finish even if many history deltas arrive first.
        if isGuideEnriching && (!searchEntries.isEmpty || indexBuildTask != nil) { return }
        if !isGuideEnriching && indexBuildTask != nil && searchIndexBuildIsFirstColdSnapshot { return }

        indexBuildTask?.cancel()
        let buildID = UUID()
        searchBuildID = buildID
        let generation = sourceGeneration
        let capturedGuideVersion = guideVersion
        let capturedCatalogVersion = channelCatalogVersion
        let capturedSmartMode = isSmartSportsActive
        let capturedSmartRevision = smartSports.revision
        let channelSnapshot = displayedChannels
        let guideSnapshot = displayedPrograms

        // One searchable guide per EPG id, owned by the first playlist channel
        // that references it (channel order is the index's guide order).
        var seenEPGIDs = Set<String>()
        seenEPGIDs.reserveCapacity(channelSnapshot.count)
        var guideInputs: [(epgID: String, channelID: String, programs: [EPGProgram])] = []
        guideInputs.reserveCapacity(channelSnapshot.count)
        // Retain only guide arrays referenced by this playlist's entries;
        // unrelated XMLTV channels must not stay alive in the search snapshot.
        var programsSnapshot: [String: [EPGProgram]] = [:]
        var searchableCount = 0
        for channel in channelSnapshot {
            guard let epgID = channel.epgChannelID, seenEPGIDs.insert(epgID).inserted else { continue }
            guard let rows = guideSnapshot[epgID] else { continue }
            programsSnapshot[epgID] = rows
            searchableCount += rows.count
            guideInputs.append((epgID, channel.id, rows))
        }
        searchIndexNeedsRebuild = false
        guard searchableCount > 0 else {
            indexBuildTask = nil
            searchIndexBuildIsFirstColdSnapshot = false
            if !searchEntries.isEmpty || !programSearchStore.isEmpty {
                searchEntries = []
                programSearchStore = [:]
                searchIndexVersion &+= 1
            }
            return
        }
        searchIndexBuildIsFirstColdSnapshot = searchEntries.isEmpty
        programSearchIndexBuildCount &+= 1

        indexBuildTask = Task.detached(priority: .utility) { [weak self, guideInputs, programsSnapshot] in
            let started = ContinuousClock.now
            guard let entries = ProgramSearchIndex.build(guides: guideInputs) else { return }
            if Task.isCancelled { return }
            let finalEntries = entries
            let buildMs = AppLog.elapsedMilliseconds(since: started)
            let preparedAt = ContinuousClock.now

            await MainActor.run { [weak self] in
                guard let self, self.searchBuildID == buildID, self.sourceGeneration == generation else { return }
                self.indexBuildTask = nil
                self.searchIndexBuildIsFirstColdSnapshot = false
                // Catalogue changes can replace the selected physical feed.
                // A worker built for that obsolete catalogue cannot publish.
                let catalogStillCurrent = capturedSmartMode
                    ? self.smartSports.revision == capturedSmartRevision
                    : self.channelCatalogVersion == capturedCatalogVersion
                guard self.isSmartSportsActive == capturedSmartMode, catalogStillCurrent else {
                    self.searchIndexNeedsRebuild = true
                    self.rebuildSearchIndex()
                    return
                }
                self.searchEntries = finalEntries
                self.programSearchStore = programsSnapshot
                self.searchIndexVersion &+= 1
                self.programSearchIndexPublicationCount &+= 1
                if !capturedSmartMode && self.guideVersion != capturedGuideVersion { self.searchIndexNeedsRebuild = true }
                AppLog.sync.info("Program search index ready entries=\(finalEntries.count, privacy: .public) buildMs=\(buildMs, privacy: .public) mainWaitMs=\(AppLog.elapsedMilliseconds(since: preparedAt), privacy: .public)")
                if self.searchIndexNeedsRebuild && !self.isGuideEnriching { self.rebuildSearchIndex() }
            }
        }
    }

    private func finishGuideSearchEnrichment() {
        isGuideEnriching = false
        if searchIndexNeedsRebuild { rebuildSearchIndex() }
    }

    #if PROGRAM_SEARCH_INDEX_TESTING
    func testRequestProgramSearchIndex() { rebuildSearchIndex() }
    func testBeginProgramSearchEnrichment() { isGuideEnriching = true }
    func testFinishProgramSearchEnrichment() { finishGuideSearchEnrichment() }
    func testInvalidateProgramSearchSource() { invalidateSourceWork() }
    func testWaitForProgramSearchIndex() async {
        while let task = indexBuildTask { await task.value }
    }
    #endif

    // MARK: - Pre-bucketing for fast visible-range queries (Agent 02 / Master Issues)

    private func publishPreparedGuide(_ snapshot: PreparedGuideSnapshot) {
        let mainWaitMs = AppLog.elapsedMilliseconds(since: snapshot.preparedAt)
        programs = snapshot.programs
        guideTimeline = snapshot.timeline
        rebuildSearchIndex()
        AppLog.sync.info("Guide published programKeys=\(snapshot.programs.count, privacy: .public) organizeMs=\(snapshot.organizeMs, privacy: .public) mergeMs=\(snapshot.mergeMs, privacy: .public) bucketMs=\(snapshot.bucketMs, privacy: .public) mainWaitMs=\(mainWaitMs, privacy: .public)")
    }

    private struct PreparedGuideSnapshot: Sendable {
        let programs: [String: [EPGProgram]]
        let timeline: GuideTimeline
        let organizeMs: Int
        let mergeMs: Int
        /// Timeline column build (formerly hour buckets + per-key lookups).
        let bucketMs: Int
        let preparedAt: ContinuousClock.Instant
    }

    /// Builds the flat timeline for a complete guide. Runs that share array
    /// storage with `previous` are copied column-wise instead of recomputed.
    nonisolated private static func prepareGuideSnapshot(
        programs: [String: [EPGProgram]],
        reusing previous: GuideTimeline? = nil,
        organizeMs: Int = 0,
        mergeMs: Int = 0
    ) -> PreparedGuideSnapshot {
        let bucketStarted = ContinuousClock.now
        let timeline = GuideTimeline(programs, reusing: previous)
        return PreparedGuideSnapshot(
            programs: programs,
            timeline: timeline,
            organizeMs: organizeMs,
            mergeMs: mergeMs,
            bucketMs: AppLog.elapsedMilliseconds(since: bucketStarted),
            preparedAt: .now
        )
    }

    /// Returns programs for the channel that intersect [start, end), ordered
    /// by (start, end). Two binary searches over the channel's contiguous
    /// Int32 columns bound the run; only that slice is scanned.
    func programsForChannel(_ channel: Channel, between start: Date, and end: Date) -> [EPGProgram] {
        if channel.sourceOwnership?.logicalChannelID != nil ||
            (channel.sourceChannelIdentity != nil && channel.sourceChannelIdentity?.sourceID != activePlaylistID) {
            return programsForChannel(channel).filter { $0.end > start && $0.start < end }
                .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        }
        _ = guideVersion
        guard let epgID = channel.epgChannelID else { return [] }
        if let timeline = guideTimeline {
            guard let handle = timeline.handle(for: epgID) else { return [] }
            return timeline.programs(handle, between: start, and: end)
        }
        return (programs[epgID] ?? [])
            .filter { $0.end > start && $0.start < end }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    nonisolated private static func organize(_ allPrograms: [EPGProgram]) -> [String: [EPGProgram]] {
        var organized: [String: [EPGProgram]] = [:]
        organized.reserveCapacity(1024)
        for program in allPrograms {
            organized[program.channelID, default: []].append(program)
        }
        // Most XMLTV generators emit programmes in chronological order.
        // Skip the sort for already-sorted channels — saves ~89% of sort cost.
        for (key, value) in organized {
            var needsSort = false
            for i in 1..<value.count {
                if value[i].start < value[i - 1].start { needsSort = true; break }
            }
            if needsSort {
                organized[key] = value.sorted { $0.start < $1.start }
            }
        }
        return organized
    }

    /// Merges `incoming` programs into `existing`, replacing the fetched time
    /// window with fresh provider data. Stalker guide rows can be revised or
    /// reissued with new IDs, so ID-only dedupe leaves stale programs visible.
    /// Programs outside the fetched window are preserved for catch-up history.
    nonisolated private static func mergePrograms(
        existing: [String: [EPGProgram]],
        incoming: [String: [EPGProgram]]
    ) -> [String: [EPGProgram]] {
        guard !existing.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return existing }

        var incomingStart: Date?
        var incomingEnd: Date?
        for program in incoming.values.flatMap({ $0 }) {
            incomingStart = min(incomingStart ?? program.start, program.start)
            incomingEnd = max(incomingEnd ?? program.end, program.end)
        }
        guard let incomingStart, let incomingEnd, incomingEnd > incomingStart else { return existing }

        var merged: [String: [EPGProgram]] = [:]
        let channelIDs = Set(existing.keys).union(incoming.keys)
        for (channelID, incomingPrograms) in incoming {
            guard !incomingPrograms.isEmpty else { continue }
            let incomingIDs = Set(incomingPrograms.map(\.id))
            var channelPrograms = (existing[channelID] ?? []).filter {
                ($0.end <= incomingStart || $0.start >= incomingEnd) && !incomingIDs.contains($0.id)
            }
            channelPrograms.append(contentsOf: incomingPrograms)
            channelPrograms.sort { $0.start < $1.start }
            merged[channelID] = channelPrograms
        }

        for channelID in channelIDs where incoming[channelID] == nil {
            let channelPrograms = (existing[channelID] ?? []).filter {
                $0.end <= incomingStart || $0.start >= incomingEnd
            }
            if !channelPrograms.isEmpty {
                merged[channelID] = channelPrograms
            }
        }
        return merged
    }
    /// Merges partial provider responses into existing guide data. Unlike
    /// `mergePrograms`, channels absent from `incoming` are preserved as-is;
    /// Xtream lookback/current XMLTV responses can omit channels depending on
    /// panel settings, and absence must not erase their current guide rows.
    nonisolated private static func mergePartialPrograms(
        existing: [String: [EPGProgram]],
        incoming: [String: [EPGProgram]]
    ) -> [String: [EPGProgram]] {
        guard !existing.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return existing }

        var incomingStart: Date?
        var incomingEnd: Date?
        for program in incoming.values.flatMap({ $0 }) {
            incomingStart = min(incomingStart ?? program.start, program.start)
            incomingEnd = max(incomingEnd ?? program.end, program.end)
        }
        guard let incomingStart, let incomingEnd, incomingEnd > incomingStart else { return existing }

        var merged = existing
        for (channelID, incomingPrograms) in incoming {
            guard !incomingPrograms.isEmpty else { continue }
            let incomingIDs = Set(incomingPrograms.map(\.id))
            var channelPrograms = (existing[channelID] ?? []).filter {
                ($0.end <= incomingStart || $0.start >= incomingEnd) && !incomingIDs.contains($0.id)
            }
            channelPrograms.append(contentsOf: incomingPrograms)
            channelPrograms.sort { $0.start < $1.start }
            merged[channelID] = channelPrograms
        }
        return merged
    }


    // MARK: - Playlist CRUD

    /// Insert a new playlist. If `makeActive` is true (default) it becomes the
    /// active one and per-playlist state is swapped in.
    func addPlaylist(_ config: ServerConfig, makeActive: Bool = true) {
        playlists.append(config)
        resolveProvidedCredentials(for: config)
        persistPassword(for: config)
        savePlaylists()
        if makeActive {
            setActivePlaylist(id: config.id)
        }
    }

    /// Replace an existing playlist in-place (matched by id). If it is the
    /// active playlist, per-playlist state is refreshed (cache key may have
    /// changed if the URL/username changed).
    func updatePlaylist(_ config: ServerConfig) {
        guard let index = playlists.firstIndex(where: { $0.id == config.id }) else {
            addPlaylist(config, makeActive: false)
            return
        }
        let previous = playlists[index]
        playlists[index] = config
        if unresolvedCredentialIDs.contains(config.id), config.password.isEmpty {
            // Settings can edit a source's metadata while its saved password
            // is still unread. An empty placeholder must not replace Keychain.
            if !Self.hasSameSource(previous, config) { startCredentialRead(for: config) }
        } else {
            resolveProvidedCredentials(for: config)
            persistPassword(for: config)
        }
        savePlaylists()

        if isSmartSportsActive {
            smartRefreshTask?.cancel()
            smartSports.cancelRefresh()
            refreshSmartSports(immediately: true)
        }

        if activePlaylistID == config.id {
            // Source edits obsolete every in-flight request. Content keys
            // include credentials/guide inputs; preference keys stay stable.
            if !Self.hasSameSource(previous, config) {
                swapInActivePlaylistState(previousKey: DataCache.cacheKey(for: previous))
                if let readyConfig = serverConfig { setActiveStreamProbeScope(for: readyConfig) }
            }
        }
    }

    /// Delete a playlist. If it was active, the first remaining playlist (if
    /// any) becomes active. Passwords are removed from the keychain; cached
    /// channel/program files are left alone (cheap to keep and re-usable if
    /// the user re-adds the same source).
    func removePlaylist(id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let removed = playlists.remove(at: index)
        resolveProvidedCredentials(for: removed)
        Task { _ = await ServerPasswordStore.deletePasswordAsync(for: removed.id) }
        NotificationManager.shared.cancelReminders(forPlaylistID: id)
        savePlaylists()

        if isSmartSportsActive {
            smartRefreshTask?.cancel()
            smartSports.cancelRefresh()
            refreshSmartSports(immediately: true)
        }

        if activePlaylistID == id {
            if let fallback = playlists.first {
                setActivePlaylist(id: fallback.id)
            } else {
                clearActivePlaylist()
            }
        }
    }

    /// Activate the reminder's playlist (if it differs from the current one),
    /// wait for channels to load from cache (syncing if the cache is empty),
    /// and return the matching channel if the playlist still contains it.
    func resolveReminder(_ reminder: ProgramReminder) async -> Channel? {
        if let ownership = reminder.sourceOwnership {
            let key = ownership.channelIdentity
            guard playlists.contains(where: { $0.id == key.sourceID }) else { return nil }
            setActivePlaylist(id: key.sourceID)
            await hydrate()
            guard !isSmartSportsActive, activePlaylistID == key.sourceID else { return nil }
            if channels.isEmpty { await syncAndWait() }
            guard !isSmartSportsActive, activePlaylistID == key.sourceID else { return nil }
            return channels.first { $0.sourceChannelIdentity == key }
        }
        if activePlaylistID != reminder.playlistID {
            setActivePlaylist(id: reminder.playlistID)
        }
        await hydrate()
        guard activePlaylistID == reminder.playlistID else { return nil }
        if channels.isEmpty {
            await syncAndWait()
        }
        guard activePlaylistID == reminder.playlistID else { return nil }
        return channels.first(where: { $0.id == reminder.channelID })
    }

    /// Switch the active playlist and reload its per-playlist state.
    func setActivePlaylist(id: UUID) {
        guard playlists.contains(where: { $0.id == id }) else { return }
        if isSmartSportsActive {
            isSmartSportsActive = false
            cancelInactiveSourceRefresh()
            smartRefreshTask?.cancel()
            smartSports.cancelRefresh()
            smartDisplayedCatalogSnapshot = nil
            channelCatalogVersion &+= 1
            guideVersion &+= 1
            loadFavorites()
            loadRecents()
            loadChannelUsage()
            loadGroupUsage()
            loadGroupPreferences()
            rebuildChannelDerivedState()
            rebuildSearchIndex()
            selection = .allChannels
        }
        if activePlaylistID == id { return }

        activePlaylistID = id
        saveActivePlaylistID()
        swapInActivePlaylistState(previousKey: nil)
        if let config = serverConfig {
            setActiveStreamProbeScope(for: config)
        }
    }

    /// Shared between `setActivePlaylist` and cache-key-changing updates.
    /// Clears visible state, reloads per-playlist prefs (favorites/recents/
    /// groups/status), hydrates from disk cache, and triggers a sync if the
    /// cache was empty.
    private func swapInActivePlaylistState(previousKey: String?) {
        invalidateSourceWork()
        // Old content cannot remain actionable under the newly selected
        // account, or be merged into its guide when it has no cache yet.
        clearSourceContent()
        searchEntries = []
        searchIndexVersion &+= 1
        lastUpdated = nil
        errorMessage = nil
        loadingStage = nil
        isRefreshing = false
        revealChannelID = nil

        // If the current selection references a group that won't exist in the
        // new playlist, fall back to All Channels. The group list repopulates
        // once channels hydrate.
        if case .group = selection {
            selection = .allChannels
        } else if case .movieGroup = selection {
            selection = .movies
        } else if case .movieDetail = selection {
            selection = .movies
        } else if case .seriesGroup = selection {
            selection = .series
        } else if case .seriesDetail = selection {
            selection = .series
        }

        loadServerStatus()
        loadRecents()
        loadVODResumeEntries()
        loadFavorites()
        loadChannelUsage()
        loadGroupUsage()
        loadGroupPreferences()

        // Read only the current content identity. Legacy content slots cannot
        // prove their credential/guide revision and are not hydrated here.
        hydrationTask?.cancel()
        let generation = sourceGeneration
        let sourceID = activePlaylistID
        let credentialTask = sourceID.flatMap { credentialLoadTasks[$0] }
        hydrationTask = Task { [weak self] in
            await credentialTask?.value
            guard !Task.isCancelled, let self, self.sourceGeneration == generation,
                  self.activePlaylistID == sourceID, let config = self.serverConfig else { return }
            self.loadActivePlaylistPreferences()
            self.setActiveStreamProbeScope(for: config)
            let shouldHydrate = DataCache.cacheKey(for: config) != previousKey
            if shouldHydrate {
                await self.hydrateFromDisk()
            }
            guard !Task.isCancelled, self.sourceGeneration == generation else { return }
            if shouldHydrate {
                self.syncAfterPlaylistSwapIfNeeded()
            } else {
                self.hasLoadedOnce = true
                self.sync(scope: .all)
            }
        }
        if isLoadingSourceCredentials { loadingStage = "Unlocking saved source…" }
    }

    private func invalidateSourceWork() {
        sourceGeneration = UUID()
        catalogGeneration = UUID()
        searchBuildID = UUID()
        activeSyncTask?.cancel()
        activeSyncTask = nil
        activeSyncID = nil
        activeSyncScope = nil
        pendingSync = nil
        hydrationTask?.cancel()
        hydrationTask = nil
        indexBuildTask?.cancel()
        indexBuildTask = nil
        searchIndexNeedsRebuild = false
        searchIndexBuildIsFirstColdSnapshot = false
        searchEntries = []
        programSearchStore = [:]
        searchIndexVersion &+= 1
        catchupGuideSyncKeys = []
        guidePublicationTask?.cancel()
        guidePublicationTask = nil
        visibleGuidePriorityIDs = []
        guideAttempts = [:]
        isGuideEnriching = false
        lastGuidePersistedAt = nil
        guideProgressBuffer = nil
    }

    private func clearSourceContent() {
        channels = []
        vodItems = []
        vodSeries = []
        seriesEpisodes = [:]
        seriesEpisodeLoadErrors = [:]
        loadingSeriesIDs = []
        vodItemDetails = [:]
        vodItemDetailLoadErrors = [:]
        loadingVODItemIDs = []
        programs = [:]
        hasLoadedOnce = false
    }

    private func clearActivePlaylist() {
        invalidateSourceWork()
        activePlaylistID = nil
        saveActivePlaylistID()
        clearSourceContent()
        hasLoadedOnce = true
        searchEntries = []
        searchIndexVersion &+= 1
        lastUpdated = nil
        errorMessage = nil
        loadingStage = nil
        isRefreshing = false
        recentChannelIDs = []
        vodResumeEntries = []
        favoriteChannelIDs = []
        channelUsageCounts = [:]
        groupUsageCounts = [:]
        storedGroupOrder = []
        hiddenGroupNames = []
        serverStatus = nil
    }

    // MARK: - Config Persistence

    private static let playlistsKey = "buffer_playlists_v1"
    private static let activePlaylistKey = "buffer_active_playlist_id"
    private static let legacyConfigKey = "buffer_server_config"
    private static let legacyServerStatusKey = "buffer_server_status"
    private static let recentsLimit = 24
    private static let vodResumeLimit = 24
    private static let channelUsageLimit = 500
    private static let groupUsageLimit = 100

    private static func serverStatusKey(for cacheKey: String) -> String {
        "buffer_server_status_\(cacheKey)"
    }

    private func serverStatusKeys(for config: ServerConfig) -> (primary: String, legacy: [String]) {
        (
            Self.serverStatusKey(for: DataCache.preferenceKey(for: config)),
            DataCache.legacyCacheKeys(for: config).map { Self.serverStatusKey(for: $0) }
        )
    }

    private struct StoredServerConfig: Codable {
        let id: UUID
        var name: String
        var type: ServerType
        var serverURL: String
        var username: String
        var m3uURL: String
        var epgURL: String

        init(_ config: ServerConfig) {
            id = config.id
            name = config.name
            type = config.type
            serverURL = config.serverURL
            username = config.username
            m3uURL = config.m3uURL
            epgURL = config.epgURL
        }

        func serverConfig(password: String) -> ServerConfig {
            ServerConfig(
                id: id,
                name: name,
                type: type,
                serverURL: serverURL,
                username: username,
                password: password,
                m3uURL: m3uURL,
                epgURL: epgURL
            )
        }
    }

    private func savePlaylists() {
        let stored = playlists.map(StoredServerConfig.init)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.playlistsKey)
        }
    }

    private func saveActivePlaylistID() {
        if let id = activePlaylistID {
            UserDefaults.standard.set(id.uuidString, forKey: Self.activePlaylistKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activePlaylistKey)
        }
    }

    func loadConfig() {
        isSmartSportsActive = false
        cancelInactiveSourceRefresh()
        smartRefreshTask?.cancel()
        smartSports.cancelRefresh()
        invalidateSourceWork()
        clearSourceContent()
        for task in credentialLoadTasks.values { task.cancel() }
        credentialLoadTasks = [:]
        credentialReadTokens = [:]
        unresolvedCredentialIDs = []
        loadingCredentialIDs = []
        var needsCredentialRead: [ServerConfig] = []
        var migrated = false
        var migrationNeedsPasswordSave = false
        if let data = UserDefaults.standard.data(forKey: Self.playlistsKey),
           let stored = try? JSONDecoder().decode([StoredServerConfig].self, from: data) {
            playlists = stored.map { entry in
                entry.serverConfig(password: "")
            }
            needsCredentialRead = playlists.filter { $0.type != .m3u }
        } else {
            playlists = []
            if let data = UserDefaults.standard.data(forKey: Self.legacyConfigKey) {
                // Decode the password-bearing legacy shape first: decoding
                // StoredServerConfig would otherwise ignore and lose that field.
                if let legacy = try? JSONDecoder().decode(ServerConfig.self, from: data) {
                    playlists = [legacy]
                    persistPassword(for: legacy, saveMetadataOnSuccess: true)
                    migrated = true
                    migrationNeedsPasswordSave = true
                } else if let stored = try? JSONDecoder().decode(StoredServerConfig.self, from: data) {
                    let config = stored.serverConfig(password: "")
                    playlists = [config]
                    if config.type != .m3u { needsCredentialRead = [config] }
                    migrated = true
                }
            }
        }

        if let raw = UserDefaults.standard.string(forKey: Self.activePlaylistKey),
           let id = UUID(uuidString: raw),
           playlists.contains(where: { $0.id == id }) {
            activePlaylistID = id
        } else {
            activePlaylistID = playlists.first?.id
            saveActivePlaylistID()
        }

        if migrated, let config = playlists.first {
            if !migrationNeedsPasswordSave { savePlaylists() }
            migrateLegacyServerStatus(for: config)
        }
        // Prioritize the visible source. Metadata appears immediately while
        // securityd may wait for permission on the dedicated worker queue.
        needsCredentialRead.sort { $0.id == activePlaylistID && $1.id != activePlaylistID }
        for config in needsCredentialRead { startCredentialRead(for: config) }
        loadActivePlaylistPreferences()
        let generation = sourceGeneration
        let sourceID = activePlaylistID
        let credentialTask = sourceID.flatMap { credentialLoadTasks[$0] }
        hydrationTask = Task { [weak self] in
            // Do not retain the view model while a Security call is blocked.
            await credentialTask?.value
            guard !Task.isCancelled, let self, self.sourceGeneration == generation,
                  self.activePlaylistID == sourceID else { return }
            guard let config = self.serverConfig else {
                self.hasLoadedOnce = true
                return
            }
            self.loadActivePlaylistPreferences()
            self.setActiveStreamProbeScope(for: config)
            await self.hydrateFromDisk()
        }
    }

    private func loadActivePlaylistPreferences() {
        loadServerStatus()
        loadRecents()
        loadVODResumeEntries()
        loadFavorites()
        loadChannelUsage()
        loadGroupUsage()
        loadGroupPreferences()
    }

    private func migrateLegacyServerStatus(for config: ServerConfig) {
        if let data = UserDefaults.standard.data(forKey: Self.legacyServerStatusKey),
           var stored = try? JSONDecoder().decode(ServerAccountStatus.self, from: data) {
            stored.cacheKey = DataCache.preferenceKey(for: config)
            if let migrated = try? JSONEncoder().encode(stored) {
                UserDefaults.standard.set(migrated, forKey: serverStatusKeys(for: config).primary)
                UserDefaults.standard.removeObject(forKey: Self.legacyServerStatusKey)
            }
        }
    }

    private func startCredentialRead(for config: ServerConfig) {
        credentialLoadTasks[config.id]?.cancel()
        let token = UUID()
        credentialReadTokens[config.id] = token
        unresolvedCredentialIDs.insert(config.id)
        loadingCredentialIDs.insert(config.id)
        if activePlaylistID == config.id { loadingStage = "Unlocking saved source…" }
        credentialLoadTasks[config.id] = Task { [weak self] in
            let started = ContinuousClock.now
            AppLog.sync.info("Saved source credential read started")
            let password = await ServerPasswordStore.loadPasswordAsync(for: config.id)
            AppLog.sync.info("Saved source credential read finished available=\(password != nil, privacy: .public) elapsedMs=\(AppLog.elapsedMilliseconds(since: started), privacy: .public)")
            guard !Task.isCancelled, let self,
                  self.credentialReadTokens[config.id] == token,
                  let index = self.playlists.firstIndex(where: { $0.id == config.id }) else { return }
            self.credentialLoadTasks[config.id] = nil
            self.credentialReadTokens[config.id] = nil
            self.loadingCredentialIDs.remove(config.id)
            if self.activePlaylistID == config.id, self.loadingStage == "Unlocking saved source…" {
                self.loadingStage = nil
            }
            guard let password else {
                if self.activePlaylistID == config.id {
                    self.errorMessage = "Saved source password is unavailable. Re-enter it in source settings."
                }
                return
            }
            self.playlists[index].password = password
            self.unresolvedCredentialIDs.remove(config.id)
        }
    }

    private func resolveProvidedCredentials(for config: ServerConfig) {
        credentialLoadTasks[config.id]?.cancel()
        credentialLoadTasks[config.id] = nil
        credentialReadTokens[config.id] = nil
        unresolvedCredentialIDs.remove(config.id)
        loadingCredentialIDs.remove(config.id)
    }

    private func persistPassword(for config: ServerConfig, saveMetadataOnSuccess: Bool = false) {
        Task { [weak self] in
            let saved = await ServerPasswordStore.savePasswordAsync(config.password, for: config.id)
            guard !Task.isCancelled, let self,
                  let current = self.playlists.first(where: { $0.id == config.id }),
                  Self.hasSameSource(current, config) else { return }
            if saved {
                if saveMetadataOnSuccess { self.savePlaylists() }
            } else {
                self.errorMessage = "Source password could not be saved. Check Keychain access and apply the source again."
            }
        }
    }

    private func updateServerStatus(_ status: ServerAccountStatus) {
        var status = status
        if let config = serverConfig {
            status.cacheKey = DataCache.preferenceKey(for: config)
        }
        serverStatus = status
        if let config = serverConfig {
            AccountCapacityLedger.shared.updateStatus(accountKey: .init(config: config),
                maxConnections: status.maxConnections, activeConnections: status.activeConnections,
                observedAt: status.lastChecked)
        }
        if let config = serverConfig,
           let data = try? JSONEncoder().encode(status) {
            UserDefaults.standard.set(data, forKey: serverStatusKeys(for: config).primary)
        }
    }

    private func loadServerStatus() {
        guard let config = serverConfig else {
            serverStatus = nil
            return
        }

        let keys = serverStatusKeys(for: config)
        let defaults = UserDefaults.standard
        let data = defaults.data(forKey: keys.primary)
            ?? keys.legacy.lazy.compactMap { defaults.data(forKey: $0) }.first
        guard let data,
              var stored = try? JSONDecoder().decode(ServerAccountStatus.self, from: data) else {
            serverStatus = nil
            return
        }

        stored.cacheKey = DataCache.preferenceKey(for: config)
        serverStatus = stored
        AccountCapacityLedger.shared.updateStatus(accountKey: .init(config: config),
            maxConnections: stored.maxConnections, activeConnections: stored.activeConnections,
            observedAt: stored.lastChecked)
        if defaults.data(forKey: keys.primary) == nil,
           let migrated = try? JSONEncoder().encode(stored) {
            defaults.set(migrated, forKey: keys.primary)
        }
    }

    // MARK: - Per-Source Preferences

    private func preferenceKeys(prefix: String) -> (primary: String, legacy: [String])? {
        if isSmartSportsActive { return ("\(prefix)_smart_sports_v1", []) }
        guard let config = serverConfig else { return nil }
        return (
            "\(prefix)_\(DataCache.preferenceKey(for: config))",
            DataCache.legacyCacheKeys(for: config).map { "\(prefix)_\($0)" }
        )
    }

    private func loadStringArrayPreference(primaryKey: String?, legacyKeys: [String] = []) -> [String] {
        guard let primaryKey else { return [] }
        let defaults = UserDefaults.standard

        if defaults.object(forKey: primaryKey) != nil {
            return defaults.array(forKey: primaryKey) as? [String] ?? []
        }

        for key in legacyKeys where defaults.object(forKey: key) != nil {
            let value = defaults.array(forKey: key) as? [String] ?? []
            defaults.set(value, forKey: primaryKey)
            return value
        }

        return []
    }

    private func loadIntDictionaryPreference(primaryKey: String?, legacyKeys: [String] = []) -> [String: Int] {
        guard let primaryKey else { return [:] }
        let defaults = UserDefaults.standard

        if defaults.object(forKey: primaryKey) != nil {
            return defaults.dictionary(forKey: primaryKey) as? [String: Int] ?? [:]
        }

        for key in legacyKeys where defaults.object(forKey: key) != nil {
            let value = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
            defaults.set(value, forKey: primaryKey)
            return value
        }

        return [:]
    }

    private func loadDataPreference(primaryKey: String?, legacyKeys: [String] = []) -> Data? {
        guard let primaryKey else { return nil }
        let defaults = UserDefaults.standard

        if defaults.object(forKey: primaryKey) != nil {
            return defaults.data(forKey: primaryKey)
        }

        for key in legacyKeys where defaults.object(forKey: key) != nil {
            guard let value = defaults.data(forKey: key) else { continue }
            defaults.set(value, forKey: primaryKey)
            return value
        }

        return nil
    }

    // MARK: - Recents

    private func saveRecents() {
        guard let keys = preferenceKeys(prefix: "buffer_recents") else { return }
        UserDefaults.standard.set(recentChannelIDs, forKey: keys.primary)
    }

    private func loadRecents() {
        guard let keys = preferenceKeys(prefix: "buffer_recents") else {
            recentChannelIDs = []
            return
        }
        recentChannelIDs = loadStringArrayPreference(primaryKey: keys.primary, legacyKeys: keys.legacy)
    }

    // MARK: - VOD Resume

    private func saveVODResumeEntries() {
        guard let keys = preferenceKeys(prefix: "buffer_vod_resume"),
              let data = try? JSONEncoder().encode(vodResumeEntries) else { return }
        UserDefaults.standard.set(data, forKey: keys.primary)
    }

    private func loadVODResumeEntries() {
        guard let keys = preferenceKeys(prefix: "buffer_vod_resume") else {
            vodResumeEntries = []
            return
        }
        guard let data = loadDataPreference(primaryKey: keys.primary, legacyKeys: keys.legacy),
              let entries = try? JSONDecoder().decode([VODResumeEntry].self, from: data) else {
            vodResumeEntries = []
            return
        }
        vodResumeEntries = Array(entries.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.vodResumeLimit))
    }

    // MARK: - Favorites

    private func saveFavorites() {
        guard let keys = preferenceKeys(prefix: "buffer_favorites") else { return }
        UserDefaults.standard.set(Array(favoriteChannelIDs), forKey: keys.primary)
    }

    private func loadFavorites() {
        guard let keys = preferenceKeys(prefix: "buffer_favorites") else {
            favoriteChannelIDs = []
            return
        }
        let ids = loadStringArrayPreference(primaryKey: keys.primary, legacyKeys: keys.legacy)
        favoriteChannelIDs = Set(ids)
    }

    // MARK: - Channel Usage

    private func trimChannelUsageCounts() {
        guard channelUsageCounts.count > Self.channelUsageLimit else { return }
        let keep = channelUsageCounts
            .sorted { $0.value > $1.value }
            .prefix(Self.channelUsageLimit)
        channelUsageCounts = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func saveChannelUsage() {
        guard let keys = preferenceKeys(prefix: "buffer_channel_usage") else { return }
        UserDefaults.standard.set(channelUsageCounts, forKey: keys.primary)
    }

    private func loadChannelUsage() {
        guard let keys = preferenceKeys(prefix: "buffer_channel_usage") else {
            channelUsageCounts = [:]
            return
        }
        channelUsageCounts = loadIntDictionaryPreference(primaryKey: keys.primary, legacyKeys: keys.legacy)
        trimChannelUsageCounts()
    }

    // MARK: - Group Usage

    private func trimGroupUsageCounts() {
        guard groupUsageCounts.count > Self.groupUsageLimit else { return }
        let keep = groupUsageCounts
            .sorted { $0.value > $1.value }
            .prefix(Self.groupUsageLimit)
        groupUsageCounts = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func saveGroupUsage() {
        guard let keys = preferenceKeys(prefix: "buffer_group_usage") else { return }
        UserDefaults.standard.set(groupUsageCounts, forKey: keys.primary)
    }

    private func loadGroupUsage() {
        guard let keys = preferenceKeys(prefix: "buffer_group_usage") else {
            groupUsageCounts = [:]
            return
        }
        groupUsageCounts = loadIntDictionaryPreference(primaryKey: keys.primary, legacyKeys: keys.legacy)
        trimGroupUsageCounts()
    }

    // MARK: - Group Preferences

    private func groupPrefsKeys() -> (
        order: String,
        hidden: String,
        legacyOrder: [String],
        legacyHidden: [String]
    )? {
        guard let orderKeys = preferenceKeys(prefix: "buffer_group_order"),
              let hiddenKeys = preferenceKeys(prefix: "buffer_group_hidden") else { return nil }
        return (
            orderKeys.primary,
            hiddenKeys.primary,
            orderKeys.legacy,
            hiddenKeys.legacy
        )
    }

    private func saveGroupPreferences() {
        guard let keys = groupPrefsKeys() else { return }
        UserDefaults.standard.set(storedGroupOrder, forKey: keys.order)
        UserDefaults.standard.set(Array(hiddenGroupNames), forKey: keys.hidden)
    }

    private func loadGroupPreferences() {
        guard let keys = groupPrefsKeys() else {
            storedGroupOrder = []
            hiddenGroupNames = []
            return
        }
        storedGroupOrder = loadStringArrayPreference(primaryKey: keys.order, legacyKeys: keys.legacyOrder)
        let hidden = loadStringArrayPreference(primaryKey: keys.hidden, legacyKeys: keys.legacyHidden)
        hiddenGroupNames = Set(hidden)
    }
}
