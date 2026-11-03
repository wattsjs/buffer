import Foundation

// ESPN scoreboard/leaderboard parsing written once over a minimal JSON
// object interface. Two representations implement it: the one-pass byte
// tape (`ConnectorJSONTape`, the normal path) and JSONSerialization
// dictionaries (the fallback whenever the tape declines), whose accessors
// are exactly the `as?` casts the parser always used.

/// Read access to one JSON object, with JSONSerialization `as?` semantics.
nonisolated protocol ESPNJSONObject {
    func string(_ key: StaticString) throws -> String?
    func int(_ key: StaticString) throws -> Int?
    func double(_ key: StaticString) throws -> Double?
    func object(_ key: StaticString) throws -> Self?
    /// `as? [[String: Any]]`: nil unless every element is an object.
    func objects(_ key: StaticString) throws -> [Self]?
    /// `as? [String]`: nil unless every element is a string.
    func strings(_ key: StaticString) throws -> [String]?
    /// `dict[key] != nil` (present, including JSON null).
    func has(_ key: StaticString) throws -> Bool
}

/// The JSONSerialization representation.
nonisolated struct ESPNDictionaryObject: ESPNJSONObject {
    let dictionary: [String: Any]
    @inline(__always) private func value(_ key: StaticString) -> Any? { dictionary[key.description] }
    func string(_ key: StaticString) -> String? { value(key) as? String }
    func int(_ key: StaticString) -> Int? { value(key) as? Int }
    func double(_ key: StaticString) -> Double? { value(key) as? Double }
    func object(_ key: StaticString) -> ESPNDictionaryObject? { (value(key) as? [String: Any]).map(ESPNDictionaryObject.init) }
    func objects(_ key: StaticString) -> [ESPNDictionaryObject]? { (value(key) as? [[String: Any]])?.map(ESPNDictionaryObject.init) }
    func strings(_ key: StaticString) -> [String]? { value(key) as? [String] }
    func has(_ key: StaticString) -> Bool { value(key) != nil }
}

/// The byte-tape representation.
nonisolated struct ESPNTapeObject: ESPNJSONObject {
    let tape: ConnectorJSONTape
    let node: Int32

    func string(_ key: StaticString) -> String? { tape.member(node, key).flatMap { tape.string($0) } }
    func int(_ key: StaticString) throws -> Int? {
        guard let member = tape.member(node, key) else { return nil }
        return try tape.int(member)
    }
    func double(_ key: StaticString) throws -> Double? {
        guard let member = tape.member(node, key) else { return nil }
        return try tape.double(member)
    }
    func object(_ key: StaticString) -> ESPNTapeObject? {
        guard let member = tape.member(node, key), tape.kind[Int(member)] == .object else { return nil }
        return ESPNTapeObject(tape: tape, node: member)
    }
    func objects(_ key: StaticString) -> [ESPNTapeObject]? {
        guard let member = tape.member(node, key), tape.kind[Int(member)] == .array else { return nil }
        let children = tape.children(member)
        for child in children where tape.kind[Int(child)] != .object { return nil }
        return children.map { ESPNTapeObject(tape: tape, node: $0) }
    }
    func strings(_ key: StaticString) -> [String]? {
        guard let member = tape.member(node, key), tape.kind[Int(member)] == .array else { return nil }
        var result: [String] = []
        for child in tape.children(member) {
            guard let string = tape.string(child) else { return nil }
            result.append(string)
        }
        return result
    }
    func has(_ key: StaticString) -> Bool { tape.member(node, key) != nil }
}

/// One validated scoreboard/leaderboard response.
nonisolated struct ESPNDocument: Sendable {
    let data: Data
    /// Nil when the tape declined; the JSONSerialization path is used then.
    let tape: ConnectorJSONTape?

    init(_ data: Data) {
        self.data = data
        tape = try? ConnectorJSONTape(data)
    }
}

/// Scoreboard parsing over either representation. `parseDate` is the
/// client's formatter-backed parser for strings the byte parser declines.
nonisolated struct ESPNScoreboardParser {
    struct RoundAgg { var earliestTee: Date?; var scored: Int; var total: Int }
    let parseDate: (String) -> Date
    static let tournamentSports: Set<Sport> = [.tennis, .golf, .motorsport]

    // MARK: Document entry points

    /// `json["events"] is [[String: Any]]`.
    func isValidScoreboard(_ document: ESPNDocument) -> Bool {
        (try? withEvents(document) { _ in true }) ?? false
    }

    /// `(json["events"] as? [[String: Any]])?.count`.
    func eventCount(_ document: ESPNDocument) -> Int? {
        try? withEvents(document) { $0 }
    }

    func parse(_ document: ESPNDocument, league: League) -> [SportEvent] {
        if let tape = document.tape {
            do {
                if let events = ESPNTapeObject(tape: tape, node: ConnectorJSONTape.root).rootEvents() {
                    return try events.flatMap { try parseEvent($0, league: league) }
                }
                return []
            } catch {}
        }
        guard let events = Self.dictionaryEvents(document.data) else { return [] }
        return events.flatMap { (try? parseEvent($0, league: league)) ?? [] }
    }

    func golfEventIDs(_ document: ESPNDocument) -> [String] {
        if let tape = document.tape {
            return (ESPNTapeObject(tape: tape, node: ConnectorJSONTape.root).rootEvents() ?? []).compactMap { $0.string("id") }
        }
        return (Self.dictionaryEvents(document.data) ?? []).compactMap { $0.string("id") }
    }

    func golfRounds(_ document: ESPNDocument, league: League) -> [SportEvent] {
        if let tape = document.tape {
            do {
                guard let event = ESPNTapeObject(tape: tape, node: ConnectorJSONTape.root).rootEvents()?.first else { return [] }
                return try buildGolfRounds(from: event, league: league)
            } catch {}
        }
        guard let event = Self.dictionaryEvents(document.data)?.first else { return [] }
        return (try? buildGolfRounds(from: event, league: league)) ?? []
    }

    private func withEvents<R>(_ document: ESPNDocument, _ body: (Int) -> R) throws -> R? {
        if let tape = document.tape {
            guard let events = ESPNTapeObject(tape: tape, node: ConnectorJSONTape.root).rootEvents() else { return nil }
            return body(events.count)
        }
        guard let events = Self.dictionaryEvents(document.data) else { return nil }
        return body(events.count)
    }

    static func dictionaryEvents(_ data: Data) -> [ESPNDictionaryObject]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else { return nil }
        return events.map(ESPNDictionaryObject.init)
    }

    // MARK: Events

    func parseEvent<J: ESPNJSONObject>(_ json: J, league: League) throws -> [SportEvent] {
        guard let id = try json.string("id"),
              let name = try json.string("name"),
              let dateString = try json.string("date") else {
            return []
        }

        // Tennis / golf use groupings[].competitions[] for individual matches
        let groupings = try json.objects("groupings")
        if Self.tournamentSports.contains(league.sport), let groupings, !groupings.isEmpty {
            return try expandGroupings(groupings, eventID: id, tournamentName: name, league: league)
        }

        // F1 / NASCAR use competitions[] with session types (FP1, Qual, Race)
        let competitions = try json.objects("competitions")
        if Self.tournamentSports.contains(league.sport), let competitions, competitions.count > 1 {
            return try competitions.compactMap { try parseSessionCompetition($0, eventID: id, tournamentName: name, league: league) }
        }

        // Standard single-competition event (NBA, NFL, etc.)
        let shortName = try json.string("shortName") ?? name
        let startDate = parseDate(dateString)
        let competition = competitions?.first

        // Event-level state; competition-level detail when the event's is blank.
        let eventStatusType = try json.object("status")?.object("type")
        let compStatusType = try competition?.object("status")?.object("type")
        let eventShortDetail = try eventStatusType?.string("shortDetail")
        let eventDetail = try eventStatusType?.string("detail")
        let compShortDetail = try compStatusType?.string("shortDetail")
        let compDetail = try compStatusType?.string("detail")
        let bestShortDetail = (eventShortDetail?.isEmpty == false ? eventShortDetail : compShortDetail)
        let bestDetail = (eventDetail?.isEmpty == false ? eventDetail : compDetail)
        // The merged status keeps the event's state and its own shortDetail
        // unless a better one was found.
        let status = Self.parseStatus(state: try eventStatusType?.string("state"), shortDetail: bestShortDetail ?? eventShortDetail)

        let competitors = try competition?.objects("competitors")
        let (home, away) = try parseTeams(competitors)
        let broadcasts = try parseBroadcasts(competition)
        let venueJSON = try competition?.object("venue") ?? json.object("venue")
        let venue = try venueJSON?.string("fullName")
        let detail = bestShortDetail ?? bestDetail

        // Leader (golf-style events with many athlete competitors and no
        // home/away distinction — first by `order` holds the lead).
        var leader: LeaderInfo?
        if home == nil, away == nil, let comps = competitors, comps.count > 1 {
            let orders = try comps.map { try $0.int("order") ?? Int.max }
            let sorted = comps.indices.sorted { orders[$0] < orders[$1] }
            if let first = sorted.first.map({ comps[$0] }),
               let athlete = try first.object("athlete"),
               let name = try athlete.string("displayName") ?? athlete.string("shortName"),
               let score = try first.string("score"), !score.isEmpty {
                leader = LeaderInfo(name: name, score: score)
            }
        }

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

    // MARK: Tournament expansion (tennis / golf groupings)

    /// Expands the first grouping (singles / main draw), dropping matches
    /// finished before today and TBD-vs-TBD placeholders.
    func expandGroupings<J: ESPNJSONObject>(_ groupings: [J], eventID: String, tournamentName: String,
                                            league: League) throws -> [SportEvent] {
        guard let primary = groupings.first, let comps = try primary.objects("competitions") else { return [] }
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return try comps.compactMap { comp -> SportEvent? in
            let state = try comp.object("status")?.object("type")
            let stateStr = try state?.string("state") ?? "pre"
            let compDate = try comp.string("date") ?? comp.string("startDate")
            if stateStr == "post", let compDate {
                if parseDate(compDate) < startOfToday { return nil }
            }
            let competitors = try comp.objects("competitors") ?? []
            if stateStr == "pre" && competitors.count == 2 {
                let allTBD = try competitors.allSatisfy { c in
                    let name = try c.object("athlete")?.string("displayName")
                    return name == nil || name == "TBD"
                }
                if allTBD { return nil }
            }
            return try parseTournamentMatch(comp, eventID: eventID, tournamentName: tournamentName, league: league)
        }
    }

    func parseTournamentMatch<J: ESPNJSONObject>(_ comp: J, eventID: String, tournamentName: String,
                                                 league: League) throws -> SportEvent? {
        let compID = try comp.string("id") ?? UUID().uuidString
        let statusType = try comp.object("status")?.object("type")
        let status = Self.parseStatus(state: try statusType?.string("state"), shortDetail: try statusType?.string("shortDetail"))
        let dateString = try comp.string("date") ?? comp.string("startDate")
        let startDate = dateString.map(parseDate) ?? .distantPast
        let (home, away) = try parseAthletes(comp.objects("competitors"))
        let title: String
        let shortTitle: String
        if let away, let home {
            title = "\(away.displayName) vs \(home.displayName)"
            shortTitle = "\(away.abbreviation) vs \(home.abbreviation)"
        } else {
            title = tournamentName
            shortTitle = tournamentName
        }
        let venue = try comp.object("venue")?.string("fullName")
        let detail = try statusType?.string("shortDetail") ?? statusType?.string("detail")
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
            broadcast: try parseBroadcasts(comp),
            venue: venue,
            detail: detail,
            tournamentName: tournamentName,
            leader: nil
        )
    }

    // MARK: Golf rounds (leaderboard)

    /// One SportEvent per round from a leaderboard event.
    func buildGolfRounds<J: ESPNJSONObject>(from ev: J, league: League) throws -> [SportEvent] {
        guard let id = try ev.string("id"), let name = try ev.string("name") else { return [] }
        let shortName = try ev.string("shortName") ?? name
        let comp = try ev.objects("competitions")?.first
        let competitors = try comp?.objects("competitors") ?? []
        let compStatus = try comp?.object("status")
        let compStatusType = try compStatus?.object("type")
        let compState = try compStatusType?.string("state") ?? "pre"
        let compPeriod = try compStatus?.int("period") ?? 1
        let broadcasts = try parseBroadcasts(comp)
        let courses = try ev.objects("courses")
        let venue = try courses?.first?.string("name") ?? comp?.object("venue")?.string("fullName")

        // Earliest tee time per round = round start.
        var byPeriod: [Int: RoundAgg] = [:]
        var maxPeriod = 0
        for c in competitors {
            for line in try c.objects("linescores") ?? [] {
                guard let period = try line.int("period") else { continue }
                maxPeriod = max(maxPeriod, period)
                var agg = byPeriod[period] ?? RoundAgg(earliestTee: nil, scored: 0, total: 0)
                agg.total += 1
                if try line.has("value") { agg.scored += 1 }
                if let teeStr = try line.string("teeTime") {
                    let t = parseDate(teeStr)
                    if let cur = agg.earliestTee { agg.earliestTee = min(cur, t) } else { agg.earliestTee = t }
                }
                byPeriod[period] = agg
            }
        }
        guard maxPeriod > 0 else { return [] }

        let leader = try extractGolfLeader(competitors: competitors)
        let fallbackStart = parseDate(try ev.string("date") ?? "")

        var out: [SportEvent] = []
        for period in 1...maxPeriod {
            let agg = byPeriod[period] ?? RoundAgg(earliestTee: nil, scored: 0, total: 0)
            let startDate = agg.earliestTee ?? fallbackStart.addingTimeInterval(Double(period - 1) * 86400)
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

    /// First competitor by sort order with a display score.
    func extractGolfLeader<J: ESPNJSONObject>(competitors: [J]) throws -> LeaderInfo? {
        let orders = try competitors.map { try $0.int("sortOrder") ?? $0.int("order") ?? Int.max }
        let sorted = competitors.indices.sorted { orders[$0] < orders[$1] }
        guard let first = sorted.first.map({ competitors[$0] }),
              let athlete = try first.object("athlete"),
              let name = try athlete.string("displayName") ?? athlete.string("shortName") else {
            return nil
        }
        var score: String?
        if let dict = try first.object("score"), let dv = try dict.string("displayValue"), !dv.isEmpty {
            score = dv
        } else if let str = try first.string("score"), !str.isEmpty {
            score = str
        }
        guard let score else { return nil }
        return LeaderInfo(name: name, score: score)
    }

    // MARK: Session expansion (F1 / NASCAR)

    func parseSessionCompetition<J: ESPNJSONObject>(_ comp: J, eventID: String, tournamentName: String,
                                                    league: League) throws -> SportEvent? {
        let compID = try comp.string("id") ?? UUID().uuidString
        let sessionAbbr = try comp.object("type")?.string("abbreviation") ?? ""
        let statusType = try comp.object("status")?.object("type")
        let status = Self.parseStatus(state: try statusType?.string("state"), shortDetail: try statusType?.string("shortDetail"))
        let dateString = try comp.string("date") ?? comp.string("startDate")
        let startDate = dateString.map(parseDate) ?? .distantPast
        let title = sessionAbbr.isEmpty ? tournamentName : "\(tournamentName) — \(sessionAbbr)"
        let venue = try comp.object("venue")?.string("fullName")
        let detail = try statusType?.string("shortDetail") ?? statusType?.string("detail")
        return SportEvent(
            id: "\(league.id)_\(eventID)_\(compID)",
            sport: league.sport,
            league: league,
            title: title,
            shortTitle: title,
            homeTeam: nil,
            awayTeam: nil,
            startDate: startDate,
            status: status,
            broadcast: try parseBroadcasts(comp),
            venue: venue,
            detail: detail,
            tournamentName: tournamentName,
            leader: nil
        )
    }

    // MARK: Pieces

    static func parseStatus(state: String?, shortDetail detail: String?) -> EventStatus {
        guard let state else { return .scheduled }
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

    func parseTeams<J: ESPNJSONObject>(_ competitors: [J]?) throws -> (home: TeamInfo?, away: TeamInfo?) {
        guard let competitors else { return (nil, nil) }
        var home: TeamInfo?
        var away: TeamInfo?
        for competitor in competitors {
            let team = try competitor.object("team")
            let info = TeamInfo(
                name: try team?.string("shortDisplayName") ?? team?.string("name") ?? "TBD",
                abbreviation: try team?.string("abbreviation") ?? "",
                displayName: try team?.string("displayName") ?? team?.string("name") ?? "TBD",
                score: try competitor.string("score"),
                logoURL: try team?.string("logo").flatMap(URL.init(string:)),
                record: try parseRecord(competitor)
            )
            if (try competitor.string("homeAway") ?? "") == "home" {
                home = info
            } else {
                away = info
            }
        }
        return (home, away)
    }

    /// Athlete-based competitors (tennis, golf): data under `athlete`.
    func parseAthletes<J: ESPNJSONObject>(_ competitors: [J]?) throws -> (home: TeamInfo?, away: TeamInfo?) {
        guard let competitors else { return (nil, nil) }
        var home: TeamInfo?
        var away: TeamInfo?
        for competitor in competitors {
            let athlete = try competitor.object("athlete")
            let flag = try athlete?.object("flag")
            // Set score string from linescores: "6-4 4-6 6-4"
            let score: String?
            if let linescores = try competitor.objects("linescores"), !linescores.isEmpty {
                score = try linescores.map { set in
                    let value = try set.double("value") ?? 0
                    // Int(_:) traps outside its range; leave that to the reference path.
                    guard value.isFinite, abs(value) < 9.0e15 else { throw ConnectorJSONDecline() }
                    return String(Int(value))
                }.joined(separator: " ")
            } else {
                score = try competitor.string("score")
            }
            let displayName = try athlete?.string("displayName") ?? athlete?.string("fullName") ?? "TBD"
            let shortName = try athlete?.string("shortName") ?? displayName
            let info = TeamInfo(
                name: shortName,
                abbreviation: shortName,
                displayName: displayName,
                score: score,
                logoURL: try flag?.string("href").flatMap(URL.init(string:)),
                record: nil
            )
            if (try competitor.string("homeAway") ?? "") == "home" {
                home = info
            } else {
                away = info
            }
        }
        return (home, away)
    }

    func parseRecord<J: ESPNJSONObject>(_ competitor: J) throws -> String? {
        guard let records = try competitor.objects("records") else { return nil }
        for record in records {
            if try record.string("name") == "overall" || record.string("type") == "total" {
                return try record.string("summary")
            }
        }
        return nil
    }

    func parseBroadcasts<J: ESPNJSONObject>(_ competition: J?) throws -> [String] {
        // geoBroadcasts first (more structured), then broadcasts[].names.
        if let geo = try competition?.objects("geoBroadcasts") {
            let names = try geo.compactMap { try $0.object("media")?.string("shortName") }
            if !names.isEmpty { return Array(Set(names)) }
        }
        if let broadcasts = try competition?.objects("broadcasts") {
            let names = try broadcasts.flatMap { try $0.strings("names") ?? [] }
            if !names.isEmpty { return Array(Set(names)) }
        }
        return []
    }

    // MARK: Dates

    /// Exact UTC instant for `yyyy-MM-ddTHH:mmZ` and `yyyy-MM-ddTHH:mm:ssZ`
    /// with in-range fields; nil for every other spelling (formatters decide).
    static func fastDate(_ string: String) -> Date? {
        var string = string
        return string.withUTF8 { buffer in buffer.baseAddress.flatMap { fastDate($0, buffer.count) } }
    }

    static func fastDate(_ p: UnsafePointer<UInt8>, _ n: Int) -> Date? {
        guard n == 17 || n == 20, p[4] == 0x2D, p[7] == 0x2D, p[10] == 0x54, p[13] == 0x3A, p[n - 1] == 0x5A else { return nil }
        func digits(_ at: Int, _ count: Int) -> Int? {
            var value = 0
            for k in 0..<count {
                let d = Int(p[at + k]) - 0x30
                guard d >= 0, d <= 9 else { return nil }
                value = value * 10 + d
            }
            return value
        }
        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2) else { return nil }
        var second = 0
        if n == 20 {
            guard p[16] == 0x3A, let s = digits(17, 2) else { return nil }
            second = s
        }
        guard year >= 1900, year <= 2200, month >= 1, month <= 12, hour <= 23, minute <= 59, second <= 59 else { return nil }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day >= 1, day <= monthDays[month - 1] else { return nil }
        // Days from civil (Howard Hinnant).
        let y = month <= 2 ? year - 1 : year
        let era = y / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Date(timeIntervalSince1970: TimeInterval(days * 86400 + hour * 3600 + minute * 60 + second))
    }
}

nonisolated extension ESPNTapeObject {
    /// `json["events"] as? [[String: Any]]` on the root.
    func rootEvents() -> [ESPNTapeObject]? {
        guard tape.kind[Int(node)] == .object else { return nil }
        return objects("events")
    }
}
