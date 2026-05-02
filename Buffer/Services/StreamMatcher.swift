import Foundation

/// Pre-built, lowercased search data for a single channel.
/// Built once when channels/programs change. Stored as a flat struct
/// to minimize copy overhead when iterating.
nonisolated struct ChannelSearchIndex: Sendable {
    let channel: Channel
    let nameLower: String
    let nameWords: ContiguousArray<String>
    let nameCompact: String
    let nameAcronym: String
    let group: String          // original channel group name (for display)
    let inSportsGroup: Bool
    let isAudioOnlyGroup: Bool
    let isHidden: Bool         // channel belongs to a user-hidden group
    /// EPG titles already lowercased, sorted by start time.
    /// Only programs within a ±48h window are kept.
    let epgTitles: ContiguousArray<EPGTitle>

    struct EPGTitle: Sendable {
        let title: String       // original casing for display
        let description: String // original casing, trimmed for display
        let titleLower: ContiguousArray<UInt8>  // UTF-8 bytes for fast search
        let descLower: ContiguousArray<UInt8>   // description UTF-8 bytes
        let titleWords: ContiguousArray<String>
        let descWords: ContiguousArray<String>
        let titleCompact: String
        let descCompact: String
        let start: Date
        let end: Date
    }
}

nonisolated struct StreamSearchIndex: Sendable {
    let entries: [ChannelSearchIndex]
    let tokenToEntryIndices: [String: ContiguousArray<Int>]
    let inverseDocumentFrequency: [String: Double]

    static let empty = StreamSearchIndex(
        entries: [],
        tokenToEntryIndices: [:],
        inverseDocumentFrequency: [:]
    )
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
    ) -> StreamSearchIndex {
        let cutoff = Date().addingTimeInterval(-3600)
        let horizon = Date().addingTimeInterval(48 * 3600)
        let hiddenGroupPaths = hiddenGroups.map(splitGroupPath)

        let entries = channels.compactMap { channel in
            let isHidden = isGroupHidden(
                channel.group,
                hiddenGroups: hiddenGroups,
                hiddenGroupPaths: hiddenGroupPaths
            )
            let nameLower = normalise(channel.name)
            let nameWords = ContiguousArray(tokenWords(in: nameLower))
            let nameCompact = compactKey(nameLower)
            let nameAcronym = acronym(for: nameWords)
            let groupLower = normalise(channel.group)
            let isAudioOnlyGroup = groupLower.contains("radio") || nameLower.hasPrefix("radio:")

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
                        let titleLower = normalise(p.title)
                        let descLower = normalise(descPrefix)
                        epgTitles.append(.init(
                            title: p.title,
                            description: descPrefix,
                            titleLower: ContiguousArray(titleLower.utf8),
                            descLower: ContiguousArray(descLower.utf8),
                            titleWords: ContiguousArray(tokenWords(in: titleLower)),
                            descWords: ContiguousArray(tokenWords(in: descLower)),
                            titleCompact: compactKey(titleLower),
                            descCompact: compactKey(descLower),
                            start: p.start,
                            end: p.end
                        ))
                    }
                }
            }

            return ChannelSearchIndex(
                channel: channel,
                nameLower: nameLower,
                nameWords: nameWords,
                nameCompact: nameCompact,
                nameAcronym: nameAcronym,
                group: channel.group,
                inSportsGroup: groupLower.contains("sport") || groupLower.contains("ppv"),
                isAudioOnlyGroup: isAudioOnlyGroup,
                isHidden: isHidden,
                epgTitles: epgTitles
            )
        }

        let inverted = buildInvertedIndex(for: entries)
        return StreamSearchIndex(
            entries: entries,
            tokenToEntryIndices: inverted,
            inverseDocumentFrequency: buildInverseDocumentFrequency(
                tokenToEntryIndices: inverted,
                documentCount: entries.count
            )
        )
    }

    private static func buildInvertedIndex(
        for entries: [ChannelSearchIndex]
    ) -> [String: ContiguousArray<Int>] {
        var buckets: [String: [Int]] = [:]

        for (idx, entry) in entries.enumerated() {
            var tokens = Set<String>()
            collectIndexTokens(entry.nameWords, into: &tokens)
            collectIndexToken(entry.nameAcronym, into: &tokens)

            for epg in entry.epgTitles {
                collectIndexTokens(epg.titleWords, into: &tokens)
                collectIndexTokens(epg.descWords, into: &tokens)
            }

            for token in tokens {
                buckets[token, default: []].append(idx)
            }
        }

        return buckets.mapValues { ContiguousArray($0) }
    }

    private static func buildInverseDocumentFrequency(
        tokenToEntryIndices: [String: ContiguousArray<Int>],
        documentCount: Int
    ) -> [String: Double] {
        guard documentCount > 0 else { return [:] }
        let total = Double(documentCount)
        return tokenToEntryIndices.mapValues { indices in
            let df = Double(indices.count)
            return log((total - df + 0.5) / (df + 0.5) + 1.0)
        }
    }

    private static func collectIndexTokens(
        _ words: ContiguousArray<String>,
        into tokens: inout Set<String>
    ) {
        for word in words {
            collectIndexToken(word, into: &tokens)
        }
    }

    private static func collectIndexToken(_ token: String, into tokens: inout Set<String>) {
        guard token.count >= 2, !trivialWords.contains(token) else { return }
        tokens.insert(token)
    }

    private static func isGroupHidden(
        _ group: String,
        hiddenGroups: Set<String>,
        hiddenGroupPaths: [[String]]
    ) -> Bool {
        guard !hiddenGroups.isEmpty else { return false }
        if hiddenGroups.contains(group) { return true }

        let path = splitGroupPath(group)
        guard !path.isEmpty else { return false }

        for hiddenPath in hiddenGroupPaths {
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
    private static let maxCandidateEntries = 160

    /// Sports where EPG listings use tournament/sport names rather than
    /// individual match names, and events may span many hours.
    private static let tournamentSports: Set<Sport> = [.tennis, .golf, .motorsport, .cricket]

    /// Sports where "teams" are individual athletes — EPG often lists just
    /// surnames (e.g. "Djokovic vs Alcaraz", "McIlroy" in description).
    private static let athleteSports: Set<Sport> = [.tennis, .golf, .mma]

    static func findMatches(
        for event: SportEvent,
        index: StreamSearchIndex
    ) -> [StreamMatch] {
        let queries = buildQueries(for: event)
        guard !queries.isEmpty else { return [] }
        guard !index.entries.isEmpty else { return [] }

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
        let now = Date()
        let isEventLive = event.status.isLive
        let allowCurrentlyLiveEPG = isEventLive || (!event.status.isFinished && event.startDate <= now)
        let windowStart = event.startDate.addingTimeInterval(isTournament ? -6 * 3600 : -1800)
        let windowEnd = event.startDate.addingTimeInterval(isTournament ? 12 * 3600 : 7200)

        var matches: [StreamMatch] = []
        matches.reserveCapacity(16)

        let candidateIndices = candidateEntryIndices(for: queries, in: index)
        guard !candidateIndices.isEmpty else { return [] }

        // Iterate candidate indices only; the inverted index is built in the
        // background whenever channels/EPG change.
        for i in candidateIndices {
            let score = scoreEntry(
                entries: index.entries, at: i,
                queries: queries,
                broadcastLower: broadcastLower,
                contextKeywords: contextKeywords,
                eventStart: event.startDate,
                windowStart: windowStart,
                windowEnd: windowEnd,
                allowCurrentlyLiveEPG: allowCurrentlyLiveEPG,
                isTournament: isTournament
            )
            if score.value >= minimumScore {
                matches.append(StreamMatch(
                    channel: index.entries[i].channel,
                    score: score.value,
                    reason: score.reason,
                    programTitle: score.programTitle,
                    programDescription: score.programDescription,
                    programStart: score.programStart,
                    programEnd: score.programEnd,
                    isHidden: index.entries[i].isHidden
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

    private static func candidateEntryIndices(
        for queries: [SearchQuery],
        in index: StreamSearchIndex
    ) -> [Int] {
        var candidateWeights: [Int: Double] = [:]

        for query in queries {
            for term in query.fuzzyTerms {
                if let hits = index.tokenToEntryIndices[term] {
                    let weight = index.inverseDocumentFrequency[term] ?? 0.1
                    for hit in hits {
                        candidateWeights[hit, default: 0] += weight
                    }
                }
            }
            for token in query.tokens where token.count >= 2 {
                if let hits = index.tokenToEntryIndices[token] {
                    let weight = index.inverseDocumentFrequency[token] ?? 0.1
                    for hit in hits {
                        candidateWeights[hit, default: 0] += weight
                    }
                }
            }
        }

        guard candidateWeights.count > maxCandidateEntries else {
            return Array(candidateWeights.keys)
        }

        return candidateWeights
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(maxCandidateEntries)
            .map(\.key)
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
        entries: [ChannelSearchIndex], at i: Int,
        queries: [SearchQuery],
        broadcastLower: [String],
        contextKeywords: [ContiguousArray<UInt8>],
        eventStart: Date,
        windowStart: Date,
        windowEnd: Date,
        allowCurrentlyLiveEPG: Bool,
        isTournament: Bool
    ) -> Score {
        var best = Score()
        let entry = entries[i]
        let groupLabel = entry.group.isEmpty ? "" : entry.group

        // ── EPG titles + descriptions in event window (strongest signal) ──
        if !entry.epgTitles.isEmpty {
            let now = Date()
            for epg in entry.epgTitles {
                let overlapsEventWindow = epg.start < windowEnd && epg.end > windowStart
                let isCurrentlyLive = allowCurrentlyLiveEPG && epg.start <= now && epg.end > now
                guard overlapsEventWindow || isCurrentlyLive else { continue }
                let timeBonus = overlapsEventWindow
                    ? matchTimeBonus(
                        eventStart: eventStart,
                        epgStart: epg.start,
                        isTournament: isTournament
                    )
                    : 12

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
                    if let coverage = fuzzyTokenCoverage(
                        query: q,
                        words: epg.titleWords,
                        compactText: epg.titleCompact
                    ) {
                        best.record(
                            q.score + 28 + (coverage * 18) + (timeBonus * 0.8),
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
                    if q.tokens.count >= 2,
                       let coverage = fuzzyTokenCoverage(
                        query: q,
                        words: epg.descWords,
                        compactText: epg.descCompact
                       ) {
                        best.record(
                            q.score + 18 + (coverage * 14) + (timeBonus * 0.6),
                            groupLabel,
                            program: epg.title,
                            description: epg.description,
                            start: epg.start,
                            end: epg.end
                        )
                        break
                    }
                }
            }
        }

        // ── Channel name ──
        for q in queries {
            guard q.target != .epgOnly else { continue }
            if isWeakSingleTokenChannelQuery(q, entry: entry) { continue }
            if allTokensMatch(q.tokens, in: entry.nameLower, words: entry.nameWords, acronym: entry.nameAcronym) {
                best.record(q.score, groupLabel)
                break
            }
            if let coverage = fuzzyTokenCoverage(
                query: q,
                words: entry.nameWords,
                compactText: entry.nameCompact,
                requireExactAnchor: true
            ) {
                best.record(q.score * (0.78 + coverage * 0.12), groupLabel)
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
            if entry.isAudioOnlyGroup { best.value *= 0.55 }
        }

        return best
    }

    private static func isWeakSingleTokenChannelQuery(
        _ query: SearchQuery,
        entry: ChannelSearchIndex
    ) -> Bool {
        guard query.tokens.count == 1, query.score <= 110 else { return false }
        return !entry.inSportsGroup || entry.nameWords.count > 4
    }

    // MARK: - Token matching (String — used for channel name matching)

    @inline(__always)
    private static func allTokensMatch(
        _ tokens: [String],
        in text: String,
        words: ContiguousArray<String>? = nil,
        acronym: String = ""
    ) -> Bool {
        for token in tokens {
            if token.count <= 4 {
                if let words, words.contains(token) { continue }
                if !acronym.isEmpty, acronym.contains(token) { continue }
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
                    if nLen <= 4 {
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
        let fuzzyTerms: [String]
        let score: Double
        let label: String
        let target: QueryTarget
        let allowsFuzzy: Bool

        init(
            tokens: [String],
            score: Double,
            label: String,
            target: QueryTarget = .both,
            allowsFuzzy: Bool = true
        ) {
            self.tokens = tokens
            self.tokenBytes = tokens.map { ContiguousArray($0.utf8) }
            self.fuzzyTerms = tokens.flatMap { tokenWords(in: $0, minimumLength: 2) }
            self.score = score
            self.label = label
            self.target = target
            self.allowsFuzzy = allowsFuzzy
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

    private static func fuzzyTokenCoverage(
        query: SearchQuery,
        words: ContiguousArray<String>,
        compactText: String,
        requireExactAnchor: Bool = false
    ) -> Double? {
        guard query.allowsFuzzy, query.score >= 100, !words.isEmpty else { return nil }

        let queryTerms = query.fuzzyTerms
        guard !queryTerms.isEmpty else { return nil }

        // Single fuzzy terms are prone to cross-sport false positives. Keep
        // them only for long, high-signal names such as athletes or nicknames.
        if queryTerms.count == 1 {
            guard let term = queryTerms.first, term.count >= 6, query.score >= 110 else { return nil }
            guard !ambiguousTeamNames.contains(term), !ambiguousCityNames.contains(term) else { return nil }
        }

        var total = 0.0
        var exactHits = 0
        var missingTerms: [String] = []

        for term in queryTerms {
            if term.count <= 3 {
                guard words.contains(term) else { return nil }
                total += 1.0
                exactHits += 1
                continue
            }

            if words.contains(term) || compactText.contains(term) {
                total += 1.0
                exactHits += 1
                continue
            }

            missingTerms.append(term)
        }

        if requireExactAnchor || queryTerms.count >= 2 {
            guard exactHits > 0 else { return nil }
        }

        // Fuzzy repair is intentionally narrow: it is for one misspelled or
        // abbreviated word inside an otherwise plausible indexed candidate,
        // not a second search pass over every token in the guide.
        guard missingTerms.count <= 1 else { return nil }

        for term in missingTerms {
            let best = bestSimilarity(for: term, in: words)
            let threshold = term.count <= 5 ? 0.91 : 0.86
            guard best >= threshold else { return nil }
            total += best
        }

        let coverage = total / Double(queryTerms.count)
        return coverage >= 0.88 ? coverage : nil
    }

    private static func bestSimilarity(for term: String, in words: ContiguousArray<String>) -> Double {
        var best = 0.0
        for word in words {
            guard word.count >= 4 else { continue }
            let lengthDelta = abs(word.count - term.count)
            guard lengthDelta <= max(3, term.count / 3) else { continue }
            guard hasComparableShape(term, word) else { continue }
            let score = max(jaroWinkler(term, word), diceCoefficient(term, word))
            if score > best { best = score }
        }
        return best
    }

    private static func hasComparableShape(_ lhs: String, _ rhs: String) -> Bool {
        guard let lFirst = lhs.first, let rFirst = rhs.first else { return false }
        if lFirst == rFirst { return true }

        guard let lLast = lhs.last, let rLast = rhs.last else { return false }
        return lhs.count >= 7 && rhs.count >= 7 && lLast == rLast
    }

    private static func jaroWinkler(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        let matchDistance = max(a.count, b.count) / 2 - 1
        var aMatches = Array(repeating: false, count: a.count)
        var bMatches = Array(repeating: false, count: b.count)

        var matches = 0
        for i in a.indices {
            let start = max(0, i - matchDistance)
            let end = min(i + matchDistance + 1, b.count)
            var j = start
            while j < end {
                if !bMatches[j], a[i] == b[j] {
                    aMatches[i] = true
                    bMatches[j] = true
                    matches += 1
                    break
                }
                j += 1
            }
        }
        guard matches > 0 else { return 0 }

        var transpositions = 0
        var k = 0
        for i in a.indices where aMatches[i] {
            while !bMatches[k] { k += 1 }
            if a[i] != b[k] { transpositions += 1 }
            k += 1
        }

        let m = Double(matches)
        let jaro = (
            m / Double(a.count)
            + m / Double(b.count)
            + (m - Double(transpositions) / 2) / m
        ) / 3

        var prefix = 0
        while prefix < min(4, a.count, b.count), a[prefix] == b[prefix] {
            prefix += 1
        }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    private static func diceCoefficient(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs)
        let b = Array(rhs)
        guard a.count >= 2, b.count >= 2 else { return lhs == rhs ? 1 : 0 }

        var counts: [String: Int] = [:]
        for i in 0..<(a.count - 1) {
            counts[String(a[i...i + 1]), default: 0] += 1
        }

        var intersection = 0
        for i in 0..<(b.count - 1) {
            let gram = String(b[i...i + 1])
            if let count = counts[gram], count > 0 {
                intersection += 1
                counts[gram] = count - 1
            }
        }

        return (2.0 * Double(intersection)) / Double(a.count + b.count - 2)
    }

    private static let broadcastStopWords: Set<String> = [
        "tv", "network", "networks", "sports", "sport", "channel", "chs", "hd", "fhd", "uhd",
        "plus", "live", "stream", "streaming", "network",
        "mlb", "nba", "wnba", "nfl", "nhl", "ncaaf", "ncaam"
    ]

    private static let eventTitleStopWords = trivialWords.union([
        "vs", "v", "at", "and", "night", "fight", "game", "match",
    ])

    private static let singleTokenBroadcastChannels: Set<String> = [
        "abc", "cbs", "espn", "fox", "fs1", "fs2", "nbc", "tnt", "tbs",
        "peacock", "prime", "ion", "metv", "mnmt"
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

    private static func tokenWords(in normalisedText: String, minimumLength: Int = 2) -> [String] {
        normalisedText
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= minimumLength }
    }

    private static func compactKey(_ normalisedText: String) -> String {
        normalisedText.filter { $0.isLetter || $0.isNumber }
    }

    private static func acronym(for words: ContiguousArray<String>) -> String {
        String(words.compactMap(\.first))
    }

    private static func teamSearchTerms(for team: TeamInfo) -> [String] {
        var terms: [String] = []
        appendTeamTerm(normalise(team.name), to: &terms)
        appendTeamTerm(normalise(team.displayName), to: &terms)
        appendTeamTerm(normalise(team.abbreviation), to: &terms)

        for source in [normalise(team.name), normalise(team.displayName)] {
            appendTeamTerm(clubBaseName(source), to: &terms)
            if let aliases = clubAliases[source] {
                for alias in aliases {
                    appendTeamTerm(alias, to: &terms)
                }
            }
        }

        return terms
    }

    private static func appendTeamTerm(_ term: String, to terms: inout [String]) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, !terms.contains(trimmed) else { return }
        terms.append(trimmed)
    }

    private static func clubBaseName(_ name: String) -> String {
        var words = tokenWords(in: name, minimumLength: 2)
        while let last = words.last, clubSuffixWords.contains(last) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    private static func isStrongSingleTeamTerm(_ term: String) -> Bool {
        guard term.count >= 5 else { return false }
        guard !ambiguousTeamNames.contains(term), !ambiguousCityNames.contains(term) else { return false }
        return true
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
                    target: .channelOnly,
                    allowsFuzzy: false
                ))
            } else if let first = tokens.first, singleTokenBroadcastChannels.contains(first) {
                out.append(SearchQuery(
                    tokens: [first],
                    score: 120,
                    label: "Broadcast token: \(first)",
                    target: .channelOnly,
                    allowsFuzzy: false
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
                    label: "Short title: \(event.shortTitle)",
                    allowsFuzzy: false
                ))
            }
        }

        let competitionTokens = competitionKeywords(for: event)

        // ── Team/player-based queries (strongest) ──

        if teams.count == 2 {
            let t0 = teams[0], t1 = teams[1]
            let n0 = normalise(t0.name), n1 = normalise(t1.name)
            let a0 = normalise(t0.abbreviation), a1 = normalise(t1.abbreviation)
            let t0Terms = teamSearchTerms(for: t0)
            let t1Terms = teamSearchTerms(for: t1)

            if !t0Terms.isEmpty && !t1Terms.isEmpty {
                for left in t0Terms.prefix(4) {
                    for right in t1Terms.prefix(4) where left != right {
                        queries.append(SearchQuery(tokens: [left, right], score: 170,
                                                   label: "\(left) vs \(right)"))
                    }
                }
                for comp in competitionTokens {
                    for left in t0Terms.prefix(3) {
                        for right in t1Terms.prefix(3) where left != right {
                            queries.append(SearchQuery(tokens: [left, right, comp], score: 200,
                                                       label: "\(left) + \(right) + \(comp)"))
                        }
                    }
                }
            } else if n0.count >= 3 && n1.count >= 3 {
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
                                           label: "\(t0.abbreviation) vs \(t1.abbreviation)",
                                           allowsFuzzy: false))
            } else if a0.count >= 2 && a1.count >= 2 {
                for comp in competitionTokens where comp.count >= 3 {
                    queries.append(SearchQuery(tokens: [a0, a1, comp], score: 180,
                                               label: "\(t0.abbreviation) vs \(t1.abbreviation) + \(comp)",
                                               allowsFuzzy: false))
                }
            }

            for (primary, secondary) in [(t0, t1), (t1, t0)] {
                if primary.displayName.count >= 5 && secondary.abbreviation.count >= 3 {
                    queries.append(SearchQuery(
                        tokens: [normalise(primary.displayName), normalise(secondary.abbreviation)],
                        score: 160, label: "\(primary.displayName) + \(secondary.abbreviation)"))
                }
            }

            for team in teams {
                for term in teamSearchTerms(for: team).prefix(3) where isStrongSingleTeamTerm(term) {
                    queries.append(SearchQuery(
                        tokens: [term],
                        score: 88,
                        label: "Team channel: \(term)",
                        target: .channelOnly,
                        allowsFuzzy: false
                    ))
                }
            }
        }

        if teams.count != 2 {
            for team in teams {
                if team.displayName.count >= 5 {
                    queries.append(SearchQuery(tokens: [normalise(team.displayName)], score: 130,
                                               label: team.displayName))
                }
            }
        }

        // ── Surname-only queries for athlete sports ──
        // EPG descriptions often list just surnames (e.g. "Djokovic", "McIlroy").
        // Extract the last word of displayName as the surname.
        if athleteSports.contains(event.sport) {
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
                queries.append(SearchQuery(
                    tokens: [city],
                    score: 90,
                    label: "City: \(city)",
                    target: .epgOnly,
                    allowsFuzzy: false
                ))
            }
        }

        if teams.isEmpty || teams.allSatisfy({ $0.displayName == "TBD" }) {
            let titleTokens = extractTokens(
                from: event.title,
                minimumLength: 3,
                stopWords: eventTitleStopWords
            )
            if !titleTokens.isEmpty {
                queries.append(SearchQuery(
                    tokens: Array(titleTokens.prefix(6)),
                    score: 165,
                    label: "Event title: \(event.title)"
                ))

                if titleTokens.count >= 2 {
                    queries.append(SearchQuery(
                        tokens: Array(titleTokens.suffix(min(4, titleTokens.count))),
                        score: 150,
                        label: "Event title core: \(event.title)"
                    ))
                }
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
                    target: .epgOnly,
                    allowsFuzzy: false
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
                    target: .epgOnly,
                    allowsFuzzy: false
                ))
            }
        }

        if teams.isEmpty {
            for comp in competitionTokens where comp.count >= 3 {
                queries.append(SearchQuery(tokens: [comp], score: 90,
                                         label: "League: \(comp)", allowsFuzzy: false))
            }
            for kw in sportKeywords(for: event) where kw.count >= 3 {
                queries.append(SearchQuery(tokens: [kw], score: 70, label: "Sport: \(kw)", allowsFuzzy: false))
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
                queries.append(SearchQuery(tokens: [kw], score: 60, label: "Sport: \(kw)", allowsFuzzy: false))
            }
            // League-specific: "atp", "wta", "pga", "ipl", "f1"
            for comp in competitionTokens {
                queries.append(SearchQuery(tokens: [comp], score: 70, label: "League: \(comp)", allowsFuzzy: false))
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
        case (.soccer, "eng.2"):          kw.append(contentsOf: ["championship", "efl", "ch"])
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

    private static let clubSuffixWords: Set<String> = [
        "afc", "fc", "cf", "sc", "city", "town", "county", "united"
    ]

    private static let clubAliases: [String: [String]] = [
        "afc bournemouth": ["bournemouth", "cherries"],
        "middlesbrough": ["boro"],
        "norwich city": ["norwich", "canaries"],
        "portsmouth": ["pompey"],
        "queens park rangers": ["qpr"],
        "southampton": ["saints"],
        "sheffield united": ["sheff utd"],
        "sheffield wednesday": ["sheff wed"],
        "west bromwich albion": ["west brom", "wba"],
        "wolverhampton wanderers": ["wolves"],
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
