import Foundation

/// Standalone companion to the app's guide-lookup-480 case. Both variants
/// compile real production GuideLookup code with identical Debug settings.
/// Prepared-index construction is included in every query batch.
@main
enum GuideLookupBenchmark {
    static func main() throws {
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let programs = (0..<480).map { i in
            EPGProgram(id: "p-\(i)", channelID: "guide", title: "Fixture \(i)", description: "Match schedule",
                       start: origin.addingTimeInterval(Double(i * 1800)),
                       end: origin.addingTimeInterval(Double((i + 1) * 1800)))
        }
        let dates = (0..<480).map { origin.addingTimeInterval(Double($0 * 1800 + 30)) }
        func batch() -> Int {
#if PREPARED_GUIDE_LOOKUP
            let prepared = GuideLookup.Prepared(programs: programs)
#endif
            var matches = 0
            for (index, date) in dates.enumerated() {
#if PREPARED_GUIDE_LOOKUP
                let program = prepared.program(containing: date)
#else
                let program = GuideLookup.program(in: programs, containing: date)
#endif
                if program?.id == "p-\(index)" { matches += 1 }
            }
            return matches
        }
        for _ in 0..<5 { precondition(batch() == 480) }
        var samples: [Double] = []
        for _ in 0..<21 {
            let start = ContinuousClock.now
            for _ in 0..<20 { precondition(batch() == 480) }
            let elapsed = start.duration(to: .now).components
            samples.append((Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15) / 20)
        }
        let report: [String: Any] = [
            "schema": 1, "fixture": "guide-lookup-480-v1", "configuration": "swiftc-Debug-Onone",
            "samplesMs": samples, "checksum": 480, "queriesPerBatch": 480,
            "preparationIncluded": true
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
