import Foundation

/// Pre-built, lowercased search data for a single channel.
/// Built once when channels/programs change. Stored as a flat struct
/// to minimize copy overhead when iterating.
nonisolated struct ChannelSearchIndex: Sendable {
    let channel: Channel
    let nameLower: String
    let group: String          // original channel group name (for display)
    let inSportsGroup: Bool
    let isHidden: Bool         // channel belongs to a user-hidden group
    /// EPG titles already lowercased, sorted by start time.
    /// Only programs within a ±48h window are kept.
    let epgTitles: ContiguousArray<EPGTitle>

    struct EPGTitle: Sendable {
        let title: String       // original casing for display
        let description: String // original casing, trimmed for display
        let titleLower: ContiguousArray<UInt8>  // UTF-8 bytes for fast search
        let descLower: ContiguousArray<UInt8>   // description UTF-8 bytes
        let start: Date
        let end: Date
    }
}

/// A matched stream for a sport event.
nonisolated struct StreamMatch: Identifiable, Sendable {
    var id: String { channel.id }
    let channel: Channel
    let score: Double
    let reason: String         // channel group / folder
    let programTitle: String?  // matched EPG program title, if any
    let programDescription: String?
    let programStart: Date?
    let programEnd: Date?
    let isHidden: Bool         // from a user-hidden group (fallback only)
}

/// High-performance sport event → channel matcher.
/// All methods are nonisolated. Designed for parallel execution.
nonisolated enum StreamMatcher {

    // MARK: - Normalisation

    /// Lowercase and strip diacritics so accented text matches plain ASCII.
    /// e.g. "Atlético" → "atletico", "São Paulo" → "sao paulo"
    private static func normalise(_ string: String) -> String {
        string.lowercased().folding(options: .diacriticInsensitive, locale: nil)
    }

    // MARK: - Index building

    static func buildIndex(
        channels: [Channel],
        programs: [String: [EPGProgram]],
        hiddenGroups: Set<String> = []
    ) -> [ChannelSearchIndex] {
        let cutoff = Date().addingTimeInterval(-3600)
        let horizon = Date().addingTimeInterval(48 * 3600)

        return channels.compactMap { channel in
            let isHidden = isGroupHidden(channel.group, hiddenGroups: hiddenGroups)
            let nameLower = normalise(channel.name)
            let groupLower = normalise(channel.group)

            var epgTitles = ContiguousArray<ChannelSearchIndex.EPGTitle>()
            if let epgID = channel.epgChannelID {
                for p in programs[epgID] ?? [] {
                    if p.end > cutoff && p.start < horizon {
                        // Cap description to 256 chars — athlete names and key
                        // details are near the start; normalise() is expensive
                        // on long strings (lowercased + diacritics folding).
                        let desc = p.description
                        let descPrefix = desc.count > 256
                            ? String(desc.prefix(256))
                            : desc
                        epgTitles.append(.init(
                            title: p.title,
                            description: descPrefix,
                            titleLower: ContiguousArray(normalise(p.title).utf8),
                            descLower: ContiguousArray(normalise(descPrefix).utf8),
                            start: p.start,
                            end: p.end
                        ))
                    }
                }
            }

            return ChannelSearchIndex(
                channel: channel,
                nameLower: nameLower,
                group: channel.group,
                inSportsGroup: groupLower.contains("sport") || groupLower.contains("ppv"),
                isHidden: isHidden,
                epgTitles: epgTitles
            )
        }
    }

    private static func isGroupHidden(_ group: String, hiddenGroups: Set<String>) -> Bool {
        guard !hiddenGroups.isEmpty else { return false }
        if hiddenGroups.contains(group) { return true }

        let path = splitGroupPath(group)
        guard !path.isEmpty else { return false }

        for hidden in hiddenGroups {
            let hiddenPath = splitGroupPath(hidden)
            guard !hiddenPath.isEmpty, hiddenPath.count <= path.count else { continue }
            if Array(path.prefix(hiddenPath.count)) == hiddenPath {
                return true
            }
            if path.contains(hiddenPath[0]) {
                return true
            }
        }
        return false
    }

    private static func splitGroupPath(_ group: String) -> [String] {
        group
            .components(separatedBy: "|")
            .flatMap { $0.components(separatedBy: "/") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Matching

    private static let minimumScore: Double = 80

    /// Sports where EPG listings use tournament/sport names rather than
    /// individual match names, and events may span many hours.
    private static let tournamentSports: Set<Sport> = [.tennis, .golf, .motorsport, .cricket]

    /// Sports where "teams" are individual athletes — EPG often lists just
    /// surnames (e.g. "Djokovic vs Alcaraz", "McIlroy" in description).
    private static let athleteSports: Set<Sport> = [.tennis, .golf, .mma]

    static func findMatches(
        for event: SportEvent,
        index: [ChannelSearchIndex]
    ) -> [StreamMatch] {
        let queries = buildQueries(for: event)
        guard !queries.isEmpty else { return [] }

        let broadcastLower = event.broadcast.compactMap { b -> String? in
            let l = normalise(b)
            return l.count >= 3 ? l : nil
        }

        // Sport-context keywords used to validate single-token EPG matches.
        // e.g. "giants" alone in an EPG title is ambiguous, but "giants" in
        // a title that also contains "mlb" or "baseball" is a strong signal.
        let contextKeywords: [ContiguousArray<UInt8>] = (
            sportKeywords(for: event) + competitionKeywords(for: event)
        ).map { ContiguousArray(normalise($0).utf8) }

        // Tournament sports get a much wider EPG window because:
        // - EPG entries often span the whole day ("ATP Tennis 10am-8pm")
        // - Individual match times within the block are approximate
        let isTournament = tournamentSports.contains(event.sport)
        let windowStart = event.startDate.addingTimeInterval(isTournament ? -6 * 3600 : -1800)
        let windowEnd = event.startDate.addingTimeInterval(isTournament ? 12 * 3600 : 7200)

        var matches: [StreamMatch] = []
        matches.reserveCapacity(16)

        // Iterate by index to avoid copying ChannelSearchIndex structs
        for i in index.indices {
            let score = scoreEntry(
                index: index, at: i,
                queries: queries,
                broadcastLower: broadcastLower,
                contextKeywords: contextKeywords,
                eventStart: event.startDate,
                windowStart: windowStart,
                windowEnd: windowEnd,
                isTournament: isTournament
            )
            if score.value >= minimumScore {
                matches.append(StreamMatch(
                    channel: index[i].channel,
                    score: score.value,
                    reason: score.reason,
                    programTitle: score.programTitle,
                    programDescription: score.programDescription,
                    programStart: score.programStart,
                    programEnd: score.programEnd,
                    isHidden: index[i].isHidden
                ))
            }
        }

        // Prefer non-hidden matches. Only surface hidden-group matches when
        // nothing else is available.
        let visible = matches.filter { !$0.isHidden }
        var result = visible.isEmpty ? matches : visible
        result.sort { $0.score > $1.score }
        if result.count > 10 { result.removeSubrange(10...) }
        return result
    }

    // MARK: - Scoring

    private struct Score {
        var value: Double = 0
        var reason: String = ""
        var programTitle: String?
        var programDescription: String?
        var programStart: Date?
        var programEnd: Date?

        mutating func record(
            _ v: Double,
            _ r: String,
            program: String? = nil,
            description: String? = nil,
            start: Date? = nil,
            end: Date? = nil
        ) {
            if v > value {
                value = v
                reason = r
                programTitle = program
                programDescription = description
                programStart = start
                programEnd = end
            }
        }
    }

    private static func scoreEntry(
        index: [ChannelSearchIndex], at i: Int,
        queries: [SearchQuery],
        broadcastLower: [String],
        contextKeywords: [ContiguousArray<UInt8>],
        eventStart: Date,
        windowStart: Date,
        windowEnd: Date,
        isTournament: Bool
    ) -> Score {
        var best = Score()
        let entry = index[i]
        let groupLabel = entry.group.isEmpty ? "" : entry.group

        // ── EPG titles + descriptions in event window (strongest signal) ──
        if !entry.epgTitles.isEmpty {
            for epg in entry.epgTitles {
                guard epg.start < windowEnd && epg.end > windowStart else { continue }
                let timeBonus = matchTimeBonus(
                    eventStart: eventStart,
                    epgStart: epg.start,
                    isTournament: isTournament
                )

                for q in queries {
                    guard q.target != .channelOnly else { continue }

                    if allBytesMatch(q.tokenBytes, in: epg.titleLower) {
                        // Single-token EPG title matches are ambiguous across
                        // sports (e.g. "giants" in both MLB and IPL cricket).
                        // Require a sport-context signal: the EPG title or
                        // description must also contain a sport/league keyword.
                        if q.tokenBytes.count == 1 {
                            let hasContext = contextKeywords.contains { kw in
                                containsBytes(kw, in: epg.titleLower)
                                || (!epg.descLower.isEmpty && containsBytes(kw, in: epg.descLower))
                            }
                            if !hasContext { continue }
                        }
                        best.record(
                            q.score + 50 + timeBonus,
                            groupLabel,
                            program: epg.title,
                            description: epg.description,
                            start: epg.start,
                            end: epg.end
                        )
                        break
                    }
                    // Description search: only for multi-token queries.
                    // A single word in a description is too weak a signal.
                    if q.tokenBytes.count >= 2
                        && !epg.descLower.isEmpty
                        && allBytesMatch(q.tokenBytes, in: epg.descLower)
                    {
                        best.record(
                            q.score + 35 + (timeBonus * 0.8),
                            groupLabel,
                            program: epg.title,
                            description: epg.description,
                            start: epg.start,
                            end: epg.end
                        )
                        break
                    }
                }
                if best.value > 0 { break }
            }
        }

        // ── Channel name ──
        for q in queries {
            guard q.target != .epgOnly else { continue }
            if allTokensMatch(q.tokens, in: entry.nameLower) {
                best.record(q.score, groupLabel)
                break
            }
        }

        // ── Multipliers (never standalone) ──
        if best.value > 0 {
            for net in broadcastLower {
                if entry.nameLower.contains(net) {
                    best.value *= 1.3
                    break
                }
            }
            if entry.inSportsGroup { best.value *= 1.15 }
        }

        return best
    }

    // MARK: - Token matching (String — used for channel name matching)

    @inline(__always)
    private static func allTokensMatch(_ tokens: [String], in text: String) -> Bool {
        for token in tokens {
            if token.count <= 3 {
                if !wordBoundaryMatch(token, in: text) { return false }
            } else {
                if !text.contains(token) { return false }
            }
        }
        return true
    }

    @inline(__always)
    private static func wordBoundaryMatch(_ needle: String, in haystack: String) -> Bool {
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            let beforeOK = range.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: range.lowerBound)].isLetter
            let afterOK = range.upperBound == haystack.endIndex
                || !haystack[range.upperBound].isLetter
            if beforeOK && afterOK { return true }
            searchRange = range.upperBound..<haystack.endIndex
        }
        return false
    }

    // MARK: - Byte-level substring check (ContiguousArray convenience)

    @inline(__always)
    private static func containsBytes(
        _ needle: ContiguousArray<UInt8>,
        in haystack: ContiguousArray<UInt8>
    ) -> Bool {
        let nLen = needle.count
        let hLen = haystack.count
        guard nLen > 0 && nLen <= hLen else { return false }
        return haystack.withUnsafeBufferPointer { hBuf in
            needle.withUnsafeBufferPointer { nBuf in
                guard let h = hBuf.baseAddress, let n = nBuf.baseAddress else { return false }
                return _substringFind(n, nLen, h, hLen)
            }
        }
    }

    // MARK: - Token matching (UTF-8 bytes — used for EPG title/description)
    //
    // Hot path: a single withUnsafeBufferPointer on the haystack, then raw
    // pointer scans for each token. Avoids per-token closure overhead and
    // uses while-loops instead of ClosedRange iteration (ClosedRange.index(after:)
    // showed up as a significant cost in profiling).

    @inline(__always)
    private static func allBytesMatch(
        _ needles: [ContiguousArray<UInt8>],
        in haystack: ContiguousArray<UInt8>
    ) -> Bool {
        let hLen = haystack.count
        return haystack.withUnsafeBufferPointer { hBuf in
            guard let hBase = hBuf.baseAddress else { return false }
            for needle in needles {
                let nLen = needle.count
                guard nLen <= hLen else { return false }
                let found = needle.withUnsafeBufferPointer { nBuf -> Bool in
                    guard let nBase = nBuf.baseAddress else { return false }
                    if nLen <= 3 {
                        return _wordBoundaryFind(nBase, nLen, hBase, hLen)
                    } else {
                        return _substringFind(nBase, nLen, hBase, hLen)
                    }
                }
                if !found { return false }
            }
            return true
        }
    }

    @inline(__always)
    private static func _substringFind(
        _ nBase: UnsafePointer<UInt8>, _ nLen: Int,
        _ hBase: UnsafePointer<UInt8>, _ hLen: Int
    ) -> Bool {
        let limit = hLen - nLen
        var i = 0
        while i <= limit {
            if memcmp(hBase + i, nBase, nLen) == 0 { return true }
            i &+= 1
        }
        return false
    }

    @inline(__always)
    private static func _wordBoundaryFind(
        _ nBase: UnsafePointer<UInt8>, _ nLen: Int,
        _ hBase: UnsafePointer<UInt8>, _ hLen: Int
    ) -> Bool {
        let limit = hLen - nLen
        var i = 0
        while i <= limit {
            if memcmp(hBase + i, nBase, nLen) == 0 {
                let beforeOK = i == 0 || !_isASCIILetter(hBase[i &- 1])
                let afterIdx = i &+ nLen
                let afterOK = afterIdx >= hLen || !_isASCIILetter(hBase[afterIdx])
                if beforeOK && afterOK { return true }
            }
            i &+= 1
        }
        return false
    }

    @inline(__always)
    private static func _isASCIILetter(_ byte: UInt8) -> Bool {
        (byte &- 0x41) < 26 || (byte &- 0x61) < 26
    }

    // MARK: - Query generation

    private struct SearchQuery {
        let tokens: [String]
        let tokenBytes: [ContiguousArray<UInt8>]  // pre-computed UTF-8 for fast matching
        let score: Double
        let label: String
        let target: QueryTarget

        init(
            tokens: [String],
            score: Double,
            label: String,
            target: QueryTarget = .both
        ) {
            self.tokens = tokens
            self.tokenBytes = tokens.map { ContiguousArray($0.utf8) }
            self.score = score
            self.label = label
            self.target = target
        }
    }

    private enum QueryTarget {
        case both
        case epgOnly
        case channelOnly
    }

    private static func matchTimeBonus(
        eventStart: Date,
        epgStart: Date,
        isTournament: Bool
    ) -> Double {
        let delta = abs(epgStart.timeIntervalSince(eventStart))
        if isTournament {
            if delta <= 30 * 60 { return 8 }
            if delta <= 2 * 3600 { return 4 }
            return 0
        }

        if delta <= 10 * 60 { return 20 }
        if delta <= 30 * 60 { return 14 }
        if delta <= 60 * 60 { return 8 }
        if delta <= 120 * 60 { return 4 }
        return 0
    }

    private static let broadcastStopWords: Set<String> = [
        "tv", "network", "networks", "sports", "sport", "channel", "chs", "hd", "fhd", "uhd",
        "plus", "live", "stream", "streaming", "network"
    ]

    private static func extractTokens(
        from text: String,
        minimumLength: Int = 3,
        stopWords: Set<String> = trivialWords
    ) -> [String] {
        normalise(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .map { String($0) }
            .map(normalise)
            .filter {
                let token = $0
                return token.count >= minimumLength && !stopWords.contains(token)
            }
    }

    private static func buildBroadcastQueries(_ broadcasts: [String]) -> [SearchQuery] {
        var out: [SearchQuery] = []

        for broadcast in broadcasts {
            let tokens = extractTokens(
                from: broadcast,
                minimumLength: 2,
                stopWords: broadcastStopWords
            )
            guard !tokens.isEmpty else { continue }

            if tokens.count > 1 {
                out.append(SearchQuery(
                    tokens: Array(tokens.prefix(3)),
                    score: 190,
                    label: "Broadcast: \(broadcast)",
                    target: .channelOnly
                ))
            }

            if let first = tokens.first {
                out.append(SearchQuery(
                    tokens: [first],
                    score: 120,
                    label: "Broadcast token: \(first)",
                    target: .channelOnly
                ))
            }

            if let second = tokens.dropFirst().first {
                out.append(SearchQuery(
                    tokens: [second],
                    score: 100,
                    label: "Broadcast token: \(second)",
                    target: .channelOnly
                ))
            }
        }

        return out
    }

    private static func buildQueries(for event: SportEvent) -> [SearchQuery] {
        let teams = [event.homeTeam, event.awayTeam].compactMap { $0 }

        var queries: [SearchQuery] = []
        queries.reserveCapacity(16)

        let broadcastQueries = buildBroadcastQueries(event.broadcast)
        queries.append(contentsOf: broadcastQueries)

        // Prefer short, broadcast-friendly identifiers (e.g. "LAL vs BOS") when available.
        if event.shortTitle != event.title {
            let shortTokens = extractTokens(
                from: event.shortTitle,
                minimumLength: 2,
                stopWords: broadcastStopWords
            )
            if !shortTokens.isEmpty {
                queries.append(SearchQuery(
                    tokens: Array(shortTokens.prefix(3)),
                    score: 120,
                    label: "Short title: \(event.shortTitle)"
                ))
            }
        }

        let competitionTokens = competitionKeywords(for: event)

        // ── Team/player-based queries (strongest) ──

        if teams.count == 2 {
            let t0 = teams[0], t1 = teams[1]
            let n0 = normalise(t0.name), n1 = normalise(t1.name)
            let a0 = normalise(t0.abbreviation), a1 = normalise(t1.abbreviation)

            if n0.count >= 3 && n1.count >= 3 {
                for comp in competitionTokens {
                    queries.append(SearchQuery(tokens: [n0, n1, comp], score: 200,
                                               label: "\(t0.name) + \(t1.name) + \(comp)"))
                }
                queries.append(SearchQuery(tokens: [n0, n1], score: 170,
                                           label: "\(t0.name) vs \(t1.name)"))
            }

            // Abbreviation pairs: require 3+ chars each to avoid false
            // positives from 2-char country codes ("US", "LI") or generic
            // short abbreviations matching broadly in EPG text.
            if a0.count >= 3 && a1.count >= 3 {
                queries.append(SearchQuery(tokens: [a0, a1], score: 150,
                                           label: "\(t0.abbreviation) vs \(t1.abbreviation)"))
            }

            for (primary, secondary) in [(t0, t1), (t1, t0)] {
                if primary.displayName.count >= 5 && secondary.abbreviation.count >= 3 {
                    queries.append(SearchQuery(
                        tokens: [normalise(primary.displayName), normalise(secondary.abbreviation)],
                        score: 160, label: "\(primary.displayName) + \(secondary.abbreviation)"))
                }
            }
        }

        for team in teams {
            if team.displayName.count >= 5 {
                queries.append(SearchQuery(tokens: [normalise(team.displayName)], score: 130,
                                           label: team.displayName))
            }
        }

        for team in teams {
            let lower = normalise(team.name)
            if lower.count >= 4, !ambiguousTeamNames.contains(lower) {
                queries.append(SearchQuery(tokens: [lower], score: 110, label: team.name))
            }
        }

        // ── Surname-only queries for athlete sports ──
        // EPG descriptions often list just surnames (e.g. "Djokovic", "McIlroy").
        // Extract the last word of displayName as the surname.
        if athleteSports.contains(event.sport) {
            for team in teams {
                let surname = extractSurname(team)
                if surname.count >= 4, surname != normalise(team.name) {
                    queries.append(SearchQuery(tokens: [surname], score: 95,
                                               label: "Surname: \(surname)"))
                }
            }
            // Both surnames together is a stronger signal
            if teams.count == 2 {
                let s0 = extractSurname(teams[0])
                let s1 = extractSurname(teams[1])
                if s0.count >= 3 && s1.count >= 3 && s0 != s1 {
                    queries.append(SearchQuery(tokens: [s0, s1], score: 155,
                                               label: "Surnames: \(s0) + \(s1)"))
                }
            }
        }

        for team in teams {
            let city = normalise(extractCity(team))
            if city.count >= 4, !ambiguousCityNames.contains(city) {
                queries.append(SearchQuery(tokens: [city], score: 90, label: "City: \(city)"))
            }
        }

        if teams.isEmpty || teams.allSatisfy({ $0.displayName == "TBD" }) {
            let titleTokens = normalise(event.title)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 3 }
            if !titleTokens.isEmpty {
                queries.append(SearchQuery(tokens: Array(titleTokens.prefix(3)), score: 100,
                                           label: event.title))
            }
        }

        if let venue = event.venue {
            let venueTokens = extractTokens(
                from: venue,
                minimumLength: 4,
                stopWords: trivialWords
            )
            if !venueTokens.isEmpty {
                queries.append(SearchQuery(
                    tokens: Array(venueTokens.prefix(2)),
                    score: 80,
                    label: "Venue: \(venue)",
                    target: .epgOnly
                ))
            }
        }

        if let detail = event.detail {
            let detailTokens = extractTokens(
                from: detail,
                minimumLength: 3,
                stopWords: trivialWords
            )
            if !detailTokens.isEmpty {
                queries.append(SearchQuery(
                    tokens: Array(detailTokens.prefix(2)),
                    score: 75,
                    label: "Detail: \(detail)",
                    target: .epgOnly
                ))
            }
        }

        if teams.isEmpty {
            for comp in competitionTokens where comp.count >= 3 {
                queries.append(SearchQuery(tokens: [comp], score: 90,
                                         label: "League: \(comp)"))
            }
            for kw in sportKeywords(for: event) where kw.count >= 3 {
                queries.append(SearchQuery(tokens: [kw], score: 70, label: "Sport: \(kw)"))
            }
        }

        // ── Tournament / sport fallback queries ──
        // For tournament sports, EPG often lists the tournament name or generic
        // sport keyword (e.g. "ATP Tennis: Barcelona Open", "Live Golf", "F1
        // Practice") rather than individual match names.

        if let tournamentName = event.tournamentName {
            let tourTokens = normalise(tournamentName)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 3 && !trivialWords.contains($0) }

            if tourTokens.count >= 2 {
                // Tournament name + sport keyword is a strong fallback
                for kw in sportKeywords(for: event) {
                    queries.append(SearchQuery(
                        tokens: Array(tourTokens.prefix(3)) + [kw],
                        score: 140, label: "Tournament: \(tournamentName) + \(kw)"))
                }
                // Tournament name alone
                queries.append(SearchQuery(
                    tokens: Array(tourTokens.prefix(3)),
                    score: 120, label: "Tournament: \(tournamentName)"))
            }

            // First significant word of tournament + sport keyword
            // Matches "Barcelona Open" → "barcelona" + "tennis"
            if let firstSig = tourTokens.first(where: { $0.count >= 5 }) {
                for kw in sportKeywords(for: event) {
                    queries.append(SearchQuery(
                        tokens: [firstSig, kw],
                        score: 100, label: "Tournament hint: \(firstSig) + \(kw)"))
                }
            }
        }

        // Generic sport keyword match (weakest fallback — e.g. EPG says just "Tennis")
        // Only use for tournament sports where this is common
        if tournamentSports.contains(event.sport) {
            for kw in sportKeywords(for: event) {
                queries.append(SearchQuery(tokens: [kw], score: 60, label: "Sport: \(kw)"))
            }
            // League-specific: "atp", "wta", "pga", "ipl", "f1"
            for comp in competitionTokens {
                queries.append(SearchQuery(tokens: [comp], score: 70, label: "League: \(comp)"))
            }
        }

        // Ensure we have at least some queries even with no teams
        guard !queries.isEmpty else {
            // Last resort: use the event title tokens
            let titleTokens = extractTokens(
                from: event.title,
                minimumLength: 3,
                stopWords: trivialWords
            )
            if !titleTokens.isEmpty {
                queries.append(SearchQuery(tokens: Array(titleTokens.prefix(3)), score: 80,
                                           label: event.title))
            }
            return queries
        }

        return queries
    }

    // MARK: - Static data

    /// Generic sport keywords that EPG listings commonly use.
    private static func sportKeywords(for event: SportEvent) -> [String] {
        switch event.sport {
        case .tennis:             return ["tennis"]
        case .golf:               return ["golf"]
        case .motorsport:         return ["racing", "motorsport"]
        case .cricket:            return ["cricket"]
        case .mma:                return ["ufc", "mma", "fight"]
        case .rugbyLeague:        return ["rugby", "league"]
        case .australianFootball: return ["afl", "aussie", "australian", "footy"]
        default:                  return [normalise(event.sport.rawValue)]
        }
    }

    /// Words too common to be useful in tournament name matching.
    private static let trivialWords: Set<String> = [
        "the", "open", "cup", "tour", "grand", "prix", "series",
        "championship", "international", "classic", "masters",
        "invitational", "memorial", "pro", "live",
    ]

    private static func competitionKeywords(for event: SportEvent) -> [String] {
        var kw: [String] = [normalise(event.league.shortName)]
        switch (event.sport, event.league.slug) {
        case (.soccer, "uefa.champions"): kw.append(contentsOf: ["champions", "ucl"])
        case (.soccer, "eng.1"):          kw.append(contentsOf: ["premier", "epl"])
        case (.soccer, "esp.1"):          kw.append("liga")
        case (.soccer, "ger.1"):          kw.append("bundesliga")
        case (.soccer, "ita.1"):          kw.append("serie")
        case (.soccer, "fra.1"):          kw.append("ligue")
        case (.soccer, "usa.1"):          kw.append("mls")
        case (.soccer, "aus.1"):          kw.append(contentsOf: ["a-league", "aleague"])
        case (.soccer, "aus.w.1"):        kw.append(contentsOf: ["a-league", "aleague", "women"])
        case (.soccer, "eng.fa"):         kw.append(contentsOf: ["fa", "cup"])
        case (.soccer, "eng.2"):          kw.append(contentsOf: ["championship", "efl"])
        case (.mma, _):                   kw.append(contentsOf: ["ufc", "fight"])
        case (.motorsport, "f1"):         kw.append(contentsOf: ["formula", "grand prix", "f1"])
        case (.motorsport, "nascar-premier"): kw.append("nascar")
        case (.motorsport, "nascar-secondary"): kw.append(contentsOf: ["nascar", "xfinity"])
        case (.motorsport, "irl"):        kw.append(contentsOf: ["indycar", "indy"])
        case (.tennis, "atp"):            kw.append(contentsOf: ["atp", "tennis"])
        case (.tennis, "wta"):            kw.append(contentsOf: ["wta", "tennis"])
        case (.golf, "pga"):              kw.append(contentsOf: ["pga", "golf"])
        case (.golf, "liv"):              kw.append(contentsOf: ["liv", "golf"])
        case (.golf, "lpga"):             kw.append(contentsOf: ["lpga", "golf"])
        case (.golf, "eur"):              kw.append(contentsOf: ["dp world", "european tour", "golf"])
        case (.golf, _):                  kw.append("golf")
        case (.cricket, "8048"):          kw.append(contentsOf: ["ipl", "cricket", "t20"])
        case (.cricket, "8044"):          kw.append(contentsOf: ["bbl", "big bash", "cricket", "t20"])
        case (.cricket, "8043"):          kw.append(contentsOf: ["sheffield shield", "cricket"])
        case (.cricket, "8039"):          kw.append(contentsOf: ["world cup", "cricket", "icc"])
        case (.cricket, _):               kw.append("cricket")
        case (.rugbyLeague, _):           kw.append(contentsOf: ["nrl", "rugby league"])
        case (.rugby, "242041"):          kw.append(contentsOf: ["super rugby", "rugby"])
        case (.rugby, "244293"):          kw.append(contentsOf: ["rugby championship", "rugby"])
        case (.rugby, "270557"):          kw.append(contentsOf: ["urc", "united rugby", "rugby"])
        case (.rugby, "180659"):          kw.append(contentsOf: ["six nations", "rugby"])
        case (.australianFootball, _):    kw.append(contentsOf: ["afl", "aussie rules", "footy"])
        default: break
        }
        return kw
    }

    private static let ambiguousTeamNames: Set<String> = [
        "city", "united", "real", "sporting", "racing", "fc",
        "inter", "athletic", "roma", "paris", "milan",
    ]

    private static let ambiguousCityNames: Set<String> = [
        "new", "san", "los", "las", "fort", "west", "east", "north", "south",
        "st.", "bay", "salt", "lake",
    ]

    private static func extractCity(_ team: TeamInfo) -> String {
        let display = normalise(team.displayName)
        let short = normalise(team.name)
        if display.hasSuffix(short) {
            return display.dropLast(short.count).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    /// Extract the surname (last word) from a player's displayName.
    /// e.g. "Novak Djokovic" → "djokovic", "Carlos Alcaraz" → "alcaraz"
    private static func extractSurname(_ team: TeamInfo) -> String {
        let parts = normalise(team.displayName)
            .split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2, let last = parts.last else { return "" }
        return String(last)
    }
}
