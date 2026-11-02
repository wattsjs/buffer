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
        func same(_ lhs: [EPGProgram], _ rhs: [EPGProgram]) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
                $0.id == $1.id && $0.title == $1.title && $0.start == $1.start && $0.end == $1.end
            }
        }
        func verify(_ programs: [EPGProgram], dates: [Date]) {
            let prepared = GuideLookup.Prepared(programs: programs)
            // The timeline must agree on its integer path and on the exact
            // fallback (forced by a fractional listing in a sibling run).
            let timeline = GuideTimeline(["guide": programs, "other": [p("x", 0, 1)]])
            let handle = timeline.handle(for: "guide")!
            let reused = GuideTimeline(["guide": programs], reusing: timeline)
            precondition(reused.rebuiltRuns == 0, "unchanged run was not reused")
            let reusedHandle = reused.handle(for: "guide")!
            var packed = [Int32](repeating: 0, count: 2)
            for date in dates {
                let expected = programs.first { $0.start <= date && date < $0.end }
                var candidates = [GuideLookup.program(in: programs, containing: date), prepared.program(containing: date),
                                  timeline.program(handle, at: date), reused.program(reusedHandle, at: date)]
                [handle, handle].withUnsafeBufferPointer { handles in
                    packed.withUnsafeMutableBufferPointer { timeline.programIndices(handles, at: date, into: $0) }
                }
                candidates.append(packed[0] < 0 ? nil : programs[Int(packed[0])])
                for window: TimeInterval in [1, 0.5, 30, 6 * 3600] {
                    let end = date.addingTimeInterval(window)
                    let expectedRange = programs.filter { $0.end > date && $0.start < end }
                        .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
                    guard same(expectedRange, timeline.programs(handle, between: date, and: end)) else {
                        fputs("FAIL ranged date=\(date.timeIntervalSince(epoch)) window=\(window)\n", stderr)
                        exit(1)
                    }
                    checks += 1
                }
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

        // Runs the Int32 columns cannot represent exactly take the exact path:
        // fractional seconds, out-of-range dates and starts out of order.
        let fractional = [p("a", 0, 10), EPGProgram(id: "frac", channelID: "guide", title: "frac", description: "",
                          start: epoch.addingTimeInterval(10.25), end: epoch.addingTimeInterval(20.75))]
        let farFuture = [EPGProgram(id: "far", channelID: "guide", title: "far", description: "",
                         start: Date(timeIntervalSince1970: 1e12), end: Date(timeIntervalSince1970: 1e12 + 60))]
        // Published lists are start-sorted; an unsorted one must still match
        // the stateless lookup the view model falls back to.
        let unsorted = [p("late", 50, 60), p("early", 0, 100)]
        let unsortedTimeline = GuideTimeline(["guide": unsorted])
        let unsortedHandle = unsortedTimeline.handle(for: "guide")!
        precondition(unsortedHandle & GuideTimeline.exactFlag != 0)
        for second in -5...105 {
            let date = epoch.addingTimeInterval(Double(second))
            precondition(unsortedTimeline.program(unsortedHandle, at: date)?.id == GuideLookup.program(in: unsorted, containing: date)?.id)
        }
        for list in [fractional, farFuture] {
            let timeline = GuideTimeline(["guide": list])
            precondition(timeline.handle(for: "guide")! & GuideTimeline.exactFlag != 0, "unrepresentable run used Int32 columns")
            verify(list, dates: (-5...105).flatMap { [epoch.addingTimeInterval(Double($0)), epoch.addingTimeInterval(Double($0) + 0.5)] }
                + [Date(timeIntervalSince1970: 1e12 + 1)])
        }
        // Extreme and non-finite query instants clamp without trapping.
        let clamp = GuideTimeline(["guide": [p("one", 0, 10)]])
        let clampHandle = clamp.handle(for: "guide")!
        for date in [Date.distantPast, Date.distantFuture, Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: -1e300)] {
            precondition(clamp.program(clampHandle, at: date) == nil)
            precondition(clamp.programs(clampHandle, between: Date.distantPast, and: date).count == (date == .distantFuture ? 1 : 0))
        }
        print("PASS \(checks) guide lookup differential checks: prepared/stateless/timeline versus independent first-match")
    }
}
