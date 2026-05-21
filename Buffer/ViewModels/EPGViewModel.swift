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

@MainActor
@Observable
class EPGViewModel {
    static let disableVODKey = "disableVOD"

    var channels: [Channel] = [] {
        didSet { rebuildChannelDerivedState() }
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
    var programs: [String: [EPGProgram]] = [:] // keyed by channel epgID

    /// Pre-bucketed programs by hour (unix hour since 1970) per channel.
    /// Enables fast visible-range / timeline-window queries without scanning full per-channel program lists
    /// (critical for 500-1000+ channel guides with catchup days of data). See Agent 02 / Master perf issue.
    private var programHourBuckets: [String: [Int: [Int]]] = [:]

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
    var loadingStage: String? = nil
    var errorMessage: String?
    var playlists: [ServerConfig] = []
    var activePlaylistID: UUID?
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
    private var filteredChannelsCached: [Channel] = []
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
        return playlists.first(where: { $0.id == id })
    }

    var searchEntries: [ProgramSearchEntry] = []
    var searchIndexVersion: Int = 0
    private var indexBuildTask: Task<Void, Never>?
    private var playlistSchedulerTask: Task<Void, Never>?
    private var epgSchedulerTask: Task<Void, Never>?
    private var activeSyncTask: Task<Void, Never>?
    private var hydrationTask: Task<Void, Never>?

    init() {
        loadConfig()
        // Race disk IO against window creation — start loading cache
        // immediately so channels are often ready before the view appears.
        hydrationTask = Task { [weak self] in
            await self?.hydrateFromDisk()
        }
        if let config = serverConfig {
            setActiveStreamProbeScope(for: config)
        }

        // Seed caches from any prefs loaded in loadConfig (groups, etc.) + empty data.
        rebuildChannelDerivedState()
        rebuildVODDerivedState()
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
        favoriteChannelIDs.contains(channel.id)
    }

    func toggleFavorite(_ channel: Channel) {
        if favoriteChannelIDs.contains(channel.id) {
            favoriteChannelIDs.remove(channel.id)
        } else {
            favoriteChannelIDs.insert(channel.id)
        }
        saveFavorites()
    }

    func addRecent(_ channel: Channel) {
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
        guard let epgID = channel.epgChannelID else { return [] }
        return programs[epgID] ?? []
    }

    func currentProgram(for channel: Channel) -> EPGProgram? {
        programsForChannel(channel).first { $0.isNowPlaying }
    }

    func program(for channel: Channel, at date: Date) -> EPGProgram? {
        for program in programsForChannel(channel) {
            if program.start <= date && date < program.end {
                return program
            }
        }
        return nil
    }

    // MARK: - Indexed State Rebuilders (Agent 03 - incremental, not per-access)

    private func rebuildChannelDerivedState() {
        channelByID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        groupedChannels = Dictionary(grouping: channels, by: \.group)
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
            legacyKeys: DataCache.legacyCacheKeys(for: config)
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
        groupPreferenceScoresCached = gScores

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
        channelPreferenceScoresCached = cScores
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
            chResult = channels
        }
        if !searchText.isEmpty {
            chResult = chResult.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
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
        let key = DataCache.cacheKey(for: config)

        let channelsCache = await Task.detached(priority: .userInitiated) {
            DataCache.loadChannels(key: key)
        }.value
        if let channelsCache, !channelsCache.channels.isEmpty {
            channels = channelsCache.channels
            lastUpdated = channelsCache.savedAt
        }
        if let vodCache = await Task.detached(priority: .userInitiated, operation: {
            DataCache.loadVODItems(key: key)
        }).value {
            vodItems = vodCache.items
            if lastUpdated == nil {
                lastUpdated = vodCache.savedAt
            }
        }
        if let seriesCache = await Task.detached(priority: .userInitiated, operation: {
            DataCache.loadVODSeries(key: key)
        }).value {
            vodSeries = seriesCache.series
            if lastUpdated == nil {
                lastUpdated = seriesCache.savedAt
            }
        }
        searchIndexVersion &+= 1
        hasLoadedOnce = true

        let programsCache = await Task.detached(priority: .userInitiated) {
            DataCache.loadPrograms(key: key)
        }.value
        if let programsCache {
            programs = programsCache.programs
            rebuildProgramHourBuckets()
            rebuildSearchIndex()
        }
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
        guard let config = serverConfig else {
            errorMessage = nil
            hasLoadedOnce = true
            return
        }

        // Coalesce: if a sync is already running, leave it be.
        if let active = activeSyncTask, !active.isCancelled {
            return
        }

        activeSyncTask = Task { [weak self] in
            await self?.performSync(config: config, silent: silent, scope: scope)
        }
    }

    /// Await the current (or newly started) sync — used by the refresh button.
    func syncAndWait(silent: Bool = false, scope: SyncScope = .all) async {
        sync(silent: silent, scope: scope)
        await activeSyncTask?.value
    }

    private func performSync(config: ServerConfig, silent: Bool, scope: SyncScope) async {
        let signpostID = AppLog.syncSignposter.makeSignpostID()
        let signpostState = AppLog.syncSignposter.beginInterval(
            "EPGSync",
            id: signpostID,
            "scope=\(String(describing: scope), privacy: .public) silent=\(silent, privacy: .public)"
        )
        let started = ContinuousClock.now
        let cacheKey = DataCache.cacheKey(for: config)
        var syncedStatus = ServerAccountStatus.initial(for: config, cacheKey: DataCache.preferenceKey(for: config))

        if !silent {
            isRefreshing = true
            loadingStage = scope == .epg ? "Loading guide…" : "Loading channels…"
            errorMessage = nil
        }

        defer {
            if !silent {
                isRefreshing = false
                loadingStage = nil
            }
            AppLog.syncSignposter.endInterval("EPGSync", signpostState)
            hasLoadedOnce = true
            activeSyncTask = nil
        }

        do {
            if scope == .all {
                if config.type == .xtream,
                   let accountInfo = try? await XtreamClient(config: config).fetchAccountInfo() {
                    syncedStatus.apply(accountInfo)
                }

                let freshChannels = try await fetchChannels(config: config)
                syncedStatus.channelCount = freshChannels.count
                let freshVODItems: [VODItem]
                let freshSeries: [VODSeries]
                if isVODDisabled {
                    freshVODItems = []
                    freshSeries = []
                } else {
                    freshVODItems = try await fetchVODItems(config: config)
                    freshSeries = try await fetchSeries(config: config, vodItems: freshVODItems)
                }

                if !freshChannels.isEmpty {
                    channels = freshChannels
                    rebuildSearchIndex()

                    Task.detached(priority: .utility) {
                        DataCache.saveChannels(freshChannels, key: cacheKey)
                    }
                }
                vodItems = freshVODItems
                vodSeries = freshSeries
                vodItemDetails = [:]
                vodItemDetailLoadErrors = [:]
                loadingVODItemIDs = []
                searchIndexVersion &+= 1
                if !isVODDisabled {
                    Task.detached(priority: .utility) {
                        DataCache.saveVODItems(freshVODItems, key: cacheKey)
                        DataCache.saveVODSeries(freshSeries, key: cacheKey)
                    }
                }
            } else {
                // EPG-only: preserve existing channel count in status
                syncedStatus.channelCount = channels.count
            }

            if let epgURL = epgURL(for: config) {
                if !silent { loadingStage = "Loading guide…" }
                do {
                    let allPrograms = try await XMLTVParser.parse(from: epgURL)
                    if !silent { loadingStage = "Organizing guide…" }
                    let organized = await Task.detached(priority: .userInitiated) {
                        Self.organize(allPrograms)
                    }.value
                    programs = organized
                    rebuildProgramHourBuckets()
                    rebuildSearchIndex()
                    syncedStatus.guideStatus = "Reachable"

                    Task.detached(priority: .utility) {
                        DataCache.savePrograms(organized, key: cacheKey)
                    }
                } catch {
                    AppLog.sync.error("EPG fetch failed error=\(error.localizedDescription, privacy: .public)")
                    syncedStatus.guideStatus = "Unavailable"
                }
            } else {
                syncedStatus.guideStatus = "Not configured"
            }

            lastUpdated = Date()
            updateServerStatus(syncedStatus)
            let elapsed = started.duration(to: .now).components.seconds
            AppLog.sync.info("Sync finished scope=\(String(describing: scope), privacy: .public) silent=\(silent, privacy: .public) seconds=\(elapsed, privacy: .public) channels=\(self.channels.count, privacy: .public) groups=\(self.groups.count, privacy: .public)")

        } catch {
            AppLog.sync.error("Sync failed scope=\(String(describing: scope), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if !silent && channels.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
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

    private func syncIfAutomatic(scope: SyncScope, silent: Bool = false) {
        if automaticRefreshEnabled(scope: scope) {
            sync(silent: silent, scope: scope)
        }
    }

    func syncOnLaunchIfNeeded() {
        guard activePlaylist != nil else { return }
        if channels.isEmpty {
            syncIfAutomatic(scope: .all)
        } else {
            syncIfAutomatic(scope: .epg, silent: true)
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
        let statusKey = DataCache.preferenceKey(for: config)
        var refreshed = serverStatus?.cacheKey == statusKey
            ? (serverStatus ?? ServerAccountStatus.initial(for: config, cacheKey: statusKey))
            : ServerAccountStatus.initial(for: config, cacheKey: statusKey)
        refreshed.channelCount = channels.count
        refreshed.guideStatus = epgURL(for: config) == nil ? "Not configured" : refreshed.guideStatus

        switch config.type {
        case .xtream:
            if let info = try? await XtreamClient(config: config).fetchAccountInfo() {
                refreshed.apply(info)
            }
        case .m3u:
            refreshed.lastChecked = .now
        }

        updateServerStatus(refreshed)
    }

    private func fetchChannels(config: ServerConfig) async throws -> [Channel] {
        switch config.type {
        case .xtream:
            let client = XtreamClient(config: config)
            return try await client.fetchChannels()
        case .m3u:
            guard let url = config.m3uSourceURL else {
                throw XtreamError.invalidURL
            }
            return try await M3UParser.parse(from: url)
        }
    }

    private func fetchVODItems(config: ServerConfig) async throws -> [VODItem] {
        switch config.type {
        case .xtream:
            let client = XtreamClient(config: config)
            return (try? await client.fetchVODItems()) ?? []
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
            return (try? await XtreamClient(config: config).fetchSeries()) ?? []
        case .m3u:
            return seriesFromM3UEpisodes(vodItems)
        }
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

        loadingVODItemIDs.insert(item.id)
        defer { loadingVODItemIDs.remove(item.id) }

        do {
            let detailed = try await XtreamClient(config: config).fetchVODItemDetails(item: item)
            vodItemDetails[item.id] = detailed
            vodItemDetailLoadErrors[item.id] = nil
            searchIndexVersion &+= 1
        } catch {
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

        loadingSeriesIDs.insert(series.id)
        defer { loadingSeriesIDs.remove(series.id) }

        if let local = localEpisodes(for: series), !local.isEmpty {
            seriesEpisodes[series.id] = local
            seriesEpisodeLoadErrors[series.id] = nil
            searchIndexVersion &+= 1
            return
        }

        guard let config = serverConfig, config.type == .xtream else {
            seriesEpisodes[series.id] = []
            seriesEpisodeLoadErrors[series.id] = nil
            return
        }

        do {
            let episodes = try await XtreamClient(config: config).fetchSeriesEpisodes(series: series)
            seriesEpisodes[series.id] = episodes
            seriesEpisodeLoadErrors[series.id] = nil
            searchIndexVersion &+= 1
        } catch {
            seriesEpisodes[series.id] = []
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
            sync(silent: false, scope: .all)
        } else {
            searchIndexVersion &+= 1
        }
    }

    private func epgURL(for config: ServerConfig) -> URL? {
        switch config.type {
        case .xtream:
            return config.xtreamEPGURL
        case .m3u:
            return config.epgSourceURL
        }
    }

    // MARK: - Search index

    private func rebuildSearchIndex() {
        indexBuildTask?.cancel()

        let channelsByEPGID: [String: Channel] = Dictionary(
            channels.compactMap { channel -> (String, Channel)? in
                guard let id = channel.epgChannelID else { return nil }
                return (id, channel)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let programsSnapshot = programs

        indexBuildTask = Task.detached(priority: .utility) { [weak self, channelsByEPGID, programsSnapshot] in
            var entries: [ProgramSearchEntry] = []
            entries.reserveCapacity(programsSnapshot.values.reduce(0) { $0 + $1.count })

            for (epgID, progs) in programsSnapshot {
                if Task.isCancelled { return }
                guard let channel = channelsByEPGID[epgID] else { continue }
                for (programIndex, program) in progs.enumerated() {
                    entries.append(
                        ProgramSearchEntry(
                            id: program.id,
                            epgID: epgID,
                            programIndex: programIndex,
                            channelID: channel.id,
                            titleLower: program.title.lowercased(),
                            start: program.start,
                            end: program.end
                        )
                    )
                }
            }

            if Task.isCancelled { return }
            let finalEntries = entries

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.searchEntries = finalEntries
                self.searchIndexVersion &+= 1
            }
        }
    }

    // MARK: - Pre-bucketing for fast visible-range queries (Agent 02 / Master Issues)

    private func rebuildProgramHourBuckets() {
        programHourBuckets.removeAll(keepingCapacity: true)
        for (epgID, progs) in programs {
            var buckets: [Int: [Int]] = [:]
            buckets.reserveCapacity(max(1, progs.count / 8))
            for (programIndex, p) in progs.enumerated() {
                // A program may span hour boundaries; place in all overlapping buckets so range queries are O(1-ish per hour).
                let startH = Int(floor(p.start.timeIntervalSince1970 / 3600))
                let endH = Int(floor((p.end.timeIntervalSince1970 - 0.001) / 3600))
                for h in startH...max(startH, endH) {
                    buckets[h, default: []].append(programIndex)
                }
            }
            // Keep per-bucket lists sorted (inherited from parent channel sort)
            programHourBuckets[epgID] = buckets
        }
    }

    /// Returns programs for the channel that intersect [start, end).
    /// Uses pre-buckets when available for O(relevant hours) instead of O(all programs for channel).
    /// This makes the now-limited visible row computations (rowData + buildBlocks) fast even with long catchup histories.
    func programsForChannel(_ channel: Channel, between start: Date, and end: Date) -> [EPGProgram] {
        guard let epgID = channel.epgChannelID else { return [] }
        guard let buckets = programHourBuckets[epgID], !buckets.isEmpty else {
            // Fallback (no buckets yet or empty)
            return programsForChannel(channel)
                .filter { $0.end > start && $0.start < end }
                .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        }
        let allPrograms = programs[epgID] ?? []
        let startH = Int(floor(start.timeIntervalSince1970 / 3600)) - 1
        let endH = Int(ceil(end.timeIntervalSince1970 / 3600)) + 1
        var candidates: [EPGProgram] = []
        var seenIndices = Set<Int>()
        for h in startH...endH {
            if let list = buckets[h] {
                for programIndex in list where seenIndices.insert(programIndex).inserted {
                    guard allPrograms.indices.contains(programIndex) else { continue }
                    let p = allPrograms[programIndex]
                    if p.end > start && p.start < end {
                        candidates.append(p)
                    }
                }
            }
        }
        // Buckets are not globally sorted across hours, so sort the small result
        return candidates.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    nonisolated private static func organize(_ allPrograms: [EPGProgram]) -> [String: [EPGProgram]] {
        var organized: [String: [EPGProgram]] = [:]
        for program in allPrograms {
            organized[program.channelID, default: []].append(program)
        }
        for (key, value) in organized {
            organized[key] = value.sorted { $0.start < $1.start }
        }
        return organized
    }

    // MARK: - Playlist CRUD

    /// Insert a new playlist. If `makeActive` is true (default) it becomes the
    /// active one and per-playlist state is swapped in.
    func addPlaylist(_ config: ServerConfig, makeActive: Bool = true) {
        playlists.append(config)
        _ = ServerPasswordStore.savePassword(config.password, for: config.id)
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
        _ = ServerPasswordStore.savePassword(config.password, for: config.id)
        savePlaylists()

        if activePlaylistID == config.id {
            let previousKey = DataCache.cacheKey(for: previous)
            let newKey = DataCache.cacheKey(for: config)
            if previousKey != newKey {
                swapInActivePlaylistState(previousKey: previousKey)
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
        _ = ServerPasswordStore.deletePassword(for: removed.id)
        NotificationManager.shared.cancelReminders(forPlaylistID: id)
        savePlaylists()

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
        if activePlaylistID != reminder.playlistID {
            setActivePlaylist(id: reminder.playlistID)
        }
        await hydrate()
        if channels.isEmpty {
            await syncAndWait()
        }
        return channels.first(where: { $0.id == reminder.channelID })
    }

    /// Switch the active playlist and reload its per-playlist state.
    func setActivePlaylist(id: UUID) {
        guard playlists.contains(where: { $0.id == id }) else { return }
        if activePlaylistID == id { return }

        // Abort any in-flight sync; it would finish by writing data from the
        // old playlist into our (now reassigned) `channels`/`programs` slots.
        activeSyncTask?.cancel()
        activeSyncTask = nil

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
        // Do NOT immediately clear channels/programs/vod — this caused a
        // jarring empty flash while the new playlist hydrated (Agent 03).
        // Instead, keep the previous data visible until the new hydrate
        // completes and overwrites it. This gives a much smoother playlist
        // switch experience, especially for large libraries.
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

        hydrationTask?.cancel()
        hydrationTask = Task { [weak self] in
            await self?.hydrateFromDisk()
            guard let self else { return }
            self.syncAfterPlaylistSwapIfNeeded()
        }
    }

    private func clearActivePlaylist() {
        activeSyncTask?.cancel()
        activeSyncTask = nil
        activePlaylistID = nil
        saveActivePlaylistID()
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
        programHourBuckets = [:]
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
        if let data = UserDefaults.standard.data(forKey: Self.playlistsKey),
           let stored = try? JSONDecoder().decode([StoredServerConfig].self, from: data) {
            playlists = stored.map { entry in
                let password = ServerPasswordStore.loadPassword(for: entry.id) ?? ""
                return entry.serverConfig(password: password)
            }
        } else {
            migrateLegacyConfigIfNeeded()
        }

        if let raw = UserDefaults.standard.string(forKey: Self.activePlaylistKey),
           let id = UUID(uuidString: raw),
           playlists.contains(where: { $0.id == id }) {
            activePlaylistID = id
        } else {
            activePlaylistID = playlists.first?.id
            saveActivePlaylistID()
        }

        loadServerStatus()
        loadRecents()
        loadVODResumeEntries()
        loadFavorites()
        loadChannelUsage()
        loadGroupUsage()
        loadGroupPreferences()
    }

    /// One-time migration of the pre-multi-playlist single-config key. Leaves
    /// the legacy key in place for a while in case an older build is opened
    /// (they'll just see a stale single config, not a crash).
    private func migrateLegacyConfigIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: Self.legacyConfigKey) else { return }

        if let stored = try? JSONDecoder().decode(StoredServerConfig.self, from: data) {
            let password = ServerPasswordStore.loadPassword(for: stored.id) ?? ""
            playlists = [stored.serverConfig(password: password)]
        } else if let legacy = try? JSONDecoder().decode(ServerConfig.self, from: data) {
            _ = ServerPasswordStore.savePassword(legacy.password, for: legacy.id)
            playlists = [legacy]
        }

        if !playlists.isEmpty {
            savePlaylists()
            activePlaylistID = playlists.first?.id
            saveActivePlaylistID()

            // Migrate the old single-slot server status into the stable
            // per-source slot so the user doesn't lose their status card.
            if let data = UserDefaults.standard.data(forKey: Self.legacyServerStatusKey),
               var stored = try? JSONDecoder().decode(ServerAccountStatus.self, from: data),
               let config = serverConfig {
                stored.cacheKey = DataCache.preferenceKey(for: config)
                if let migrated = try? JSONEncoder().encode(stored) {
                    UserDefaults.standard.set(migrated, forKey: serverStatusKeys(for: config).primary)
                    UserDefaults.standard.removeObject(forKey: Self.legacyServerStatusKey)
                }
            }
        }
    }

    private func updateServerStatus(_ status: ServerAccountStatus) {
        var status = status
        if let config = serverConfig {
            status.cacheKey = DataCache.preferenceKey(for: config)
        }
        serverStatus = status
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
        if defaults.data(forKey: keys.primary) == nil,
           let migrated = try? JSONEncoder().encode(stored) {
            defaults.set(migrated, forKey: keys.primary)
        }
    }

    // MARK: - Per-Source Preferences

    private func preferenceKeys(prefix: String) -> (primary: String, legacy: [String])? {
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
