import Foundation

enum StalkerESPNBench {
    static let legacyESPN = LegacyESPN()
    static let parser = ESPNScoreboardParser(parseDate: { ESPNScoreboardParser.fastDate($0) ?? legacyESPN.parseDate($0) })

    static func cases() -> [BenchCase] {
        let nba = League.all.first { $0.slug == "nba" }!
        let pga = League.all.first { $0.slug == "pga" }!
        let genreData = ConnectorFixtures.stalkerGenres()
        let stalkerCategories = try! LegacyStalker.categories(genreData)
        let epgChannels: [Channel] = (0..<3000).map { i in
            Channel(id: "\(i + 1)", name: "c", logoURL: nil, group: "g", streamURL: URL(string: "http://x/\(i)")!, epgChannelID: "guide-\(i + 1)")
        }
        return [
            BenchCase(name: "stalker.all_channels.30k", prepare: {
                cachedFixture("stalker30k") { ConnectorFixtures.stalkerChannels(count: 30_000) }
            }, legacy: { input in
                try! LegacyStalker.channels(input as! Data, categories: stalkerCategories).count
            }, fast: { input in
                try! StalkerClient.decodeChannels(input as! Data, categories: stalkerCategories).count
            }),
            BenchCase(name: "stalker.epg_info.3k_channels", prepare: {
                cachedFixture("stalkerepg3k") { ConnectorFixtures.stalkerEPG(channels: 3000, entries: 24) }
            }, legacy: { input in
                try! LegacyStalker.epg(input as! Data, channels: epgChannels).count
            }, fast: { input in
                try! StalkerClient.decodeEPG(input as! Data, channels: epgChannels).count
            }),
            BenchCase(name: "stalker.media_pages.200x14", prepare: {
                cachedFixtures("stalkermedia200", count: 200) { ConnectorFixtures.stalkerMediaPage(count: 14, total: 2800, offset: $0 * 14) }
            }, legacy: { input in
                (input as! [Data]).reduce(0) { total, page in
                    let decoded = try! LegacyStalker.mediaPage(page)
                    return total + LegacyStalker.vodItems(decoded.items, categories: stalkerCategories).count
                }
            }, fast: { input in
                (input as! [Data]).reduce(0) { $0 + (try! StalkerClient.decodeMediaPage($1, categories: stalkerCategories)).vod.count }
            }),
            BenchCase(name: "espn.scoreboard.day_nba_15", prepare: {
                ConnectorFixtures.espnScoreboard(events: 15, baseDate: Date(timeIntervalSince1970: 1_790_000_000))
            }, legacy: { input in
                let data = input as! Data
                // validate + parse, as the client did (two JSONSerialization passes)
                precondition(legacyESPN.scoreboardIsValid(data))
                return legacyESPN.parse(data: data, league: nba).count
            }, fast: { input in
                let document = ESPNDocument(input as! Data)
                precondition(parser.isValidScoreboard(document))
                return parser.parse(document, league: nba).count
            }),
            BenchCase(name: "espn.scoreboard.week_nfl_250", prepare: {
                ConnectorFixtures.espnScoreboard(events: 250, seed: 5, baseDate: Date(timeIntervalSince1970: 1_790_000_000))
            }, legacy: { input in
                let data = input as! Data
                precondition(legacyESPN.scoreboardIsValid(data))
                return legacyESPN.parse(data: data, league: nba).count
            }, fast: { input in
                let document = ESPNDocument(input as! Data)
                precondition(parser.isValidScoreboard(document))
                return parser.parse(document, league: nba).count
            }),
            BenchCase(name: "espn.golf_leaderboard.150", prepare: {
                ConnectorFixtures.espnGolfLeaderboard(players: 150, baseDate: Date(timeIntervalSince1970: 1_790_000_000))
            }, legacy: { input in
                legacyESPN.golfRounds(input as! Data, league: pga).count
            }, fast: { input in
                parser.golfRounds(ESPNDocument(input as! Data), league: pga).count
            }),
        ]
    }
}
