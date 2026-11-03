import Foundation
import OSLog
import SwiftUI

/// A section of events grouped by time bucket, ready for display.
nonisolated struct SportEventSection: Identifiable, Sendable {
    var id: Int { group.rawValue }
    let group: SportTimeGroup
    let events: [SportEvent]
}

private struct IndexToken: Equatable {
    var guideVersion: Int
    var channelSetVersion: Int
    var hiddenGroups: Set<String>
}

@MainActor
@Observable
final class SportsViewModel {
    // MARK: - View-facing state

    private(set) var sections: [SportEventSection] = []
    private(set) var availableSports: [Sport] = []
    private(set) var liveCount: Int = 0
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false
    private(set) var lastRefreshed: Date?
    private(set) var refreshWarning: String?
    private(set) var totalEvents: Int = 0
    private(set) var isStreamIndexBuilding = false

    /// Incremented each time the stream search index transitions from
    /// building/empty to ready. Cards observe this to rematch while a
    /// popover is open.
    private(set) var searchIndexVersion: Int = 0
    /// Changes only when favorites or ranking values actually change. Cards
    /// observe this scalar instead of retaining entire prior score maps.
    private(set) var matchingPreferencesVersion: Int = 0

    var selectedSports: Set<Sport> = [] { didSet { if oldValue != selectedSports { rebuildSections() } } }
    var hideFinished = false { didSet { if oldValue != hideFinished { rebuildSections() } } }

    // MARK: - Internal state

    @ObservationIgnored private var events: [SportEvent] = []
    private let espn: ESPNClient
    @ObservationIgnored private let fixtureCache: SportsFixtureCache
    @ObservationIgnored private var eventConfirmationDates: [String: Date] = [:]
    @ObservationIgnored private var didHydrateFixtures = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var indexRebuildTask: Task<Void, Never>?
    @ObservationIgnored private var indexWorkerTask: Task<Void, Never>?
    @ObservationIgnored private var indexBuildGeneration = 0
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var lastIndexToken: IndexToken?
    @ObservationIgnored private var lastGuideWaitLogAt: Date?
    @ObservationIgnored private var lastGuideWaitChannelCount = 0

    // External data for stream matching — set by the view
    @ObservationIgnored private var channels: [Channel] = []
    @ObservationIgnored private var programs: [String: [EPGProgram]] = [:]
    private(set) var favoriteChannelIDs: Set<String> = []
    private(set) var channelPreferenceScores: [String: Double] = [:]
    private(set) var groupPreferenceScores: [String: Double] = [:]
    @ObservationIgnored private var hiddenGroups: Set<String> = []
    @ObservationIgnored private var channelQuality: [String: StreamMatchQuality] = [:]

    /// Pre-built search index for on-demand matching.
    @ObservationIgnored
    private var searchIndex = StreamSearchIndex.empty

    init(espn: ESPNClient = ESPNClient(), fixtureCache: SportsFixtureCache = .shared) {
        self.espn = espn
        self.fixtureCache = fixtureCache
    }

    deinit {
        refreshTask?.cancel()
        autoRefreshTask?.cancel()
        indexRebuildTask?.cancel()
        indexWorkerTask?.cancel()
    }

    var isStreamIndexReady: Bool {
        !isStreamIndexBuilding && searchIndex.entryCount > 0 && searchIndex.epgTitleCount > 0
    }

    var streamIndexUnavailableMessage: String? {
        if isStreamIndexBuilding {
            return "Indexing channels and guide data…"
        }
        if searchIndex.entryCount == 0 || searchIndex.epgTitleCount == 0 {
            return "Channel search index is not ready yet"
        }
        return nil
    }

    @ObservationIgnored private var guideIndexDeferred = false
#if SPORTS_MATCH_TESTING
    @ObservationIgnored var matchWorkerBarrierForTesting: (@Sendable () -> Void)?
#endif

    func updateStreamMatchingContext(
        channels: [Channel],
        programs: [String: [EPGProgram]],
        favoriteChannelIDs: Set<String>,
        channelPreferenceScores: [String: Double],
        groupPreferenceScores: [String: Double],
        hiddenGroups: Set<String>,
        guideVersion: Int,
        channelSetVersion: Int,
        deferGuideIndex: Bool = false,
        qualityByChannel: [String: StreamMatchQuality]? = nil
    ) {
        let token = IndexToken(
            guideVersion: guideVersion,
            channelSetVersion: channelSetVersion,
            hiddenGroups: hiddenGroups
        )
        let contextUnchanged = token == lastIndexToken && deferGuideIndex == guideIndexDeferred
        updateStreamMatchingPreferences(
            favoriteChannelIDs: favoriteChannelIDs,
            channelPreferenceScores: channelPreferenceScores,
            groupPreferenceScores: groupPreferenceScores,
            qualityByChannel: qualityByChannel
        )
        guard !contextUnchanged else {
            AppLog.sports.info("Sports stream index skipped unchanged guide=\(guideVersion, privacy: .public) channels=\(channelSetVersion, privacy: .public)")
            return
        }
        // A changed catalog or visibility set must never expose matches from
        // the previous source while its replacement guide is still loading.
        let catalogChanged = lastIndexToken?.channelSetVersion != channelSetVersion
            || lastIndexToken?.hiddenGroups != hiddenGroups
        self.channels = channels
        self.programs = programs
        self.hiddenGroups = hiddenGroups
        lastIndexToken = token
        guideIndexDeferred = deferGuideIndex
        if catalogChanged || channels.isEmpty || programs.isEmpty {
            searchIndex = .empty
            isStreamIndexBuilding = !channels.isEmpty
            searchIndexVersion &+= 1
        }
        if deferGuideIndex {
            if catalogChanged || (searchIndex.entryCount > 0 && (indexRebuildTask != nil || indexWorkerTask != nil)) {
                indexBuildGeneration &+= 1
                indexRebuildTask?.cancel()
                indexRebuildTask = nil
                indexWorkerTask?.cancel()
                indexWorkerTask = nil
            }
            isStreamIndexBuilding = !channels.isEmpty && searchIndex.entryCount == 0
            // Cold launch still gets one useful current-guide index. Further
            // enrichment keeps that snapshot until the quiet tail completes.
            if searchIndex.entryCount == 0, !programs.isEmpty,
               indexRebuildTask == nil, indexWorkerTask == nil {
                scheduleIndexRebuild()
            }
            return
        }
        scheduleIndexRebuild()
    }

    func updateStreamMatchingPreferences(
        favoriteChannelIDs: Set<String>,
        channelPreferenceScores: [String: Double],
        groupPreferenceScores: [String: Double],
        qualityByChannel: [String: StreamMatchQuality]? = nil
    ) {
        let qualityChanged = qualityByChannel.map { channelQuality != $0 } ?? false
        guard self.favoriteChannelIDs != favoriteChannelIDs
            || self.channelPreferenceScores != channelPreferenceScores
            || self.groupPreferenceScores != groupPreferenceScores
            || qualityChanged else { return }
        self.favoriteChannelIDs = favoriteChannelIDs
        self.channelPreferenceScores = channelPreferenceScores
        self.groupPreferenceScores = groupPreferenceScores
        if let qualityByChannel { channelQuality = qualityByChannel }
        matchingPreferencesVersion &+= 1
    }

    // MARK: - Index building

    /// Build the sports stream search index in the background.
    /// The index is built purely in-memory from channels + EPG programs;
    /// it is not persisted to disk. EPG is the durable source of truth.
    private func scheduleIndexRebuild() {
        indexBuildGeneration &+= 1
        let generation = indexBuildGeneration
        indexRebuildTask?.cancel()
        indexWorkerTask?.cancel()
        indexWorkerTask = nil
        guard !channels.isEmpty else {
            indexRebuildTask = nil
            isStreamIndexBuilding = false
            return
        }
        indexRebuildTask = Task { [weak self, generation] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.indexRebuildTask = nil
            self.rebuildIndexInBackground(generation: generation)
        }
    }

    private func rebuildIndexInBackground(generation: Int) {
        let ch = channels
        let pr = programs
        let hidden = hiddenGroups

        if ch.isEmpty {
            searchIndex = .empty
            isStreamIndexBuilding = false
            AppLog.sports.info("Sports stream index cleared; no channels")
            return
        }

        if pr.isEmpty {
            // Channels are loaded but EPG hasn't arrived yet.
            // Keep whatever index we have (if any) and mark building.
            if searchIndex.entryCount == 0 {
                isStreamIndexBuilding = true
            }
            let now = Date()
            let shouldLog = lastGuideWaitChannelCount != ch.count
                || lastGuideWaitLogAt.map { now.timeIntervalSince($0) >= 30 } ?? true
            if shouldLog {
                lastGuideWaitLogAt = now
                lastGuideWaitChannelCount = ch.count
                AppLog.sports.info("Sports stream index waiting for guide data channels=\(ch.count, privacy: .public)")
            }
            return
        }

        isStreamIndexBuilding = searchIndex.entryCount == 0
        AppLog.sports.info("Sports stream index build started generation=\(generation, privacy: .public) channels=\(ch.count, privacy: .public) programKeys=\(pr.count, privacy: .public)")

        let playbackActive = PlayerSessionRegistry.shared.activeSession != nil
        let priority: TaskPriority = playbackActive ? .background : .utility
        AppLog.sports.info("Sports stream index priority=\(playbackActive ? "background" : "utility", privacy: .public)")
        indexWorkerTask = Task.detached(priority: priority) { [weak self, ch, pr, hidden, generation] in
            let signpostID = AppLog.sportsSignposter.makeSignpostID()
            let signpostState = AppLog.sportsSignposter.beginInterval(
                "SportsStreamIndexBuild",
                id: signpostID,
                "generation=\(generation, privacy: .public) channels=\(ch.count, privacy: .public) programKeys=\(pr.count, privacy: .public)"
            )
            let start = ContinuousClock.now
            defer {
                AppLog.sportsSignposter.endInterval("SportsStreamIndexBuild", signpostState)
            }
            let index = StreamMatcher.buildIndex(channels: ch, programs: pr, hiddenGroups: hidden, shouldCancel: { Task.isCancelled })
            guard !Task.isCancelled else { return }
            let buildMs = AppLog.elapsedMilliseconds(since: start)
            PerfMetrics.shared.record("sports.index.buildMs", Double(buildMs))
            let preparedAt = ContinuousClock.now

            await MainActor.run { [weak self] in
                guard let self, self.indexBuildGeneration == generation else { return }
                self.searchIndex = index
                self.isStreamIndexBuilding = false
                self.searchIndexVersion &+= 1
                self.indexWorkerTask = nil
#if DEBUG
                if index.programKeyCount > 1000 { self.runDiagnosticMatchValidationIfRequested() }
#endif
                AppLog.sports.info("Sports stream index ready generation=\(generation, privacy: .public) entries=\(index.entryCount, privacy: .public) programKeys=\(index.programKeyCount, privacy: .public) epgTitles=\(index.epgTitleCount, privacy: .public) buildMs=\(buildMs, privacy: .public) mainWaitMs=\(AppLog.elapsedMilliseconds(since: preparedAt), privacy: .public)")
            }
        }
    }

    // MARK: - Section building

    private func rebuildSections() {
        let now = Date()
        let maxHorizon = now.addingTimeInterval(7 * 24 * 3600) // Only show events within 7 days

        var filtered = events.filter { $0.startDate < maxHorizon || $0.status.isLive || $0.status.isFinished }
        if !selectedSports.isEmpty {
            filtered = filtered.filter { selectedSports.contains($0.sport) }
        }
        if hideFinished {
            filtered = filtered.filter { !$0.status.isFinished }
        }

        var buckets: [SportTimeGroup: [SportEvent]] = [:]
        for event in filtered {
            let group = SportTimeGroup.group(for: event, now: now)
            buckets[group, default: []].append(event)
        }
        for (group, items) in buckets {
            buckets[group] = items.sorted { lhs, rhs in
                if group == .finished { return lhs.startDate > rhs.startDate }
                return lhs.startDate < rhs.startDate
            }
        }
        sections = SportTimeGroup.allCases.compactMap { group in
            guard let items = buckets[group], !items.isEmpty else { return nil }
            return SportEventSection(group: group, events: items)
        }
        liveCount = filtered.filter { $0.status.isLive }.count
        totalEvents = filtered.count
    }

    private func rebuildAvailableSports() {
        let maxHorizon = Date().addingTimeInterval(7 * 24 * 3600)
        let relevant = events.filter { $0.startDate < maxHorizon || $0.status.isLive || $0.status.isFinished }
        let present = Set(relevant.map(\.sport))
        availableSports = Sport.allCases.filter { present.contains($0) }
    }

    // MARK: - Actions

    func refresh() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        isLoading = true
        // Keep only the client alive during I/O; a dismissed window can
        // release the model and cancel its transport requests in deinit.
        let shouldHydrate = !didHydrateFixtures
        refreshTask = Task { [weak self, espn, fixtureCache] in
            let started = ContinuousClock.now
            // Start transport immediately; disk hydration does not delay it.
            async let fresh = espn.fetchAllEventsResult()
            if shouldHydrate {
                let snapshot = await fixtureCache.load()
                guard !Task.isCancelled else { return }
                if let self, self.refreshGeneration == generation {
                    self.didHydrateFixtures = true
                    if self.events.isEmpty, let snapshot {
                        self.events = snapshot.events
                        self.eventConfirmationDates = snapshot.confirmedAt
                        self.lastRefreshed = snapshot.refreshedAt
                        self.refreshWarning = "Showing saved fixtures while refreshing. Scores and status may be out of date."
                        self.hasLoadedOnce = true
                        self.rebuildAvailableSports()
                        self.rebuildSections()
                        AppLog.sports.info("Sports saved fixtures hydrated events=\(snapshot.events.count, privacy: .public)")
                    }
                }
            }
            let result = await fresh
            guard !Task.isCancelled, let self, self.refreshGeneration == generation else { return }
            AppLog.sports.info("Sports fixtures fetched events=\(result.events.count, privacy: .public) successfulLeagues=\(result.successfulLeagueIDs.count, privacy: .public) failedLeagues=\(result.failedLeagueIDs.count, privacy: .public) partialLeagues=\(result.partialLeagueIDs.count, privacy: .public) fetchMs=\(AppLog.elapsedMilliseconds(since: started), privacy: .public)")
            let now = Date()
            let previous = SportsFixtureCache.retained(events: self.events,
                confirmedAt: self.eventConfirmationDates, refreshedAt: self.lastRefreshed ?? now, now: now)
            self.events = previous.events
            self.eventConfirmationDates = previous.confirmedAt
            if result.isUnavailable {
                self.refreshWarning = self.events.isEmpty
                    ? "Sports schedules are unavailable. Try refreshing in a moment."
                    : "Sports schedules could not refresh. Showing the last available fixtures."
            } else {
                // Replace leagues with a complete fresh response, retaining
                // prior fixtures for failed or limited single-day feeds only.
                let retainedLeagues = result.failedLeagueIDs.union(result.partialLeagueIDs)
                let retained = self.events.filter { retainedLeagues.contains($0.league.id) }
                var seen = Set(result.events.map { "\($0.league.id):\($0.id)" })
                self.events = result.events + retained.filter { seen.insert("\($0.league.id):\($0.id)").inserted }
                var confirmed = self.eventConfirmationDates
                for event in result.events { confirmed[SportsFixtureCache.eventKey(event)] = now }
                let snapshot = SportsFixtureCache.retained(events: self.events, confirmedAt: confirmed,
                                                          refreshedAt: now, now: now)
                self.events = snapshot.events
                self.eventConfirmationDates = snapshot.confirmedAt
                fixtureCache.enqueueSave(snapshot)
                self.refreshWarning = result.isPartial
                    ? "Some sports schedules are unavailable. Showing available fixtures."
                    : nil
                self.lastRefreshed = now
            }
            self.rebuildAvailableSports()
            self.rebuildSections()
            self.isLoading = false
            self.hasLoadedOnce = true
            self.refreshTask = nil
        }
    }

    func toggleSport(_ sport: Sport) {
        if selectedSports.contains(sport) {
            selectedSports.remove(sport)
        } else {
            selectedSports.insert(sport)
        }
    }

#if DEBUG
    @ObservationIgnored private var didRunDiagnosticMatchValidation = false

    /// `--validate-sport-matches`: runs the production matcher for a few
    /// current fixtures and logs each ranked list (see matchEvent's audit).
    private func runDiagnosticMatchValidationIfRequested() {
        guard CommandLine.arguments.contains("--validate-sport-matches"), !didRunDiagnosticMatchValidation else { return }
        didRunDiagnosticMatchValidation = true
        let now = Date()
        let candidates = events
            .filter { $0.homeTeam != nil && $0.awayTeam != nil && !$0.status.isFinished }
            .sorted { lhs, rhs in
                if lhs.status.isLive != rhs.status.isLive { return lhs.status.isLive }
                return abs(lhs.startDate.timeIntervalSince(now)) < abs(rhs.startDate.timeIntervalSince(now))
            }
            .prefix(6)
        AppLog.sports.info("Diagnostic match validation events=\(candidates.count, privacy: .public) available=\(self.events.count, privacy: .public)")
        Task { @MainActor [weak self] in
            for event in candidates {
                guard let self else { return }
                _ = await self.matchEvent(event)
            }
            AppLog.sports.info("Diagnostic match validation finished")
        }
    }
#endif

    /// Match a single event on demand (called when user clicks an event card).
    /// Runs matching on a background thread and returns results sorted with
    /// event relevance, current stream quality, then personal preferences.
    func matchEvent(_ event: SportEvent) async -> [StreamMatch] {
        guard !Task.isCancelled else { return [] }
        let generation = indexBuildGeneration
        let index = searchIndex
        let favIDs = favoriteChannelIDs
        let channelScores = channelPreferenceScores
        let groupScores = groupPreferenceScores
        let quality = channelQuality
        guard index.entryCount > 0, index.epgTitleCount > 0 else {
            AppLog.sports.info("Sports stream match skipped; index not ready event=\(event.displayTitle, privacy: .public) entries=\(index.entryCount, privacy: .public) epgTitles=\(index.epgTitleCount, privacy: .public)")
            return []
        }
#if SPORTS_MATCH_TESTING
        let matchBarrier = matchWorkerBarrierForTesting
#endif

        let worker = Task.detached(priority: .userInitiated) {
#if SPORTS_MATCH_TESTING
            matchBarrier?()
#endif
            guard !Task.isCancelled else { return [StreamMatch]() }
            let signpostID = AppLog.sportsSignposter.makeSignpostID()
            let signpostState = AppLog.sportsSignposter.beginInterval(
                "SportsStreamMatch",
                id: signpostID,
                "event=\(event.displayTitle, privacy: .public) entries=\(index.entryCount, privacy: .public)"
            )
            let start = ContinuousClock.now
            defer {
                AppLog.sportsSignposter.endInterval("SportsStreamMatch", signpostState)
            }
            var matches = StreamMatcher.findMatches(for: event, index: index, shouldCancel: { Task.isCancelled })
            guard !Task.isCancelled else { return [] }
            matches = StreamMatcher.rankedMatches(matches, qualityByChannel: quality,
                favoriteChannelIDs: favIDs, channelScores: channelScores, groupScores: groupScores)
            let found = matches.count
            matches = StreamMatcher.presentable(matches)
            PerfMetrics.shared.record("sports.match.hintsTrimmed", Double(found - matches.count))
            let elapsed = start.duration(to: .now).components
            let milliseconds = (elapsed.seconds * 1_000) + (elapsed.attoseconds / 1_000_000_000_000_000)
            PerfMetrics.shared.record("sports.match.eventMs", Double(milliseconds))
            PerfMetrics.shared.record("sports.match.candidates", Double(matches.count))
            // Ranking audit: what won and why, without stream URLs.
            for (rank, match) in matches.prefix(8).enumerated() {
                let q = quality[match.channel.preferenceIdentity]
                AppLog.sports.info("Sports stream match rank=\(rank, privacy: .public) event=\(event.displayTitle, privacy: .public) channel=\(match.channel.name, privacy: .public) group=\(match.channel.group, privacy: .public) favorite=\(favIDs.contains(match.channel.preferenceIdentity), privacy: .public) relevance=\(match.relevance.rawValue, privacy: .public) score=\(match.score, format: .fixed(precision: 1), privacy: .public) height=\(q?.observedHeight ?? 0, privacy: .public) fps=\(q?.observedFPS ?? 0, format: .fixed(precision: 1), privacy: .public) bitrate=\(q?.observedBitRate ?? 0, privacy: .public) availability=\(q?.availability.rawValue ?? -1, privacy: .public) programme=\(match.programTitle ?? "", privacy: .public)")
            }
            AppLog.sports.info("Sports stream match finished event=\(event.displayTitle, privacy: .public) matches=\(matches.count, privacy: .public) entries=\(index.entryCount, privacy: .public) epgTitles=\(index.epgTitleCount, privacy: .public) matchMs=\(milliseconds, privacy: .public)")
            return matches
        }
        let matches = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, indexBuildGeneration == generation else { return [] }
        return matches
    }

    // MARK: - Auto refresh

    func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                if Task.isCancelled { return }
                guard let self else { return }
                // A slow request must be allowed to finish. Restarting it at
                // every timer tick can otherwise prevent publication forever.
                if !self.isLoading { self.refresh() }
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }
}
