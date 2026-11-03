import Foundation

// Differential tests: production connector decoders vs the frozen reference
// decoders (benchmarks/legacy_connector_decoders.swift) on synthetic payloads,
// hand-written provider quirks and random mutations. Built by
// scripts/test-connectors.sh.

enum Outcome: Equatable {
    case value([String])
    case failure(String)
}

func outcome(_ body: () throws -> [String]) -> Outcome {
    do { return .value(try body()) } catch {
        // NSError userInfo prints in hash order; compare everything else.
        let text = String(describing: error)
        return .failure(text.replacingOccurrences(of: #"(?s)UserInfo=.*"#, with: "", options: .regularExpression))
    }
}

func describe(_ c: Channel) -> String {
    "\(c.id)|\(c.name)|\(c.logoURL?.absoluteString ?? "-")|\(c.group)|\(c.streamURL.absoluteString)|\(c.epgChannelID ?? "-")|\(c.catchup.map { "\($0.kind.rawValue):\($0.days):\($0.source ?? "-")" } ?? "-")|\(c.contentType.rawValue)"
}

func describe(_ p: EPGProgram) -> String {
    "\(p.id)|\(p.channelID)|\(p.title)|\(p.description)|\(p.start.timeIntervalSinceReferenceDate.bitPattern)|\(p.end.timeIntervalSinceReferenceDate.bitPattern)"
}

func describe(_ v: VODItem) -> String {
    [v.id, v.name, v.posterURL?.absoluteString ?? "-", v.group, v.streamURL.absoluteString, v.kind.rawValue, v.genre ?? "-",
     v.durationSeconds.map(String.init) ?? "-", v.rating ?? "-", v.releaseDate ?? "-", v.containerExtension ?? "-",
     v.summary ?? "-", v.director ?? "-", v.cast ?? "-", v.country ?? "-", v.seasonNumber.map(String.init) ?? "-",
     v.episodeNumber.map(String.init) ?? "-"].joined(separator: "|")
}

func describe(_ s: VODSeries) -> String {
    [s.id, s.name, s.posterURL?.absoluteString ?? "-", s.group, s.genre ?? "-", s.rating ?? "-", s.releaseDate ?? "-",
     s.summary ?? "-", s.director ?? "-", s.cast ?? "-", s.episodeCount.map(String.init) ?? "-"].joined(separator: "|")
}

func describe(_ t: TeamInfo?) -> String {
    guard let t else { return "-" }
    return "\(t.name)/\(t.abbreviation)/\(t.displayName)/\(t.score ?? "-")/\(t.logoURL?.absoluteString ?? "-")/\(t.record ?? "-")"
}

func describe(_ e: SportEvent, stableIDs: Bool = true) -> String {
    let status: String
    switch e.status {
    case .scheduled: status = "scheduled"
    case .live(let d): status = "live:\(d ?? "nil")"
    case .halftime: status = "halftime"
    case .delayed: status = "delayed"
    case .postponed: status = "postponed"
    case .canceled: status = "canceled"
    case .final_(let d): status = "final:\(d ?? "nil")"
    }
    let id = stableIDs ? e.id : String(e.id.prefix(while: { $0 != "_" }))
    return [id, e.sport.rawValue, e.league.id, e.title, e.shortTitle, describe(e.homeTeam), describe(e.awayTeam),
            "\(e.startDate.timeIntervalSinceReferenceDate.bitPattern)", status, e.broadcast.sorted().joined(separator: ","),
            e.venue ?? "-", e.detail ?? "-", e.tournamentName ?? "-", e.leader.map { "\($0.name)=\($0.score)" } ?? "-"].joined(separator: "|")
}

struct Mutator {
    var rng: FixtureRNG
    static let tokens: [String] = ["\"", ",", ":", "{", "}", "[", "]", "1", "0", "-", ".", "e", "null", "true", "\\", "\\u00e9",
                                   "\\ud83d", " ", "\"1\"", "\"x\"", "1.5", "\u{FEFF}", "é", "\n", "\"\"", "2.0", "1e2"]
    mutating func mutate(_ data: Data) -> Data {
        var bytes = Array(data)
        for _ in 0..<(1 + rng.int(3)) {
            guard !bytes.isEmpty else { break }
            let at = rng.int(bytes.count)
            switch rng.int(4) {
            case 0: bytes.remove(at: at)
            case 1: bytes.insert(contentsOf: Array(Self.tokens[rng.int(Self.tokens.count)].utf8), at: at)
            case 2: bytes.replaceSubrange(at..<min(bytes.count, at + 1 + rng.int(3)), with: Array(Self.tokens[rng.int(Self.tokens.count)].utf8))
            default: bytes[at] = UInt8(truncatingIfNeeded: rng.next())
            }
        }
        return Data(bytes)
    }
}

@main
struct ConnectorDecodeTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var compared = 0

    static func expectEqual(_ fast: Outcome, _ reference: Outcome, _ label: String) {
        compared += 1
        guard fast != reference else { return }
        failures += 1
        guard failures <= 20 else { return }
        print("FAIL \(label)")
        switch (fast, reference) {
        case (.value(let a), .value(let b)):
            print("  counts fast=\(a.count) reference=\(b.count)")
            if let index = zip(a, b).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
                print("  fast:      \(a[index])\n  reference: \(b[index])")
            }
        default:
            print("  fast=\(String(describing: fast).prefix(400))\n  reference=\(String(describing: reference).prefix(400))")
        }
    }

    static let config = ConnectorFixtures.config

    /// Fixture payloads must be decoded by the fast path, not the fallback.
    static func expectFastPath(_ before: Int, _ label: String) {
        if ConnectorJSONDecline.count != before {
            failures += 1
            print("FAIL \(label) declined \(ConnectorJSONDecline.count - before) times")
        }
    }

    static func compareChannels(_ streams: Data, _ categories: Data, _ label: String) {
        let fast = outcome { try XtreamClient.decodeChannels(streams: streams, categories: categories, config: config).map(describe) }
        let reference = outcome {
            let cats = try LegacyXtream.categories(categories)
            return try LegacyXtream.channels(streams, categories: cats, config: config).map(describe)
        }
        expectEqual(fast, reference, label)
    }

    static func compareVOD(_ streams: Data, _ categories: Data, _ label: String) {
        let table = (try? XtreamClient.decodeCategoryTable(categories)) ?? .empty
        let dictionary = (try? LegacyXtream.categories(categories)) ?? [:]
        expectEqual(outcome { try XtreamClient.decodeVODItems(streams: streams, categories: table, config: config).map(describe) },
                    outcome { try LegacyXtream.vodItems(streams, categories: dictionary, config: config).map(describe) }, label)
    }

    static func compareSeries(_ data: Data, _ categories: Data, _ label: String) {
        let table = (try? XtreamClient.decodeCategoryTable(categories)) ?? .empty
        let dictionary = (try? LegacyXtream.categories(categories)) ?? [:]
        expectEqual(outcome { try XtreamClient.decodeSeries(data, categories: table).map(describe) },
                    outcome { try LegacyXtream.series(data, categories: dictionary).map(describe) }, label)
    }

    static func compareCatchup(_ data: Data, minimumStart: Date?, _ label: String) {
        let fast = outcome {
            let r = try XtreamClient.decodeCatchupListings(data, channelID: "77", epgID: "guide.77", minimumStart: minimumStart)
            return r.programs.map(describe) + ["\(r.receivedListings)|\(r.responseEarliestEpoch)|\(r.responseLatestEpoch)"]
        }
        let reference = outcome {
            let r = try LegacyXtream.catchupListings(data, channelID: "77", epgID: "guide.77", minimumStart: minimumStart)
            return r.programs.map(describe) + ["\(r.receivedListings)|\(r.earliest)|\(r.latest)"]
        }
        expectEqual(fast, reference, label)
    }

    static func data(_ text: String) -> Data { Data(text.utf8) }

    static func main() {
        let rounds = CommandLine.arguments.contains("--quick") ? 300 : 3000
        // Default chunking, then tiny chunks so every payload is split at
        // (candidate) element boundaries, including mutated ones.
        runSuite(mutationRounds: rounds)
        ConnectorParallel.minimumChunkBytes = 48
        ConnectorParallel.facadeRowsPerTask = 3
        runSuite(mutationRounds: rounds)
        print("forced chunking: parallel decodes \(ConnectorParallel.parallelDecodes), misaligned-chunk fallbacks \(ConnectorParallel.chunkFallbacks)")
        if ConnectorParallel.parallelDecodes == 0 || ConnectorParallel.chunkFallbacks == 0 {
            failures += 1
            print("FAIL forced chunking did not exercise both the parallel and the fallback path")
        }
        if failures > 0 {
            print("FAILURES \(failures) of \(compared) comparisons")
            exit(1)
        }
        print("PASS connector decoders equal reference on \(compared) payloads (fixtures, provider quirks, mutations; default and forced chunking)")
    }

    static func runSuite(mutationRounds: Int) {
        let categories = ConnectorFixtures.liveCategories()

        // MARK: Xtream live streams
        let declinesBefore = ConnectorJSONDecline.count
        compareChannels(ConnectorFixtures.liveStreams(count: 3000), categories, "live fixtures")
        compareChannels(ConnectorFixtures.liveStreams(count: 500, quirks: false), categories, "live plain")
        expectFastPath(declinesBefore, "live fixtures")
        let liveQuirks = [
            "[]", " [ ] ", "", "{}", "null", "[null]", "[1]", "[{}]", "[{},]", "\u{FEFF}[{\"stream_id\":1}]",
            "[{\"stream_id\":1,\"name\":7}]", "[{\"stream_id\":1,\"name\":null,\"stream_icon\":\"\",\"epg_channel_id\":\" \"}]",
            "[{\"stream_id\":1.0},{\"stream_id\":1.5},{\"stream_id\":-0},{\"stream_id\":\"x y\"},{\"stream_id\":true},{\"stream_id\":null},{\"stream_id\":[1]}]",
            "[{\"stream_id\":\"7\",\"tv_archive\":\"1\",\"tv_archive_duration\":\"+5\"},{\"stream_id\":8,\"tv_archive\":1.0,\"tv_archive_duration\":\"007\"}]",
            "[{\"stream_id\":9,\"tv_archive\":true},{\"stream_id\":10,\"tv_archive\":\"\\u0031\",\"tv_archive_duration\":-3},{\"stream_id\":11,\"tv_archive\":\" 1\"}]",
            "[{\"stream_id\":12,\"tv_archive\":1,\"tv_archive_duration\":\" 5\"},{\"stream_id\":13,\"tv_archive\":1,\"tv_archive_duration\":2.5}]",
            "[{\"stream_id\":14,\"tv_archive\":1,\"tv_archive_duration\":99999999999999999999}]",
            "[{\"stream_id\":15,\"name\":\"a\",\"name\":\"b\",\"stream_id\":16}]",
            "[{\"n\\u0061me\":\"escaped key\",\"stream_id\":17}]",
            "[{\"stream_id\":18,\"name\":\"\\ud83d\\ude00 \\u00e9 caf\u{e9} \\\"q\\\" \\/ \\\\\"}]",
            "[{\"stream_id\":19,\"name\":\"\\ud83d\"}]", "[{\"stream_id\":20,\"name\":\"tab\there\"}]",
            "[{\"stream_id\":21,\"category_id\":5},{\"stream_id\":22,\"category_id\":\"5\"},{\"stream_id\":23,\"category_id\":5.5},{\"stream_id\":24,\"category_id\":null}]",
            "[{\"stream_id\":25,\"stream_icon\":\"not a url with spaces\"},{\"stream_id\":26,\"stream_icon\":\"http:\\/\\/x.example\\/a b.png\"}]",
            "[{\"stream_id\":27,\"extra\":{\"deep\":[[[[{\"a\":[1,2,{\"b\":null}]}]]]]}}]",
            "[{\"stream_id\":28,\"epg_channel_id\":\"\\u00a0guide\\u2003\"}]",
            "[{\"stream_id\":29,\"epg_channel_id\":5}]", "[{\"stream_id\":30}] trailing", "[{\"stream_id\":31,}]",
            "[{\"stream_id\":01}]", "[{\"stream_id\":1e400}]", "[{\"stream_id\":1E2,\"name\":\"exp\"}]",
            "[{\"stream_id\":32,\"name\":\"tricky },{ \\\"x\\\":1 } , { inside a string padded to span a forced chunk boundary\"},{\"stream_id\":33,\"name\":\"}, {\"},{\"stream_id\":34}]",
            "[{\"stream_id\":35,\"nested\":[{\"a\":1},{\"b\":2},{\"c\":{\"d\":[{},{}]}}]},{\"stream_id\":36}]",
        ]
        for (k, payload) in liveQuirks.enumerated() { compareChannels(data(payload), categories, "live quirk \(k): \(payload.prefix(80))") }
        let quirkCategories = [
            "[{\"category_id\":\"5\",\"category_name\":\"First\"},{\"category_id\":5,\"category_name\":\"Second\"}]",
            "[{\"category_id\":\"5\",\"category_name\":null},{\"category_id\":\"\",\"category_name\":\"Empty\"}]",
            "[{\"category_id\":\"\u{212A}\",\"category_name\":\"Kelvin\"},{\"category_id\":\"5\",\"category_name\":\"Five\"}]",
            "[{\"category_id\":\"5\",\"category_name\":3}]", "[{\"category_name\":\"no id\"}]", "{}", "[]", "",
        ]
        let kelvinStreams = data("[{\"stream_id\":1,\"category_id\":\"K\"},{\"stream_id\":2,\"category_id\":\"5\"},{\"stream_id\":3,\"category_id\":\"\"},{\"stream_id\":4,\"category_id\":5}]")
        for (k, cats) in quirkCategories.enumerated() { compareChannels(kelvinStreams, data(cats), "category quirk \(k)") }

        var mutator = Mutator(rng: FixtureRNG(42))
        let liveSeed = ConnectorFixtures.liveStreams(count: 6)
        for round in 0..<mutationRounds { compareChannels(mutator.mutate(liveSeed), categories, "live mutation \(round)") }
        let categorySeed = ConnectorFixtures.liveCategories(count: 4)
        for round in 0..<mutationRounds / 3 { compareChannels(liveSeed, mutator.mutate(categorySeed), "category mutation \(round)") }

        // MARK: Xtream short EPG
        let minimumStart = Date(timeIntervalSince1970: 1_700_050_000)
        let epgDeclines = ConnectorJSONDecline.count
        for stream in 0..<40 {
            compareCatchup(ConnectorFixtures.shortEPG(streamID: stream, listings: 120), minimumStart: stream % 2 == 0 ? minimumStart : nil, "epg fixture \(stream)")
        }
        expectFastPath(epgDeclines, "epg fixtures")
        let b = ConnectorFixtures.base64
        let epgQuirks = [
            "{}", "[]", "{\"epg_listings\":null}", "{\"epg_listings\":{}}", "{\"epg_listings\":[null]}", "{\"epg_listings\":[]}", "",
            "{\"epg_listings\":[{\"title\":\"\(b("A"))\",\"start_timestamp\":\"1700000100\",\"stop_timestamp\":\"1700000200\"}],\"epg_listings\":[]}",
            "{\"epg_listings\":[{\"title\":\"\(b("A"))\",\"start_timestamp\":1700000100,\"stop_timestamp\":1700000200.0,\"id\":7}]}",
            "{\"epg_listings\":[{\"title\":\"\(b("A"))\",\"start_timestamp\":1700000100.5,\"stop_timestamp\":\"1700000200.5\"}]}",
            "{\"epg_listings\":[{\"title\":\"\(b("A"))\",\"start_timestamp\":\"1e9\",\"stop_timestamp\":\"0x7FFFFFFF\"}]}",
            "{\"epg_listings\":[{\"title\":\"\(b("A"))\",\"start_timestamp\":\"inf\",\"stop_timestamp\":\"nan\"},{\"title\":\"x\",\"start_timestamp\":\"-5\",\"stop_timestamp\":\"10\"}]}",
            "{\"epg_listings\":[{\"title\":\"AAAA\",\"start_timestamp\":\"100\",\"stop_timestamp\":\"200\"},{\"title\":\"News\",\"start_timestamp\":\"100\",\"stop_timestamp\":\"200\"}]}",
            "{\"epg_listings\":[{\"title\":\"QQ=A\",\"start_timestamp\":\"100\",\"stop_timestamp\":\"200\"},{\"title\":\"VbG2=\",\"start_timestamp\":\"100\",\"stop_timestamp\":\"200\"}]}",
            "{\"epg_listings\":[{\"title\":\"\(b("\u{FEFF}BOM title"))\",\"start_timestamp\":\"100\",\"stop_timestamp\":\"200\"},{\"title\":\"\(b("   "))\",\"start_timestamp\":\"100\",\"stop_timestamp\":\"200\"}]}",
            "{\"epg_listings\":[{\"title\":\"\(b("Caf\u{e9} \u{2003}"))\",\"description\":\"\(b("\u{00a0}desc\u{00a0}"))\",\"start_timestamp\":\"100\",\"stop_timestamp\":\"200\",\"id\":\" padded \"}]}",
            "{\"epg_listings\":[{\"title\":\"\\u00e9t\\u00e9\",\"start_timestamp\":\"100\",\"stop_timestamp\":\"200\",\"id\":\"   \"}]}",
            "{\"epg_listings\":[{\"title\":5,\"start_timestamp\":\"100\",\"stop_timestamp\":\"200\"}]}",
            "{\"epg_listings\":[{\"title\":\"x\",\"description\":false,\"start_timestamp\":\"1\",\"stop_timestamp\":\"0\"}]}",
            "{\"epg_listings\":[{\"title\":null,\"start_timestamp\":\"100\",\"stop_timestamp\":\"200\"},{\"title\":\" \",\"start_timestamp\":\"100\",\"stop_timestamp\":\"200\"}]}",
            "{\"epg_listings\":[{\"title\":\"\(b("x"))\",\"start_timestamp\":\"1700050000\",\"stop_timestamp\":\"1700050000\"},{\"title\":\"\(b("y"))\",\"start_timestamp\":\"1700049000\",\"stop_timestamp\":\"1700050000\"}]}",
            "{\"epg_listings\":[{\"title\":\"\(b("x"))\",\"start_timestamp\":\" 100\",\"stop_timestamp\":\"+200\"},{\"title\":\"7w==\",\"start_timestamp\":\"100\",\"stop_timestamp\":\"200\"}]}",
        ]
        for (k, payload) in epgQuirks.enumerated() {
            compareCatchup(data(payload), minimumStart: k % 2 == 0 ? nil : minimumStart, "epg quirk \(k): \(payload.prefix(80))")
        }
        let epgSeed = ConnectorFixtures.shortEPG(streamID: 3, listings: 4)
        for round in 0..<mutationRounds { compareCatchup(mutator.mutate(epgSeed), minimumStart: nil, "epg mutation \(round)") }

        // MARK: Xtream VOD + series
        let vodCategories = ConnectorFixtures.liveCategories(count: 130)
        let vodDeclines = ConnectorJSONDecline.count
        compareVOD(ConnectorFixtures.vodStreams(count: 3000), vodCategories, "vod fixtures")
        compareSeries(ConnectorFixtures.series(count: 2000), vodCategories, "series fixtures")
        expectFastPath(vodDeclines, "vod/series fixtures")
        let vodQuirks = [
            "[]", "[{\"stream_id\":1,\"container_extension\":\" .mkv. \"},{\"stream_id\":2,\"container_extension\":\"..\"},{\"stream_id\":3,\"container_extension\":\"m\u{e9}\"}]",
            "[{\"stream_id\":1,\"rating\":\"\",\"rating_5based\":4},{\"stream_id\":2,\"rating\":7.5,\"rating_5based\":\"3\"},{\"stream_id\":3,\"rating\":null}]",
            "[{\"stream_id\":1,\"year\":2019,\"release_date\":null},{\"stream_id\":2,\"year\":\"2019\",\"release_date\":\"2019-01-01\"},{\"stream_id\":3,\"year\":2019.0}]",
            "[{\"stream_id\":1,\"duration_secs\":\"+60\"},{\"stream_id\":2,\"duration_secs\":60.5},{\"stream_id\":3,\"duration_secs\":\"x\"}]",
            "[{\"stream_id\":1,\"genre\":\"  \",\"category_id\":\"3\"},{\"stream_id\":2,\"genre\":\" Drama \",\"plot\":\"p\",\"director\":\"d\",\"cast\":\"c\",\"country\":\"x\"}]",
            "[{\"stream_id\":1,\"plot\":5}]", "[{\"stream_id\":\"a b\"}]", "[{\"stream_id\":1,\"added\":{\"weird\":true}}]",
        ]
        for (k, payload) in vodQuirks.enumerated() { compareVOD(data(payload), vodCategories, "vod quirk \(k)") }
        let vodSeed = ConnectorFixtures.vodStreams(count: 5)
        for round in 0..<mutationRounds { compareVOD(mutator.mutate(vodSeed), vodCategories, "vod mutation \(round)") }

        compareSeries(ConnectorFixtures.series(count: 2000), vodCategories, "series fixtures")
        let seriesQuirks = ["[]", "[{\"series_id\":1,\"genre\":null,\"category_id\":3},{\"series_id\":\"2\",\"rating\":\" \"},{\"series_id\":3.0,\"rating\":8}]",
                            "[{\"series_id\":1,\"cover\":3}]", "[{\"name\":\"no id\"}]"]
        for (k, payload) in seriesQuirks.enumerated() { compareSeries(data(payload), vodCategories, "series quirk \(k)") }
        let seriesSeed = ConnectorFixtures.series(count: 4)
        for round in 0..<mutationRounds / 2 { compareSeries(mutator.mutate(seriesSeed), vodCategories, "series mutation \(round)") }

        StalkerAndESPNDifferential.run(mutator: &mutator, rounds: mutationRounds)
    }
}
