import Foundation

@main
struct GuideLookupTests {
    static func main() {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        func p(_ id: String, _ start: Int, _ end: Int) -> EPGProgram {
            EPGProgram(id: id, channelID: "guide", title: id, description: "", start: epoch.addingTimeInterval(Double(start)), end: epoch.addingTimeInterval(Double(end)))
        }
        let fixtures: [[EPGProgram]] = [
            [], [p("one", 0, 10)],
            [p("long", 0, 100), p("short", 10, 20)],
            [p("first", 0, 100), p("second", 0, 100)],
            [p("one", 0, 10), p("two", 20, 30)],
            [p("invalid", 0, -1), p("zero", 0, 0), p("valid", 0, 10)],
            [p("one", 0, 10), p("enclosing", 5, 100), p("short", 10, 20), p("later", 30, 40)],
            [p("expired", 0, 5), p("earlier", 5, 8), p("duplicate", 5, 100), p("last", 10, 12)]
        ]
        var checks = 0
        func verify(_ programs: [EPGProgram], dates: [Date]) {
            let prepared = GuideLookup.Prepared(programs: programs)
            for date in dates {
                let expected = programs.first { $0.start <= date && date < $0.end }
                let candidates = [GuideLookup.program(in: programs, containing: date), prepared.program(containing: date)]
                for actual in candidates {
                    guard expected?.id == actual?.id, expected?.title == actual?.title,
                          expected?.start == actual?.start, expected?.end == actual?.end else {
                        fputs("FAIL date=\(date.timeIntervalSince(epoch)) expected=\(expected?.id ?? "nil") actual=\(actual?.id ?? "nil")\n", stderr)
                        exit(1)
                    }
                    checks += 1
                }
            }
        }
        for programs in fixtures {
            verify(programs, dates: (-5...105).map { epoch.addingTimeInterval(Double($0)) })
        }

        // Independent deterministic fixtures contain nested and crossing
        // intervals, identical starts, expired/invalid durations and long gaps.
        var seed: UInt64 = 0x46_55_49_44_45
        func random(_ upperBound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int((seed >> 32) % UInt64(upperBound))
        }
        for fixture in 0..<200 {
            var programs: [EPGProgram] = []
            var start = -20
            for index in 0..<random(129) {
                start += random(5)
                programs.append(p("r-\(fixture)-\(index)", start, start + random(100) - 10))
            }
            let boundaries = programs.flatMap { [$0.start, $0.end] }.flatMap {
                [$0.addingTimeInterval(-0.001), $0, $0.addingTimeInterval(0.001)]
            }
            let dates = (-25...350).map { epoch.addingTimeInterval(Double($0)) } + boundaries
            verify(programs, dates: dates)
        }

        // Duplicate IDs must not hide a wrong choice of listing metadata.
        let repeatedIDs = [
            EPGProgram(id: "same", channelID: "guide", title: "Earlier", description: "", start: epoch, end: epoch.addingTimeInterval(100)),
            EPGProgram(id: "same", channelID: "guide", title: "Later", description: "", start: epoch, end: epoch.addingTimeInterval(50))
        ]
        verify(repeatedIDs, dates: [epoch, epoch.addingTimeInterval(50), epoch.addingTimeInterval(100)])
        print("PASS \(checks) guide lookup differential checks: prepared/stateless versus independent first-match")
    }
}
