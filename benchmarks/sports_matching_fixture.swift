import Foundation

/// Deterministic synthetic library sized like a real multi-account setup:
/// three accounts of ~20k live streams, source-scoped and raw guide keys,
/// shared variant guides, ~200k programmes in the matcher's 49 h window,
/// and ~300 ESPN-like fixtures for one day. Used by the sports matching
/// benchmark and the legacy-equivalence oracle test.
nonisolated struct SportsMatchingFixture {
    let now: Date
    let channels: [Channel]
    let programs: [String: [EPGProgram]]
    let hiddenGroups: Set<String>
    let events: [SportEvent]
    let quality: [String: StreamMatchQuality]
    let favorites: Set<String>
    let channelScores: [String: Double]
    let groupScores: [String: Double]

    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) / 1_000_000 < p }
        mutating func pick<T>(_ values: [T]) -> T { values[int(values.count)] }
    }

    struct LeagueTeams {
        let slug: String
        let teams: [(city: String, name: String, abbr: String)]
        let titleFormat: Int
    }

    static func make(channelsPerAccount: Int = 20_000, accounts: Int = 3, fixtures: Int = 300, seed: UInt64 = 42) -> SportsMatchingFixture {
        var rng = RNG(state: seed)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usCities = ["Detroit", "Carolina", "Los Angeles", "Boston", "New York", "Chicago", "Dallas", "Miami", "Denver",
                        "Seattle", "Philadelphia", "Atlanta", "Houston", "Phoenix", "Minnesota", "Cleveland", "Green Bay",
                        "Kansas City", "Las Vegas", "San Francisco", "Tampa Bay", "New Orleans", "Pittsburgh", "Baltimore",
                        "Buffalo", "Cincinnati", "Indianapolis", "Jacksonville", "Tennessee", "Arizona", "Washington", "Toronto"]
        let nfl = ["Lions", "Panthers", "Rams", "Patriots", "Giants", "Bears", "Cowboys", "Dolphins", "Broncos", "Seahawks",
                   "Eagles", "Falcons", "Texans", "Cardinals", "Vikings", "Browns", "Packers", "Chiefs", "Raiders", "49ers",
                   "Buccaneers", "Saints", "Steelers", "Ravens", "Bills", "Bengals", "Colts", "Jaguars", "Titans", "Commanders"]
        let nba = ["Pistons", "Hornets", "Lakers", "Celtics", "Knicks", "Bulls", "Mavericks", "Heat", "Nuggets", "SuperSonics",
                   "76ers", "Hawks", "Rockets", "Suns", "Timberwolves", "Cavaliers", "Bucks", "Thunder", "Aces", "Warriors",
                   "Magic", "Pelicans", "Grizzlies", "Wizards", "Raptors", "Pacers", "Jazz", "Spurs", "Kings", "Clippers"]
        let mlb = ["Tigers", "Dodgers", "Red Sox", "Yankees", "Cubs", "Rangers", "Marlins", "Rockies", "Mariners", "Phillies",
                   "Braves", "Astros", "Diamondbacks", "Twins", "Guardians", "Brewers", "Royals", "Athletics", "Giants", "Rays",
                   "Mets", "Padres", "Pirates", "Orioles", "Blue Jays", "Reds", "White Sox", "Angels", "Nationals", "Cardinals"]
        let nhl = ["Red Wings", "Hurricanes", "Kings", "Bruins", "Rangers", "Blackhawks", "Stars", "Panthers", "Avalanche", "Kraken",
                   "Flyers", "Thrashers", "Coyotes", "Wild", "Golden Knights", "Sharks", "Lightning", "Penguins", "Sabres", "Capitals"]
        let epl = [("", "Arsenal", "ARS"), ("", "Chelsea", "CHE"), ("", "Liverpool", "LIV"), ("", "Everton", "EVE"),
                   ("", "Manchester City", "MCI"), ("", "Manchester United", "MUN"), ("", "Tottenham Hotspur", "TOT"),
                   ("", "Newcastle United", "NEW"), ("", "Aston Villa", "AVL"), ("", "West Ham United", "WHU"),
                   ("", "Brighton & Hove Albion", "BHA"), ("", "AFC Bournemouth", "BOU"), ("", "Wolverhampton Wanderers", "WOL"),
                   ("", "Crystal Palace", "CRY"), ("", "Fulham", "FUL"), ("", "Brentford", "BRE"), ("", "Nottingham Forest", "NFO"),
                   ("", "Southampton", "SOU"), ("", "Leicester City", "LEI"), ("", "Ipswich Town", "IPS")]
        let liga = [("", "Atlético Madrid", "ATM"), ("", "Real Madrid", "RMA"), ("", "Barcelona", "BAR"), ("", "Sevilla", "SEV"),
                    ("", "Real Sociedad", "RSO"), ("", "Villarreal", "VIL"), ("", "Athletic Club", "ATH"), ("", "Real Betis", "BET"),
                    ("", "Valencia", "VAL"), ("", "Celta Vigo", "CEL"), ("", "Osasuna", "OSA"), ("", "Getafe", "GET")]
        let mls = [("", "Inter Miami CF", "MIA"), ("", "LA Galaxy", "LA"), ("", "Seattle Sounders FC", "SEA"), ("", "Atlanta United FC", "ATL"),
                   ("", "New York City FC", "NYC"), ("", "Toronto FC", "TOR"), ("", "Austin FC", "ATX"), ("", "Columbus Crew", "CLB")]
        func us(_ names: [String]) -> [(String, String, String)] {
            names.enumerated().map { i, n in (usCities[i % usCities.count], n, String(n.uppercased().filter(\.isLetter).prefix(3))) }
        }
        let leagues: [LeagueTeams] = [
            .init(slug: "nfl", teams: us(nfl), titleFormat: 0),
            .init(slug: "nba", teams: us(nba), titleFormat: 0),
            .init(slug: "mlb", teams: us(mlb), titleFormat: 1),
            .init(slug: "nhl", teams: us(nhl), titleFormat: 0),
            .init(slug: "eng.1", teams: epl, titleFormat: 2),
            .init(slug: "esp.1", teams: liga, titleFormat: 2),
            .init(slug: "usa.1", teams: mls, titleFormat: 2),
            .init(slug: "uefa.champions", teams: Array(epl.prefix(8)) + Array(liga.prefix(6)), titleFormat: 2),
        ]
        let tennisPlayers = ["Novak Djokovic", "Carlos Alcaraz", "Jannik Sinner", "Daniil Medvedev", "Alexander Zverev",
                             "Holger Rune", "Casper Ruud", "Stefanos Tsitsipas", "Taylor Fritz", "Ben Shelton"]
        let tournaments = ["Barcelona Open", "Madrid Open", "Italian Open", "Queen's Club Championships", "Shanghai Masters"]
        let broadcasters = ["ESPN", "NBC", "FOX", "CBS", "TNT", "ABC", "Sky Sports", "beIN Sports", "Peacock", "ESPN+",
                            "Prime Video", "NBA TV", "NFL Network", "MLB Network", "TSN", "Sportsnet", "DAZN", "Bally Sports Detroit"]

        // ── Fixtures ──
        var events: [SportEvent] = []
        var eventTitles: [(start: Date, title: String, homeName: String, awayName: String, league: String)] = []
        for i in 0..<fixtures {
            let start = now.addingTimeInterval(Double(rng.int(26 * 3600)) - 6 * 3600)
            let statusRoll = start < now.addingTimeInterval(-3 * 3600) ? 2 : (start <= now ? 1 : 0)
            let status: EventStatus = statusRoll == 2 ? .final_(detail: "Final") : (statusRoll == 1 ? .live(detail: "2nd") : .scheduled)
            var b: [String] = []
            for _ in 0..<(1 + rng.int(3)) { let x = rng.pick(broadcasters); if !b.contains(x) { b.append(x) } }
            if i % 23 == 7 {
                let league = League.all.first { $0.slug == "atp" } ?? League.all[0]
                let p0 = rng.pick(tennisPlayers); var p1 = rng.pick(tennisPlayers); if p1 == p0 { p1 = tennisPlayers[0] == p0 ? tennisPlayers[1] : tennisPlayers[0] }
                func player(_ n: String) -> TeamInfo {
                    TeamInfo(name: n, abbreviation: String(n.split(separator: " ").last!.prefix(3)).uppercased(), displayName: n, score: nil, logoURL: nil, record: nil)
                }
                let tour = rng.pick(tournaments)
                events.append(SportEvent(id: "ev\(i)", sport: .tennis, league: league, title: "\(p0) vs \(p1)",
                    shortTitle: "\(p0.split(separator: " ").last!) v \(p1.split(separator: " ").last!)",
                    homeTeam: player(p0), awayTeam: player(p1), startDate: start, status: status, broadcast: ["Tennis Channel"] + b.prefix(1),
                    venue: "Court \(1 + rng.int(8))", detail: nil, tournamentName: tour, leader: nil))
                eventTitles.append((start, "ATP Tennis: \(tour)", p0, p1, "atp"))
                continue
            }
            if i % 37 == 11 {
                let league = League.all.first { $0.slug == "f1" } ?? League.all[0]
                events.append(SportEvent(id: "ev\(i)", sport: .motorsport, league: league, title: "Grand Prix of Mexico",
                    shortTitle: "Mexico GP", homeTeam: nil, awayTeam: nil, startDate: start, status: status, broadcast: ["ESPN", "Sky Sports F1"],
                    venue: "Autódromo Hermanos Rodríguez", detail: nil, tournamentName: "Mexico City Grand Prix", leader: nil))
                eventTitles.append((start, "Formula 1: Mexico City Grand Prix", "", "", "f1"))
                continue
            }
            let lt = leagues[rng.int(leagues.count)]
            let league = League.all.first { $0.slug == lt.slug } ?? League.all[0]
            let h = rng.int(lt.teams.count); var a = rng.int(lt.teams.count); if a == h { a = (h + 1) % lt.teams.count }
            func team(_ t: (city: String, name: String, abbr: String)) -> TeamInfo {
                let display = t.city.isEmpty ? t.name : "\(t.city) \(t.name)"
                return TeamInfo(name: t.city.isEmpty ? t.name : t.name, abbreviation: t.abbr, displayName: display, score: nil, logoURL: nil, record: nil)
            }
            let home = team(lt.teams[h]), away = team(lt.teams[a])
            events.append(SportEvent(id: "ev\(i)", sport: league.sport, league: league,
                title: "\(away.displayName) at \(home.displayName)", shortTitle: "\(away.abbreviation) @ \(home.abbreviation)",
                homeTeam: home, awayTeam: away, startDate: start, status: status, broadcast: b,
                venue: rng.chance(0.5) ? "\(home.displayName) Stadium" : nil, detail: nil, tournamentName: nil, leader: nil))
            let title: String
            switch lt.titleFormat {
            case 0: title = rng.chance(0.5) ? "\(league.shortName) Football: \(away.name) at \(home.name)" : "\(away.displayName) vs \(home.displayName)"
            case 1: title = "\(league.shortName) Baseball: \(away.name) vs \(home.name)"
            default: title = rng.chance(0.5) ? "Live: \(home.displayName) v \(away.displayName)" : "\(league.shortName): \(home.displayName) v \(away.displayName)"
            }
            eventTitles.append((start, title, home.displayName, away.displayName, lt.slug))
        }

        // ── Channels and guides ──
        let sportsBrands = ["ESPN", "ESPN 2", "ESPNU", "ESPN News", "NBC Sports", "FOX Sports 1", "FS2", "CBS Sports Network",
                            "TNT Sports", "NBA TV", "NFL Network", "NFL RedZone", "MLB Network", "NHL Network", "Sky Sports Main Event",
                            "Sky Sports Premier League", "Sky Sports F1", "Sky Sports Football", "beIN Sports 1", "beIN Sports 2",
                            "beIN Sports 3", "TSN 1", "TSN 2", "Sportsnet One", "DAZN 1", "Tennis Channel", "Golf Channel",
                            "Bally Sports Detroit", "Movistar LaLiga", "Sport TV 1", "TRT Spor", "Eurosport 1", "Peacock Event"]
        let locals = ["NBC WSFA 12 Montgomery", "FOX KTTV 11 Los Angeles", "CBS WBZ 4 Boston", "ABC WABC 7 New York",
                      "NBC KNBC 4 Los Angeles", "FOX WJBK 2 Detroit", "CBS KCBS 2", "ABC WLS 7 Chicago", "NBC WMAQ 5 Chicago",
                      "FOX KDFW 4 Dallas", "NBC WTVJ 6 Miami", "CBS KCNC 4 Denver"]
        let general = ["CNN", "BBC News", "Sky News", "HBO", "Cinemax", "Disney Channel", "Cartoon Network", "Nickelodeon",
                       "Discovery", "History", "National Geographic", "Comedy Central", "MTV", "AMC", "Das Erste", "ZDF",
                       "TF1", "France 2", "Rai 1", "Canal+", "MBC 2", "TVE La 1", "Antena 3", "RTL", "ProSieben", "Sat.1",
                       "Česká televize", "TVP Info", "Россия 1", "NHK World", "Al Jazeera", "Telemundo", "Univision"]
        let prefixes = ["US|", "US:", "UK:", "CA:", "ES:", "DE:", "FR:", "PT:", "AR:", "IT:", ""]
        let qualities = ["", " HD", " FHD", " UHD", " 4K", " SD", " HEVC", " 50fps", " (Backup)", " RAW"]
        let sportGroups = ["USA | Sports", "UK | Sports", "Sports PPV", "NFL Game Pass", "beIN Sports", "Canada Sports",
                           "LaLiga TV", "Hidden Sports", "Sport Events"]
        let generalGroups = ["USA | Entertainment", "UK | General", "Movies", "Kids", "News", "Documentaries",
                             "Germany", "France", "Arabic", "España", "Radio", "USA | Locals"]
        let fillerTitles = ["SportsCenter", "NFL Live", "First Take", "Inside the NBA", "Premier League Review", "Golf Central",
                            "Tennis Highlights", "College Football Live", "MLB Tonight", "NHL Tonight", "Paid Programming",
                            "The Simpsons", "Friends", "News at Ten", "Tagesschau", "Le Journal", "Telediario", "Pelicula: El Laberinto",
                            "Movie: The Dark Knight", "Wildlife Documentary", "Football Focus", "Match of the Day", "Soccer Saturday",
                            "Fútbol Mundial", "Jornal da Noite", "WWE Raw", "UFC Countdown", "Bundesliga Highlights", "Ligue 1 Uber Eats Magazine"]
        let descWords = ["live", "coverage", "of", "the", "match", "between", "season", "highlights", "analysis", "from",
                         "stadium", "with", "commentary", "and", "expert", "preview", "kickoff", "rivals", "meet", "title",
                         "race", "playoff", "week", "game", "night", "football", "basketball", "baseball", "hockey", "soccer",
                         "championship", "derby", "final", "quarter", "goals", "team", "news", "weather", "café", "después"]

        var channels: [Channel] = []
        var programs: [String: [EPGProgram]] = [:]
        channels.reserveCapacity(channelsPerAccount * accounts)
        var allGroups: [String] = []
        for account in 0..<accounts {
            let sourceID = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", account + 1))!
            let scoped = account > 0
            var guideIDs: [String] = []
            var sportsGuideIDs: [String] = []
            var c = 0
            while c < channelsPerAccount {
                let roll = rng.int(100)
                let isSport = roll < 18, isLocal = roll >= 18 && roll < 26
                let base: String = isSport ? rng.pick(sportsBrands) : (isLocal ? rng.pick(locals) : rng.pick(general))
                let group = isSport ? rng.pick(sportGroups) : (isLocal ? "USA | Locals" : rng.pick(generalGroups))
                let isRadio = group == "Radio"
                let hasGuide = rng.chance(isSport || isLocal ? 0.7 : 0.35) && !isRadio
                var guideID: String? = nil
                if hasGuide {
                    if !guideIDs.isEmpty && rng.chance(0.25) {
                        guideID = isSport && !sportsGuideIDs.isEmpty ? rng.pick(sportsGuideIDs) : rng.pick(guideIDs)
                    } else {
                        guideID = base.lowercased().filter { $0.isLetter || $0.isNumber } + ".\(account).\(guideIDs.count)"
                        guideIDs.append(guideID!)
                        if isSport || isLocal { sportsGuideIDs.append(guideID!) }
                    }
                }
                // Variants share a guide: 1-3 quality variants per brand row.
                let variantCount = 1 + rng.int(3)
                for v in 0..<variantCount where c < channelsPerAccount {
                    let name = isRadio ? "Radio: \(base)" : rng.pick(prefixes) + " " + base + qualities[(v + rng.int(qualities.count)) % qualities.count]
                    let id = "a\(account)-\(c)"
                    let ownership: ChannelSourceOwnership? = scoped
                        ? ChannelSourceOwnership(channelIdentity: SourceChannelIdentity(sourceID: sourceID, nativeID: id),
                                                 accountKey: .unconfiguredSource(sourceID))
                        : nil
                    channels.append(Channel(id: id, name: name.trimmingCharacters(in: .whitespaces), logoURL: nil, group: group,
                        streamURL: URL(string: "http://127.0.0.1/\(account)/\(c).ts")!, epgChannelID: guideID, sourceOwnership: ownership))
                    c += 1
                }
            }
            // A few event channels per account carry fixture names directly.
            for (n, fixture) in eventTitles.enumerated() where n % 4 == account % 4 && !fixture.homeName.isEmpty {
                let id = "a\(account)-ppv\(n)"
                channels.append(Channel(id: id, name: "PPV \(n % 90): \(fixture.awayName) vs \(fixture.homeName)", logoURL: nil,
                    group: "Sport Events", streamURL: URL(string: "http://127.0.0.1/\(account)/ppv\(n).ts")!, epgChannelID: nil,
                    sourceOwnership: scoped ? ChannelSourceOwnership(channelIdentity: SourceChannelIdentity(sourceID: sourceID, nativeID: id),
                                                                    accountKey: .unconfiguredSource(sourceID)) : nil))
            }
            // Assign fixture programmes to random sports guides.
            var assigned: [String: [(Date, String, Bool)]] = [:]
            for fixture in eventTitles {
                for _ in 0..<(2 + rng.int(10)) where !sportsGuideIDs.isEmpty {
                    let g = rng.pick(sportsGuideIDs)
                    assigned[g, default: []].append((fixture.start.addingTimeInterval(Double(rng.int(1800)) - 900), fixture.title, true))
                }
                // Same team against a different opponent elsewhere (conflict).
                if !fixture.homeName.isEmpty, rng.chance(0.3), let g = sportsGuideIDs.randomElementDeterministic(&rng) {
                    assigned[g, default: []].append((fixture.start.addingTimeInterval(86_400 / 2), "\(fixture.homeName) v Opponent United", true))
                }
            }
            for g in guideIDs {
                let key = scoped ? sourceID.uuidString.lowercased() + "|" + g : g
                var rows: [EPGProgram] = []
                let special = (assigned[g] ?? []).sorted { $0.0 < $1.0 }
                var t = now.addingTimeInterval(-3 * 3600 - Double(rng.int(3600)))
                let end = now.addingTimeInterval(50 * 3600)
                var si = 0
                var pid = 0
                while t < end {
                    if si < special.count, special[si].0 <= t.addingTimeInterval(4 * 3600) {
                        let s = max(t, special[si].0)
                        if s > t {
                            rows.append(EPGProgram(id: "\(g)-\(pid)", channelID: g, title: rng.pick(fillerTitles), description: "", start: t, end: s)); pid += 1
                        }
                        var desc = (0..<(15 + rng.int(60))).map { _ in rng.pick(descWords) }.joined(separator: " ")
                        desc = special[si].1 + ". " + desc.prefix(1).uppercased() + desc.dropFirst()
                        rows.append(EPGProgram(id: "\(g)-\(pid)", channelID: g, title: special[si].1, description: desc,
                                               start: s, end: s.addingTimeInterval(3 * 3600))); pid += 1
                        t = s.addingTimeInterval(3 * 3600); si += 1
                        continue
                    }
                    let duration = Double(60 + rng.int(6) * 60) * 60
                    let desc = (0..<(10 + rng.int(70))).map { _ in rng.pick(descWords) }.joined(separator: " ")
                    rows.append(EPGProgram(id: "\(g)-\(pid)", channelID: g, title: rng.pick(fillerTitles), description: desc,
                                           start: t, end: t.addingTimeInterval(duration))); pid += 1
                    t = t.addingTimeInterval(duration)
                }
                programs[key] = rows
            }
            allGroups = sportGroups + generalGroups
        }

        var quality: [String: StreamMatchQuality] = [:]
        var favorites = Set<String>()
        var channelScores: [String: Double] = [:]
        for channel in channels {
            let key = channel.preferenceIdentity
            if rng.chance(0.3) {
                var q = StreamMatchQuality()
                q.availability = rng.chance(0.1) ? .failed : .observedAvailable
                q.isUnstable = rng.chance(0.1)
                q.healthySeconds = Double(rng.int(200))
                q.observedHeight = rng.pick([0, 576, 720, 1080, 2160])
                q.observedFPS = rng.pick([0, 25, 30, 50, 60])
                q.observedBitRate = Int64(rng.int(20_000_000))
                q.observedSeconds = Double(rng.int(600))
                q.bufferingSeconds = Double(rng.int(30))
                quality[key] = q
            }
            if rng.chance(0.004) { favorites.insert(key) }
            if rng.chance(0.01) { channelScores[key] = Double(rng.int(100)) / 100 }
        }
        let groupScores = Dictionary(uniqueKeysWithValues: allGroups.prefix(10).map { ($0, Double(rng.int(100)) / 100) })
        return SportsMatchingFixture(now: now, channels: channels, programs: programs, hiddenGroups: ["Hidden Sports"],
                                     events: events, quality: quality, favorites: favorites,
                                     channelScores: channelScores, groupScores: groupScores)
    }
}

extension Array {
    nonisolated fileprivate func randomElementDeterministic(_ rng: inout SportsMatchingFixture.RNG) -> Element? {
        isEmpty ? nil : self[rng.int(count)]
    }
}
