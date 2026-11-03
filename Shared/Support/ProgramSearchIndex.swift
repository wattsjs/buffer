import Foundation

nonisolated struct ProgramSearchEntry: Sendable {
    let id: String
    let epgID: String
    let programIndex: Int
    let channelID: String
    let titleLower: String
    let start: Date
    let end: Date
}

/// Immutable, flat programme search index.
///
/// Layout (built once per guide publication, off the main actor):
/// - Guides: the exact `[EPGProgram]` arrays searched, one *slot* per guide
///   (guide slot == channel slot: one playlist channel per EPG id). A
///   programme's *ordinal* is its position in the concatenation of those
///   arrays (legacy `searchEntries` order); `guideStart` maps ordinal -> slot.
/// - Titles: every distinct raw title interned once; its lowercased UTF-8
///   bytes live in one blob (`titleBytes` + `titleOffsets`).
/// - Tokens: every distinct whitespace-separated title token interned once
///   (`tokenBytes` + `tokenOffsets`), with a sorted posting list of title ids
///   (`tokenTitleOffsets` + `tokenTitles`).
/// - Substring dictionary: every suffix of every token, sorted by its first
///   eight bytes packed big-endian into a `UInt64`. A query token's matches
///   are one binary-searched range, so search keeps the exact `contains`
///   semantics of the original linear scan without scanning anything.
/// - Programme columns in title-major order (structure of arrays): start,
///   end, guide slot, ordinal. A title's programmes are one contiguous run,
///   ordered by start time.
///
/// Queries build a title bitset per query token (OR of postings), AND them,
/// and rank the surviving titles' programme runs with a bounded heap.
nonisolated struct ProgramSearchIndex: Sendable, RandomAccessCollection, ExpressibleByArrayLiteral {
    typealias Index = Int
    typealias Element = ProgramSearchEntry

    final class Storage: Sendable {
        // Guides (slot-indexed)
        let guideIDs: [String]
        let guideChannelIDs: [String]
        let guides: [[EPGProgram]]
        let guideStart: [UInt32]          // slots + 1, prefix sums of guide sizes
        // Titles
        let titleOffsets: [UInt32]        // titles + 1 into titleBytes
        let titleBytes: [UInt8]           // lowercased UTF-8
        let titleRunOffsets: [UInt32]     // titles + 1 into the programme columns
        // Tokens
        let tokenOffsets: [UInt32]        // tokens + 1 into tokenBytes
        let tokenBytes: [UInt8]
        let tokenTitleOffsets: [UInt32]   // tokens + 1 into tokenTitles
        let tokenTitles: [UInt32]         // ascending title ids per token
        // Substring dictionary (sorted by key)
        let suffixKeys: [UInt64]
        let suffixRefs: [UInt64]          // token << 32 | byte offset in token
        // Programme columns, title-major
        let start: [Double]               // timeIntervalSinceReferenceDate
        let end: [Double]
        let slot: [UInt32]
        let ordinal: [UInt32]
        let maxDuration: Double           // longest programme, bounds live look-back

        init(guideIDs: [String], guideChannelIDs: [String], guides: [[EPGProgram]], guideStart: [UInt32],
             titleOffsets: [UInt32], titleBytes: [UInt8], titleRunOffsets: [UInt32],
             tokenOffsets: [UInt32], tokenBytes: [UInt8], tokenTitleOffsets: [UInt32], tokenTitles: [UInt32],
             suffixKeys: [UInt64], suffixRefs: [UInt64],
             start: [Double], end: [Double], slot: [UInt32], ordinal: [UInt32], maxDuration: Double) {
            self.guideIDs = guideIDs; self.guideChannelIDs = guideChannelIDs; self.guides = guides
            self.guideStart = guideStart
            self.titleOffsets = titleOffsets; self.titleBytes = titleBytes; self.titleRunOffsets = titleRunOffsets
            self.tokenOffsets = tokenOffsets; self.tokenBytes = tokenBytes
            self.tokenTitleOffsets = tokenTitleOffsets; self.tokenTitles = tokenTitles
            self.suffixKeys = suffixKeys; self.suffixRefs = suffixRefs
            self.start = start; self.end = end; self.slot = slot; self.ordinal = ordinal
            self.maxDuration = maxDuration
        }

        var titleCount: Int { titleOffsets.count - 1 }
        var tokenCount: Int { tokenOffsets.count - 1 }
    }

    let storage: Storage?

    init(storage: Storage?) { self.storage = storage }
    init() { storage = nil }
    init(arrayLiteral elements: ProgramSearchEntry...) {
        precondition(elements.isEmpty, "ProgramSearchIndex is built with ProgramSearchIndex.build")
        storage = nil
    }

    // MARK: Collection (legacy `[ProgramSearchEntry]` view, materialized on access)

    var startIndex: Int { 0 }
    var endIndex: Int { storage.map { Int($0.guideStart[$0.guideStart.count - 1]) } ?? 0 }
    /// Compatibility with code that inspected the old array's reservation.
    var capacity: Int { count }
    /// Number of guide slots (== channel slots) referenced by the index.
    var slotCount: Int { storage?.guides.count ?? 0 }
    var channelIDs: [String] { storage?.guideChannelIDs ?? [] }

    subscript(position: Int) -> ProgramSearchEntry {
        let (slot, row) = locate(ordinal: position)
        let s = storage!
        let program = s.guides[slot][row]
        return ProgramSearchEntry(id: program.id, epgID: s.guideIDs[slot], programIndex: row,
                                  channelID: s.guideChannelIDs[slot], titleLower: program.title.lowercased(),
                                  start: program.start, end: program.end)
    }

    func locate(ordinal: Int) -> (slot: Int, row: Int) {
        let starts = storage!.guideStart
        var lo = 0, hi = starts.count - 1   // invariant: starts[lo] <= ordinal < starts[hi]
        while hi - lo > 1 {
            let mid = (lo + hi) >> 1
            if Int(starts[mid]) <= ordinal { lo = mid } else { hi = mid }
        }
        return (lo, ordinal - Int(starts[lo]))
    }

    func program(ordinal: Int) -> (program: EPGProgram, slot: Int) {
        let (slot, row) = locate(ordinal: ordinal)
        return (storage!.guides[slot][row], slot)
    }

    // MARK: Build

    /// Builds the index. Returns nil when the current task is cancelled.
    static func build(guides input: [(epgID: String, channelID: String, programs: [EPGProgram])]) -> ProgramSearchIndex? {
        var guideIDs: [String] = []
        var guideChannelIDs: [String] = []
        var guides: [[EPGProgram]] = []
        var guideStart: [UInt32] = [0]
        guideIDs.reserveCapacity(input.count); guideChannelIDs.reserveCapacity(input.count)
        guides.reserveCapacity(input.count); guideStart.reserveCapacity(input.count + 1)
        var total = 0
        for g in input where !g.programs.isEmpty {
            guideIDs.append(g.epgID); guideChannelIDs.append(g.channelID); guides.append(g.programs)
            total += g.programs.count
            guideStart.append(UInt32(total))
        }
        guard total > 0 else { return ProgramSearchIndex() }
        precondition(total < Int(UInt32.max), "programme ordinals are UInt32")

        // 1. Intern raw titles; lowercase each distinct title exactly once.
        var titles = SearchByteInterner(expected: Swift.max(1024, total / 4))
        var lowerOffsets: [UInt32] = [0]
        var lowerBytes: [UInt8] = []
        lowerBytes.reserveCapacity(total * 4)
        var titleOfOrdinal = [UInt32](repeating: 0, count: total)
        var o = 0
        for programs in guides {
            for program in programs {
                if o & 4095 == 0, Task.isCancelled { return nil }
                var title = program.title
                let (id, inserted) = title.withUTF8 { titles.intern($0) }
                if inserted {
                    lowerBytes.append(contentsOf: normalize(program.title).utf8)
                    lowerOffsets.append(UInt32(lowerBytes.count))
                }
                titleOfOrdinal[o] = id
                o += 1
            }
        }
        let titleCount = titles.count
        titles = SearchByteInterner(expected: 0)   // release raw title table

        // 2. Tokenize lowercased titles on " " and "\t" (the query splitter),
        //    intern tokens and collect deduplicated (token, title) postings.
        var tokens = SearchByteInterner(expected: Swift.max(1024, titleCount))
        var pairTokens: [UInt32] = []
        pairTokens.reserveCapacity(titleCount * 4)
        var pairTitleStarts = [UInt32](repeating: 0, count: titleCount + 1)
        var lastTitleOfToken: [UInt32] = []
        lowerBytes.withUnsafeBufferPointer { blob in
            for t in 0..<titleCount {
                let lo = Int(lowerOffsets[t]), hi = Int(lowerOffsets[t + 1])
                var i = lo
                while i < hi {
                    while i < hi, blob[i] == 0x20 || blob[i] == 0x09 { i += 1 }
                    let tokenStart = i
                    while i < hi, blob[i] != 0x20, blob[i] != 0x09 { i += 1 }
                    if i > tokenStart {
                        let (id, inserted) = tokens.intern(UnsafeBufferPointer(rebasing: blob[tokenStart..<i]))
                        if inserted { lastTitleOfToken.append(UInt32.max) }
                        if lastTitleOfToken[Int(id)] != UInt32(t) {
                            lastTitleOfToken[Int(id)] = UInt32(t)
                            pairTokens.append(id)
                        }
                    }
                }
                pairTitleStarts[t + 1] = UInt32(pairTokens.count)
            }
        }
        if Task.isCancelled { return nil }
        let tokenCount = tokens.count
        lastTitleOfToken = []

        // Token -> titles CSR (titles visited ascending, so postings sorted).
        var tokenTitleOffsets = [UInt32](repeating: 0, count: tokenCount + 1)
        for token in pairTokens { tokenTitleOffsets[Int(token) + 1] &+= 1 }
        for k in 0..<tokenCount { tokenTitleOffsets[k + 1] &+= tokenTitleOffsets[k] }
        var cursor = Array(tokenTitleOffsets.dropLast())
        var tokenTitles = [UInt32](repeating: 0, count: pairTokens.count)
        for t in 0..<titleCount {
            for p in Int(pairTitleStarts[t])..<Int(pairTitleStarts[t + 1]) {
                let token = Int(pairTokens[p])
                tokenTitles[Int(cursor[token])] = UInt32(t)
                cursor[token] &+= 1
            }
        }
        pairTokens = []; cursor = []

        // 3. Substring dictionary: every token suffix keyed by 8 bytes.
        let tokenOffsets = tokens.offsets
        let tokenBytes = tokens.bytes
        var suffixes: [Suffix] = []
        suffixes.reserveCapacity(tokenBytes.count)
        tokenBytes.withUnsafeBufferPointer { blob in
            for k in 0..<tokenCount {
                let lo = Int(tokenOffsets[k]), hi = Int(tokenOffsets[k + 1])
                for s in lo..<hi {
                    suffixes.append(Suffix(key: packKey(blob, s, hi), ref: UInt64(k) << 32 | UInt64(s - lo)))
                }
            }
        }
        if Task.isCancelled { return nil }
        suffixes.sort { $0.key != $1.key ? $0.key < $1.key : $0.ref < $1.ref }
        let suffixKeys = suffixes.map(\.key)
        let suffixRefs = suffixes.map(\.ref)
        suffixes = []
        if Task.isCancelled { return nil }

        // 4. Title-major programme columns (counting sort, stable by ordinal).
        var runOffsets = [UInt32](repeating: 0, count: titleCount + 1)
        for t in titleOfOrdinal { runOffsets[Int(t) + 1] &+= 1 }
        for k in 0..<titleCount { runOffsets[k + 1] &+= runOffsets[k] }
        var fill = Array(runOffsets.dropLast())
        var startColumn = [Double](repeating: 0, count: total)
        var endColumn = [Double](repeating: 0, count: total)
        var slotColumn = [UInt32](repeating: 0, count: total)
        var ordinalColumn = [UInt32](repeating: 0, count: total)
        var maxDuration: Double = 0
        o = 0
        for (slot, programs) in guides.enumerated() {
            if Task.isCancelled { return nil }
            for program in programs {
                let t = Int(titleOfOrdinal[o])
                let at = Int(fill[t]); fill[t] = UInt32(at + 1)
                let s = program.start.timeIntervalSinceReferenceDate
                let e = program.end.timeIntervalSinceReferenceDate
                startColumn[at] = s
                endColumn[at] = e
                if e - s > maxDuration { maxDuration = e - s }
                slotColumn[at] = UInt32(slot)
                ordinalColumn[at] = UInt32(o)
                o += 1
            }
        }
        titleOfOrdinal = []

        // 5. Order each title run by (start, ordinal): the time component of
        //    the score is then monotonic along the run, so ranking can stop
        //    a run as soon as the heap threshold is out of reach.
        var permutation: [Int] = []
        var startScratch: [Double] = [], endScratch: [Double] = []
        var slotScratch: [UInt32] = [], ordinalScratch: [UInt32] = []
        for t in 0..<titleCount {
            if t & 1023 == 0, Task.isCancelled { return nil }
            let lo = Int(runOffsets[t]), hi = Int(runOffsets[t + 1])
            if hi - lo < 2 { continue }
            var sorted = true
            for i in (lo + 1)..<hi where startColumn[i] < startColumn[i - 1] { sorted = false; break }
            if sorted { continue }   // ordinals ascend within a run, so ties are already ordered
            permutation.removeAll(keepingCapacity: true)
            permutation.append(contentsOf: lo..<hi)
            permutation.sort { a, b in
                startColumn[a] != startColumn[b] ? startColumn[a] < startColumn[b] : ordinalColumn[a] < ordinalColumn[b]
            }
            startScratch.removeAll(keepingCapacity: true); endScratch.removeAll(keepingCapacity: true)
            slotScratch.removeAll(keepingCapacity: true); ordinalScratch.removeAll(keepingCapacity: true)
            for i in permutation {
                startScratch.append(startColumn[i]); endScratch.append(endColumn[i])
                slotScratch.append(slotColumn[i]); ordinalScratch.append(ordinalColumn[i])
            }
            for k in 0..<(hi - lo) {
                startColumn[lo + k] = startScratch[k]; endColumn[lo + k] = endScratch[k]
                slotColumn[lo + k] = slotScratch[k]; ordinalColumn[lo + k] = ordinalScratch[k]
            }
        }

        return ProgramSearchIndex(storage: Storage(
            guideIDs: guideIDs, guideChannelIDs: guideChannelIDs, guides: guides, guideStart: guideStart,
            titleOffsets: lowerOffsets, titleBytes: lowerBytes, titleRunOffsets: runOffsets,
            tokenOffsets: tokenOffsets, tokenBytes: tokenBytes,
            tokenTitleOffsets: tokenTitleOffsets, tokenTitles: tokenTitles,
            suffixKeys: suffixKeys, suffixRefs: suffixRefs,
            start: startColumn, end: endColumn, slot: slotColumn, ordinal: ordinalColumn,
            maxDuration: maxDuration))
    }

    /// Search normalization shared by index and query: lowercased, and
    /// canonically composed (NFC) when non-ASCII so byte matching agrees
    /// with the original `String.contains` for precomposed/decomposed text.
    static func normalize(_ text: String) -> String {
        let lower = text.lowercased()
        return lower.utf8.allSatisfy({ $0 < 0x80 }) ? lower : lower.precomposedStringWithCanonicalMapping
    }

    private struct Suffix { var key: UInt64; var ref: UInt64 }

    @inline(__always)
    private static func packKey(_ blob: UnsafeBufferPointer<UInt8>, _ from: Int, _ to: Int) -> UInt64 {
        var key: UInt64 = 0
        let n = Swift.min(8, to - from)
        for i in 0..<n { key |= UInt64(blob[from + i]) << UInt64(56 - 8 * i) }
        return key
    }

    // MARK: Query

    struct Hit: Sendable {
        let ordinal: UInt32
        let score: Double
    }

    /// Ranks every programme whose lowercased title contains each of
    /// `tokens` (bytes, lowercased, no spaces/tabs), exactly as the original
    /// linear scan: score = title match (120 prefix of `phrase` / 70 contains
    /// `phrase` / 10) + airtime proximity; sorted by score, then upcoming
    /// first (soonest), then past (most recent), then guide order; capped to
    /// `limit` distinct programme ids. `slotChannel[slot] < 0` excludes
    /// programmes whose channel is not in the caller's channel list.
    func search(phrase: [UInt8], tokens: [[UInt8]], now: Date, slotChannel: [Int32], limit: Int = 300) -> [Hit] {
        guard let s = storage, !tokens.isEmpty, limit > 0 else { return [] }
        let titleWords = (s.titleCount + 63) >> 6
        let tokenWords = (s.tokenCount + 63) >> 6
        let nowRef = now.timeIntervalSinceReferenceDate
        return withUnsafeTemporaryAllocation(of: UInt64.self, capacity: titleWords * 2 + tokenWords) { scratch in
            let matched = UnsafeMutableBufferPointer(rebasing: scratch[0..<titleWords])
            let term = UnsafeMutableBufferPointer(rebasing: scratch[titleWords..<(titleWords * 2)])
            let seenTokens = UnsafeMutableBufferPointer(rebasing: scratch[(titleWords * 2)...])
            for (n, token) in tokens.enumerated() {
                let target = n == 0 ? matched : term
                let any = s.fillTitles(containing: token, into: target, seenTokens: seenTokens)
                if !any { return [] }
                if n > 0 {
                    var nonEmpty: UInt64 = 0
                    for w in 0..<titleWords { matched[w] &= term[w]; nonEmpty |= matched[w] }
                    if nonEmpty == 0 { return [] }
                }
            }
            if Task.isCancelled { return [] }
            var capacity = limit
            while true {
                let (ranked, complete) = s.rank(titles: UnsafeBufferPointer(matched), phrase: phrase,
                                                tokenCount: tokens.count, now: nowRef,
                                                slotChannel: slotChannel, capacity: capacity)
                // Deduplicate by programme id, keeping the best-ranked copy.
                var seen = Set<String>(minimumCapacity: Swift.min(ranked.count, limit))
                var hits: [Hit] = []
                hits.reserveCapacity(Swift.min(ranked.count, limit))
                for candidate in ranked {
                    if hits.count >= limit { break }
                    if seen.insert(program(ordinal: Int(candidate.ordinal)).program.id).inserted {
                        hits.append(Hit(ordinal: candidate.ordinal, score: candidate.score))
                    }
                }
                // If duplicates pushed us under the cap while better-ranked
                // candidates were cut by the heap, widen and rank again.
                if hits.count >= limit || complete { return hits }
                if Task.isCancelled { return [] }
                capacity *= 4
            }
        }
    }
}

// MARK: - Query internals

nonisolated extension ProgramSearchIndex.Storage {
    /// Sets the bit of every title that has a token containing `query`.
    /// Returns false when nothing matches.
    fileprivate func fillTitles(containing query: [UInt8],
                                into bits: UnsafeMutableBufferPointer<UInt64>,
                                seenTokens: UnsafeMutableBufferPointer<UInt64>) -> Bool {
        bits.update(repeating: 0)
        seenTokens.update(repeating: 0)
        let qn = query.count
        var lowKey: UInt64 = 0, highKey: UInt64 = .max
        for i in 0..<Swift.min(8, qn) {
            let shift = UInt64(56 - 8 * i)
            lowKey |= UInt64(query[i]) << shift
        }
        let fixed = Swift.min(8, qn)
        if fixed < 8 {
            highKey = lowKey | (UInt64.max >> UInt64(8 * fixed))
        } else {
            highKey = lowKey
        }
        var any = false
        suffixKeys.withUnsafeBufferPointer { keys in
            // lower_bound(lowKey), upper_bound(highKey)
            var lo = 0, hi = keys.count
            while lo < hi { let m = (lo + hi) >> 1; if keys[m] < lowKey { lo = m + 1 } else { hi = m } }
            let first = lo
            hi = keys.count
            while lo < hi { let m = (lo + hi) >> 1; if keys[m] <= highKey { lo = m + 1 } else { hi = m } }
            let last = lo
            guard first < last else { return }
            suffixRefs.withUnsafeBufferPointer { refs in
            tokenBytes.withUnsafeBufferPointer { tb in
            tokenOffsets.withUnsafeBufferPointer { toff in
            tokenTitleOffsets.withUnsafeBufferPointer { ptoff in
            tokenTitles.withUnsafeBufferPointer { postings in
            query.withUnsafeBufferPointer { q in
                for i in first..<last {
                    let ref = refs[i]
                    let token = Int(ref >> 32)
                    let word = token >> 6, bit = UInt64(1) << UInt64(token & 63)
                    if seenTokens[word] & bit != 0 { continue }
                    if qn > 8 {
                        // Key equality covers 8 bytes; verify the rest.
                        let at = Int(toff[token]) + Int(ref & 0xFFFF_FFFF)
                        let end = Int(toff[token + 1])
                        if end - at < qn { continue }
                        var equal = true
                        for j in 8..<qn where tb[at + j] != q[j] { equal = false; break }
                        if !equal { continue }
                    }
                    seenTokens[word] |= bit
                    any = true
                    for p in Int(ptoff[token])..<Int(ptoff[token + 1]) {
                        let t = Int(postings[p])
                        bits[t >> 6] |= UInt64(1) << UInt64(t & 63)
                    }
                }
            }}}}}}
        }
        return any
    }

    fileprivate struct Candidate {
        var score: Double
        var start: Double
        var ordinal: UInt32
        var future: Bool
    }

    /// Strict ranking order of the original comparator, with guide order as
    /// the final tiebreak.
    @inline(__always)
    fileprivate static func ranksBefore(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.future != b.future { return a.future }
        if a.start != b.start { return a.future ? a.start < b.start : a.start > b.start }
        return a.ordinal < b.ordinal
    }

    /// Returns the best `capacity` candidates in rank order and whether that
    /// list is every matching candidate.
    fileprivate func rank(titles: UnsafeBufferPointer<UInt64>, phrase: [UInt8], tokenCount: Int,
                          now: Double, slotChannel: [Int32], capacity: Int) -> ([Candidate], Bool) {
        var heap: [Candidate] = []   // root = worst kept candidate
        heap.reserveCapacity(capacity)
        var complete = true
        @inline(__always) func consider(_ candidate: Candidate) {
            if heap.count < capacity {
                heap.append(candidate)
                Self.siftUp(&heap, heap.count - 1)
            } else {
                complete = false
                if Self.ranksBefore(candidate, heap[0]) {
                    heap[0] = candidate
                    Self.siftDown(&heap, 0)
                }
            }
        }
        titleBytes.withUnsafeBufferPointer { tbytes in
        titleOffsets.withUnsafeBufferPointer { toff in
        titleRunOffsets.withUnsafeBufferPointer { runs in
        start.withUnsafeBufferPointer { startCol in
        end.withUnsafeBufferPointer { endCol in
        slot.withUnsafeBufferPointer { slotCol in
        ordinal.withUnsafeBufferPointer { ordCol in
        slotChannel.withUnsafeBufferPointer { channelOfSlot in
        phrase.withUnsafeBufferPointer { ph in
            // Title text score is constant per title. Visit the 120 group,
            // then 70, then 10 so the heap threshold rises early and whole
            // titles (and passes) can be skipped by their upper bound.
            for pass in 0..<3 {
                let passScore: Double = pass == 0 ? 120 : (pass == 1 ? 70 : 10)
                if pass == 2 && tokenCount == 1 { break }
                if heap.count == capacity, passScore + 80 < heap[0].score { complete = false; break }
                for w in 0..<titles.count {
                    var bitsWord = titles[w]
                    while bitsWord != 0 {
                        let t = (w << 6) | bitsWord.trailingZeroBitCount
                        bitsWord &= bitsWord &- 1
                        let tlo = Int(toff[t]), thi = Int(toff[t + 1])
                        let text: Double
                        if Self.hasPrefix(tbytes, tlo, thi, ph) { text = 120 }
                        else if tokenCount == 1 || Self.contains(tbytes, tlo, thi, ph) { text = 70 }
                        else { text = 10 }
                        if text != passScore { continue }
                        if heap.count == capacity, text + 80 < heap[0].score { complete = false; continue }
                        let lo = Int(runs[t]), hi = Int(runs[t + 1])
                        // pivot = first programme starting after `now`.
                        var pivot = lo, upper = hi
                        while pivot < upper {
                            let m = (pivot + upper) >> 1
                            if startCol[m] <= now { pivot = m + 1 } else { upper = m }
                        }
                        // Upcoming: the score falls 40 -> 0 over the next 24 h,
                        // is 4 up to 7 days, then 0. Each piece is non-increasing
                        // along the run, so an out-of-reach programme ends its
                        // piece (jump to the 4-point piece) or the whole run.
                        var i = pivot
                        while i < hi {
                            let s = startCol[i]
                            var score: Double = 0
                            score += text
                            let minutes = (s - now) / 60
                            if minutes < 24 * 60 {
                                score += 40 - (minutes / (24 * 60)) * 40
                            } else if minutes < 7 * 24 * 60 {
                                score += 4
                            }
                            if heap.count == capacity && score < heap[0].score {
                                complete = false
                                guard minutes < 24 * 60, text + 4 >= heap[0].score else { break }
                                var next = i + 1, top = hi
                                while next < top {
                                    let m = (next + top) >> 1
                                    if (startCol[m] - now) / 60 < 24 * 60 { next = m + 1 } else { top = m }
                                }
                                i = next
                                continue
                            }
                            if channelOfSlot[Int(slotCol[i])] >= 0 {
                                consider(Candidate(score: score, start: s, ordinal: ordCol[i], future: endCol[i] > now))
                            }
                            i += 1
                        }
                        // Started at or before now: live (+80) or past (-40).
                        // Below `now - maxDuration` nothing can still be live.
                        let liveFloor = now - maxDuration - 1
                        i = pivot - 1
                        while i >= lo {
                            let s = startCol[i]
                            if s <= liveFloor && heap.count == capacity && text - 40 < heap[0].score {
                                complete = false; break
                            }
                            if channelOfSlot[Int(slotCol[i])] >= 0 {
                                let live = endCol[i] > now
                                var score: Double = 0
                                score += text
                                if live { score += 80 } else { score -= 40 }
                                consider(Candidate(score: score, start: s, ordinal: ordCol[i], future: live))
                            }
                            i -= 1
                        }
                    }
                }
            }
        }}}}}}}}}
        heap.sort(by: Self.ranksBefore)
        return (heap, complete)
    }

    // Heap ordered so the root is the candidate that ranks last.
    @inline(__always)
    private static func siftUp(_ heap: inout [Candidate], _ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) >> 1
            if ranksBefore(heap[parent], heap[child]) { heap.swapAt(parent, child); child = parent } else { return }
        }
    }

    @inline(__always)
    private static func siftDown(_ heap: inout [Candidate], _ index: Int) {
        var parent = index
        let n = heap.count
        while true {
            let l = 2 * parent + 1
            if l >= n { return }
            var worst = l
            let r = l + 1
            if r < n, ranksBefore(heap[l], heap[r]) { worst = r }
            if ranksBefore(heap[parent], heap[worst]) { heap.swapAt(parent, worst); parent = worst } else { return }
        }
    }

    @inline(__always)
    private static func hasPrefix(_ blob: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int,
                                  _ phrase: UnsafeBufferPointer<UInt8>) -> Bool {
        let n = phrase.count
        if hi - lo < n { return false }
        return memcmp(blob.baseAddress! + lo, phrase.baseAddress!, n) == 0
    }

    private static func contains(_ blob: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int,
                                 _ phrase: UnsafeBufferPointer<UInt8>) -> Bool {
        let n = phrase.count
        if hi - lo < n { return false }
        return memmem(blob.baseAddress! + lo, hi - lo, phrase.baseAddress!, n) != nil
    }
}

// MARK: - Byte-string interner (build time only)

/// Open-addressing table of UInt32 ids over a byte blob. Interns each
/// distinct byte string once; ids are dense and assigned in first-seen order.
nonisolated struct SearchByteInterner {
    private(set) var bytes: [UInt8] = []
    private(set) var offsets: [UInt32] = [0]
    private var hashes: [UInt32] = []
    private var table: [UInt32]      // id + 1, 0 = empty
    private var mask: Int

    init(expected: Int) {
        var size = 16
        while size < expected * 2 { size <<= 1 }
        table = [UInt32](repeating: 0, count: expected == 0 ? 0 : size)
        mask = size - 1
        if expected > 0 { bytes.reserveCapacity(expected * 8); offsets.reserveCapacity(expected + 1); hashes.reserveCapacity(expected) }
    }

    var count: Int { offsets.count - 1 }

    @inline(__always)
    static func hash(_ key: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var h: UInt64 = 0x9E37_79B9_7F4A_7C15 ^ UInt64(key.count)
        var i = 0
        let n = key.count
        if let base = key.baseAddress {
            let raw = UnsafeRawPointer(base)
            while i + 8 <= n {
                let w = raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)
                h = (h ^ w) &* 0xFF51_AFD7_ED55_8CCD
                h ^= h >> 32
                i += 8
            }
            var tail: UInt64 = 0
            var shift: UInt64 = 0
            while i < n { tail |= UInt64(base[i]) << shift; shift += 8; i += 1 }
            h = (h ^ tail) &* 0xC4CE_B9FE_1A85_EC53
        }
        h ^= h >> 29
        return h
    }

    mutating func intern(_ key: UnsafeBufferPointer<UInt8>) -> (UInt32, Bool) {
        if count * 2 >= table.count { grow() }
        let h = Self.hash(key)
        let h32 = UInt32(truncatingIfNeeded: h)
        var slot = Int(truncatingIfNeeded: h) & mask
        while true {
            let entry = table[slot]
            if entry == 0 { break }
            let id = Int(entry - 1)
            if hashes[id] == h32 {
                let lo = Int(offsets[id]), hi = Int(offsets[id + 1])
                if hi - lo == key.count && (key.count == 0 || bytes.withUnsafeBufferPointer {
                    memcmp($0.baseAddress! + lo, key.baseAddress!, key.count) == 0 }) {
                    return (UInt32(id), false)
                }
            }
            slot = (slot + 1) & mask
        }
        let id = UInt32(count)
        table[slot] = id + 1
        hashes.append(h32)
        bytes.append(contentsOf: key)
        offsets.append(UInt32(bytes.count))
        return (id, true)
    }

    private mutating func grow() {
        let size = Swift.max(16, table.count * 2)
        table = [UInt32](repeating: 0, count: size)
        mask = size - 1
        for id in 0..<count {
            var slot = Int(truncatingIfNeeded: rehash(id)) & mask
            while table[slot] != 0 { slot = (slot + 1) & mask }
            table[slot] = UInt32(id + 1)
        }
    }

    private func rehash(_ id: Int) -> UInt64 {
        let lo = Int(offsets[id]), hi = Int(offsets[id + 1])
        return bytes.withUnsafeBufferPointer { Self.hash(UnsafeBufferPointer(rebasing: $0[lo..<hi])) }
    }
}
