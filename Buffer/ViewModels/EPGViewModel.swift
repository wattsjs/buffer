import Foundation
import SwiftUI

enum SidebarSelection: Hashable {
    case home
    case sports
    case reminders
    case recordings
    case search
    case favorites
    case allChannels
    case group(String)
}

@MainActor
@Observable
class EPGViewModel {
    var channels: [Channel] = []
    var programs: [String: [EPGProgram]] = [:] // keyed by channel epgID
    var storedGroupOrder: [String] = []
    var hiddenGroupNames: Set<String> = []
    var selection: SidebarSelection = .home
    var revealChannelID: String?
    var searchText: String = ""
    var recentChannelIDs: [String] = []
    var favoriteChannelIDs: Set<String> = []
    var hasLoadedOnce = false
    var isRefreshing = false
    var loadingStage: String? = nil
    var errorMessage: String?
    var playlists: [ServerConfig] = []
    var activePlaylistID: UUID?
    var lastUpdated: Date? = nil
    var serverStatus: ServerAccountStatus?

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
    }

    /// All known groups in user-preferred order. Stored order wins for known names;
    /// any newly-discovered groups are appended alphabetically at the end.
    var allGroups: [String] {
        let raw = Set(channels.map(\.group))
        let ordered = storedGroupOrder.filter { raw.contains($0) }
        let seen = Set(ordered)
        let newOnes = raw.subtracting(seen).sorted()
        return ordered + newOnes
    }

    /// Visible groups shown in the sidebar.
    var groups: [String] {
        allGroups.filter { !hiddenGroupNames.contains($0) }
    }

    /// Hidden groups, in the same relative order as `allGroups`.
    var hiddenGroups: [String] {
        allGroups.filter { hiddenGroupNames.contains($0) }
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

    var filteredChannels: [Channel] {
        var result = channels

        switch selection {
        case .group(let group):
            result = result.filter { $0.group == group }
        case .favorites:
            result = favoriteChannels
        default:
            break
        }

        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        return result
    }

    var recentChannels: [Channel] {
        let byID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return recentChannelIDs.compactMap { byID[$0] }
    }

    var favoriteChannels: [Channel] {
        channels.filter { favoriteChannelIDs.contains($0.id) }
    }

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
        saveRecents()
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
        hasLoadedOnce = true

        let programsCache = await Task.detached(priority: .userInitiated) {
            DataCache.loadPrograms(key: key)
        }.value
        if let programsCache {
            programs = programsCache.programs
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
        let cacheKey = DataCache.cacheKey(for: config)
        var syncedStatus = ServerAccountStatus.initial(for: config, cacheKey: cacheKey)

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

                if !freshChannels.isEmpty {
                    channels = freshChannels
                    rebuildSearchIndex()

                    Task.detached(priority: .utility) {
                        DataCache.saveChannels(freshChannels, key: cacheKey)
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
                    rebuildSearchIndex()
                    syncedStatus.guideStatus = "Reachable"

                    Task.detached(priority: .utility) {
                        DataCache.savePrograms(organized, key: cacheKey)
                    }
                } catch {
                    print("[Buffer] EPG fetch failed: \(error)")
                    syncedStatus.guideStatus = "Unavailable"
                }
            } else {
                syncedStatus.guideStatus = "Not configured"
            }

            lastUpdated = Date()
            updateServerStatus(syncedStatus)
            print("[Buffer] Synced \(channels.count) channels in \(groups.count) groups (scope=\(scope), silent=\(silent))")

        } catch {
            print("[Buffer] Sync failed: \(error)")
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
        playlistSchedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                let hours = UserDefaults.standard.object(forKey: SyncInterval.playlistStorageKey) as? Int
                    ?? SyncInterval.playlistDefault.hours
                do {
                    try await Task.sleep(for: .seconds(Double(hours) * 3600))
                } catch {
                    return
                }
                if Task.isCancelled { return }
                self?.sync(silent: true, scope: .all)
            }
        }

        epgSchedulerTask?.cancel()
        epgSchedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                let hours = UserDefaults.standard.object(forKey: SyncInterval.epgStorageKey) as? Int
                    ?? SyncInterval.epgDefault.hours
                do {
                    try await Task.sleep(for: .seconds(Double(hours) * 3600))
                } catch {
                    return
                }
                if Task.isCancelled { return }
                self?.sync(silent: true, scope: .epg)
            }
        }
    }

    func stopSyncScheduler() {
        playlistSchedulerTask?.cancel()
        playlistSchedulerTask = nil
        epgSchedulerTask?.cancel()
        epgSchedulerTask = nil
    }

    func refreshServerStatus() async {
        guard let config = serverConfig else { return }
        let cacheKey = DataCache.cacheKey(for: config)
        var refreshed = serverStatus?.cacheKey == cacheKey
            ? (serverStatus ?? ServerAccountStatus.initial(for: config, cacheKey: cacheKey))
            : ServerAccountStatus.initial(for: config, cacheKey: cacheKey)
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
                let channelNameLower = channel.name.lowercased()
                for program in progs {
                    entries.append(
                        ProgramSearchEntry(
                            program: program,
                            channel: channel,
                            titleLower: program.title.lowercased(),
                            channelNameLower: channelNameLower
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
    }

    /// Shared between `setActivePlaylist` and cache-key-changing updates.
    /// Clears visible state, reloads per-playlist prefs (favorites/recents/
    /// groups/status), hydrates from disk cache, and triggers a sync if the
    /// cache was empty.
    private func swapInActivePlaylistState(previousKey: String?) {
        channels = []
        programs = [:]
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
        }

        loadServerStatus()
        loadRecents()
        loadFavorites()
        loadGroupPreferences()

        hydrationTask?.cancel()
        hydrationTask = Task { [weak self] in
            await self?.hydrateFromDisk()
            // If the cache is empty, fetch fresh data so the user sees channels
            // immediately rather than a blank window.
            guard let self else { return }
            if self.channels.isEmpty && self.serverConfig != nil {
                self.sync()
            }
        }
    }

    private func clearActivePlaylist() {
        activeSyncTask?.cancel()
        activeSyncTask = nil
        activePlaylistID = nil
        saveActivePlaylistID()
        channels = []
        programs = [:]
        searchEntries = []
        searchIndexVersion &+= 1
        lastUpdated = nil
        errorMessage = nil
        loadingStage = nil
        isRefreshing = false
        recentChannelIDs = []
        favoriteChannelIDs = []
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

    private static func serverStatusKey(for cacheKey: String) -> String {
        "buffer_server_status_\(cacheKey)"
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
        loadFavorites()
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

            // Migrate the old single-slot server status into the new
            // per-cache-key slot so the user doesn't lose their status card.
            if let data = UserDefaults.standard.data(forKey: Self.legacyServerStatusKey),
               let stored = try? JSONDecoder().decode(ServerAccountStatus.self, from: data) {
                UserDefaults.standard.set(data, forKey: Self.serverStatusKey(for: stored.cacheKey))
                UserDefaults.standard.removeObject(forKey: Self.legacyServerStatusKey)
            }
        }
    }

    private func updateServerStatus(_ status: ServerAccountStatus) {
        serverStatus = status
        if let data = try? JSONEncoder().encode(status) {
            UserDefaults.standard.set(data, forKey: Self.serverStatusKey(for: status.cacheKey))
        }
    }

    private func loadServerStatus() {
        guard let config = serverConfig else {
            serverStatus = nil
            return
        }

        let cacheKey = DataCache.cacheKey(for: config)
        guard let data = UserDefaults.standard.data(forKey: Self.serverStatusKey(for: cacheKey)),
              let stored = try? JSONDecoder().decode(ServerAccountStatus.self, from: data) else {
            serverStatus = nil
            return
        }

        serverStatus = stored
    }

    // MARK: - Recents

    private func recentsKey() -> String? {
        guard let config = serverConfig else { return nil }
        return "buffer_recents_\(DataCache.cacheKey(for: config))"
    }

    private func saveRecents() {
        guard let key = recentsKey() else { return }
        UserDefaults.standard.set(recentChannelIDs, forKey: key)
    }

    private func loadRecents() {
        guard let key = recentsKey() else {
            recentChannelIDs = []
            return
        }
        recentChannelIDs = (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
    }

    // MARK: - Favorites

    private func favoritesKey() -> String? {
        guard let config = serverConfig else { return nil }
        return "buffer_favorites_\(DataCache.cacheKey(for: config))"
    }

    private func saveFavorites() {
        guard let key = favoritesKey() else { return }
        UserDefaults.standard.set(Array(favoriteChannelIDs), forKey: key)
    }

    private func loadFavorites() {
        guard let key = favoritesKey() else {
            favoriteChannelIDs = []
            return
        }
        let ids = (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
        favoriteChannelIDs = Set(ids)
    }

    // MARK: - Group Preferences

    private func groupPrefsKeys() -> (order: String, hidden: String)? {
        guard let config = serverConfig else { return nil }
        let base = DataCache.cacheKey(for: config)
        return ("buffer_group_order_\(base)", "buffer_group_hidden_\(base)")
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
        storedGroupOrder = (UserDefaults.standard.array(forKey: keys.order) as? [String]) ?? []
        let hidden = (UserDefaults.standard.array(forKey: keys.hidden) as? [String]) ?? []
        hiddenGroupNames = Set(hidden)
    }
}
