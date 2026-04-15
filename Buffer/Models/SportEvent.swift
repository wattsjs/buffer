import Foundation

// MARK: - Canonical sport event model

nonisolated struct SportEvent: Identifiable, Sendable {
    let id: String
    let sport: Sport
    let league: League
    let title: String              // "Lakers vs Celtics"
    let shortTitle: String         // "LAL vs BOS"
    let homeTeam: TeamInfo?
    let awayTeam: TeamInfo?
    let startDate: Date
    let status: EventStatus
    let broadcast: [String]        // e.g. ["ESPN", "TNT"]
    let venue: String?
    let detail: String?            // "3rd Quarter 5:42" or "Final"
    let tournamentName: String?    // "Barcelona Open" for expanded tournament matches

    var displayTitle: String {
        if let away = awayTeam, let home = homeTeam {
            return "\(away.displayName) vs \(home.displayName)"
        }
        return title
    }

    /// Normalized search tokens for fuzzy matching against channel names / EPG.
    var searchTokens: [String] {
        var tokens: [String] = []
        if let home = homeTeam {
            tokens.append(contentsOf: home.searchNames)
        }
        if let away = awayTeam {
            tokens.append(contentsOf: away.searchNames)
        }
        tokens.append(contentsOf: broadcast.map { $0.lowercased() })
        tokens.append(sport.rawValue.lowercased())
        tokens.append(league.shortName.lowercased())
        return tokens
    }
}

nonisolated struct TeamInfo: Sendable {
    let name: String               // "Celtics"
    let abbreviation: String       // "BOS"
    let displayName: String        // "Boston Celtics"
    let score: String?             // "104"
    let logoURL: URL?
    let record: String?            // "52-30"

    var searchNames: [String] {
        [
            name.lowercased(),
            abbreviation.lowercased(),
            displayName.lowercased(),
        ]
    }
}

// MARK: - Sport & League taxonomy

nonisolated enum Sport: String, CaseIterable, Sendable, Identifiable {
    case football = "Football"
    case basketball = "Basketball"
    case baseball = "Baseball"
    case hockey = "Hockey"
    case soccer = "Soccer"
    case mma = "MMA"
    case motorsport = "Motorsport"
    case tennis = "Tennis"
    case golf = "Golf"
    case cricket = "Cricket"
    case rugby = "Rugby"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .football:   "football.fill"
        case .basketball: "basketball.fill"
        case .baseball:   "baseball.fill"
        case .hockey:     "hockey.puck.fill"
        case .soccer:     "soccerball"
        case .mma:        "figure.martial.arts"
        case .motorsport: "car.fill"
        case .tennis:     "tennisball.fill"
        case .golf:       "figure.golf"
        case .cricket:    "cricket.ball.fill"
        case .rugby:      "rugbyball.fill"
        }
    }
}

nonisolated struct League: Sendable, Hashable, Identifiable {
    let sport: Sport
    let slug: String               // ESPN path component e.g. "nfl"
    let shortName: String          // "NFL"
    let fullName: String           // "National Football League"

    var id: String { "\(sport.rawValue)/\(slug)" }

    // ESPN scoreboard endpoint path
    var espnPath: String { "\(espnSport)/\(slug)" }

    private var espnSport: String {
        switch sport {
        case .football:   "football"
        case .basketball: "basketball"
        case .baseball:   "baseball"
        case .hockey:     "hockey"
        case .soccer:     "soccer"
        case .mma:        "mma"
        case .motorsport: "racing"
        case .tennis:     "tennis"
        case .golf:       "golf"
        case .cricket:    "cricket"
        case .rugby:      "rugby"
        }
    }

    static let all: [League] = [
        // American Football
        League(sport: .football, slug: "nfl", shortName: "NFL", fullName: "National Football League"),
        League(sport: .football, slug: "college-football", shortName: "NCAAF", fullName: "NCAA Football"),

        // Basketball
        League(sport: .basketball, slug: "nba", shortName: "NBA", fullName: "National Basketball Association"),
        League(sport: .basketball, slug: "wnba", shortName: "WNBA", fullName: "Women's NBA"),
        League(sport: .basketball, slug: "mens-college-basketball", shortName: "NCAAM", fullName: "NCAA Men's Basketball"),

        // Baseball
        League(sport: .baseball, slug: "mlb", shortName: "MLB", fullName: "Major League Baseball"),

        // Hockey
        League(sport: .hockey, slug: "nhl", shortName: "NHL", fullName: "National Hockey League"),

        // Soccer
        League(sport: .soccer, slug: "eng.1", shortName: "EPL", fullName: "English Premier League"),
        League(sport: .soccer, slug: "usa.1", shortName: "MLS", fullName: "Major League Soccer"),
        League(sport: .soccer, slug: "uefa.champions", shortName: "UCL", fullName: "UEFA Champions League"),
        League(sport: .soccer, slug: "esp.1", shortName: "La Liga", fullName: "La Liga"),
        League(sport: .soccer, slug: "ger.1", shortName: "Bundesliga", fullName: "Bundesliga"),
        League(sport: .soccer, slug: "ita.1", shortName: "Serie A", fullName: "Serie A"),
        League(sport: .soccer, slug: "fra.1", shortName: "Ligue 1", fullName: "Ligue 1"),

        // MMA
        League(sport: .mma, slug: "ufc", shortName: "UFC", fullName: "Ultimate Fighting Championship"),

        // Motorsport
        League(sport: .motorsport, slug: "f1", shortName: "F1", fullName: "Formula 1"),
        League(sport: .motorsport, slug: "nascar-cup", shortName: "NASCAR", fullName: "NASCAR Cup Series"),

        // Tennis
        League(sport: .tennis, slug: "atp", shortName: "ATP", fullName: "ATP Tour"),
        League(sport: .tennis, slug: "wta", shortName: "WTA", fullName: "WTA Tour"),

        // Golf
        League(sport: .golf, slug: "pga", shortName: "PGA", fullName: "PGA Tour"),

        // Cricket
        League(sport: .cricket, slug: "8048", shortName: "IPL", fullName: "Indian Premier League"),
        League(sport: .cricket, slug: "icc-world-cup", shortName: "ICC", fullName: "ICC Cricket World Cup"),

        // Rugby
        League(sport: .rugby, slug: "six-nations", shortName: "Six Nations", fullName: "Six Nations Championship"),
    ]
}

// MARK: - Event status

nonisolated enum EventStatus: Sendable {
    case scheduled
    case live(detail: String?)      // "2nd Half 67'"
    case halftime
    case delayed
    case postponed
    case canceled
    case final_(detail: String?)    // "Final", "Final/OT"

    var isLive: Bool {
        switch self {
        case .live, .halftime: true
        default: false
        }
    }

    var isFinished: Bool {
        if case .final_ = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .scheduled:          "Scheduled"
        case .live(let d):        d ?? "LIVE"
        case .halftime:           "Halftime"
        case .delayed:            "Delayed"
        case .postponed:          "Postponed"
        case .canceled:           "Canceled"
        case .final_(let d):      d ?? "Final"
        }
    }
}

// MARK: - Time bucket for grouping

nonisolated enum SportTimeGroup: Int, CaseIterable, Sendable {
    case live = 0
    case upNext      // within 2 hours
    case laterToday
    case tomorrow
    case thisWeek
    case finished

    var title: String {
        switch self {
        case .live:       "Live Now"
        case .upNext:     "Up Next"
        case .laterToday: "Later Today"
        case .tomorrow:   "Tomorrow"
        case .thisWeek:   "This Week"
        case .finished:   "Finished"
        }
    }

    var icon: String {
        switch self {
        case .live:       "play.circle.fill"
        case .upNext:     "clock.badge"
        case .laterToday: "sun.horizon.fill"
        case .tomorrow:   "sunrise.fill"
        case .thisWeek:   "calendar"
        case .finished:   "checkmark.circle"
        }
    }

    var accentColor: String {
        switch self {
        case .live:       "red"
        case .upNext:     "orange"
        case .laterToday: "yellow"
        case .tomorrow:   "blue"
        case .thisWeek:   "purple"
        case .finished:   "gray"
        }
    }

    static func group(for event: SportEvent, now: Date = Date()) -> SportTimeGroup {
        if event.status.isFinished { return .finished }
        if event.status.isLive { return .live }

        // For non-live, non-finished events, group by start time
        let cal = Calendar.current
        let interval = event.startDate.timeIntervalSince(now)

        // Already started but status says scheduled (e.g. pre-game) — treat as up next
        if interval <= 0 { return .upNext }
        if interval <= 2 * 3600 { return .upNext }
        if cal.isDateInToday(event.startDate) { return .laterToday }
        if cal.isDateInTomorrow(event.startDate) { return .tomorrow }
        return .thisWeek
    }
}
