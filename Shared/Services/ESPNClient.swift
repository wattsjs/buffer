import Foundation
import OSLog

/// A successful empty scoreboard differs from an unavailable feed. Callers
/// retain prior fixtures only for leagues that did not provide a fresh result.
nonisolated struct ESPNRefreshResult: Sendable {
    let events: [SportEvent]
    let successfulLeagueIDs: Set<String>
    let failedLeagueIDs: Set<String>
    let partialLeagueIDs: Set<String>
    var isUnavailable: Bool { successfulLeagueIDs.isEmpty }
    var isPartial: Bool { !failedLeagueIDs.isEmpty || !partialLeagueIDs.isEmpty }
}

private nonisolated struct ESPNLeagueResult: Sendable {
    let leagueID: String
    let events: [SportEvent]
    let succeeded: Bool
    var partial = false
}

private enum ESPNFeedError: Error {
    case http(Int)
    case invalidResponse
}

/// Fetches live and upcoming sporting events from ESPN's public scoreboard API
/// and parses them into canonical `SportEvent` models.
actor ESPNClient {
    private let session: URLSession
    private let requestLimiter: ESPNRequestLimiter
    private let baseURL = "https://site.api.espn.com/apis/site/v2/sports"
    private let lookbackDays = 1
    private let futureDays = 7
    private let requestLimit = 250
    private let maxConcurrentLeagueFetches = 8

    init(session: URLSession = .shared, maxConcurrentRequests: Int = 8) {
        self.session = session
        self.requestLimiter = ESPNRequestLimiter(limit: max(1, min(8, maxConcurrentRequests)))
    }

    // MARK: - Public

    /// Fetch events for all configured leagues concurrently.
    func fetchAllEvents() async -> [SportEvent] {
        await fetchAllEventsResult().events
    }

    func fetchAllEventsResult() async -> ESPNRefreshResult {
        guard !Task.isCancelled else {
            return ESPNRefreshResult(events: [], successfulLeagueIDs: [], failedLeagueIDs: [], partialLeagueIDs: [])
        }
        return await withTaskGroup(of: ESPNLeagueResult.self) { group in
            let leagues = League.all
            var nextIndex = 0
            let initialCount = min(maxConcurrentLeagueFetches, leagues.count)
            for _ in 0..<initialCount {
                let league = leagues[nextIndex]
                nextIndex += 1
                group.addTask { [self] in await self.fetchEventsResult(for: league) }
            }
            var all: [SportEvent] = []
            var successful = Set<String>()
            var failed = Set<String>()
            var partial = Set<String>()
            while let result = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return ESPNRefreshResult(events: [], successfulLeagueIDs: [], failedLeagueIDs: [], partialLeagueIDs: [])
                }
                all.append(contentsOf: result.events)
                if result.succeeded { successful.insert(result.leagueID) }
                else { failed.insert(result.leagueID) }
                if result.partial { partial.insert(result.leagueID) }
                if nextIndex < leagues.count {
                    let league = leagues[nextIndex]
                    nextIndex += 1
                    group.addTask { [self] in await self.fetchEventsResult(for: league) }
                }
            }
            return ESPNRefreshResult(events: all, successfulLeagueIDs: successful,
                                     failedLeagueIDs: failed, partialLeagueIDs: partial)
        }
    }

    func fetchEvents(for league: League) async -> [SportEvent] {
        await fetchEventsResult(for: league).events
    }

    private func fetchEventsResult(for league: League) async -> ESPNLeagueResult {
        let failed = ESPNLeagueResult(leagueID: league.id, events: [], succeeded: false)
        guard !Task.isCancelled else { return failed }
        if league.sport == .cricket { return await fetchCricketEvents(for: league) }
        let df = scoreboardDateFormatter()
        let start = df.string(from: Date().addingTimeInterval(TimeInterval(-lookbackDays * 86400)))
        let end = df.string(from: Date().addingTimeInterval(TimeInterval(futureDays * 86400)))
        do {
            let datasets: [Data]
            var partial = false
            do {
                datasets = [try await scoreboardData(for: league, dates: "\(start)-\(end)")]
            } catch ESPNFeedError.http(400) {
                try Task.checkCancellation()
                do {
                    // A server may reject the requested count rather than
                    // the date range. Preserve the full horizon when a smaller
                    // count is accepted; access denials are never retried.
                    let data = try await scoreboardData(for: league, dates: "\(start)-\(end)", limit: 100)
                    datasets = [data]
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    partial = (json?["events"] as? [[String: Any]])?.count == 100
                    AppLog.sports.info("ESPN smaller-limit fallback league=\(league.shortName, privacy: .public)")
                } catch ESPNFeedError.http(400) {
                    // Brisbane's Monday starts before the league's Sunday
                    // games. Both day buckets are needed to retain overnight
                    // fixtures; do not multiply a rejected range into nine
                    // daily requests across every configured league.
                    try Task.checkCancellation()
                    datasets = await fallbackDailyScoreboards(for: league, dates: [start, df.string(from: Date())])
                    try Task.checkCancellation()
                    guard !datasets.isEmpty else { throw ESPNFeedError.invalidResponse }
                    partial = true
                    AppLog.sports.info("ESPN overnight-day fallback league=\(league.shortName, privacy: .public) successfulDays=\(datasets.count, privacy: .public)")
                }
            }
            var events: [SportEvent] = []
            for data in datasets {
                try Task.checkCancellation()
                events.append(contentsOf: league.sport == .golf
                    ? await expandGolfScoreboard(data: data, league: league)
                    : filterStaleLookbackEvents(parse(data: data, league: league)))
            }
            var seen = Set<String>()
            // Daily buckets are chronological; the later bucket contains the
            // newer score/status when ESPN repeats an overnight fixture.
            let deduplicated = events.reversed().filter { seen.insert($0.id).inserted }.reversed()
            return ESPNLeagueResult(leagueID: league.id, events: Array(deduplicated),
                                    succeeded: true, partial: partial)
        } catch {
            guard !Task.isCancelled else { return failed }
            if case ESPNFeedError.http(let status) = error {
                AppLog.sports.error("ESPN scoreboard unavailable league=\(league.shortName, privacy: .public) status=\(status, privacy: .public)")
            } else {
                // Log a classification rather than localized transport text,
                // which can embed the request URL.
                AppLog.sports.error("ESPN scoreboard unavailable league=\(league.shortName, privacy: .public) transportOrFormatError=true")
            }
            return failed
        }
    }

    private func fallbackDailyScoreboards(for league: League, dates: [String]) async -> [Data] {
        await withTaskGroup(of: (String, Data?).self) { group in
            for date in Set(dates) {
                guard !Task.isCancelled else { break }
                group.addTask { [self] in
                    guard !Task.isCancelled else { return (date, nil) }
                    return (date, try? await self.scoreboardData(for: league, dates: date, limit: 100))
                }
            }
            var result: [(String, Data)] = []
            for await (date, data) in group {
                guard !Task.isCancelled else { group.cancelAll(); return [] }
                if let data { result.append((date, data)) }
            }
            return result.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    private func scoreboardDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = .current
        return formatter
    }

    private func scoreboardData(for league: League, dates: String, limit: Int? = nil) async throws -> Data {
        guard let url = URL(string: "\(baseURL)/\(league.espnPath)/scoreboard?dates=\(dates)&limit=\(limit ?? requestLimit)") else {
            throw ESPNFeedError.invalidResponse
        }
        let (data, response) = try await fetchData(from: url)
        guard let http = response as? HTTPURLResponse else { throw ESPNFeedError.invalidResponse }
        guard http.statusCode == 200 else { throw ESPNFeedError.http(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["events"] is [[String: Any]] else { throw ESPNFeedError.invalidResponse }
        return data
    }

    /// Cricket only supports individual dates. Preserve successful days even
    /// if another day is unavailable, and surface the incomplete refresh.
    private func fetchCricketEvents(for league: League) async -> ESPNLeagueResult {
        let failed = ESPNLeagueResult(leagueID: league.id, events: [], succeeded: false)
        guard !Task.isCancelled else { return failed }
        let df = scoreboardDateFormatter()
        let fetched: [Data?] = await withTaskGroup(of: Data?.self) { group in
            for dayOffset in (-lookbackDays)...futureDays {
                guard !Task.isCancelled else { break }
                let dateStr = df.string(from: Date().addingTimeInterval(Double(dayOffset) * 86400))
                group.addTask { [self] in
                    guard !Task.isCancelled else { return nil }
                    return try? await self.scoreboardData(for: league, dates: dateStr)
                }
            }
            var results: [Data?] = []
            for await data in group {
                guard !Task.isCancelled else { group.cancelAll(); return [] }
                results.append(data)
            }
            return results
        }
        guard !Task.isCancelled else { return failed }
        var all: [SportEvent] = []
        let successfulDays = fetched.compactMap { $0 }
        for data in successfulDays {
            guard !Task.isCancelled else { return failed }
            all.append(contentsOf: parse(data: data, league: league))
        }
        all = filterStaleLookbackEvents(all)
        var seen = Set<String>()
        return ESPNLeagueResult(leagueID: league.id, events: all.filter { seen.insert($0.id).inserted },
                                succeeded: !successfulDays.isEmpty, partial: successfulDays.count != fetched.count)
    }

    /// A lookback keeps genuinely live overnight events available in time
    /// zones ahead of the league, without surfacing yesterday's finished games.
    private func filterStaleLookbackEvents(_ events: [SportEvent]) -> [SportEvent] {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return events.filter { $0.startDate >= startOfToday || $0.status.isLive }
    }

    // MARK: - JSON Parsing

    /// Sports where ESPN nests individual matches/races inside a tournament
    /// event — either via `groupings[].competitions[]` (tennis) or
    /// `competitions[]` with a session `type` (F1, NASCAR).
    private static let tournamentSports: Set<Sport> = [.tennis, .golf, .motorsport]

    private func parse(data: Data, league: League) -> [SportEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else {
            return []
        }

        return events.flatMap { parseEvent($0, league: league) }
    }

    private func parseEvent(_ json: [String: Any], league: League) -> [SportEvent] {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String,
              let dateString = json["date"] as? String else {
            return []
        }

        // Tennis / golf use groupings[].competitions[] for individual matches
        let groupings = json["groupings"] as? [[String: Any]]
        if Self.tournamentSports.contains(league.sport), let groupings, !groupings.isEmpty {
            return expandGroupings(groupings, eventID: id, tournamentName: name, league: league)
        }

        // F1 / NASCAR use competitions[] with session types (FP1, Qual, Race)
        let competitions = json["competitions"] as? [[String: Any]]
        if Self.tournamentSports.contains(league.sport),
           let competitions, competitions.count > 1 {
            return competitions.compactMap { comp in
                parseSessionCompetition(comp, eventID: id, tournamentName: name, league: league)
            }
        }

        // Standard single-competition event (NBA, NFL, etc.)
        let shortName = (json["shortName"] as? String) ?? name
        let startDate = parseDate(dateString)

        let competition = competitions?.first

        // Use event-level status for state (live/scheduled/final) since a
        // tournament can be live even when a single round/session has
        // completed. But fall back to the competition-level status text for
        // the display detail, since some sports (golf) leave the event-level
        // detail blank while the competition has "Round 1 - Play Complete".
        let eventStatusType = (json["status"] as? [String: Any])?["type"] as? [String: Any]
        let compStatusType = (competition?["status"] as? [String: Any])?["type"] as? [String: Any]
        let eventShortDetail = eventStatusType?["shortDetail"] as? String
        let eventDetail = eventStatusType?["detail"] as? String
        let compShortDetail = compStatusType?["shortDetail"] as? String
        let compDetail = compStatusType?["detail"] as? String
        let bestShortDetail = (eventShortDetail?.isEmpty == false ? eventShortDetail : compShortDetail)
        let bestDetail = (eventDetail?.isEmpty == false ? eventDetail : compDetail)

        // Build a merged status type dict so parseStatus sees the event's
        // state but the richer detail string.
        var mergedStatus: [String: Any] = eventStatusType ?? [:]
        if let bestShortDetail { mergedStatus["shortDetail"] = bestShortDetail }
        if let bestDetail { mergedStatus["detail"] = bestDetail }
        let status = parseStatus(mergedStatus)

        let competitors = competition?["competitors"] as? [[String: Any]]
        let (home, away) = parseTeams(competitors)

        let broadcasts = parseBroadcasts(competition)

        let venueJSON = (competition?["venue"] as? [String: Any])
            ?? (json["venue"] as? [String: Any])
        let venue = venueJSON?["fullName"] as? String

        let detail = bestShortDetail ?? bestDetail

        // Leader (golf-style events with many athlete competitors and no
        // home/away distinction — first by `order` holds the lead).
        let leader: LeaderInfo? = {
            guard home == nil, away == nil,
                  let comps = competitors, comps.count > 1 else { return nil }
            let sorted = comps.sorted { (a, b) in
                let ao = a["order"] as? Int ?? Int.max
                let bo = b["order"] as? Int ?? Int.max
                return ao < bo
            }
            guard let first = sorted.first,
                  let athlete = first["athlete"] as? [String: Any],
                  let name = (athlete["displayName"] as? String)
                    ?? (athlete["shortName"] as? String),
                  let score = first["score"] as? String, !score.isEmpty else {
                return nil
            }
            return LeaderInfo(name: name, score: score)
        }()

        return [SportEvent(
            id: "\(league.id)_\(id)",
            sport: league.sport,
            league: league,
            title: name,
            shortTitle: shortName,
            homeTeam: home,
            awayTeam: away,
            startDate: startDate,
            status: status,
            broadcast: broadcasts,
            venue: venue,
            detail: detail,
            tournamentName: nil,
            leader: leader
        )]
    }

    // MARK: - Tournament expansion (tennis / golf groupings)

    /// Expand `groupings[].competitions[]` into individual SportEvents.
    /// Only expands the first grouping (e.g. "Men's Singles") to avoid
    /// flooding with doubles matches. Filters out completed matches from
    /// previous days to keep the list manageable.
    private func expandGroupings(
        _ groupings: [[String: Any]],
        eventID: String,
        tournamentName: String,
        league: League
    ) -> [SportEvent] {
        // Take the first grouping (singles for tennis, main draw for golf)
        guard let primary = groupings.first,
              let comps = primary["competitions"] as? [[String: Any]] else {
            return []
        }

        let startOfToday = Calendar.current.startOfDay(for: Date())

        return comps.compactMap { comp -> SportEvent? in
            let state = (comp["status"] as? [String: Any])?["type"] as? [String: Any]
            let stateStr = state?["state"] as? String ?? "pre"
            let compDate = (comp["date"] as? String) ?? (comp["startDate"] as? String)

            // Skip finished matches from before today
            if stateStr == "post", let compDate {
                let date = parseDate(compDate)
                if date < startOfToday { return nil }
            }

            // Skip TBD vs TBD placeholders for future rounds
            let competitors = comp["competitors"] as? [[String: Any]] ?? []
            if stateStr == "pre" && competitors.count == 2 {
                let allTBD = competitors.allSatisfy { c in
                    let name = (c["athlete"] as? [String: Any])?["displayName"] as? String
                    return name == nil || name == "TBD"
                }
                if allTBD { return nil }
            }

            return parseTournamentMatch(comp, eventID: eventID, tournamentName: tournamentName, league: league)
        }
    }

    /// Parse a single match from a tournament grouping (tennis match, golf round).
    private func parseTournamentMatch(
        _ comp: [String: Any],
        eventID: String,
        tournamentName: String,
        league: League
    ) -> SportEvent? {
        let compID = (comp["id"] as? String) ?? UUID().uuidString

        // Status
        let statusJSON = comp["status"] as? [String: Any]
        let statusType = statusJSON?["type"] as? [String: Any]
        let status = parseStatus(statusType)

        // Date
        let dateString = (comp["date"] as? String) ?? (comp["startDate"] as? String)
        let startDate: Date
        if let dateString {
            startDate = parseDate(dateString)
        } else {
            startDate = .distantPast
        }

        // Competitors — tennis uses `athlete` instead of `team`
        let competitors = comp["competitors"] as? [[String: Any]]
        let (home, away) = parseAthletes(competitors)

        // Title
        let title: String
        let shortTitle: String
        if let away, let home {
            title = "\(away.displayName) vs \(home.displayName)"
            shortTitle = "\(away.abbreviation) vs \(home.abbreviation)"
        } else {
            title = tournamentName
            shortTitle = tournamentName
        }

        let broadcasts = parseBroadcasts(comp)

        let venueJSON = comp["venue"] as? [String: Any]
        let venue = venueJSON?["fullName"] as? String

        let detail = (statusType?["shortDetail"] as? String)
            ?? (statusType?["detail"] as? String)

        return SportEvent(
            id: "\(league.id)_\(eventID)_\(compID)",
            sport: league.sport,
            league: league,
            title: title,
            shortTitle: shortTitle,
            homeTeam: home,
            awayTeam: away,
            startDate: startDate,
            status: status,
            broadcast: broadcasts,
            venue: venue,
            detail: detail,
            tournamentName: tournamentName,
            leader: nil
        )
    }

    // MARK: - Golf expansion (per-round events)

    /// Enumerate the tournaments in a golf scoreboard response and fan out to
    /// the leaderboard endpoint for each, so we can surface per-round start
    /// times and round-level completion state.
    private func expandGolfScoreboard(data: Data, league: League) async -> [SportEvent] {
        guard !Task.isCancelled else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else {
            return []
        }

        let ids: [String] = events.compactMap { $0["id"] as? String }

        var all: [SportEvent] = []
        await withTaskGroup(of: [SportEvent].self) { group in
            for id in ids {
                guard !Task.isCancelled else { break }
                group.addTask { [self] in
                    await self.fetchGolfEventRounds(eventID: id, league: league)
                }
            }
            for await rounds in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                all.append(contentsOf: rounds)
            }
        }
        return Task.isCancelled ? [] : all
    }

    /// Fetch the leaderboard for a single golf event and expand it into one
    /// SportEvent per round.
    private func fetchGolfEventRounds(eventID: String, league: League) async -> [SportEvent] {
        guard !Task.isCancelled else { return [] }
        guard let url = URL(string: "https://site.web.api.espn.com/apis/site/v2/sports/golf/leaderboard?league=\(league.slug)&event=\(eventID)") else {
            return []
        }
        do {
            let (data, response) = try await fetchData(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let events = json["events"] as? [[String: Any]],
                  let ev = events.first else {
                return []
            }
            return buildGolfRounds(from: ev, league: league)
        } catch {
            guard !Task.isCancelled else { return [] }
            AppLog.sports.error("ESPN leaderboard fetch failed eventID=\(eventID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func buildGolfRounds(from ev: [String: Any], league: League) -> [SportEvent] {
        guard let id = ev["id"] as? String,
              let name = ev["name"] as? String else { return [] }
        let shortName = (ev["shortName"] as? String) ?? name

        let comp = (ev["competitions"] as? [[String: Any]])?.first
        let competitors = (comp?["competitors"] as? [[String: Any]]) ?? []
        let compStatus = comp?["status"] as? [String: Any]
        let compStatusType = compStatus?["type"] as? [String: Any]
        let compState = (compStatusType?["state"] as? String) ?? "pre"
        let compPeriod = (compStatus?["period"] as? Int) ?? 1

        let broadcasts = parseBroadcasts(comp)
        let courses = ev["courses"] as? [[String: Any]]
        let venue = (courses?.first?["name"] as? String)
            ?? ((comp?["venue"] as? [String: Any])?["fullName"] as? String)

        // Aggregate per-round tee times and scoring progress across all
        // competitors. Earliest tee time = round start; we also track how
        // many competitors have a posted score to detect an in-progress round
        // that hasn't moved ESPN's overall status forward yet.
        struct RoundAgg { var earliestTee: Date?; var scored: Int; var total: Int }
        var byPeriod: [Int: RoundAgg] = [:]
        var maxPeriod = 0
        for c in competitors {
            let ls = c["linescores"] as? [[String: Any]] ?? []
            for line in ls {
                guard let period = line["period"] as? Int else { continue }
                maxPeriod = max(maxPeriod, period)
                var agg = byPeriod[period] ?? RoundAgg(earliestTee: nil, scored: 0, total: 0)
                agg.total += 1
                if line["value"] != nil { agg.scored += 1 }
                if let teeStr = line["teeTime"] as? String {
                    let t = parseDate(teeStr)
                    if let cur = agg.earliestTee {
                        agg.earliestTee = min(cur, t)
                    } else {
                        agg.earliestTee = t
                    }
                }
                byPeriod[period] = agg
            }
        }

        guard maxPeriod > 0 else { return [] }

        let leader = extractGolfLeader(competitors: competitors)
        let fallbackStart = parseDate((ev["date"] as? String) ?? "")

        var out: [SportEvent] = []
        for period in 1...maxPeriod {
            let agg = byPeriod[period] ?? RoundAgg(earliestTee: nil, scored: 0, total: 0)
            let startDate = agg.earliestTee
                ?? fallbackStart.addingTimeInterval(Double(period - 1) * 86400)

            let status: EventStatus
            let detailText: String
            if period < compPeriod {
                status = .final_(detail: "Round \(period) Complete")
                detailText = "Round \(period) Complete"
            } else if period == compPeriod {
                switch compState {
                case "in":
                    status = .live(detail: "R\(period) in progress")
                    detailText = "Round \(period) in progress"
                case "post":
                    status = .final_(detail: "R\(period) Play Complete")
                    detailText = "Round \(period) Play Complete"
                default:
                    status = .scheduled
                    detailText = "Round \(period)"
                }
            } else {
                status = .scheduled
                detailText = "Round \(period)"
            }

            let roundLeader: LeaderInfo? = (status.isLive || status.isFinished) ? leader : nil

            out.append(SportEvent(
                id: "\(league.id)_\(id)_r\(period)",
                sport: league.sport,
                league: league,
                title: "\(name) — Round \(period)",
                shortTitle: "R\(period) \(shortName)",
                homeTeam: nil,
                awayTeam: nil,
                startDate: startDate,
                status: status,
                broadcast: broadcasts,
                venue: venue,
                detail: detailText,
                tournamentName: name,
                leader: roundLeader
            ))
        }
        return out
    }

    /// Leader across the field — first competitor by sort order with a display
    /// score. Leaderboard responses wrap score as `{ displayValue, value }`.
    private func extractGolfLeader(competitors: [[String: Any]]) -> LeaderInfo? {
        let sorted = competitors.sorted { a, b in
            let ao = (a["sortOrder"] as? Int) ?? (a["order"] as? Int) ?? Int.max
            let bo = (b["sortOrder"] as? Int) ?? (b["order"] as? Int) ?? Int.max
            return ao < bo
        }
        guard let first = sorted.first,
              let athlete = first["athlete"] as? [String: Any],
              let name = (athlete["displayName"] as? String)
                ?? (athlete["shortName"] as? String) else {
            return nil
        }
        let scoreDisplay: String? = {
            if let dict = first["score"] as? [String: Any],
               let dv = dict["displayValue"] as? String, !dv.isEmpty { return dv }
            if let str = first["score"] as? String, !str.isEmpty { return str }
            return nil
        }()
        guard let score = scoreDisplay else { return nil }
        return LeaderInfo(name: name, score: score)
    }

    // MARK: - Session expansion (F1 / NASCAR)

    /// Parse a session competition (FP1, Qualifying, Race) from an F1/NASCAR event.
    private func parseSessionCompetition(
        _ comp: [String: Any],
        eventID: String,
        tournamentName: String,
        league: League
    ) -> SportEvent? {
        let compID = (comp["id"] as? String) ?? UUID().uuidString

        // Session type (FP1, FP2, Qual, Race, etc.)
        let sessionType = comp["type"] as? [String: Any]
        let sessionAbbr = (sessionType?["abbreviation"] as? String) ?? ""

        // Status
        let statusJSON = comp["status"] as? [String: Any]
        let statusType = statusJSON?["type"] as? [String: Any]
        let status = parseStatus(statusType)

        // Date
        let dateString = (comp["date"] as? String) ?? (comp["startDate"] as? String)
        let startDate: Date
        if let dateString {
            startDate = parseDate(dateString)
        } else {
            startDate = .distantPast
        }

        // Title: "Gulf Air Bahrain GP — Race"
        let title = sessionAbbr.isEmpty ? tournamentName : "\(tournamentName) — \(sessionAbbr)"
        let shortTitle = title

        let broadcasts = parseBroadcasts(comp)

        let venueJSON = comp["venue"] as? [String: Any]
        let venue = venueJSON?["fullName"] as? String

        let detail = (statusType?["shortDetail"] as? String)
            ?? (statusType?["detail"] as? String)

        return SportEvent(
            id: "\(league.id)_\(eventID)_\(compID)",
            sport: league.sport,
            league: league,
            title: title,
            shortTitle: shortTitle,
            homeTeam: nil,
            awayTeam: nil,
            startDate: startDate,
            status: status,
            broadcast: broadcasts,
            venue: venue,
            detail: detail,
            tournamentName: tournamentName,
            leader: nil
        )
    }

    private func parseStatus(_ type: [String: Any]?) -> EventStatus {
        guard let state = type?["state"] as? String else { return .scheduled }
        let detail = type?["shortDetail"] as? String

        switch state {
        case "in":
            if let d = detail?.lowercased(), d.contains("halftime") || d.contains("half") {
                return .halftime
            }
            return .live(detail: detail)
        case "post":
            return .final_(detail: detail)
        case "pre":
            if let d = detail?.lowercased() {
                if d.contains("postponed") { return .postponed }
                if d.contains("delayed") { return .delayed }
                if d.contains("canceled") || d.contains("cancelled") { return .canceled }
            }
            return .scheduled
        default:
            return .scheduled
        }
    }

    private func parseTeams(_ competitors: [[String: Any]]?) -> (home: TeamInfo?, away: TeamInfo?) {
        guard let competitors else { return (nil, nil) }
        var home: TeamInfo?
        var away: TeamInfo?

        for competitor in competitors {
            let team = competitor["team"] as? [String: Any]
            let info = TeamInfo(
                name: (team?["shortDisplayName"] as? String) ?? (team?["name"] as? String) ?? "TBD",
                abbreviation: (team?["abbreviation"] as? String) ?? "",
                displayName: (team?["displayName"] as? String) ?? (team?["name"] as? String) ?? "TBD",
                score: competitor["score"] as? String,
                logoURL: (team?["logo"] as? String).flatMap(URL.init(string:)),
                record: parseRecord(competitor)
            )
            let homeAway = (competitor["homeAway"] as? String) ?? ""
            if homeAway == "home" {
                home = info
            } else {
                away = info
            }
        }
        return (home, away)
    }

    /// Parse athlete-based competitors (tennis, golf) where data is under
    /// `competitor.athlete` instead of `competitor.team`.
    private func parseAthletes(_ competitors: [[String: Any]]?) -> (home: TeamInfo?, away: TeamInfo?) {
        guard let competitors else { return (nil, nil) }
        var home: TeamInfo?
        var away: TeamInfo?

        for competitor in competitors {
            let athlete = competitor["athlete"] as? [String: Any]
            let flag = athlete?["flag"] as? [String: Any]

            // Build set score string from linescores: "6-4 4-6 6-4"
            let score: String?
            if let linescores = competitor["linescores"] as? [[String: Any]], !linescores.isEmpty {
                score = linescores.map { set in
                    let val = set["value"] as? Double ?? 0
                    return String(Int(val))
                }.joined(separator: " ")
            } else {
                score = competitor["score"] as? String
            }

            let displayName = (athlete?["displayName"] as? String)
                ?? (athlete?["fullName"] as? String) ?? "TBD"
            let shortName = (athlete?["shortName"] as? String) ?? displayName

            let info = TeamInfo(
                name: shortName,
                abbreviation: shortName,
                displayName: displayName,
                score: score,
                logoURL: (flag?["href"] as? String).flatMap(URL.init(string:)),
                record: nil
            )

            let homeAway = (competitor["homeAway"] as? String) ?? ""
            if homeAway == "home" {
                home = info
            } else {
                away = info
            }
        }
        return (home, away)
    }

    private func parseRecord(_ competitor: [String: Any]) -> String? {
        guard let records = competitor["records"] as? [[String: Any]],
              let overall = records.first(where: { ($0["name"] as? String) == "overall" || ($0["type"] as? String) == "total" }),
              let summary = overall["summary"] as? String else {
            return nil
        }
        return summary
    }

    private func parseBroadcasts(_ competition: [String: Any]?) -> [String] {
        // Try geoBroadcasts first (more structured)
        if let geo = competition?["geoBroadcasts"] as? [[String: Any]] {
            let names = geo.compactMap { broadcast -> String? in
                let media = broadcast["media"] as? [String: Any]
                return media?["shortName"] as? String
            }
            if !names.isEmpty { return Array(Set(names)) }
        }

        // Fall back to broadcasts array
        if let broadcasts = competition?["broadcasts"] as? [[String: Any]] {
            let names = broadcasts.flatMap { broadcast -> [String] in
                (broadcast["names"] as? [String]) ?? []
            }
            if !names.isEmpty { return Array(Set(names)) }
        }

        return []
    }

    // ISO8601DateFormatter is not Sendable. Keep these mutable formatter
    // objects isolated to this client instead of sharing across actors.
    private let dateFormatters: [ISO8601DateFormatter] = {
        // ESPN returns dates like "2026-04-15T23:30Z" (no seconds) or
        // "2026-04-15T23:30:00Z" (with seconds). Build formatters for both.
        let withSeconds = ISO8601DateFormatter()
        withSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]

        // No-seconds variant: "2026-04-15T23:30Z"
        let noSeconds = ISO8601DateFormatter()
        noSeconds.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate,
                                   .withTime, .withColonSeparatorInTime,
                                   .withTimeZone]

        return [withSeconds, standard, noSeconds]
    }()

    private func parseDate(_ string: String) -> Date {
        for formatter in dateFormatters {
            if let date = formatter.date(from: string) { return date }
        }

        // Fallback: use DateFormatter with explicit format
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mmZ"] {
            df.dateFormat = format
            if let date = df.date(from: string) { return date }
        }

        return .distantPast
    }

    /// The league budget alone is insufficient: cricket expands into daily
    /// requests and golf into leaderboard requests. Apply one budget at the
    /// actual transport boundary across all nested work and refreshes.
    private func fetchData(from url: URL) async throws -> (Data, URLResponse) {
        let queuedAt = ContinuousClock.now
        try await requestLimiter.acquire()
        let requestStarted = ContinuousClock.now
        do {
            try Task.checkCancellation()
            let result = try await session.data(from: url)
            try Task.checkCancellation()
            await requestLimiter.release()
            AppLog.sports.debug("ESPN HTTP completed queueMs=\(AppLog.elapsedMilliseconds(since: queuedAt, now: requestStarted), privacy: .public) requestMs=\(AppLog.elapsedMilliseconds(since: requestStarted), privacy: .public) bytes=\(result.0.count, privacy: .public)")
            return result
        } catch {
            await requestLimiter.release()
            throw error
        }
    }
}

/// Suspended requests hold no URLSession task. Cancellation removes queued
/// waiters immediately, so a superseded refresh cannot drain its entire queue.
private actor ESPNRequestLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if active < limit {
                    active += 1
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            // Transfer this permit without momentarily opening an extra slot.
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
