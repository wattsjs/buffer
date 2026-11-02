import Foundation

nonisolated private final class MatchCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let limit: Int?
    init(limit: Int? = nil) { self.limit = limit }
    var count: Int { lock.withLock { calls } }
    func cancelled() -> Bool {
        lock.withLock {
            calls += 1
            return limit.map { calls >= $0 } ?? false
        }
    }
}

@main struct StreamMatchTests {
    static func main() {
        let now = Date()
        let event = SportEvent(id: "fixture", sport: .basketball, league: League.all.first { $0.slug == "nba" }!,
                               title: "Lakers vs Celtics", shortTitle: "LAL vs BOS", homeTeam: nil, awayTeam: nil,
                               startDate: now, status: .live(detail: nil), broadcast: ["ESPN"],
                               venue: nil, detail: nil, tournamentName: nil, leader: nil)
        func channel(_ id: String, source: String = "fixture") -> Channel {
            Channel(id: id, name: "ESPN NBA", logoURL: nil, group: "Sports",
                    streamURL: URL(string: "http://127.0.0.1/\(source)/\(id)")!, epgChannelID: "guide")
        }
        let programs = ["guide": (0..<256).map { index in
            EPGProgram(id: "\(index)", channelID: "guide", title: "Lakers vs Celtics NBA",
                       description: "Basketball " + String(repeating: "fixture ", count: 24),
                       start: now.addingTimeInterval(Double(index)), end: now.addingTimeInterval(3600 + Double(index)))
        }]
        let index = StreamMatcher.buildIndex(channels: (0..<512).map { channel("\($0)") }, programs: programs)
        let plainMatches = StreamMatcher.findMatches(for: event, index: index)
        precondition(!plainMatches.isEmpty)
        let fullProbe = MatchCancellationProbe()
        let checkedMatches = StreamMatcher.findMatches(for: event, index: index, shouldCancel: { fullProbe.cancelled() })
        precondition(checkedMatches.map(\.channel.id) == plainMatches.map(\.channel.id), "Checkpoints changed matching output")
        precondition(StreamMatcher.findMatches(for: event, index: index, shouldCancel: { true }).isEmpty)
        precondition(fullProbe.count > 100, "Fixture didn't exercise candidate and EPG checkpoints")
        for limit in [fullProbe.count / 2, fullProbe.count - 5] {
            let interrupted = MatchCancellationProbe(limit: limit)
            let result = StreamMatcher.findMatches(for: event, index: index, shouldCancel: { interrupted.cancelled() })
            precondition(result.isEmpty, "Partial canceled matches escaped")
            precondition(interrupted.count < fullProbe.count, "Canceled scan continued through every checkpoint")
        }

        // Use the production matcher's hidden fallback, rather than manually
        // fabricating the array the popover visibility helper will consume.
        let hiddenIndex = StreamMatcher.buildIndex(channels: [channel("hidden")], programs: programs, hiddenGroups: ["Sports"])
        let hiddenMatches = StreamMatcher.findMatches(for: event, index: hiddenIndex)
        precondition(hiddenMatches.count == 1 && hiddenMatches[0].isHidden)
        let hidden = StreamMatchVisibility(matches: hiddenMatches)
        precondition(hidden.hasOnlyHiddenMatches && hidden.displayedMatches(showHidden: false).isEmpty)
        precondition(hidden.displayedMatches(showHidden: true).map(\.channel.id) == ["hidden"])
        precondition(hiddenMatches[0].isHidden, "Disclosure changed stored hidden-group status")
        let visible = StreamMatchVisibility(matches: plainMatches)
        precondition(!visible.hasOnlyHiddenMatches && !visible.displayedMatches(showHidden: false).isEmpty)
        let mixed = StreamMatchVisibility(matches: plainMatches + hiddenMatches)
        precondition(!mixed.hasOnlyHiddenMatches)
        precondition(mixed.displayedMatches(showHidden: true).allSatisfy { !$0.isHidden }, "Mixed matches automatically revealed hidden groups")
        let empty = StreamMatchVisibility(matches: [])
        precondition(!empty.hasOnlyHiddenMatches && empty.displayedMatches(showHidden: true).isEmpty)

        let sourceB = StreamMatcher.buildIndex(channels: [channel("hidden", source: "replacement")], programs: programs, hiddenGroups: ["Sports"])
        let replacement = StreamMatchVisibility(matches: StreamMatcher.findMatches(for: event, index: sourceB))
        precondition(replacement.hidden.first?.channel.id == hidden.hidden.first?.channel.id)
        precondition(replacement.disclosureIdentity != hidden.disclosureIdentity, "Same-ID source replacement didn't reset hidden disclosure")
        // Reproduce the real NFL listings: both providers carry the exact
        // match on Sky Main Event UHD, but hundreds of local NBC entries
        // previously filled the candidate cap before Sky was ever scored.
        let nfl = SportEvent(id: "lions-panthers", sport: .football,
            league: League.all.first { $0.slug == "nfl" }!,
            title: "Detroit Lions vs Carolina Panthers", shortTitle: "DET @ CAR",
            homeTeam: TeamInfo(name: "Panthers", abbreviation: "CAR", displayName: "Carolina Panthers", score: nil, logoURL: nil, record: nil),
            awayTeam: TeamInfo(name: "Lions", abbreviation: "DET", displayName: "Detroit Lions", score: nil, logoURL: nil, record: nil),
            startDate: now, status: .live(detail: nil), broadcast: ["NBC"],
            venue: nil, detail: nil, tournamentName: nil, leader: nil)
        func nflChannel(_ id: String, name: String, group: String, guide: String) -> Channel {
            Channel(id: id, name: name, logoURL: nil, group: group,
                streamURL: URL(string: "http://127.0.0.1/\(id)")!, epgChannelID: guide)
        }
        let sky = nflChannel("sky-uhd", name: "Sky Sports Main Event UHD", group: "4K / UHD", guide: "sky-uhd")
        let localNBC = (0..<240).map {
            nflChannel("nbc-\($0)", name: "NBC Local \($0)", group: "US | Local NBC", guide: "nbc")
        }
        let hintOnly = nflChannel("network-hint", name: "NBC UHD", group: "Sports", guide: "unrelated")
        let nflTitle = "NFL Football : Detroit Lions at Carolina Panthers ᴸᶦᵛᵉ"
        func airing(_ guide: String, title: String, offset: Double) -> EPGProgram {
            EPGProgram(id: guide, channelID: guide, title: title, description: "NFL football",
                start: now.addingTimeInterval(offset), end: now.addingTimeInterval(3 * 3600))
        }
        let nflGuide = ["sky-uhd": [airing("sky-uhd", title: nflTitle, offset: -600)],
            "nbc": [airing("nbc", title: nflTitle, offset: -300)],
            "unrelated": [airing("unrelated", title: "NFL Football : Chiefs at Raiders", offset: 0)]]
        let nflIndex = StreamMatcher.buildIndex(channels: localNBC + [sky, hintOnly], programs: nflGuide)
        let nflMatches = StreamMatcher.findMatches(for: nfl, index: nflIndex)
        precondition(nflMatches.first?.channel.id == sky.id, "Exact Sky UHD listing was crowded out or ranked behind local NBC")
        precondition(nflMatches.count >= 241, "Valid alternatives were truncated before display")
        precondition(nflMatches.first?.relevance == .eventProgramme)
        precondition(nflMatches.last?.channel.id == hintOnly.id, "A broadcaster hint outranked exact event evidence")
        precondition(nflMatches.first?.reason == sky.group, "Shared-guide cache copied a different variant folder")
        let nbcMatch = nflMatches.first { $0.channel.id == localNBC[0].id }!
        var known720 = StreamMatchQuality(availability: .observedAvailable, observedHeight: 720, observedFPS: 50)
        let measured4K = StreamMatchQuality(availability: .observedAvailable, observedHeight: 2160, observedFPS: 50)
        let measuredOrder = StreamMatcher.rankedMatches([nbcMatch, nflMatches[0]],
            qualityByChannel: [sky.preferenceIdentity: measured4K, nbcMatch.channel.preferenceIdentity: known720],
            favoriteChannelIDs: [nbcMatch.channel.preferenceIdentity])
        precondition(measuredOrder.first?.channel.id == sky.id, "Favorite lower-resolution channel outranked equally reliable UHD")
        let failed4K = StreamMatchQuality(availability: .failed, observedHeight: 2160, observedFPS: 50)
        let fallbackOrder = StreamMatcher.rankedMatches([nflMatches[0], nbcMatch],
            qualityByChannel: [sky.preferenceIdentity: failed4K, nbcMatch.channel.preferenceIdentity: known720])
        precondition(fallbackOrder.first?.channel.id == nbcMatch.channel.id, "Failed UHD source outranked a current usable alternative")
        let slow4K = StreamMatchQuality(availability: .observedAvailable, observedHeight: 2160, observedFPS: 25)
        let motionOrder = StreamMatcher.rankedMatches([nflMatches[0], nbcMatch],
            qualityByChannel: [sky.preferenceIdentity: slow4K, nbcMatch.channel.preferenceIdentity: known720])
        precondition(motionOrder.first?.channel.id == nbcMatch.channel.id, "Sports motion quality did not outrank resolution")
        known720.healthySeconds = .nan
        _ = StreamMatcher.rankedMatches([nflMatches[0], nbcMatch], qualityByChannel: [nbcMatch.channel.preferenceIdentity: known720])

        // Performance measurements, rather than brand/resolution labels,
        // determine the choice when both sources have event evidence. These
        // explicit fixture values are not fabricated into production probes.
        let healthyHD = StreamMatchQuality(availability: .observedAvailable, healthySeconds: 300,
            observedHeight: 1080, observedFPS: 50, observedSeconds: 300, bufferingSeconds: 0,
            startupSeconds: 0.8, liveDelaySeconds: 2)
        let slowUHD = StreamMatchQuality(availability: .observedAvailable, healthySeconds: 300,
            observedHeight: 2160, observedFPS: 50, observedSeconds: 300, bufferingSeconds: 0,
            startupSeconds: 6, liveDelaySeconds: 18)
        let statsOrder = StreamMatcher.rankedMatches([nflMatches[0], nbcMatch],
            qualityByChannel: [sky.preferenceIdentity: slowUHD, nbcMatch.channel.preferenceIdentity: healthyHD])
        precondition(statsOrder.first?.channel.id == nbcMatch.channel.id,
            "Measured low-delay fast-start HD did not outrank equally healthy slow UHD")
        var delayedHD = healthyHD
        delayedHD.liveDelaySeconds = 30
        delayedHD.startupSeconds = 9
        let reversedStats = StreamMatcher.rankedMatches([nbcMatch, nflMatches[0]],
            qualityByChannel: [sky.preferenceIdentity: slowUHD, nbcMatch.channel.preferenceIdentity: delayedHD])
        precondition(reversedStats.first?.channel.id == sky.id, "Channel brand rather than performance statistics controlled ranking")
        var stalledUHD = slowUHD
        stalledUHD.bufferingSeconds = 2
        stalledUHD.startupSeconds = 0.5
        stalledUHD.liveDelaySeconds = 1
        let reliabilityOrder = StreamMatcher.rankedMatches([nflMatches[0], nbcMatch],
            qualityByChannel: [sky.preferenceIdentity: stalledUHD, nbcMatch.channel.preferenceIdentity: healthyHD])
        precondition(reliabilityOrder.first?.channel.id == nbcMatch.channel.id,
            "Lower delay did not yield to the source with fewer sustained stalls")
        precondition(StreamMatchQuality().startupSeconds == nil && StreamMatchQuality().liveDelaySeconds == nil,
            "Unmeasured startup or broadcast delay acquired an invented value")
        var invalidMetrics = healthyHD
        invalidMetrics.startupSeconds = .nan
        invalidMetrics.liveDelaySeconds = -.infinity
        _ = StreamMatcher.rankedMatches([nflMatches[0], nbcMatch], qualityByChannel: [nbcMatch.channel.preferenceIdentity: invalidMetrics])

        // Native IDs and XMLTV IDs can collide across saved sources. A second
        // source must retain its own programme evidence and action binding.
        let sourceA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let physicalSourceB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        func physical(_ source: UUID) -> Channel {
            Channel(id: "same-id", name: "Sky Sports Main Event UHD", logoURL: nil, group: "Sports",
                streamURL: URL(string: "http://127.0.0.1/\(source.uuidString)")!, epgChannelID: "same-guide",
                sourceOwnership: .init(channelIdentity: .init(sourceID: source, nativeID: "same-id"),
                    accountKey: .unconfiguredSource(source),
                    guideBinding: .init(sourceID: source, epgChannelID: "same-guide")))
        }
        let firstPhysical = physical(sourceA), secondPhysical = physical(physicalSourceB)
        let scopedGuide = [StreamMatcher.guideKey(for: firstPhysical)!: [airing("same-guide", title: nflTitle, offset: -600)],
            StreamMatcher.guideKey(for: secondPhysical)!: [airing("same-guide", title: "Live Tennis: China Open", offset: 0)]]
        let sourceMatches = StreamMatcher.findMatches(for: nfl,
            index: StreamMatcher.buildIndex(channels: [firstPhysical, secondPhysical], programs: scopedGuide))
        precondition(sourceMatches.count == 1 && sourceMatches[0].channel.sourceChannelIdentity?.sourceID == sourceA,
            "Equal raw guide IDs borrowed another source's exact event")
        precondition(sourceMatches[0].channel.epgChannelID == "same-guide", "Matching mutated the raw guide used by actions")
        precondition(sourceMatches[0].id == firstPhysical.preferenceIdentity)
        precondition(firstPhysical.preferenceIdentity != secondPhysical.preferenceIdentity)

        let lateStart = now.addingTimeInterval(10 * 60)
        let lateEnd = now.addingTimeInterval(3 * 3600 + 20 * 60)
        let pregame = EPGProgram(id: "pregame", channelID: "nbc", title: "Football Night in America", description: "Pregame",
            start: now.addingTimeInterval(-3600), end: lateStart)
        let actualLate = EPGProgram(id: "native-late", channelID: "nbc", title: nflTitle, description: "Actual source airing",
            start: lateStart, end: lateEnd)
        let laterMatch = StreamMatch(channel: localNBC[0], score: 220, reason: localNBC[0].group,
            programTitle: nflTitle, programDescription: actualLate.description, programStart: lateStart, programEnd: lateEnd,
            isHidden: false, relevance: .eventProgramme)
        let bound = SportsProgrammeBinding.program(for: nfl, channel: localNBC[0], match: laterMatch,
            currentPrograms: [pregame, actualLate])
        precondition(bound?.id == "native-late" && bound?.start == lateStart && bound?.end == lateEnd,
            "ESPN kickoff bound the recording to unrelated pregame instead of the exact later native programme")
        precondition(SportsProgrammeBinding.program(for: nfl, channel: localNBC[0], match: laterMatch,
            currentPrograms: [pregame]) == nil, "Missing matched programme silently became a different recording")
        precondition(SportsProgrammeBinding.program(for: nfl, channel: localNBC[1], match: laterMatch,
            currentPrograms: [actualLate]) == nil, "An event action switched its physical channel")
        let estimated = SportsProgrammeBinding.program(for: nfl, channel: hintOnly, match: nil, currentPrograms: [])
        precondition(estimated?.title == nfl.displayTitle && estimated?.start == nfl.startDate,
            "Broadcaster-only action lost its explicit ESPN estimate")

        func policyEvent(_ status: EventStatus, offset: Double) -> SportEvent {
            SportEvent(id: nfl.id, sport: nfl.sport, league: nfl.league, title: nfl.title, shortTitle: nfl.shortTitle,
                homeTeam: nfl.homeTeam, awayTeam: nfl.awayTeam, startDate: now.addingTimeInterval(offset),
                status: status, broadcast: nfl.broadcast, venue: nil, detail: nil, tournamentName: nil, leader: nil)
        }
        precondition(SportsEventActionPolicy.mode(for: policyEvent(.live(detail: nil), offset: -7200), now: now) == .live)
        precondition(SportsEventActionPolicy.mode(for: policyEvent(.halftime, offset: -3600), now: now) == .live)
        precondition(SportsEventActionPolicy.mode(for: policyEvent(.scheduled, offset: 0), now: now) == .live)
        precondition(SportsEventActionPolicy.mode(for: policyEvent(.scheduled, offset: 900), now: now) == .live)
        precondition(SportsEventActionPolicy.mode(for: policyEvent(.scheduled, offset: 901), now: now) == .upcoming)
        precondition(SportsEventActionPolicy.mode(for: policyEvent(.scheduled, offset: -1), now: now) == .unavailable,
            "An unknown past scheduled event was treated as current live playback")
        for status in [EventStatus.delayed, .postponed, .canceled] {
            precondition(SportsEventActionPolicy.mode(for: policyEvent(status, offset: -7200), now: now) == .unavailable)
        }
        let finalEvent = policyEvent(.final_(detail: "Final"), offset: -3 * 3600)
        precondition(SportsEventActionPolicy.mode(for: finalEvent, now: now) == .replayOnly,
            "Finished event retained live/record-now actions")
        let archiveChannel = Channel(id: "archive", name: "Sky Sports Main Event UHD", logoURL: nil, group: "Sports",
            streamURL: URL(string: "http://127.0.0.1/archive")!, epgChannelID: "archive-guide",
            catchup: .init(kind: .xc, days: 7, source: nil),
            sourceOwnership: .init(channelIdentity: .init(sourceID: sourceA, nativeID: "archive"),
                accountKey: .unconfiguredSource(sourceA), guideBinding: .init(sourceID: sourceA, epgChannelID: "archive-guide")))
        let completedProgramme = EPGProgram(id: "native-finished-nfl", channelID: "archive-guide", title: nflTitle,
            description: "Original source", start: finalEvent.startDate.addingTimeInterval(600), end: now.addingTimeInterval(-1800))
        let currentTennis = EPGProgram(id: "current-tennis", channelID: "archive-guide", title: "Live Tennis: China Open",
            description: "Current unrelated live content", start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(3600))
        let finishedMatch = StreamMatch(channel: archiveChannel, score: 240, reason: "Sports", programTitle: nflTitle,
            programDescription: "Original source", programStart: completedProgramme.start, programEnd: completedProgramme.end,
            isHidden: false, relevance: .eventProgramme)
        let replay = SportsEventActionPolicy.replayProgram(for: finalEvent, match: finishedMatch,
            currentPrograms: [currentTennis, completedProgramme], now: now)
        precondition(replay?.id == "native-finished-nfl" && replay?.start == completedProgramme.start,
            "Finished event replay selected current tennis or ESPN kickoff instead of its later native programme")
        precondition(SportsEventActionPolicy.replayProgram(for: finalEvent, match: finishedMatch,
            currentPrograms: [currentTennis], now: now) == nil, "Missing archive programme silently fell back to live tennis")
        let noArchive = Channel(id: archiveChannel.id, name: archiveChannel.name, logoURL: nil, group: archiveChannel.group,
            streamURL: archiveChannel.streamURL, epgChannelID: archiveChannel.epgChannelID, sourceOwnership: archiveChannel.sourceOwnership)
        let noArchiveMatch = StreamMatch(channel: noArchive, score: 240, reason: "Sports", programTitle: nflTitle,
            programDescription: nil, programStart: completedProgramme.start, programEnd: completedProgramme.end,
            isHidden: false, relevance: .eventProgramme)
        precondition(SportsEventActionPolicy.replayProgram(for: finalEvent, match: noArchiveMatch,
            currentPrograms: [completedProgramme], now: now) == nil, "Non-catchup source advertised replay")
        precondition(SportsEventActionPolicy.replayProgram(for: finalEvent, match: finishedMatch,
            currentPrograms: [completedProgramme], now: now.addingTimeInterval(8 * 86400)) == nil,
            "Expired source archive remained actionable")
        precondition(SportsEventActionPolicy.replayProgram(for: policyEvent(.scheduled, offset: 3600), match: finishedMatch,
            currentPrograms: [completedProgramme], now: now) == nil, "Future event advertised a past archive replay")
        var broadcasterMatch = finishedMatch
        broadcasterMatch.relevance = .channelHint
        precondition(SportsEventActionPolicy.replayProgram(for: finalEvent, match: broadcasterMatch,
            currentPrograms: [completedProgramme], now: now) == nil, "Broadcaster hint alone authorized replay")

        // Fixture verification: a guide title naming one of our teams against
        // a different opponent is another fixture, never this event.
        let epl = SportEvent(id: "liv-ars", sport: .soccer,
            league: League.all.first { $0.slug == "eng.1" } ?? League.all[0],
            title: "Liverpool vs Arsenal", shortTitle: "LIV vs ARS",
            homeTeam: TeamInfo(name: "Liverpool", abbreviation: "LIV", displayName: "Liverpool", score: nil, logoURL: nil, record: nil),
            awayTeam: TeamInfo(name: "Arsenal", abbreviation: "ARS", displayName: "Arsenal", score: nil, logoURL: nil, record: nil),
            startDate: now, status: .live(detail: nil), broadcast: [],
            venue: nil, detail: nil, tournamentName: nil, leader: nil)
        let fixture = StreamMatcher.FixtureTerms(event: epl)!
        precondition(fixture.verdict(forTitle: "Premier League: Liverpool v Arsenal") == .confirmed)
        precondition(fixture.verdict(forTitle: "Arsenal vs. Liverpool (Live)") == .confirmed)
        precondition(fixture.verdict(forTitle: "Liverpool v Everton: Live") == .conflicting)
        precondition(fixture.verdict(forTitle: "Everton vs Arsenal") == .conflicting)
        precondition(fixture.verdict(forTitle: "Liverpool v Arsenall") == .confirmed || fixture.verdict(forTitle: "Liverpool v Arsenall") == .undetermined,
            "A misspelt expected opponent was treated as another team")
        precondition(fixture.verdict(forTitle: "Liverpool v TBC") == .undetermined)
        precondition(fixture.verdict(forTitle: "Live Premier League Football") == .undetermined)
        func eplChannel(_ id: String, guide: String) -> Channel {
            Channel(id: id, name: "Sports \(id)", logoURL: nil, group: "Sports",
                    streamURL: URL(string: "http://127.0.0.1/epl/\(id)")!, epgChannelID: guide)
        }
        func eplProgramme(_ guide: String, _ title: String) -> EPGProgram {
            EPGProgram(id: guide, channelID: guide, title: title, description: "Premier League football",
                       start: now.addingTimeInterval(-600), end: now.addingTimeInterval(6600))
        }
        let eplIndex = StreamMatcher.buildIndex(
            channels: [eplChannel("right", guide: "g-right"), eplChannel("wrong", guide: "g-wrong")],
            programs: ["g-right": [eplProgramme("g-right", "Liverpool v Arsenal")],
                       "g-wrong": [eplProgramme("g-wrong", "Liverpool v Everton")]])
        let eplMatches = StreamMatcher.findMatches(for: epl, index: eplIndex, now: now)
        precondition(eplMatches.first?.channel.id == "right" && eplMatches.first?.relevance == .eventProgramme,
            "Exact fixture did not lead")
        precondition(!eplMatches.contains { $0.channel.id == "wrong" && $0.relevance != .channelHint },
            "A different Liverpool fixture was presented as this event's programme")

        // Equal evidence, resolution and motion: higher measured bitrate leads.
        let lowBitrate = StreamMatch(channel: eplChannel("low", guide: "a"), score: 200, reason: "", programTitle: nil,
            programDescription: nil, programStart: nil, programEnd: nil, isHidden: false, relevance: .eventProgramme)
        let highBitrate = StreamMatch(channel: eplChannel("high", guide: "b"), score: 200, reason: "", programTitle: nil,
            programDescription: nil, programStart: nil, programEnd: nil, isHidden: false, relevance: .eventProgramme)
        let bitrateRanked = StreamMatcher.rankedMatches([lowBitrate, highBitrate], qualityByChannel: [
            lowBitrate.channel.preferenceIdentity: StreamMatchQuality(observedHeight: 1080, observedFPS: 50, observedBitRate: 4_000_000),
            highBitrate.channel.preferenceIdentity: StreamMatchQuality(observedHeight: 1080, observedFPS: 50, observedBitRate: 12_000_000),
        ])
        precondition(bitrateRanked.map(\.channel.id) == ["high", "low"], "Bitrate did not break a same-resolution tie")
        let resolutionFirst = StreamMatcher.rankedMatches([lowBitrate, highBitrate], qualityByChannel: [
            lowBitrate.channel.preferenceIdentity: StreamMatchQuality(observedHeight: 2160, observedFPS: 50, observedBitRate: 4_000_000),
            highBitrate.channel.preferenceIdentity: StreamMatchQuality(observedHeight: 1080, observedFPS: 50, observedBitRate: 12_000_000),
        ])
        precondition(resolutionFirst.first?.channel.id == "low", "Bitrate outranked measured resolution")

        // A news/kids programme whose description mentions the teams is never
        // presented as the event itself (it was outranking real sports feeds).
        let nbl = SportEvent(id: "nzb-mu", sport: .basketball,
            league: League.all.first { $0.sport == .basketball } ?? League.all[0],
            title: "New Zealand Breakers vs Melbourne United", shortTitle: "NZB vs MU",
            homeTeam: TeamInfo(name: "Breakers", abbreviation: "NZB", displayName: "New Zealand Breakers", score: nil, logoURL: nil, record: nil),
            awayTeam: TeamInfo(name: "United", abbreviation: "MU", displayName: "Melbourne United", score: nil, logoURL: nil, record: nil),
            startDate: now, status: .live(detail: nil), broadcast: [],
            venue: nil, detail: nil, tournamentName: nil, leader: nil)
        let nblIndex = StreamMatcher.buildIndex(
            channels: [eplChannel("sport", guide: "g-sport"), eplChannel("news", guide: "g-news")],
            programs: [
                "g-sport": [EPGProgram(id: "s", channelID: "g-sport", title: "NBL : Breakers vs. Melbourne United", description: "Basketball",
                                       start: now.addingTimeInterval(-600), end: now.addingTimeInterval(6600))],
                "g-news": [EPGProgram(id: "n", channelID: "g-news", title: "Breakfast with Eamonn and Ellie",
                                      description: "New Zealand Breakers and Melbourne United fans join the programme.",
                                      start: now.addingTimeInterval(-600), end: now.addingTimeInterval(6600))],
            ])
        let nblMatches = StreamMatcher.findMatches(for: nbl, index: nblIndex, now: now)
        precondition(nblMatches.first?.channel.id == "sport", "Sports listing did not lead")
        precondition(!nblMatches.contains { $0.channel.id == "news" && $0.relevance == .eventProgramme },
            "A description-only mention was presented as the event")

        // Hint trimming keeps all programme evidence and the best hints only.
        func hint(_ id: String, _ relevance: StreamMatch.Relevance) -> StreamMatch {
            StreamMatch(channel: eplChannel(id, guide: id), score: 100, reason: "", programTitle: nil,
                        programDescription: nil, programStart: nil, programEnd: nil, isHidden: false, relevance: relevance)
        }
        let flood = [hint("event", .eventProgramme), hint("related", .relatedProgramme)] + (0..<50).map { hint("h\($0)", .channelHint) }
        let trimmed = StreamMatcher.presentable(flood)
        precondition(trimmed.count == 14 && trimmed.prefix(2).map(\.channel.id) == ["event", "related"]
            && trimmed.last?.channel.id == "h11", "Hint trimming dropped evidence or kept the wrong hints")
        precondition(StreamMatcher.presentable((0..<50).map { hint("h\($0)", .channelHint) }).count == 24,
            "Hint-only results were over-trimmed")

        print("PASS stream matching fixture verification (confirmed/conflicting/undetermined) and bitrate tiebreak")
        print("PASS stream matching cancellation, hidden disclosure, NFL UHD coverage beyond 240 NBC candidates, exact event relevance, all alternatives, quality/failure/motion ranking, source-scoped guide/action identity, exact later-start recording/reminder binding, and finished/upcoming/unknown event replay/live policy")
    }
}
