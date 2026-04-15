import Foundation

/// Fetches live and upcoming sporting events from ESPN's public scoreboard API
/// and parses them into canonical `SportEvent` models.
actor ESPNClient {
    private let session: URLSession
    private let baseURL = "https://site.api.espn.com/apis/site/v2/sports"
    private let lookbackDays = 1
    private let futureDays = 7
    private let requestLimit = 250

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public

    /// Fetch events for all configured leagues concurrently.
    func fetchAllEvents() async -> [SportEvent] {
        await withTaskGroup(of: [SportEvent].self) { group in
            for league in League.all {
                group.addTask { [self] in
                    await self.fetchEvents(for: league)
                }
            }
            var all: [SportEvent] = []
            for await events in group {
                all.append(contentsOf: events)
            }
            return all
        }
    }

    /// Fetch events for a single league.
    /// Uses a 1-day lookback plus a 7-day forward range so users in time zones
    /// ahead of the league still see games that are live on the league's
    /// "yesterday" (e.g. MLB overnight in Australia). Cricket endpoints only
    /// support single-date queries, so we fan out to individual days.
    func fetchEvents(for league: League) async -> [SportEvent] {
        if league.sport == .cricket {
            return await fetchCricketEvents(for: league)
        }

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        df.timeZone = .current
        let start = df.string(from: Date().addingTimeInterval(TimeInterval(-lookbackDays * 86400)))
        let end = df.string(from: Date().addingTimeInterval(TimeInterval(futureDays * 86400)))
        let dateRange = "\(start)-\(end)"

        guard let url = URL(string: "\(baseURL)/\(league.espnPath)/scoreboard?dates=\(dateRange)&limit=\(requestLimit)") else {
            return []
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return []
            }
            return filterStaleLookbackEvents(parse(data: data, league: league))
        } catch {
            print("[ESPN] Failed to fetch \(league.shortName): \(error.localizedDescription)")
            return []
        }
    }

    /// Cricket's ESPN endpoint only supports single-date queries, so fetch
    /// yesterday plus the next 7 days concurrently then parse on the actor.
    private func fetchCricketEvents(for league: League) async -> [SportEvent] {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        df.timeZone = .current

        let limit = requestLimit

        // Fetch raw data concurrently (network I/O doesn't need actor isolation)
        let fetched = await withTaskGroup(of: Data?.self) { group in
            for dayOffset in (-lookbackDays)...futureDays {
                let date = Date().addingTimeInterval(Double(dayOffset) * 86400)
                let dateStr = df.string(from: date)
                group.addTask { [session, baseURL, limit] in
                    guard let url = URL(string: "\(baseURL)/\(league.espnPath)/scoreboard?dates=\(dateStr)&limit=\(limit)") else {
                        return nil
                    }
                    guard let (data, response) = try? await session.data(from: url),
                          let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        return nil
                    }
                    return data
                }
            }
            var results: [Data] = []
            for await data in group {
                if let data { results.append(data) }
            }
            return results
        }

        // Parse on the actor
        var all: [SportEvent] = []
        for data in fetched {
            all.append(contentsOf: parse(data: data, league: league))
        }
        all = filterStaleLookbackEvents(all)
        // Deduplicate by event ID (same match can appear on adjacent days)
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
    }

    /// We query one day back so time zones ahead of the league can still see
    /// genuinely live overnight events. But we do not want to surface stale
    /// finished fixtures from that lookback day.
    private func filterStaleLookbackEvents(_ events: [SportEvent]) -> [SportEvent] {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return events.filter { event in
            event.startDate >= startOfToday || event.status.isLive
        }
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

        let statusJSON = json["status"] as? [String: Any]
        let statusType = statusJSON?["type"] as? [String: Any]
        let status = parseStatus(statusType)

        let competition = competitions?.first

        let competitors = competition?["competitors"] as? [[String: Any]]
        let (home, away) = parseTeams(competitors)

        let broadcasts = parseBroadcasts(competition)

        let venueJSON = competition?["venue"] as? [String: Any]
        let venue = venueJSON?["fullName"] as? String

        let detail = (statusType?["shortDetail"] as? String)
            ?? (statusType?["detail"] as? String)

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
            tournamentName: nil
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
            tournamentName: tournamentName
        )
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
            tournamentName: tournamentName
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

    private static let dateFormatters: [ISO8601DateFormatter] = {
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
        for formatter in Self.dateFormatters {
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
}
