import Foundation

/// Standalone sports matching benchmark (swiftc -O). Index build for ~60k
/// streams across 3 accounts, a full day of ~300 fixtures matched and
/// ranked exactly as SportsViewModel.matchEvent does, and single-event
/// latency. Prints JSON with medians and a result digest so before/after
/// builds can be checked for identical output.
@main struct SportsMatchingBenchmark {
    static func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    static func main() {
        let args = CommandLine.arguments
        let runs = args.firstIndex(of: "--runs").flatMap { Int(args[$0 + 1]) } ?? 5
        let fixtureStart = ContinuousClock.now
        let fixture = SportsMatchingFixture.make()
        let fixtureMs = ms(fixtureStart.duration(to: .now))
        let programCount = fixture.programs.values.reduce(0) { $0 + $1.count }
        FileHandle.standardError.write("fixture channels=\(fixture.channels.count) guideKeys=\(fixture.programs.count) programmes=\(programCount) events=\(fixture.events.count) built in \(Int(fixtureMs)) ms\n".data(using: .utf8)!)

        var buildTimes: [Double] = []
        var index = StreamMatcher.buildIndex(channels: fixture.channels, programs: fixture.programs,
                                             hiddenGroups: fixture.hiddenGroups, now: fixture.now)
        for _ in 0..<runs {
            let start = ContinuousClock.now
            index = StreamMatcher.buildIndex(channels: fixture.channels, programs: fixture.programs,
                                             hiddenGroups: fixture.hiddenGroups, now: fixture.now)
            buildTimes.append(ms(start.duration(to: .now)))
        }

        if args.contains("--build-only") {
            for _ in 0..<20 { index = StreamMatcher.buildIndex(channels: fixture.channels, programs: fixture.programs, hiddenGroups: fixture.hiddenGroups, now: fixture.now) }
            print("buildMedianMs", median(buildTimes)); return
        }
        func matchDay() -> [[StreamMatch]] {
            fixture.events.map { event in
                var m = StreamMatcher.findMatches(for: event, index: index, now: fixture.now)
                m = StreamMatcher.rankedMatches(m, qualityByChannel: fixture.quality, favoriteChannelIDs: fixture.favorites,
                                                channelScores: fixture.channelScores, groupScores: fixture.groupScores)
                return StreamMatcher.presentable(m)
            }
        }
        var dayTimes: [Double] = []
        var day = matchDay()
        for _ in 0..<runs {
            let start = ContinuousClock.now
            day = matchDay()
            dayTimes.append(ms(start.duration(to: .now)))
        }

        // Single-event latency: the fixture with the most raw matches.
        let heaviest = fixture.events.indices.max { day[$0].count < day[$1].count } ?? 0
        var singleTimes: [Double] = []
        for _ in 0..<max(runs, 9) {
            let start = ContinuousClock.now
            var m = StreamMatcher.findMatches(for: fixture.events[heaviest], index: index, now: fixture.now)
            m = StreamMatcher.rankedMatches(m, qualityByChannel: fixture.quality, favoriteChannelIDs: fixture.favorites,
                                            channelScores: fixture.channelScores, groupScores: fixture.groupScores)
            _ = StreamMatcher.presentable(m)
            singleTimes.append(ms(start.duration(to: .now)))
        }

        var hasher = Hasher()
        var digestText = ""
        var total = 0
        for (event, matches) in zip(fixture.events, day) {
            digestText += event.id + ":" + matches.map { m in
                "\(m.id)|\(m.score)|\(m.reason)|\(m.programTitle ?? "-")|\(m.programStart?.timeIntervalSince1970 ?? -1)|\(m.isHidden)|\(m.relevance.rawValue)"
            }.joined(separator: ",") + "\n"
            total += matches.count
        }
        hasher.combine(digestText)
        if let path = args.firstIndex(of: "--dump").map({ args[$0 + 1] }) {
            try? digestText.write(toFile: path, atomically: false, encoding: .utf8)
        }
        let eventsWithMatches = day.filter { !$0.isEmpty }.count
        print("""
        {"channels":\(fixture.channels.count),"guideKeys":\(fixture.programs.count),"programmes":\(programCount),\
        "events":\(fixture.events.count),"eventsWithMatches":\(eventsWithMatches),"totalPresented":\(total),\
        "epgTitles":\(index.epgTitleCount),"buildMedianMs":\(median(buildTimes)),"dayMedianMs":\(median(dayTimes)),\
        "singleEventMedianMs":\(median(singleTimes)),"heaviestEvent":"\(fixture.events[heaviest].id)",\
        "buildSamples":\(buildTimes),"daySamples":\(dayTimes),"digestBytes":\(digestText.utf8.count)}
        """)
    }
}
