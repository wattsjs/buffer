import Foundation

@main struct ParserCorrectnessTests {
    static func require(_ value: Bool, _ message: String = "parser correctness check") {
        precondition(value, message)
    }
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static func canonicalChannels(_ channels: [Channel]) throws -> Data {
        let json = try JSONSerialization.jsonObject(with: encoder.encode(channels)) as! [[String: Any]]
        let canonical = json.map { entry in
            var entry = entry
            if entry["epgChannelID"] == nil { entry["id"] = "generated UUID" }
            return entry
        }
        return try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys])
    }

    static func checkFallbackIdentities() {
        // Differential native-encoder vectors cover all byte values and
        // independently use Foundation's Base64 transformation. Sentinel
        // bytes prove the fixed 47-byte output never writes a terminator.
        for shift in 0..<256 {
            let digest = (0..<32).map { UInt8(($0 * 17 + shift) & 255) }
            var output = [UInt8](repeating: 0xa5, count: 49)
            let written = digest.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { buffer in
                    buffer_encode_channel_digest(input.baseAddress!, buffer.baseAddress!.advanced(by: 1))
                }
            }
            let reference = "m3u:" + Data(digest).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .dropLast()
            require(written == 47 && output[0] == 0xa5 && output[48] == 0xa5, "native digest encoder exceeded its 47-byte output contract")
            let actual = String(decoding: output[1..<48], as: UTF8.self)
            require(actual == reference, "native digest encoder discarded/changed SHA256 bits")
            let canonicalBase64 = actual.dropFirst(4).replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "="
            require(Data(base64Encoded: canonicalBase64) == Data(digest), "native digest identity failed full 256-bit roundtrip")
        }
        func playlist(_ name: String = "Original", group: String = "Old Group", url: String = "http://127.0.0.1/anonymous.ts", id: String? = nil) -> String {
            let attribute = id.map { " tvg-id=\"\($0)\"" } ?? ""
            return "#EXTINF:-1\(attribute) group-title=\"\(group)\",\(name)\n\(url)\n"
        }
        let first = M3UParser.parse(playlist())[0]
        require(first.id == "m3u:8EQ1X5mAPT_mZIpKMC4aQG6nj82tY4Wy7n9q3XqE-0w", "fallback ID is not stable across processes")
        require(M3UParser.parse(playlist())[0].id == first.id, "refresh regenerated fallback identity")
        require(M3UParser.parse(playlist("Renamed", group: "New Group"))[0].id == first.id, "display metadata changed fallback identity")
        let otherURL = "http://127.0.0.1/other.ts"
        let reordered = M3UParser.parse(playlist("Other", url: otherURL) + playlist("Renamed"))
        require(reordered[1].id == first.id, "playlist insertion/reordering changed unique fallback identity")
        require(reordered[0].id != first.id, "different streams share fallback identity")
        let duplicates = M3UParser.parse(playlist() + playlist("Duplicate") + playlist("Third"))
        require(Set(duplicates.map(\.id)).count == 3, "identical URLs produced duplicate SwiftUI IDs")
        require(duplicates.map(\.id) == M3UParser.parse(playlist("New First") + playlist("New Second") + playlist("New Third")).map(\.id), "duplicate occurrence identities changed on metadata refresh")
        for emptyID in ["", " ", "\t"] {
            let empty = M3UParser.parse(playlist(id: emptyID))[0]
            require(empty.epgChannelID == nil && empty.id == first.id, "empty tvg-id became an invalid shared channel identity")
        }
        let explicit = M3UParser.parse(playlist(id: "provided-id"))[0]
        require(explicit.id == "provided-id" && explicit.epgChannelID == "provided-id", "explicit provider ID changed")
        let variants = M3UParser.parse(playlist(url: "http://127.0.0.1/live?variant=sd&token=fixture-a") + playlist(url: "http://127.0.0.1/live?variant=hd&token=fixture-a"))
        require(variants[0].id != variants[1].id, "query-selected stream variants were merged")
        let rotatedToken = M3UParser.parse(playlist(url: "http://127.0.0.1/live?variant=sd&token=fixture-b"))[0]
        require(rotatedToken.id != variants[0].id, "unknown authorization query was silently discarded")
        require(!variants[0].id.contains("fixture-a") && !variants[0].id.contains("127.0.0.1"), "fallback ID exposes stream URL material")
    }

    static func main() async throws {
        checkFallbackIdentities()
        XMLTVDifferentialTests.run()
        // Disabling on-demand content must preserve the complete live model,
        // including catchup metadata and anonymous identities. VOD entries
        // remain excluded rather than being misclassified as live channels.
        let liveRows = """
        #EXTINF:-1 tvg-id="live" tvg-name="Équipe 😀" group-title="Sports" tvg-logo="https://fixture.invalid/logo.png" catchup="append" catchup-days="7" catchup-source="?start=${start}",Live channel
        https://fixture.invalid/live.ts
        #EXTINF:-1 group-title="News",Anonymous live
        https://fixture.invalid/anonymous.ts
        #EXTINF:-1 group-title="News",Duplicate live
        https://fixture.invalid/anonymous.ts
        """
        let vodRows = """
        #EXTINF:-1 type="movie" group-title="Movies" description="Movie metadata",Typed movie
        https://fixture.invalid/anonymous.ts
        #EXTINF:-1 tvg-type="series" season="2" episode="4",Typed episode
        https://fixture.invalid/episode.ts
        #EXTINF:-1,Path movie
        https://fixture.invalid/movie/123.ts
        #EXTINF:-1,File movie
        https://fixture.invalid/123.mkv
        #EXTINF:7200,Duration movie
        https://fixture.invalid/duration.ts
        """
        for padding in ["", String(repeating: "# ignored padding\n", count: 8000)] {
            let text = padding + "#EXTM3U\n" + vodRows + "\n" + liveRows + "\n"
            let full = M3UParser.parseContent(text)
            let disabled = M3UParser.parseContent(text, includeVOD: false)
            require(full.channels.count == 3 && full.vodItems.count == 5, "mixed fixture no longer covers live/VOD classification")
            require(disabled.vodItems.isEmpty && disabled.channels.count == 3, "disabled VOD entries became phantom live channels")
            require(try encoder.encode(disabled.channels) == encoder.encode(full.channels), "disabling VOD changed live metadata or identities")
            require(try encoder.encode(M3UParser.parse(text)) == encoder.encode(full.channels), "channels-only parsing changed live content")
            let onlyVOD = M3UParser.parseContent(padding + vodRows, includeVOD: false)
            require(onlyVOD.channels.isEmpty && onlyVOD.vodItems.isEmpty, "a disabled VOD-only playlist exposed playable phantom channels")
        }
        let fixtures = [
            [],
            ["#EXTM3U", "#EXTINF:-1 tvg-id=\"live\" tvg-name=\"Équipe 😀\" group-title=\"Sport\" catchup=\"append\" catchup-days=\"3\" catchup-source=\"?start=${start}\",Last, comma", "# comment", "", "  http://127.0.0.1/live.ts  "],
            ["#EXTM3U", "#EXTINF:7200 tvg-id=\"film\" tvg-type=\"movie\" description=\"Résumé 日本語\" rating=\"8\" year=\"2026\",Film", "http://127.0.0.1/movie/123.mp4", "#EXTINF:-1 tvg-id=\"series\" season=\"2\" episode=\"5\",Episode", "http://127.0.0.1/series/123.ts"],
            ["#EXTINF:-1 tvg-id=\"first\",First", "#EXTINF:-1 tvg-id=\"ignored\",Missing prior URL", "http://127.0.0.1/first.ts", "#EXTINF:-1 tvg-id=\"orphan\",No URL at EOF"],
            ["http://127.0.0.1/ignored.ts", "#EXTINF:-1,Generated ID", "http://127.0.0.1/anonymous.ts", "#EXTINF:-1 tvg-id=\"empty\" tvg-name=\" \" name=\"Alternative\",Default", "#EXTVLCOPT:network-caching=1000", "http://127.0.0.1/empty.ts"],
            ["#EXTINF:-1 tvg-id=\"bad\",Bad URL", "http://[invalid", "#EXTINF:-1 tvg-id=\"next\",Next", "http://127.0.0.1/next.ts"],
            ["\u{00a0}#EXTINF:-1 tvg-id=\"unicode-space\",White space\u{00a0}", "\u{00a0}http://127.0.0.1/space.ts\u{00a0}"]
        ]
        let separators = ["\n", "\r\n", "\r", "\u{000b}", "\u{000c}", "\u{0085}", "\u{2028}", "\u{2029}"]
        var m3uChecks = 0
        for lines in fixtures {
            for separator in separators {
                for finalSeparator in [false, true] {
                    for large in [false, true] {
                        let text = (large ? String(repeating: "# ignored padding\n", count: 8000) : "")
                            + lines.joined(separator: separator) + (finalSeparator ? separator : "")
                        let expected = ReferenceM3UParser.parseContent(text)
                        let actual = M3UParser.parseContent(text)
                        require(try canonicalChannels(actual.channels) == canonicalChannels(expected.channels), "M3U channel fields changed with a line separator")
                        require(try encoder.encode(actual.vodItems) == encoder.encode(expected.vodItems), "M3U VOD fields changed")
                        m3uChecks += 1
                    }
                }
            }
        }
        var seed: UInt64 = 0x9e3779b97f4a7c15
        func random(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 32) % limit
        }
        let attributeFragments = [
            "tvg-id=\"fixture\"", "tvg-id=\"later\"", "tvg-name=\"Named channel\"",
            "name=\"Alias\"", "tvg-logo=\"http://127.0.0.1/logo.png\"", "group-title=\"Test\"",
            "catchup=\"append\"", "catchup-days=\"3\"", "catchup-source=\"?start=${start}\"",
            "runtime=\"3600\"", "type=\"movie\"", "genre=\"Sport\"", "rating=\"8.5\"",
            "plot=\"A plot\"", "director=\"Person\"", "cast=\"A, B\"", "country=\"AU\"",
            "season=\"2\"", "episode-num=\"5\"", "release-date=\"2026-10-04\"",
            "prefix_tvg-id=\"unknown\"", "!tvg-id=\"punctuation\"", "-tvg-id=\"unknown\"",
            "tvg-id =\"spaces\"", "tvg-name=\"unterminated", "x=\"tvg-name=\"inner\"\"",
            "tvg-name=\"Équipe 日本語\"", "κtvg-name=\"Unicode key\"", "junk-123", "_key=\"\""
        ]
        for _ in 0..<1000 {
            let fragments = (0..<random(12)).map { _ in attributeFragments[random(attributeFragments.count)] }
            let text = "#EXTINF:-1 \(fragments.joined(separator: " ")),Display\nhttp://127.0.0.1/fixture.ts"
            let expected = ReferenceM3UParser.parseContent(text)
            let actual = M3UParser.parseContent(text)
            require(try canonicalChannels(actual.channels) == canonicalChannels(expected.channels), "M3U ASCII attribute grammar differs from regex")
            require(try encoder.encode(actual.vodItems) == encoder.encode(expected.vodItems), "M3U VOD attribute grammar differs from regex")
            m3uChecks += 1
        }
        // Large playlists take the parallel path: parts start at #EXTINF
        // lines, and entries left waiting for a URL at a part end carry over.
        for round in 0..<4 {
            var lines: [String] = []
            var anonymousOrder = 0
            while lines.count < 40_000 {
                switch random(14) {
                case 0: lines += ["#EXTINF:-1 tvg-id=\"orphan\(lines.count)\",Missing URL"]
                case 1: lines += ["#EXTINF:-1,Anonymous \(anonymousOrder)", "http://127.0.0.1/shared.ts"]; anonymousOrder += 1
                case 2: lines += fixtures[random(fixtures.count)]
                case 3: lines += ["# comment", "", "#EXTVLCOPT:x=1"]
                case 4: lines += ["#EXTINF:7200 tvg-type=\"movie\" tvg-name=\"Film \(lines.count)\",Film", "http://127.0.0.1/movie/\(lines.count).mkv"]
                case 5: lines += ["#EXTINF:-1 tvg-id=\"u\(lines.count)\" tvg-name=\"Équipe 日本語 \(lines.count)\" group-title=\"Sport\",Équipe", "http://127.0.0.1/u/\(lines.count).ts"]
                default:
                    let fragments = (0..<random(6)).map { _ in attributeFragments[random(attributeFragments.count)] }
                    lines += ["#EXTINF:-1 tvg-id=\"ch\(lines.count)\" \(fragments.joined(separator: " ")),Channel \(lines.count)", "http://127.0.0.1/live/\(lines.count).ts"]
                }
            }
            let separator = separators[round % separators.count]
            let text = lines.joined(separator: separator) + separator
            precondition(text.utf8.count > 1 << 20, "large playlist fixture must take the parallel path")
            let expected = ReferenceM3UParser.parseContent(text)
            let actual = M3UParser.parseContent(text)
            require(try canonicalChannels(actual.channels) == canonicalChannels(expected.channels), "parallel M3U channels differ (round \(round))")
            require(try encoder.encode(actual.vodItems) == encoder.encode(expected.vodItems), "parallel M3U VOD differs (round \(round))")
            // Duplicate fallback identities are numbered in playlist order across parts.
            let shared = actual.channels.filter { $0.streamURL.absoluteString == "http://127.0.0.1/shared.ts" && $0.epgChannelID == nil }
            let base = M3UParser.parse("#EXTINF:-1,X\nhttp://127.0.0.1/shared.ts\n")[0].id
            require(shared.enumerated().allSatisfy { $0.element.id == ($0.offset == 0 ? base : "\(base):\($0.offset + 1)") }, "fallback occurrences out of order")
            m3uChecks += 1
        }
        let attrs = ["start=\"20261004000000 +0000\"", "stop=\"20261004003000 +0000\"", "channel=\"test\""]
        let orders = [[0,1,2],[0,2,1],[1,0,2],[1,2,0],[2,0,1],[2,1,0]]
        let body = "<title> Équipe &amp; 日本語 </title><desc> Description &lt;encoded&gt; </desc>"
        let expectedXML = XMLTVParser.parse(data: Data("<tv><programme \(attrs.joined(separator: " "))>\(body)</programme></tv>".utf8))
        precondition(expectedXML.count == 1 && expectedXML[0].title == "Équipe & 日本語" && expectedXML[0].description == "Description <encoded>")
        var xmlChecks = 0
        for order in orders {
            for extra in ["", "x=\"ignored\" ", "xml:lang=\"en\" "] {
                let xml = "<tv><x/><programme \(extra)\(order.map { attrs[$0] }.joined(separator: " "))>\(body)<x/><p/><t/><d/></programme></tv>"
                let actual = XMLTVParser.parse(data: Data(xml.utf8))
                require(try encoder.encode(actual) == encoder.encode(expectedXML), "XMLTV attribute order changes fields")
                xmlChecks += 1
            }
        }
        let namespaced = "<tv xmlns:g=\"http://127.0.0.1/xml\"><g:programme \(attrs.joined(separator: " "))>\(body)</g:programme></tv>"
        require(try encoder.encode(XMLTVParser.parse(data: Data(namespaced.utf8))) == encoder.encode(expectedXML))
        for invalid in ["<tv/>", "<tv><programme channel=\"c\"/></tv>", "<tv><programme start=\"20261004000000\" stop=\"20261004003000\" channel=\"\"><title>No channel</title></programme></tv>"] {
            precondition(XMLTVParser.parse(data: Data(invalid.utf8)).isEmpty)
        }
        precondition(expectedXML.capacity < 1024, "tiny XML retains a large output buffer")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("buffer-parser-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let playlistURL = temporary.appendingPathComponent("fixture.m3u")
        let xmlURL = temporary.appendingPathComponent("fixture.xml")
        let largePlaylist = String(repeating: "#EXTINF:-1 tvg-id=\"fixture\",Fixture\nhttp://127.0.0.1/fixture.ts\n", count: 50_000)
        try Data(largePlaylist.utf8).write(to: playlistURL)
        try Data("<tv><programme \(attrs.joined(separator: " "))>\(body)</programme></tv>".utf8).write(to: xmlURL)
        require(try await M3UParser.parseContent(from: playlistURL).channels.count == 50_000)
        require(try await XMLTVParser.parse(from: xmlURL).count == 1)
        let cancelledPlaylist = Task { try await M3UParser.parseContent(from: playlistURL) }
        cancelledPlaylist.cancel()
        do { _ = try await cancelledPlaylist.value; preconditionFailure("cancelled playlist returned content") }
        catch is CancellationError { }
        let activePlaylist = Task { try await M3UParser.parseContent(from: playlistURL) }
        try await Task.sleep(for: .milliseconds(5))
        let cancelledAt = ContinuousClock.now
        activePlaylist.cancel()
        do { _ = try await activePlaylist.value; preconditionFailure("active cancelled playlist returned content") }
        catch is CancellationError { }
        precondition(cancelledAt.duration(to: .now) < .seconds(2), "cancelled parser kept doing CPU work")
        let cancelledGuide = Task { try await XMLTVParser.parse(from: xmlURL) }
        cancelledGuide.cancel()
        do { _ = try await cancelledGuide.value; preconditionFailure("cancelled guide returned content") }
        catch is CancellationError { }
        print("PASS \(m3uChecks) M3U content differential checks, disabled-VOD live equivalence/phantom exclusion on both parser paths, 256 native digest vectors/roundtrips/bounds, stable fallback/variant/duplicate identities, \(xmlChecks + 4) XML order/namespace/empty checks, local async imports and cancellation")
    }
}
