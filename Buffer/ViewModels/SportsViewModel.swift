import Foundation
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

    var selectedSports: Set<Sport> = [] { didSet { rebuildSections() } }
    var hideFinished = false { didSet { rebuildSections() } }

    // MARK: - Internal state

    private var events: [SportEvent] = []
    private let espn = ESPNClient()
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?

    // External data for stream matching — set by the view
    var channels: [Channel] = [] { didSet { rebuildIndexInBackground() } }
    var programs: [String: [EPGProgram]] = [:] { didSet { rebuildIndexInBackground() } }
    var favoriteChannelIDs: Set<String> = []
    var hiddenGroups: Set<String> = [] { didSet { rebuildIndexInBackground() } }

    /// Pre-built search index for on-demand matching.
    private var searchIndex: [ChannelSearchIndex] = []

    // MARK: - Index building

    private func rebuildIndexInBackground() {
        let ch = channels
        let pr = programs
        let hidden = hiddenGroups
        Task.detached(priority: .userInitiated) { [ch, pr, hidden] in
            let index = StreamMatcher.buildIndex(channels: ch, programs: pr, hiddenGroups: hidden)
            await MainActor.run { [weak self] in
                self?.searchIndex = index
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
        guard !index.isEmpty else { return [] }

        return await Task.detached(priority: .userInitiated) {
            var matches = StreamMatcher.findMatches(for: event, index: index)
            // Sort: favorites first, then by score
            matches.sort { lhs, rhs in
                let lFav = favIDs.contains(lhs.channel.id)
                let rFav = favIDs.contains(rhs.channel.id)
                if lFav != rFav { return lFav }
                return lhs.score > rhs.score
            }
            return matches
        }.value
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
