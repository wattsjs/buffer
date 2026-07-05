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
    let leader: LeaderInfo?        // For tournament events without head-to-head teams (golf)

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

nonisolated struct LeaderInfo: Sendable {
    let name: String               // "Ludvig Åberg"
    let score: String              // "-8"
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
    case rugbyLeague = "Rugby League"
    case australianFootball = "AFL"
    case fieldHockey = "Field Hockey"
    case lacrosse = "Lacrosse"
    case volleyball = "Volleyball"
    case waterPolo = "Water Polo"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .football:          "football.fill"
        case .basketball:        "basketball.fill"
        case .baseball:          "baseball.fill"
        case .hockey:            "hockey.puck.fill"
        case .soccer:            "soccerball"
        case .mma:               "figure.martial.arts"
        case .motorsport:        "car.fill"
        case .tennis:            "tennisball.fill"
        case .golf:              "figure.golf"
        case .cricket:           "cricket.ball.fill"
        case .rugby:             "rugbyball.fill"
        case .rugbyLeague:       "rugbyball.fill"
        case .australianFootball:"figure.australian.football"
        case .fieldHockey:       "hockey.puck.fill"
        case .lacrosse:          "sportscourt"
        case .volleyball:        "volleyball.fill"
        case .waterPolo:         "figure.pool.swim"
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
        case .rugbyLeague: "rugby-league"
        case .australianFootball: "australian-football"
        case .fieldHockey: "field-hockey"
        case .lacrosse: "lacrosse"
        case .volleyball: "volleyball"
        case .waterPolo: "water-polo"
        }
    }

    static let all: [League] = [
        // American Football
        League(sport: .football, slug: "nfl", shortName: "NFL", fullName: "National Football League"),
        League(sport: .football, slug: "college-football", shortName: "NCAAF", fullName: "NCAA Football"),
        League(sport: .football, slug: "cfl", shortName: "CFL", fullName: "Canadian Football League"),
        League(sport: .football, slug: "ufl", shortName: "UFL", fullName: "United Football League"),

        // Basketball
        League(sport: .basketball, slug: "nba", shortName: "NBA", fullName: "National Basketball Association"),
        League(sport: .basketball, slug: "wnba", shortName: "WNBA", fullName: "Women's NBA"),
        League(sport: .basketball, slug: "mens-college-basketball", shortName: "NCAAM", fullName: "NCAA Men's Basketball"),
        League(sport: .basketball, slug: "womens-college-basketball", shortName: "NCAAW", fullName: "NCAA Women's Basketball"),
        League(sport: .basketball, slug: "fiba", shortName: "FIBA", fullName: "FIBA World Cup"),
        League(sport: .basketball, slug: "mens-olympics-basketball", shortName: "Olympics M", fullName: "Olympics Men's Basketball"),
        League(sport: .basketball, slug: "womens-olympics-basketball", shortName: "Olympics W", fullName: "Olympics Women's Basketball"),
        League(sport: .basketball, slug: "nba-development", shortName: "G League", fullName: "NBA G League"),
        League(sport: .basketball, slug: "nbl", shortName: "NBL", fullName: "National Basketball League"),
        League(sport: .basketball, slug: "nba-summer-las-vegas", shortName: "Summer League", fullName: "Las Vegas Summer League"),
        League(sport: .basketball, slug: "nba-summer-california", shortName: "California Classic", fullName: "NBA California Classic Summer League"),
        League(sport: .basketball, slug: "nba-summer-utah", shortName: "Salt Lake", fullName: "Salt Lake City Summer League"),
        League(sport: .basketball, slug: "nba-summer-sacramento", shortName: "Sacramento", fullName: "Sacramento Summer League"),
        League(sport: .basketball, slug: "nba-summer-golden-state", shortName: "Golden State", fullName: "Golden State Summer League"),

        // Baseball
        League(sport: .baseball, slug: "mlb", shortName: "MLB", fullName: "Major League Baseball"),
        League(sport: .baseball, slug: "college-baseball", shortName: "NCAA Baseball", fullName: "NCAA Baseball"),
        League(sport: .baseball, slug: "college-softball", shortName: "NCAA Softball", fullName: "NCAA Softball"),
        League(sport: .baseball, slug: "world-baseball-classic", shortName: "WBC", fullName: "World Baseball Classic"),
        League(sport: .baseball, slug: "olympics-baseball", shortName: "Olympics", fullName: "Olympics Men's Baseball"),
        League(sport: .baseball, slug: "llb", shortName: "LLB", fullName: "Little League Baseball"),
        League(sport: .baseball, slug: "lls", shortName: "LLS", fullName: "Little League Softball"),
        League(sport: .baseball, slug: "caribbean-series", shortName: "Caribbean", fullName: "Caribbean Series"),
        League(sport: .baseball, slug: "dominican-winter-league", shortName: "LIDOM", fullName: "Dominican Winter League"),
        League(sport: .baseball, slug: "mexican-winter-league", shortName: "LMP", fullName: "Mexican Winter League"),
        League(sport: .baseball, slug: "puerto-rican-winter-league", shortName: "LBPRC", fullName: "Puerto Rican Winter League"),
        League(sport: .baseball, slug: "venezuelan-winter-league", shortName: "LVBP", fullName: "Venezuelan Winter League"),

        // Hockey
        League(sport: .hockey, slug: "nhl", shortName: "NHL", fullName: "National Hockey League"),
        League(sport: .hockey, slug: "mens-college-hockey", shortName: "NCAAM Hockey", fullName: "NCAA Men's Ice Hockey"),
        League(sport: .hockey, slug: "womens-college-hockey", shortName: "NCAAW Hockey", fullName: "NCAA Women's Hockey"),
        League(sport: .hockey, slug: "olympics-mens-ice-hockey", shortName: "Olympics M", fullName: "Men's Olympic Ice Hockey"),
        League(sport: .hockey, slug: "olympics-womens-ice-hockey", shortName: "Olympics W", fullName: "Women's Olympic Ice Hockey"),
        League(sport: .hockey, slug: "hockey-world-cup", shortName: "World Cup", fullName: "World Cup of Hockey"),

        // Soccer
        League(sport: .soccer, slug: "fifa.world", shortName: "World Cup", fullName: "FIFA World Cup"),
        League(sport: .soccer, slug: "fifa.wwc", shortName: "WWC", fullName: "FIFA Women's World Cup"),
        League(sport: .soccer, slug: "fifa.cwc", shortName: "Club WC", fullName: "FIFA Club World Cup"),
        League(sport: .soccer, slug: "fifa.intercontinental_cup", shortName: "Intercontinental", fullName: "FIFA Intercontinental Cup"),
        League(sport: .soccer, slug: "fifa.olympics", shortName: "Olympics M", fullName: "Olympic Men's Soccer"),
        League(sport: .soccer, slug: "fifa.w.olympics", shortName: "Olympics W", fullName: "Olympic Women's Soccer"),
        League(sport: .soccer, slug: "eng.1", shortName: "EPL", fullName: "English Premier League"),
        League(sport: .soccer, slug: "usa.1", shortName: "MLS", fullName: "Major League Soccer"),
        League(sport: .soccer, slug: "uefa.champions", shortName: "UCL", fullName: "UEFA Champions League"),
        League(sport: .soccer, slug: "uefa.europa", shortName: "UEL", fullName: "UEFA Europa League"),
        League(sport: .soccer, slug: "uefa.europa.conf", shortName: "UECL", fullName: "UEFA Conference League"),
        League(sport: .soccer, slug: "uefa.super_cup", shortName: "UEFA Super Cup", fullName: "UEFA Super Cup"),
        League(sport: .soccer, slug: "uefa.nations", shortName: "Nations League", fullName: "UEFA Nations League"),
        League(sport: .soccer, slug: "uefa.euro", shortName: "Euro", fullName: "UEFA European Championship"),
        League(sport: .soccer, slug: "uefa.weuro", shortName: "Women's Euro", fullName: "UEFA Women's Championship"),
        League(sport: .soccer, slug: "uefa.wchampions", shortName: "UWCL", fullName: "UEFA Women's Champions League"),
        League(sport: .soccer, slug: "esp.1", shortName: "La Liga", fullName: "La Liga"),
        League(sport: .soccer, slug: "ger.1", shortName: "Bundesliga", fullName: "Bundesliga"),
        League(sport: .soccer, slug: "ita.1", shortName: "Serie A", fullName: "Serie A"),
        League(sport: .soccer, slug: "fra.1", shortName: "Ligue 1", fullName: "Ligue 1"),
        League(sport: .soccer, slug: "mex.1", shortName: "Liga MX", fullName: "Liga MX"),
        League(sport: .soccer, slug: "ned.1", shortName: "Eredivisie", fullName: "Dutch Eredivisie"),
        League(sport: .soccer, slug: "por.1", shortName: "Liga Portugal", fullName: "Liga Portugal"),
        League(sport: .soccer, slug: "sco.1", shortName: "Scottish Prem", fullName: "Scottish Premiership"),
        League(sport: .soccer, slug: "tur.1", shortName: "Super Lig", fullName: "Turkish Super Lig"),
        League(sport: .soccer, slug: "ksa.1", shortName: "Saudi Pro", fullName: "Saudi Pro League"),
        League(sport: .soccer, slug: "aus.1", shortName: "A-League", fullName: "A-League Men"),
        League(sport: .soccer, slug: "aus.w.1", shortName: "A-League W", fullName: "A-League Women"),
        League(sport: .soccer, slug: "usa.nwsl", shortName: "NWSL", fullName: "National Women's Soccer League"),
        League(sport: .soccer, slug: "usa.open", shortName: "US Open Cup", fullName: "U.S. Open Cup"),
        League(sport: .soccer, slug: "usa.usl.1", shortName: "USL", fullName: "USL Championship"),
        League(sport: .soccer, slug: "usa.usl.l1", shortName: "USL League One", fullName: "USL League One"),
        League(sport: .soccer, slug: "eng.w.1", shortName: "WSL", fullName: "FA Women's Super League"),
        League(sport: .soccer, slug: "esp.w.1", shortName: "Liga F", fullName: "Spanish Liga F"),
        League(sport: .soccer, slug: "fra.w.1", shortName: "D1 Arkema", fullName: "Premiere Ligue"),
        League(sport: .soccer, slug: "eng.fa", shortName: "FA Cup", fullName: "FA Cup"),
        League(sport: .soccer, slug: "eng.league_cup", shortName: "EFL Cup", fullName: "English Carabao Cup"),
        League(sport: .soccer, slug: "eng.2", shortName: "Championship", fullName: "EFL Championship"),
        League(sport: .soccer, slug: "esp.copa_del_rey", shortName: "Copa del Rey", fullName: "Copa del Rey"),
        League(sport: .soccer, slug: "ger.dfb_pokal", shortName: "DFB Pokal", fullName: "DFB Pokal"),
        League(sport: .soccer, slug: "ita.coppa_italia", shortName: "Coppa Italia", fullName: "Coppa Italia"),
        League(sport: .soccer, slug: "fra.coupe_de_france", shortName: "Coupe de France", fullName: "Coupe de France"),
        League(sport: .soccer, slug: "conmebol.libertadores", shortName: "Libertadores", fullName: "CONMEBOL Libertadores"),
        League(sport: .soccer, slug: "conmebol.america", shortName: "Copa America", fullName: "Copa America"),
        League(sport: .soccer, slug: "concacaf.champions", shortName: "CONCACAF Cup", fullName: "Concacaf Champions Cup"),
        League(sport: .soccer, slug: "concacaf.gold", shortName: "Gold Cup", fullName: "CONCACAF Gold Cup"),
        League(sport: .soccer, slug: "concacaf.nations.league", shortName: "CONCACAF NL", fullName: "CONCACAF Nations League"),
        League(sport: .soccer, slug: "caf.nations", shortName: "AFCON", fullName: "Africa Cup of Nations"),
        League(sport: .soccer, slug: "afc.asian.cup", shortName: "Asian Cup", fullName: "AFC Asian Cup"),
        League(sport: .soccer, slug: "fifa.worldq.uefa", shortName: "WCQ UEFA", fullName: "FIFA World Cup Qualifying - UEFA"),
        League(sport: .soccer, slug: "fifa.worldq.concacaf", shortName: "WCQ CONCACAF", fullName: "FIFA World Cup Qualifying - CONCACAF"),
        League(sport: .soccer, slug: "fifa.worldq.conmebol", shortName: "WCQ CONMEBOL", fullName: "FIFA World Cup Qualifying - CONMEBOL"),
        League(sport: .soccer, slug: "fifa.worldq.afc", shortName: "WCQ AFC", fullName: "FIFA World Cup Qualifying - AFC"),
        League(sport: .soccer, slug: "fifa.worldq.caf", shortName: "WCQ CAF", fullName: "FIFA World Cup Qualifying - CAF"),
        League(sport: .soccer, slug: "fifa.worldq.ofc", shortName: "WCQ OFC", fullName: "FIFA World Cup Qualifying - OFC"),
        League(sport: .soccer, slug: "fifa.friendly", shortName: "Friendlies", fullName: "International Friendlies"),
        League(sport: .soccer, slug: "fifa.friendly.w", shortName: "Women's Friendlies", fullName: "Women's International Friendlies"),

        // MMA
        League(sport: .mma, slug: "ufc", shortName: "UFC", fullName: "Ultimate Fighting Championship"),
        League(sport: .mma, slug: "pfl", shortName: "PFL", fullName: "Professional Fighters League"),
        League(sport: .mma, slug: "bellator", shortName: "Bellator", fullName: "Bellator MMA"),
        League(sport: .mma, slug: "rizin", shortName: "Rizin", fullName: "Rizin Fighting Federation"),

        // Motorsport
        League(sport: .motorsport, slug: "f1", shortName: "F1", fullName: "Formula 1"),
        League(sport: .motorsport, slug: "nascar-premier", shortName: "NASCAR", fullName: "NASCAR Cup Series"),
        League(sport: .motorsport, slug: "nascar-secondary", shortName: "Xfinity", fullName: "NASCAR Xfinity Series"),
        League(sport: .motorsport, slug: "nascar-truck", shortName: "Truck", fullName: "NASCAR Truck Series"),
        League(sport: .motorsport, slug: "irl", shortName: "IndyCar", fullName: "IndyCar Series"),

        // Tennis
        League(sport: .tennis, slug: "atp", shortName: "ATP", fullName: "ATP Tour"),
        League(sport: .tennis, slug: "wta", shortName: "WTA", fullName: "WTA Tour"),

        // Golf
        League(sport: .golf, slug: "pga", shortName: "PGA", fullName: "PGA Tour"),
        League(sport: .golf, slug: "liv", shortName: "LIV", fullName: "LIV Golf"),
        League(sport: .golf, slug: "lpga", shortName: "LPGA", fullName: "LPGA Tour"),
        League(sport: .golf, slug: "eur", shortName: "DP World", fullName: "DP World Tour"),
        League(sport: .golf, slug: "champions-tour", shortName: "Champions", fullName: "PGA Tour Champions"),
        League(sport: .golf, slug: "ntw", shortName: "Korn Ferry", fullName: "Korn Ferry Tour"),
        League(sport: .golf, slug: "tgl", shortName: "TGL", fullName: "TGL"),
        League(sport: .golf, slug: "mens-olympics-golf", shortName: "Olympics M", fullName: "Olympic Men's Golf"),
        League(sport: .golf, slug: "womens-olympics-golf", shortName: "Olympics W", fullName: "Olympic Women's Golf"),

        // Cricket
        League(sport: .cricket, slug: "8048", shortName: "IPL", fullName: "Indian Premier League"),
        League(sport: .cricket, slug: "8039", shortName: "CWC", fullName: "ICC Cricket World Cup"),
        League(sport: .cricket, slug: "8604", shortName: "T20 WC", fullName: "ICC Men's T20 World Cup"),
        League(sport: .cricket, slug: "8634", shortName: "Women's T20 WC", fullName: "ICC Women's T20 World Cup"),
        League(sport: .cricket, slug: "8037", shortName: "Champions Trophy", fullName: "ICC Champions Trophy"),
        League(sport: .cricket, slug: "8038", shortName: "CWC Qualifier", fullName: "ICC Cricket World Cup Qualifier"),
        League(sport: .cricket, slug: "8040", shortName: "T20 WC Qualifier", fullName: "ICC Men's T20 World Cup Qualifier"),
        League(sport: .cricket, slug: "21266", shortName: "MLC", fullName: "Major League Cricket"),
        League(sport: .cricket, slug: "8044", shortName: "BBL", fullName: "Big Bash League"),
        League(sport: .cricket, slug: "8043", shortName: "Shield", fullName: "Sheffield Shield"),
        League(sport: .cricket, slug: "8050", shortName: "Ranji", fullName: "Ranji Trophy"),
        League(sport: .cricket, slug: "8052", shortName: "County Div 1", fullName: "County Championship Division One"),
        League(sport: .cricket, slug: "8204", shortName: "County Div 2", fullName: "County Championship Division Two"),
        League(sport: .cricket, slug: "8053", shortName: "Blast", fullName: "Vitality Blast"),
        League(sport: .cricket, slug: "8335", shortName: "One-Day Cup", fullName: "One-Day Cup"),
        League(sport: .cricket, slug: "23080", shortName: "Women's One-Day", fullName: "ECB Women's One-Day Cup"),
        League(sport: .cricket, slug: "20921", shortName: "ILT20", fullName: "International League T20"),
        League(sport: .cricket, slug: "8205", shortName: "SLPL", fullName: "Sri Lanka Premier League"),
        League(sport: .cricket, slug: "8368", shortName: "U19 WC", fullName: "ICC Under-19 World Cup"),

        // Rugby Union
        League(sport: .rugby, slug: "164205", shortName: "Rugby WC", fullName: "Rugby World Cup"),
        League(sport: .rugby, slug: "268565", shortName: "Lions", fullName: "British and Irish Lions Tour"),
        League(sport: .rugby, slug: "180659", shortName: "Six Nations", fullName: "Six Nations Championship"),
        League(sport: .rugby, slug: "242041", shortName: "Super Rugby", fullName: "Super Rugby Pacific"),
        League(sport: .rugby, slug: "244293", shortName: "Rugby Champs", fullName: "The Rugby Championship"),
        League(sport: .rugby, slug: "270557", shortName: "URC", fullName: "United Rugby Championship"),
        League(sport: .rugby, slug: "271937", shortName: "Champions Cup", fullName: "European Rugby Champions Cup"),
        League(sport: .rugby, slug: "272073", shortName: "Challenge Cup", fullName: "European Rugby Challenge Cup"),
        League(sport: .rugby, slug: "267979", shortName: "Premiership", fullName: "Premiership Rugby"),
        League(sport: .rugby, slug: "270559", shortName: "Top 14", fullName: "French Top 14"),
        League(sport: .rugby, slug: "17567", shortName: "Nations", fullName: "Nations Championship"),

        // Rugby League
        League(sport: .rugbyLeague, slug: "3", shortName: "NRL", fullName: "National Rugby League"),

        // Australian Rules Football
        League(sport: .australianFootball, slug: "afl", shortName: "AFL", fullName: "Australian Football League"),

        // Field Hockey
        League(sport: .fieldHockey, slug: "womens-college-field-hockey", shortName: "NCAA Field Hockey", fullName: "NCAA Women's Field Hockey"),

        // Lacrosse
        League(sport: .lacrosse, slug: "mens-college-lacrosse", shortName: "NCAAM Lacrosse", fullName: "NCAA Men's Lacrosse"),
        League(sport: .lacrosse, slug: "womens-college-lacrosse", shortName: "NCAAW Lacrosse", fullName: "NCAA Women's Lacrosse"),
        League(sport: .lacrosse, slug: "pll", shortName: "PLL", fullName: "Premier Lacrosse League"),
        League(sport: .lacrosse, slug: "nll", shortName: "NLL", fullName: "National Lacrosse League"),

        // Volleyball
        League(sport: .volleyball, slug: "mens-college-volleyball", shortName: "NCAAM Volleyball", fullName: "NCAA Men's Volleyball"),
        League(sport: .volleyball, slug: "womens-college-volleyball", shortName: "NCAAW Volleyball", fullName: "NCAA Women's Volleyball"),

        // Water Polo
        League(sport: .waterPolo, slug: "mens-college-water-polo", shortName: "NCAAM Water Polo", fullName: "NCAA Men's Water Polo"),
        League(sport: .waterPolo, slug: "womens-college-water-polo", shortName: "NCAAW Water Polo", fullName: "NCAA Women's Water Polo"),
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
