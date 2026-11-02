import Foundation

@inline(never)
private func equalContexts(_ lhs: SportEventMatchContext, _ rhs: SportEventMatchContext) -> Bool { lhs == rhs }

@main struct SportCardContextBenchmark {
    static func main() throws {
        let scoreCount = 28_000
        let cardCount = 120
        let identity = ObjectIdentifier(NSObject.self)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let league = League.all.first { $0.slug == "nba" }!
        let event = SportEvent(id: "fixture", sport: .basketball, league: league,
                               title: "Lakers vs Celtics", shortTitle: "LAL vs BOS", homeTeam: nil, awayTeam: nil,
                               startDate: now, status: .live(detail: nil), broadcast: ["ESPN"],
                               venue: nil, detail: nil, tournamentName: nil, leader: nil)
        let scores = Dictionary(uniqueKeysWithValues: (0..<scoreCount).map { ("channel-\($0)", Double($0 + 1) / Double(scoreCount)) })
        let equalRebuilt = Dictionary(uniqueKeysWithValues: scores.map { ($0.key, $0.value) })
        var changed = equalRebuilt
        changed["channel-13999"] = 0.751
        func context(_ values: [String: Double], indexVersion: Int = 1, preferenceVersion: Int = 1) -> SportEventMatchContext {
            #if DICTIONARY_CONTEXT
            SportEventMatchContext(event: event, indexVersion: indexVersion, modelIdentity: identity, channelScores: values)
            #else
            SportEventMatchContext(event: event, indexVersion: indexVersion, modelIdentity: identity, preferencesVersion: preferenceVersion)
            #endif
        }
        let initial = context(scores)
        let cases: [(String, SportEventMatchContext, Int, Int)] = [
            ("unchanged-shared-storage", context(scores), 300, 120 * 300),
            ("equal-rebuilt-storage", context(equalRebuilt), 4, 120 * 4),
            ("one-score-change", context(changed, preferenceVersion: 2), 4, 0),
            ("source-revision-change", context(scores, indexVersion: 2), 300, 0),
        ]
        var output: [[String: Any]] = []
        for (name, rhs, iterations, expected) in cases {
            let before = Array(repeating: initial, count: cardCount)
            let after = Array(repeating: rhs, count: cardCount)
            var timings: [Double] = []
            for sample in 0..<8 {
                let start = ContinuousClock.now
                var checksum = 0
                for _ in 0..<iterations {
                    for card in 0..<cardCount { checksum += equalContexts(before[card], after[card]) ? 1 : 0 }
                }
                let duration = start.duration(to: .now).components
                precondition(checksum == expected, "Comparison semantics changed")
                if sample > 0 { timings.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15) }
            }
            output.append(["name": name, "samplesMs": timings, "medianMs": timings.sorted()[timings.count / 2],
                           "comparisons": iterations * cardCount, "checksum": expected])
        }
        let report: [String: Any] = ["fixture": "sport-card-context-v1", "scoreCount": scoreCount,
                                      "cardCount": cardCount, "cases": output]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
