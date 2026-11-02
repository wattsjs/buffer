import Foundation

@main
enum ProgramSearchIndexTests {
    @MainActor
    static func main() async throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        let channel = Channel(id: "owned-channel", name: "Fixture", logoURL: nil, group: "Tests",
            streamURL: URL(string: "http://127.0.0.1/fixture.m3u8")!, epgChannelID: "fixture-guide")
        let now = Date(timeIntervalSince1970: 1_000_000)
        func rows(_ prefix: String, count: Int, offset: TimeInterval = 0) -> [EPGProgram] {
            (0..<count).map { index in
                EPGProgram(id: "\(prefix)-\(index)", channelID: "fixture-guide",
                    title: "\(prefix) title \(index)", description: "",
                    start: now.addingTimeInterval(offset + Double(index) * 60),
                    end: now.addingTimeInterval(offset + Double(index + 1) * 60))
            }
        }
        func coherent(_ model: EPGViewModel) -> Bool {
            model.searchEntries.allSatisfy { entry in
                guard let values = model.programSearchStore[entry.epgID], values.indices.contains(entry.programIndex) else { return false }
                let row = values[entry.programIndex]
                return row.id == entry.id && row.title.lowercased() == entry.titleLower
                    && row.start == entry.start && row.end == entry.end
            }
        }

        let warm = EPGViewModel()
        warm.channels = [channel]
        warm.programs = ["fixture-guide": rows("warm", count: 8), "unmatched-guide": rows("outside-playlist", count: 100)]
        warm.testRequestProgramSearchIndex()
        await warm.testWaitForProgramSearchIndex()
        expect(warm.programSearchIndexBuildCount == 1 && warm.programSearchIndexPublicationCount == 1,
               "Warm initial guide produces one useful index")
        expect(warm.searchEntries.count == 8 && coherent(warm), "Initial entries reference their exact guide snapshot")
        expect(Set(warm.programSearchStore.keys) == ["fixture-guide"], "Unrelated XMLTV arrays are not retained by search")
        warm.testBeginProgramSearchEnrichment()
        for index in 0..<40 {
            warm.programs = ["fixture-guide": rows("history-\(index)", count: 20 + index, offset: -600)]
            warm.testRequestProgramSearchIndex()
            await Task.yield()
        }
        expect(warm.programSearchIndexBuildCount == 1 && warm.programSearchIndexPublicationCount == 1,
               "Forty history publications retain a usable warm index without repeated workers")
        expect(warm.searchEntries.first?.id == "warm-0" && coherent(warm),
               "Reordered live guide arrays cannot change the programme resolved by an older entry")
        expect(warm.programs["fixture-guide"]?.first?.id != warm.programSearchStore["fixture-guide"]?.first?.id,
               "Burst actually changes the live arrays behind the retained search snapshot")
        warm.testFinishProgramSearchEnrichment()
        warm.testFinishProgramSearchEnrichment()
        await warm.testWaitForProgramSearchIndex()
        expect(warm.programSearchIndexBuildCount == 2 && warm.programSearchIndexPublicationCount == 2,
               "Enrichment completion flushes the final warm index exactly once")
        expect(warm.searchEntries.count == 59 && warm.searchEntries.first?.id == "history-39-0" && coherent(warm),
               "Final warm snapshot contains the completed guide")

        let cold = EPGViewModel()
        cold.channels = [channel]
        cold.testBeginProgramSearchEnrichment()
        cold.testRequestProgramSearchIndex()
        expect(cold.programSearchIndexBuildCount == 0, "Empty cold guide does not start a useless worker")
        cold.programs = ["fixture-guide": rows("first-current", count: 30_000)]
        cold.testRequestProgramSearchIndex()
        for index in 0..<40 {
            cold.programs = ["fixture-guide": rows("tail-\(index)", count: 40)]
            cold.testRequestProgramSearchIndex()
        }
        expect(cold.programSearchIndexBuildCount == 1, "A history burst does not repeatedly cancel the first useful cold worker")
        await cold.testWaitForProgramSearchIndex()
        expect(cold.programSearchIndexPublicationCount == 1 && cold.searchEntries.count == 30_000,
               "The first current guide becomes searchable while history is still enriching")
        expect(cold.searchEntries.first?.id == "first-current-0" && coherent(cold), "First cold snapshot remains internally coherent")
        cold.testFinishProgramSearchEnrichment()
        await cold.testWaitForProgramSearchIndex()
        expect(cold.programSearchIndexBuildCount == 2 && cold.programSearchIndexPublicationCount == 2,
               "Cold enrichment publishes first useful and completed indexes only")
        expect(cold.searchEntries.count == 40 && cold.searchEntries.first?.id == "tail-39-0" && coherent(cold),
               "Final cold index includes the latest history")

        let finishing = EPGViewModel()
        finishing.channels = [channel]
        finishing.testBeginProgramSearchEnrichment()
        finishing.programs = ["fixture-guide": rows("first-inflight", count: 30_000)]
        finishing.testRequestProgramSearchIndex()
        finishing.programs = ["fixture-guide": rows("finished-tail", count: 12)]
        finishing.testRequestProgramSearchIndex()
        finishing.testFinishProgramSearchEnrichment()
        expect(finishing.programSearchIndexBuildCount == 1, "Final flush does not cancel an in-flight first cold worker")
        await finishing.testWaitForProgramSearchIndex()
        expect(finishing.programSearchIndexBuildCount == 2 && finishing.programSearchIndexPublicationCount == 2,
               "Pending final flush follows first worker completion")
        expect(finishing.searchEntries.first?.id == "finished-tail-0" && coherent(finishing), "Queued final snapshot is coherent")

        warm.programs = ["fixture-guide": rows("obsolete-source", count: 30_000)]
        warm.testRequestProgramSearchIndex()
        warm.testInvalidateProgramSearchSource()
        expect(warm.searchEntries.isEmpty && warm.programSearchStore.isEmpty,
               "A source epoch change immediately removes actionable old search data")
        warm.channels = [channel]
        warm.programs = ["fixture-guide": rows("replacement-source", count: 3)]
        warm.testRequestProgramSearchIndex()
        await warm.testWaitForProgramSearchIndex()
        await Task.yield()
        expect(warm.searchEntries.count == 3 && warm.searchEntries.first?.id == "replacement-source-0" && coherent(warm),
               "A cancelled source worker cannot overwrite replacement source data")

        let catalogue = EPGViewModel()
        catalogue.channels = [channel]
        catalogue.testBeginProgramSearchEnrichment()
        catalogue.programs = ["fixture-guide": rows("catalogue-old", count: 30_000)]
        catalogue.testRequestProgramSearchIndex()
        let replacement = Channel(id: "replacement-physical", name: "New feed", logoURL: nil, group: "Tests",
            streamURL: URL(string: "http://127.0.0.1/replacement.m3u8")!, epgChannelID: "fixture-guide")
        catalogue.channels = [replacement]
        await catalogue.testWaitForProgramSearchIndex()
        expect(catalogue.searchEntries.allSatisfy { $0.channelID == replacement.id },
               "An in-flight index cannot publish the obsolete catalogue's physical channel")
        expect(catalogue.programSearchIndexPublicationCount == 1 && coherent(catalogue),
               "Catalogue replacement rebuilds before publishing one coherent index")
        catalogue.testFinishProgramSearchEnrichment()
        await catalogue.testWaitForProgramSearchIndex()
        expect(catalogue.programSearchIndexPublicationCount == 1, "No redundant tail index when the latest snapshot already won")
        // Flat index structures: interning, posting lists, substring
        // dictionary and ranking over packed columns.
        do {
            let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
            func program(_ id: String, _ title: String, _ minutes: Double, _ length: Double = 30) -> EPGProgram {
                EPGProgram(id: id, channelID: "g", title: title, description: "",
                           start: base.addingTimeInterval(minutes * 60), end: base.addingTimeInterval((minutes + length) * 60))
            }
            let guides: [(epgID: String, channelID: String, programs: [EPGProgram])] = [
                ("g1", "c1", [program("a", "World News", -60), program("b", "News at Ten", 10),
                              program("c", "World  News", 0), program("d", "CAFÉ Society", 2000)]),
                ("g2", "c2", [program("e", "world news", 5), program("a", "World News", 20),
                              program("f", "Café society", -3000), program("g", "Abcdefghijklmn", 15)]),
                ("empty", "c3", []),
                ("g3", "missing", [program("h", "World News", 0)]),
            ]
            let index = ProgramSearchIndex.build(guides: guides)!
            let storage = index.storage!
            expect(index.count == 9 && index.slotCount == 3, "Empty guides take no slot; ordinals cover every programme")
            expect(storage.titleCount == 7, "Raw titles interned once each")
            let interned = Set((0..<storage.tokenCount).map { k in
                String(decoding: storage.tokenBytes[Int(storage.tokenOffsets[k])..<Int(storage.tokenOffsets[k + 1])], as: UTF8.self)
            })
            expect(interned == ["world", "news", "at", "ten", "café", "society", "abcdefghijklmn"],
                   "Tokens are normalized and interned once: \(interned)")
            for k in 0..<storage.tokenCount {
                let postings = storage.tokenTitles[Int(storage.tokenTitleOffsets[k])..<Int(storage.tokenTitleOffsets[k + 1])]
                expect(zip(postings, postings.dropFirst()).allSatisfy { $0 < $1 }, "Posting lists are strictly ascending")
            }
            expect(zip(storage.suffixKeys, storage.suffixKeys.dropFirst()).allSatisfy { $0 <= $1 }, "Substring keys sorted")
            for t in 0..<storage.titleCount {
                let run = Int(storage.titleRunOffsets[t])..<Int(storage.titleRunOffsets[t + 1])
                expect(run.dropFirst().allSatisfy { storage.start[$0 - 1] <= storage.start[$0] }, "Title runs ordered by start")
            }
            expect(index[4].id == "e" && index[4].epgID == "g2" && index[4].programIndex == 0 && index[4].channelID == "c2"
                   && index[4].titleLower == "world news", "Collection view reconstructs legacy entries")
            func ids(_ query: String, slots: [Int32] = [0, 1, -1], at minutes: Double = 0) -> [String] {
                let phrase = ProgramSearchIndex.normalize(query)
                let tokens = phrase.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { Array($0.utf8) }
                return index.search(phrase: Array(phrase.utf8), tokens: tokens, now: base.addingTimeInterval(minutes * 60),
                                    slotChannel: slots).map { index.program(ordinal: Int($0.ordinal)).program.id }
            }
            // Upcoming prefix matches (~160) beat a live non-phrase match (90); "a" is
            // de-duplicated keeping its best-ranked copy; slot 2's channel is absent.
            expect(ids("world news") == ["e", "a", "c"], "Ranking + id de-dup: \(ids("world news"))")
            expect(ids("news") == ["b", "c", "e", "a"], "Single token: prefix 120 beats contains 70: \(ids("news"))")
            expect(ids("ews wor") == ["c", "e", "a"], "Multi-token substrings AND across tokens")
            expect(ids("CAFÉ") == ["d", "f"] && ids("cafe\u{301}") == ["d", "f"], "Unicode lower/NFC normalization")
            expect(ids("efghijklm") == ["g"] && ids("bcdefghijklmnz").isEmpty, "Substrings longer than the 8-byte key verify tail bytes")
            expect(ids("w", slots: [-1, -1, -1]).isEmpty && ids("zz").isEmpty, "Missing channels and absent tokens yield nothing")
            expect(ids("news", slots: [0, 1, 0]).count == 5, "Every channel slot participates when present")
        }
        print("Program search snapshot/enrichment checks: \(checks) passed")
    }
}
