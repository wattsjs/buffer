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
        print("Program search snapshot/enrichment checks: \(checks) passed")
    }
}
