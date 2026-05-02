import Foundation
import OSLog
import SwiftUI

/// A section of events grouped by time bucket, ready for display.
nonisolated struct SportEventSection: Identifiable, Sendable {
    var id: Int { group.rawValue }
    let group: SportTimeGroup
    let events: [SportEvent]
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
    private(set) var totalEvents: Int = 0
    private(set) var isStreamIndexBuilding = false

    var selectedSports: Set<Sport> = [] { didSet { rebuildSections() } }
    var hideFinished = false { didSet { rebuildSections() } }

    // MARK: - Internal state

    private var events: [SportEvent] = []
    private let espn = ESPNClient()
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var indexBuildGeneration = 0

    // External data for stream matching — set by the view
    var channels: [Channel] = []
    var programs: [String: [EPGProgram]] = [:]
    var favoriteChannelIDs: Set<String> = []
    var channelPreferenceScores: [String: Double] = [:]
    var groupPreferenceScores: [String: Double] = [:]
    var hiddenGroups: Set<String> = []

    /// Pre-built search index for on-demand matching.
    private var searchIndex = StreamSearchIndex.empty

    var isStreamIndexReady: Bool {
        !isStreamIndexBuilding && !searchIndex.entries.isEmpty && searchIndex.epgTitleCount > 0
    }

    var streamIndexUnavailableMessage: String? {
        if isStreamIndexBuilding {
            return "Indexing channels and guide data…"
        }
        if searchIndex.entries.isEmpty || searchIndex.epgTitleCount == 0 {
            return "Channel search index is not ready yet"
        }
        return nil
    }

    func updateStreamMatchingContext(
        channels: [Channel],
        programs: [String: [EPGProgram]],
        favoriteChannelIDs: Set<String>,
        channelPreferenceScores: [String: Double],
        groupPreferenceScores: [String: Double],
        hiddenGroups: Set<String>
    ) {
        self.channels = channels
        self.programs = programs
        self.favoriteChannelIDs = favoriteChannelIDs
        self.channelPreferenceScores = channelPreferenceScores
        self.groupPreferenceScores = groupPreferenceScores
        self.hiddenGroups = hiddenGroups
        rebuildIndexInBackground()
    }

    // MARK: - Index building

    private func rebuildIndexInBackground() {
        let ch = channels
        let pr = programs
        let hidden = hiddenGroups
        indexBuildGeneration &+= 1
        let generation = indexBuildGeneration

        if ch.isEmpty {
            searchIndex = .empty
            isStreamIndexBuilding = false
            AppLog.sports.info("Sports stream index cleared; no channels")
            return
        }

        if pr.isEmpty {
            searchIndex = .empty
            isStreamIndexBuilding = true
            AppLog.sports.info("Sports stream index waiting for guide data channels=\(ch.count, privacy: .public)")
            return
        }

        isStreamIndexBuilding = true
        AppLog.sports.info("Sports stream index build started generation=\(generation, privacy: .public) channels=\(ch.count, privacy: .public) programKeys=\(pr.count, privacy: .public)")

        Task.detached(priority: .userInitiated) { [ch, pr, hidden, generation] in
            let start = ContinuousClock.now
            let index = StreamMatcher.buildIndex(channels: ch, programs: pr, hiddenGroups: hidden)
            await MainActor.run { [weak self] in
                guard let self, self.indexBuildGeneration == generation else { return }
                self.searchIndex = index
                self.isStreamIndexBuilding = false
                let elapsed = start.duration(to: .now).components
                let milliseconds = (elapsed.seconds * 1_000) + (elapsed.attoseconds / 1_000_000_000_000_000)
                AppLog.sports.info("Sports stream index ready generation=\(generation, privacy: .public) entries=\(index.entries.count, privacy: .public) programKeys=\(index.programKeyCount, privacy: .public) epgTitles=\(index.epgTitleCount, privacy: .public) buildMs=\(milliseconds, privacy: .public)")
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
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            self.isLoading = true

            let fetched = await self.espn.fetchAllEvents()
            if Task.isCancelled { return }

            self.events = fetched
            self.rebuildAvailableSports()
            self.rebuildSections()
            self.lastRefreshed = Date()
            self.isLoading = false
            self.hasLoadedOnce = true
        }
    }

    func toggleSport(_ sport: Sport) {
        if selectedSports.contains(sport) {
            selectedSports.remove(sport)
        } else {
            selectedSports.insert(sport)
        }
    }

    /// Match a single event on demand (called when user clicks an event card).
    /// Runs matching on a background thread and returns results sorted with
    /// favorites first.
    func matchEvent(_ event: SportEvent) async -> [StreamMatch] {
        let index = searchIndex
        let favIDs = favoriteChannelIDs
        let channelScores = channelPreferenceScores
        let groupScores = groupPreferenceScores
        guard !index.entries.isEmpty, index.epgTitleCount > 0 else {
            AppLog.sports.info("Sports stream match skipped; index not ready event=\(event.displayTitle, privacy: .public) entries=\(index.entries.count, privacy: .public) epgTitles=\(index.epgTitleCount, privacy: .public)")
            return []
        }

        return await Task.detached(priority: .userInitiated) {
            let start = ContinuousClock.now
            var matches = StreamMatcher.findMatches(for: event, index: index)
            // Semantic score remains primary. User preference is a bounded
            // tie-breaker from favorite channels, channel usage, and folder usage.
            matches.sort { lhs, rhs in
                let lScore = Self.preferenceAdjustedScore(
                    match: lhs,
                    favoriteChannelIDs: favIDs,
                    channelScores: channelScores,
                    groupScores: groupScores
                )
                let rScore = Self.preferenceAdjustedScore(
                    match: rhs,
                    favoriteChannelIDs: favIDs,
                    channelScores: channelScores,
                    groupScores: groupScores
                )
                return lScore > rScore
            }
            let elapsed = start.duration(to: .now).components
            let milliseconds = (elapsed.seconds * 1_000) + (elapsed.attoseconds / 1_000_000_000_000_000)
            AppLog.sports.info("Sports stream match finished event=\(event.displayTitle, privacy: .public) matches=\(matches.count, privacy: .public) entries=\(index.entries.count, privacy: .public) epgTitles=\(index.epgTitleCount, privacy: .public) matchMs=\(milliseconds, privacy: .public)")
            return matches
        }.value
    }

    nonisolated private static func preferenceAdjustedScore(
        match: StreamMatch,
        favoriteChannelIDs: Set<String>,
        channelScores: [String: Double],
        groupScores: [String: Double]
    ) -> Double {
        let favoriteBoost = favoriteChannelIDs.contains(match.channel.id) ? 0.08 : 0
        let channelBoost = min(0.08, (channelScores[match.channel.id] ?? 0) * 0.08)
        let groupBoost = min(0.05, (groupScores[match.channel.group] ?? 0) * 0.05)
        return match.score * (1.0 + favoriteBoost + channelBoost + groupBoost)
    }

    // MARK: - Auto refresh

    func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                if Task.isCancelled { return }
                self?.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }
}
