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
    static func compareStalkerEPG(_ payload: Data, _ label: String) {
        T.expectEqual(outcome { try StalkerClient.decodeEPG(payload, channels: epgChannels).map(describe).sorted() },
                      outcome { try LegacyStalker.epg(payload, channels: epgChannels).map(describe).sorted() }, label)
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
    static func run(mutator: inout Mutator, rounds: Int) {}
}
