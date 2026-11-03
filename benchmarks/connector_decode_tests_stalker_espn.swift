import Foundation

enum StalkerAndESPNDifferential {
    typealias T = ConnectorDecodeTests

    static func data(_ text: String) -> Data { Data(text.utf8) }

    static func compareStalkerChannels(_ payload: Data, _ categories: Data, _ label: String) {
        let cats = (try? StalkerClient.decodeCategories(categories)) ?? [:]
        let legacyCats = (try? LegacyStalker.categories(categories)) ?? [:]
        T.expectEqual(outcome { try StalkerClient.decodeChannels(payload, categories: cats).map(describe) },
                      outcome { try LegacyStalker.channels(payload, categories: legacyCats).map(describe) }, label)
        T.expectEqual(outcome { try StalkerClient.decodeCategories(categories).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } },
                      outcome { try LegacyStalker.categories(categories).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } },
                      label + " categories")
    }

    static let epgChannels: [Channel] = (0..<30).map { i in
        Channel(id: "\(i + 1)", name: "c", logoURL: nil, group: "g", streamURL: URL(string: "http://x/\(i)")!,
                epgChannelID: i % 3 == 0 ? nil : "guide-\(i + 1)")
    }

    /// The reference iterates a dictionary, so programme order is unspecified: compare sorted.
    /// Which malformed value its error names also follows dictionary order
    /// (different per decode), so failures compare by kind only.
    static func compareStalkerEPG(_ payload: Data, _ label: String) {
        func kindOnly(_ result: Outcome) -> Outcome {
            if case .failure(let text) = result { return .failure(String(text.prefix(while: { $0 != ":" }))) }
            return result
        }
        T.expectEqual(kindOnly(outcome { try StalkerClient.decodeEPG(payload, channels: epgChannels).map(describe).sorted() }),
                      kindOnly(outcome { try LegacyStalker.epg(payload, channels: epgChannels).map(describe).sorted() }), label)
    }

    static func compareStalkerMedia(_ payload: Data, _ label: String) {
        let categories = ["1": "Action", "2": "Drama", "7": "Kids"]
        T.expectEqual(outcome {
            let page = try StalkerClient.decodeMediaPage(payload, categories: categories)
            return ["\(page.total)|\(page.pageSize)"] + page.vod.map(describe) + page.series.map(describe)
        }, outcome {
            let page = try LegacyStalker.mediaPage(payload)
            return ["\(page.total)|\(page.pageSize)"] + LegacyStalker.vodItems(page.items, categories: categories).map(describe)
                + LegacyStalker.series(page.items, categories: categories).map(describe)
        }, label)
    }

    static func run(mutator: inout Mutator, rounds: Int) {
        // MARK: Stalker
        let genres = ConnectorFixtures.stalkerGenres()
        let declines = ConnectorJSONDecline.count
        compareStalkerChannels(ConnectorFixtures.stalkerChannels(count: 2000), genres, "stalker channels fixture")
        compareStalkerEPG(ConnectorFixtures.stalkerEPG(channels: 30, entries: 40), "stalker epg fixture")
        compareStalkerMedia(ConnectorFixtures.stalkerMediaPage(count: 300, total: 900), "stalker media fixture")
        T.expectFastPath(declines, "stalker fixtures")

        let channelQuirks = [
            "{\"js\":{\"total_items\":1,\"max_page_items\":1,\"data\":[]}}", "{\"js\":{\"data\":[]}}", "{}", "[]", "",
            "{\"js\":{\"total_items\":\"1\",\"max_page_items\":1,\"data\":[]}}", "{\"js\":{\"total_items\":1.0,\"max_page_items\":2e1,\"data\":[]}}",
            "{\"js\":{\"total_items\":1,\"max_page_items\":1,\"data\":[{\"id\":1,\"cmd\":\"x\"}]}}",
            "{\"js\":{\"total_items\":1,\"max_page_items\":1,\"data\":[{\"cmd\":\"ffmpeg http://a/b\"}]}}",
            "{\"js\":{\"total_items\":1,\"max_page_items\":1,\"data\":[{\"id\":\"1\",\"cmd\":\"  ffmpeg  http://a/b \"},{\"id\":\"2\",\"cmd\":\"auto \\thttp://c/d\\t\"},{\"id\":\"3\",\"cmd\":\"   \"},{\"id\":\"4\"},{\"id\":\"5\",\"cmd\":null}]}}",
            "{\"js\":{\"total_items\":1,\"max_page_items\":1,\"data\":[{\"id\":\"6\",\"cmd\":\"http://a/b\",\"tv_genre_id\":7.9,\"genres_str\":\"n/a\",\"xmltv_id\":\" N/A \",\"enable_tv_archive\":true,\"tv_archive_duration\":\"3\"}]}}",
            "{\"js\":{\"total_items\":1,\"max_page_items\":1,\"data\":[{\"id\":\"7\",\"cmd\":\"http://a/b\",\"tv_genre_id\":null,\"enable_tv_archive\":\"2\",\"tv_archive_duration\":-4.5},{\"id\":\"8\",\"cmd\":\"http://a/\u{e9}\",\"enable_tv_archive\":[1]}]}}",
            "{\"js\":{\"total_items\":1,\"max_page_items\":1,\"data\":[{\"id\":\"9\",\"cmd\":\"http://a/b\",\"name\":5}]}}",
            "{\"js\":{\"total_items\":1,\"max_page_items\":1,\"data\":[{\"id\":\"11\",\"cmd\":\"http://a/b\",\"genres_str\":\"\\u00a0\",\"tv_genre_id\":\"\\u0037\"}]},\"js\":5}",
        ]
        for (k, payload) in channelQuirks.enumerated() { compareStalkerChannels(data(payload), genres, "stalker channel quirk \(k)") }
        let genreQuirks = ["{\"js\":[{\"id\":\"7\",\"title\":\" \",\"alias\":\"n/A\"},{\"id\":\"7\",\"title\":\"Second\"}]}", "{\"js\":[{\"id\":7}]}",
                           "{\"js\":{}}", "{\"js\":[{\"id\":\"*\",\"title\":\"All\"},{\"id\":\"\\u212a\",\"title\":\"Kelvin\"},{\"id\":\"K\",\"title\":\"K\"}]}"]
        let genreProbe = data("{\"js\":{\"total_items\":1,\"max_page_items\":1,\"data\":[{\"id\":\"1\",\"cmd\":\"http://a/b\",\"tv_genre_id\":\"7\"},{\"id\":\"2\",\"cmd\":\"http://a/b\",\"tv_genre_id\":\"K\"}]}}")
        for (k, payload) in genreQuirks.enumerated() { compareStalkerChannels(genreProbe, data(payload), "stalker genre quirk \(k)") }

        let epgQuirks = [
            "{\"js\":{\"data\":[]}}", "{\"js\":{\"data\":{}}}", "{\"js\":[]}",
            "{\"js\":{\"data\":{\"1\":[{\"name\":\"A\",\"start_timestamp\":100,\"stop_timestamp\":\"200\"}],\"1\":[]}}}",
            "{\"js\":{\"data\":{\"\\u0031\":[{\"name\":\"A\",\"start_timestamp\":100,\"stop_timestamp\":200}]}}}",
            "{\"js\":{\"data\":{\"2\":[{\"name\":\" N/a \",\"start_timestamp\":100,\"stop_timestamp\":200},{\"name\":\"B\",\"start_timestamp\":100.7,\"stop_timestamp\":\"200.5\",\"id\":true,\"ch_id\":\"5\"}]}}}",
            "{\"js\":{\"data\":{\"3\":[{\"name\":\"C\",\"start_timestamp\":\"+100\",\"stop_timestamp\":\" 200\",\"descr\":null},{\"name\":\"D\",\"start_timestamp\":0,\"stop_timestamp\":5}]}}}",
            "{\"js\":{\"data\":{\"4\":[{\"name\":7,\"start_timestamp\":100,\"stop_timestamp\":200}]}}}",
            "{\"js\":{\"data\":{\"caf\u{e9}\":[{\"name\":\"E\",\"start_timestamp\":100,\"stop_timestamp\":200}]}}}",
            "{\"js\":{\"data\":{\"7\":[{\"name\":\"fake ],\\\"8\\\":[ boundary inside a string, padded past the forced chunk size\",\"start_timestamp\":100,\"stop_timestamp\":200}],\"8\":[{\"name\":\"],\\\"9\\\": [\",\"start_timestamp\":100,\"stop_timestamp\":200}],\"9\":[]}}}",
            "{\"js\":{\"data\":{\"1\":[{\"name\":\"A\",\"start_timestamp\":100,\"stop_timestamp\":200}],\"2\":[{\"name\":\"B\",\"start_timestamp\":100,\"stop_timestamp\":200}],\"1\":[{\"name\":\"dup\",\"start_timestamp\":100,\"stop_timestamp\":200}]}}}",
            "{\"js\":{\"data\":{\"5\":[{\"name\":\"F\",\"start_timestamp\":100,\"stop_timestamp\":200,\"ch_id\":\"\",\"id\":\"  \"}],\"6\":null}}}",
        ]
        for (k, payload) in epgQuirks.enumerated() { compareStalkerEPG(data(payload), "stalker epg quirk \(k)") }

        let mediaQuirks = [
            "{\"js\":{\"total_items\":0,\"max_page_items\":14,\"data\":[]}}",
            "{\"js\":{\"total_items\":2,\"max_page_items\":14,\"data\":[{\"id\":\"1\",\"cmd\":\"/m/1\",\"series\":[1,2.0],\"category_id\":7,\"rating_imdb\":6.6,\"year\":\"N/A\",\"added\":\" 2020 \"},{\"id\":\"2\",\"series\":null,\"pic\":\" \",\"screenshot_uri\":\"\"}]}}",
            "{\"js\":{\"total_items\":1,\"max_page_items\":14,\"data\":[{\"id\":\"3\",\"series\":[1.5]}]}}",
            "{\"js\":{\"total_items\":1,\"max_page_items\":14,\"data\":[{\"id\":\"4\",\"series\":[\"1\"]}]}}",
            "{\"js\":{\"total_items\":1,\"max_page_items\":14,\"data\":[{\"id\":\"5\",\"year\":2020}]}}",
            "{\"js\":{\"total_items\":1,\"max_page_items\":14,\"data\":[{\"id\":\"6\",\"cmd\":\"a b&c=d\",\"screenshot_uri\":\"not a url\",\"pic\":\"http://p/x.jpg\"}]}}",
        ]
        for (k, payload) in mediaQuirks.enumerated() { compareStalkerMedia(data(payload), "stalker media quirk \(k)") }

        let channelSeed = ConnectorFixtures.stalkerChannels(count: 3)
        let epgSeed = ConnectorFixtures.stalkerEPG(channels: 2, entries: 3)
        let mediaSeed = ConnectorFixtures.stalkerMediaPage(count: 3, total: 3)
        for round in 0..<rounds / 2 {
            compareStalkerChannels(mutator.mutate(channelSeed), genres, "stalker channel mutation \(round)")
            compareStalkerEPG(mutator.mutate(epgSeed), "stalker epg mutation \(round)")
            compareStalkerMedia(mutator.mutate(mediaSeed), "stalker media mutation \(round)")
        }

        ESPNDifferential.run(mutator: &mutator, rounds: rounds)
    }
}

enum ESPNDifferential {
    typealias T = ConnectorDecodeTests
    static let legacy = LegacyESPN()
    nonisolated(unsafe) static var formatters: [ISO8601DateFormatter] = legacy.dateFormatters

    /// The production parser with the production date rule (bytes first,
    /// formatters otherwise) — as ESPNClient constructs it.
    static let parser = ESPNScoreboardParser(parseDate: { string in
        ESPNScoreboardParser.fastDate(string) ?? legacy.parseDate(string)
    })

    static func league(_ slug: String) -> League { League.all.first { $0.slug == slug }! }

    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: #"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"#, with: "<uuid>", options: .regularExpression)
    }

    static func compareScoreboard(_ data: Data, league: League, _ label: String) {
        let document = ESPNDocument(data)
        T.expectEqual(.value([String(parser.isValidScoreboard(document)), String(describing: parser.eventCount(document))]
                             + parser.parse(document, league: league).map { normalize(describe($0)) }
                             + parser.golfEventIDs(document)),
                      .value([String(legacy.scoreboardIsValid(data)), String(describing: legacy.eventCount(data))]
                             + legacy.parse(data: data, league: league).map { normalize(describe($0)) }
                             + legacy.golfEventIDs(data)), label)
    }

    static func compareGolf(_ data: Data, _ label: String) {
        let golf = league("pga")
        T.expectEqual(.value(parser.golfRounds(ESPNDocument(data), league: golf).map { describe($0) }),
                      .value(legacy.golfRounds(data, league: golf).map { describe($0) }), label)
    }

    static func run(mutator: inout Mutator, rounds: Int) {
        // Dates: byte parser == formatters wherever it answers.
        var rng = FixtureRNG(77)
        let iso = ISO8601DateFormatter()
        var dateCases = ["2026-04-15T23:30Z", "2026-04-15T23:30:00Z", "2024-02-29T00:00Z", "2023-02-29T00:00Z", "2026-13-01T00:00Z",
                         "2026-04-31T10:00Z", "2026-04-15T24:00Z", "2026-04-15T23:60Z", "2026-04-15T23:59:60Z", "2026-04-15T23:30:00.5Z",
                         "2026-04-15T23:30+01:00", "2026-04-15t23:30z", "1899-12-31T23:59Z", "2200-12-31T23:59:59Z", "2026-4-15T23:30Z", ""]
        for _ in 0..<20_000 {
            let date = Date(timeIntervalSince1970: Double(rng.int(4_000_000_000)) - 1_000_000_000)
            var text = iso.string(from: date)
            if rng.chance(50) { text = String(text.dropLast(4)) + "Z" }
            dateCases.append(text)
        }
        for text in dateCases {
            guard let fast = ESPNScoreboardParser.fastDate(text) else { continue }
            if fast != legacy.parseDate(text) {
                T.failures += 1
                print("FAIL fastDate \(text): \(fast) vs \(legacy.parseDate(text))")
            }
        }

        let declines = ConnectorJSONDecline.count
        let nba = league("nba"), nfl = league("nfl")
        compareScoreboard(ConnectorFixtures.espnScoreboard(events: 15), league: nba, "espn nba fixture")
        compareScoreboard(ConnectorFixtures.espnScoreboard(events: 40, seed: 3), league: nfl, "espn nfl fixture")
        let tennis = League.all.first { $0.sport == .tennis }!
        let motorsport = League.all.first { $0.sport == .motorsport }!
        compareScoreboard(ConnectorFixtures.espnTennis(matches: 120), league: tennis, "espn tennis fixture")
        compareScoreboard(ConnectorFixtures.espnMotorsport(), league: motorsport, "espn motorsport fixture")
        compareScoreboard(ConnectorFixtures.espnMotorsport(), league: nba, "espn motorsport payload as nba")
        compareScoreboard(ConnectorFixtures.espnTennis(matches: 10), league: nba, "espn tennis payload as nba")
        compareGolf(ConnectorFixtures.espnGolfLeaderboard(players: 150), "espn golf leaderboard fixture")
        T.expectFastPath(declines, "espn fixtures")
        let produced = [parser.parse(ESPNDocument(ConnectorFixtures.espnScoreboard(events: 15)), league: nba).count,
                        parser.parse(ESPNDocument(ConnectorFixtures.espnTennis(matches: 120)), league: tennis).count,
                        parser.parse(ESPNDocument(ConnectorFixtures.espnMotorsport()), league: motorsport).count,
                        parser.golfRounds(ESPNDocument(ConnectorFixtures.espnGolfLeaderboard(players: 150)), league: league("pga")).count]
        if produced.contains(0) { T.failures += 1; print("FAIL espn fixtures produced no events \(produced)") }

        let quirks = [
            "{}", "[]", "", "{\"events\":[]}", "{\"events\":null}", "{\"events\":[1]}", "{\"events\":[{}]}", "{\"message\":\"Unavailable\"}",
            "{\"events\":[{\"id\":1,\"name\":\"x\",\"date\":\"2026-04-15T23:30Z\"}]}",
            "{\"events\":[{\"id\":\"1\",\"name\":\"x\",\"date\":\"bad\"},{\"id\":\"2\",\"name\":\"y\",\"date\":\"2026-04-15T23:30:00.250Z\"}]}",
            "{\"events\":[{\"id\":\"3\",\"name\":\"z\",\"date\":\"2026-04-15T23:30Z\",\"status\":{\"type\":{\"state\":\"in\",\"shortDetail\":\"\",\"detail\":\"\"}},\"competitions\":[{\"status\":{\"type\":{\"shortDetail\":\"End of 1st Half\"}},\"competitors\":[{\"homeAway\":\"home\",\"team\":{\"name\":\"N\",\"logo\":\"not a url\"},\"records\":[{\"type\":\"total\",\"summary\":\"1-2\"},{\"name\":\"overall\",\"summary\":\"9-9\"}]},{\"homeAway\":\"\\u0068ome\",\"score\":5}]}]}]}",
            "{\"events\":[{\"id\":\"4\",\"name\":\"w\",\"date\":\"2026-04-15T23:30Z\",\"status\":{\"type\":{\"state\":\"pre\",\"shortDetail\":\"CANCELLED\"}},\"venue\":{\"fullName\":\"Event venue\"},\"competitions\":[{\"venue\":{},\"geoBroadcasts\":[{\"media\":{}},{\"media\":{\"shortName\":7}}],\"broadcasts\":[{\"names\":[\"A\",1]},{\"names\":[\"B\",\"B\"]}]}]}]}",
            "{\"events\":[{\"id\":\"5\",\"name\":\"v\",\"date\":\"2026-04-15T23:30Z\",\"competitions\":[{\"competitors\":[{\"order\":true,\"athlete\":{\"shortName\":\"S\"},\"score\":\"-1\"},{\"order\":1.0}]}]},{\"id\":\"5\",\"name\":\"v\",\"date\":\"2026-04-15T23:30Z\",\"competitions\":[]}]}",
            "{\"events\":[{\"id\":\"6\",\"name\":\"u\",\"date\":\"2026-04-15T23:30Z\",\"id\":\"dup\",\"competitions\":{\"not\":\"array\"},\"status\":[]}]}",
            "{\"events\":[{\"id\":\"7\",\"n\\u0061me\":\"escaped key\",\"date\":\"2026-04-15T23:30Z\"}]}",
            "{\"events\":[{\"id\":\"8\",\"name\":\"caf\\u00e9 \\ud83c\\udfc6\",\"date\":\"2026-04-15T23:30Z\",\"compet\u{e9}\":1}]}",
            "{\"events\":[{\"id\":\"\u{FEFF}10\",\"name\":\"\\ufeff\u{FEFF}bom\",\"date\":\"\u{FEFF}2026-04-15T23:30Z\",\"status\":{\"type\":{\"state\":\"\u{FEFF}in\"}}}]}",
            "{\"events\":[{\"id\":\"9\",\"name\":\"t\",\"date\":\"2026-04-15T23:30Z\",\"groupings\":[]}],\"events\":[]}",
        ]
        for (k, payload) in quirks.enumerated() {
            for sportLeague in [nba, tennis, motorsport] { compareScoreboard(Data(payload.utf8), league: sportLeague, "espn quirk \(k) \(sportLeague.slug)") }
        }
        let tennisQuirks = [
            "{\"events\":[{\"id\":\"1\",\"name\":\"Open\",\"date\":\"2026-04-15T23:30Z\",\"groupings\":[{\"competitions\":[{\"status\":{\"type\":{\"state\":\"post\"}},\"date\":\"2000-01-01T00:00Z\"},{\"status\":{\"type\":{\"state\":\"post\"}}},{\"competitors\":[{\"athlete\":{\"displayName\":\"TBD\"}},{}]},{\"competitors\":[{\"linescores\":[{\"value\":6},{\"value\":\"7\"},{},{\"value\":true}],\"homeAway\":\"home\",\"athlete\":{\"fullName\":\"Full\",\"flag\":{\"href\":\"https://x/f.png\"}}},{\"linescores\":[],\"score\":\"2\"}]}]}]}]}",
            "{\"events\":[{\"id\":\"2\",\"name\":\"Open\",\"date\":\"2026-04-15T23:30Z\",\"groupings\":[{\"competitions\":[{\"competitors\":[{\"linescores\":[{\"value\":6.75},{\"value\":-3.5}]}]}]}]}]}",
            "{\"events\":[{\"id\":\"3\",\"name\":\"Open\",\"date\":\"2026-04-15T23:30Z\",\"groupings\":[{\"competitions\":\"x\"}]}]}",
        ]
        for (k, payload) in tennisQuirks.enumerated() { compareScoreboard(Data(payload.utf8), league: tennis, "espn tennis quirk \(k)") }
        let golfQuirks = [
            "{\"events\":[]}", "{\"events\":[{\"id\":\"1\",\"name\":\"G\"}]}",
            "{\"events\":[{\"id\":\"1\",\"name\":\"G\",\"competitions\":[{\"status\":{\"period\":\"2\",\"type\":{\"state\":\"post\"}},\"competitors\":[{\"linescores\":[{\"period\":3,\"value\":null},{\"period\":1.0,\"teeTime\":\"2026-04-15T12:00Z\"},{\"period\":\"2\"}],\"order\":2,\"athlete\":{\"displayName\":\"A\"},\"score\":{\"displayValue\":\"\"}},{\"sortOrder\":1,\"athlete\":{\"shortName\":\"B\"},\"score\":\"-4\"}]}],\"courses\":[{}],\"date\":\"2026-04-14T00:00Z\"}]}",
        ]
        for (k, payload) in golfQuirks.enumerated() { compareGolf(Data(payload.utf8), "espn golf quirk \(k)") }

        let scoreboardSeed = ConnectorFixtures.espnScoreboard(events: 1, seed: 11)
        let tennisSeed = ConnectorFixtures.espnTennis(matches: 3)
        let golfSeed = ConnectorFixtures.espnGolfLeaderboard(players: 3)
        for round in 0..<rounds / 2 {
            compareScoreboard(mutator.mutate(scoreboardSeed), league: nba, "espn mutation \(round)")
            let t = mutator.mutate(tennisSeed)
            let before = T.failures
            compareScoreboard(t, league: tennis, "espn tennis mutation \(round)")
            let g = mutator.mutate(golfSeed)
            compareGolf(g, "espn golf mutation \(round)")
            if T.failures != before, CommandLine.arguments.contains("--dump") {
                try? t.write(to: URL(fileURLWithPath: ".local/scratch/fail-tennis-\(round).json"))
                try? g.write(to: URL(fileURLWithPath: ".local/scratch/fail-golf-\(round).json"))
            }
        }
    }
}
