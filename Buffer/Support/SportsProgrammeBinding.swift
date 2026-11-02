import Foundation

/// Match the exact programme that supplied the sports result against its
/// current physical source. ESPN kickoff can precede the source broadcast;
/// the programme containing kickoff may be an unrelated pregame show.
nonisolated enum SportsProgrammeBinding {
    static func program(for event: SportEvent, channel: Channel, match: StreamMatch?,
                        currentPrograms: [EPGProgram]) -> EPGProgram? {
        if let match, let title = match.programTitle,
           let start = match.programStart, let end = match.programEnd {
            guard match.channel.preferenceIdentity == channel.preferenceIdentity,
                  match.channel.streamURL == channel.streamURL,
                  match.channel.sourceOwnership == channel.sourceOwnership else { return nil }
            return currentPrograms.first {
                $0.channelID == channel.epgChannelID && $0.title == title && $0.start == start && $0.end == end
            }
        }
        // A broadcaster-only result has no native programme evidence. Retain
        // the existing explicit ESPN three-hour schedule estimate.
        return EPGProgram(id: "sport_" + event.id, channelID: channel.epgChannelID ?? channel.id,
            title: event.displayTitle, description: event.league.fullName,
            start: event.startDate, end: event.startDate.addingTimeInterval(3 * 3600))
    }
}

/// Past kickoff alone never authorizes opening today's live channel.
nonisolated enum SportsEventActionPolicy {
    enum Mode: Equatable, Sendable { case live, upcoming, replayOnly, unavailable }

    static func mode(for event: SportEvent, now: Date = Date()) -> Mode {
        switch event.status {
        case .live, .halftime: return .live
        case .final_: return .replayOnly
        case .scheduled:
            let untilStart = event.startDate.timeIntervalSince(now)
            guard untilStart >= 0 else { return .unavailable }
            return untilStart <= 15 * 60 ? .live : .upcoming
        case .delayed, .postponed, .canceled: return .unavailable
        }
    }

    static func replayProgram(for event: SportEvent, match: StreamMatch,
                              currentPrograms: [EPGProgram], now: Date = Date()) -> EPGProgram? {
        guard mode(for: event, now: now) == .replayOnly, match.relevance == .eventProgramme,
              match.programTitle != nil, match.programStart != nil, match.programEnd != nil,
              let program = SportsProgrammeBinding.program(for: event, channel: match.channel,
                  match: match, currentPrograms: currentPrograms),
              match.channel.canReplay(program, now: now) else { return nil }
        return program
    }
}
