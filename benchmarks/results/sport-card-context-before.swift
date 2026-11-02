import Foundation
import Observation

/// Only inputs read by StreamMatcher or its preference ordering participate
/// in cache identity. Score/logo updates don't repeat a channel search.
nonisolated struct SportEventMatchContext: Equatable {
    private struct Team: Equatable {
        let name: String
        let abbreviation: String
        let displayName: String

        init(_ team: TeamInfo) {
            name = team.name
            abbreviation = team.abbreviation
            displayName = team.displayName
        }
    }

    private let modelIdentity: ObjectIdentifier
    private let indexVersion: Int
    private let eventID: String
    private let sport: Sport
    private let league: League
    private let title: String
    private let shortTitle: String
    private let homeTeam: Team?
    private let awayTeam: Team?
    private let startDate: Date
    private let isLive: Bool
    private let isFinished: Bool
    private let broadcast: [String]
    private let venue: String?
    private let detail: String?
    private let tournamentName: String?
    private let favoriteIDs: Set<String>
    private let channelScores: [String: Double]
    private let groupScores: [String: Double]

    init(
        event: SportEvent,
        indexVersion: Int,
        modelIdentity: ObjectIdentifier,
        favoriteIDs: Set<String> = [],
        channelScores: [String: Double] = [:],
        groupScores: [String: Double] = [:]
    ) {
        self.modelIdentity = modelIdentity
        self.indexVersion = indexVersion
        eventID = event.id
        sport = event.sport
        league = event.league
        title = event.title
        shortTitle = event.shortTitle
        homeTeam = event.homeTeam.map(Team.init)
        awayTeam = event.awayTeam.map(Team.init)
        startDate = event.startDate
        isLive = event.status.isLive
        isFinished = event.status.isFinished
        broadcast = event.broadcast
        venue = event.venue
        detail = event.detail
        tournamentName = event.tournamentName
        self.favoriteIDs = favoriteIDs
        self.channelScores = channelScores
        self.groupScores = groupScores
    }
}

/// View-owned matching work shared by Home and Sports event cards. A new
/// context discards every result, including successful matches, before any
/// replacement starts. Cancelling a request also prevents a non-cooperative
/// matcher from publishing after dismissal or a source change.
@MainActor
@Observable
final class SportEventMatchState {
    struct Snapshot {
        let matches: [StreamMatch]
        let unavailableMessage: String?
        let isMatching: Bool
    }

    private var matches: [StreamMatch]?
    private var unavailableMessage: String?
    private var isMatching = false
    private var context: SportEventMatchContext?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    deinit { task?.cancel() }

    /// Render-time identity validation closes the gap before onChange is
    /// delivered; an old source's rows are never rendered for a new context.
    func snapshot(for context: SportEventMatchContext, unavailableMessage: String?) -> Snapshot {
        guard self.context == context else {
            return Snapshot(matches: [], unavailableMessage: unavailableMessage ?? "Finding matching streams…", isMatching: false)
        }
        return Snapshot(matches: matches ?? [], unavailableMessage: self.unavailableMessage, isMatching: isMatching)
    }

    func hasCurrentMatches(for context: SportEventMatchContext) -> Bool {
        self.context == context && matches != nil && !isMatching
    }

    func update(
        context: SportEventMatchContext,
        unavailableMessage: String?,
        isPresented: Bool,
        match: @escaping @MainActor () async -> [StreamMatch]
    ) {
        if self.context != context {
            cancel()
            self.context = context
            matches = nil
            self.unavailableMessage = nil
        }
        guard isPresented else {
            cancel()
            return
        }
        if let unavailableMessage {
            cancel()
            matches = nil
            self.unavailableMessage = unavailableMessage
            return
        }
        // Repeated taps or view updates share one request. Completed empty
        // results are cached too, until one of the actual inputs changes.
        guard task == nil, matches == nil else { return }
        self.unavailableMessage = "Finding matching streams…"
        isMatching = true
        let requestGeneration = generation
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result = await match()
            guard !Task.isCancelled, let self,
                  self.generation == requestGeneration, self.context == context else { return }
            self.matches = result
            self.unavailableMessage = nil
            self.isMatching = false
            self.task = nil
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        isMatching = false
    }
}
