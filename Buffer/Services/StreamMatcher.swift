import Foundation

/// Materialized search data for a single channel. The live index is the flat
/// `StreamSearchIndex` below; this value is only produced on demand through
/// `StreamSearchIndex.entries` for diagnostics and tests.
nonisolated struct ChannelSearchIndex: Sendable, Codable {
    let channel: Channel
    let nameLower: String
    let nameWords: ContiguousArray<String>
    let nameCompact: String
    let nameAcronym: String
    let group: String          // original channel group name (for display)
    let inSportsGroup: Bool
    let isAudioOnlyGroup: Bool
    let isHidden: Bool         // channel belongs to a user-hidden group
    let guideKey: String?       // source-scoped when physical ownership is known
    /// EPG titles already lowercased, in guide order.
    /// Only programs within the -1h…+48h window are kept.
    let epgTitles: ContiguousArray<EPGTitle>

    struct EPGTitle: Sendable, Codable {
        let title: String       // original casing for display
        let description: String // original casing, trimmed for display
        let titleLower: ContiguousArray<UInt8>  // UTF-8 bytes for fast search
        let descLower: ContiguousArray<UInt8>   // description UTF-8 bytes
        let titleWords: ContiguousArray<String>
        let titleCompact: String
        let start: Date
        let end: Date

        private enum CodingKeys: String, CodingKey {
            case title
            case description
            case titleLower
            case descLower
            case titleWords
            case titleCompact
            case start
            case end
        }

        init(
            title: String,
            description: String,
            titleLower: ContiguousArray<UInt8>,
            descLower: ContiguousArray<UInt8>,
            titleWords: ContiguousArray<String>,
            titleCompact: String,
            start: Date,
            end: Date
        ) {
            self.title = title
            self.description = description
            self.titleLower = titleLower
            self.descLower = descLower
            self.titleWords = titleWords
            self.titleCompact = titleCompact
            self.start = start
            self.end = end
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            description = try container.decode(String.self, forKey: .description)
            titleLower = ContiguousArray(try container.decode(Data.self, forKey: .titleLower))
            descLower = ContiguousArray(try container.decode(Data.self, forKey: .descLower))
            titleWords = ContiguousArray(try container.decode([String].self, forKey: .titleWords))
            titleCompact = try container.decode(String.self, forKey: .titleCompact)
            start = try container.decode(Date.self, forKey: .start)
            end = try container.decode(Date.self, forKey: .end)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(title, forKey: .title)
            try container.encode(description, forKey: .description)
            try container.encode(Data(titleLower), forKey: .titleLower)
            try container.encode(Data(descLower), forKey: .descLower)
            try container.encode(Array(titleWords), forKey: .titleWords)
            try container.encode(titleCompact, forKey: .titleCompact)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
        }
    }
}

// MARK: - Token interning

/// Every word, acronym and query term is interned once into a byte blob and
/// referenced by a `UInt32` ID. Non-ASCII tokens are stored in NFC so ID
/// equality is exactly Swift `String` (canonical) equality.
nonisolated struct SportsTokenTable: Sendable {
    static let absent = UInt32.max
    static let asciiBit: UInt32 = 1 << 16
    static let indexableBit: UInt32 = 1 << 17

    private(set) var bytes: [UInt8] = []
    private(set) var offsets: [UInt32] = [0]
    /// bits 0…15 Character count (saturating), bit 16 ASCII, bit 17 indexable.
    private(set) var info: [UInt32] = []
    private var hashes: [UInt64] = []
    /// Open addressing: `id + 1` in the low 32 bits, hash fingerprint above.
    private var slots: [UInt64] = Array(repeating: 0, count: 1 << 12)

    var count: Int { info.count }

    init(trivial: [String] = []) {
        for word in trivial {
            let id = intern(word)
            info[Int(id)] &= ~Self.indexableBit
        }
    }

    @inline(__always) func charCount(_ id: UInt32) -> Int { Int(info[Int(id)] & 0xFFFF) }
    @inline(__always) func isASCII(_ id: UInt32) -> Bool { info[Int(id)] & Self.asciiBit != 0 }
    @inline(__always) func isIndexable(_ id: UInt32) -> Bool { info[Int(id)] & Self.indexableBit != 0 }
    @inline(__always) func range(_ id: UInt32) -> Range<Int> { Int(offsets[Int(id)])..<Int(offsets[Int(id) + 1]) }

    func string(_ id: UInt32) -> String {
        String(decoding: bytes[range(id)], as: UTF8.self)
    }

    /// Word-at-a-time multiplicative hash (8-byte unaligned loads).
    @inline(__always) static func hash(_ p: UnsafeBufferPointer<UInt8>) -> UInt64 {
        let n = p.count
        var h: UInt64 = 0x9E37_79B9_7F4A_7C15 ^ UInt64(truncatingIfNeeded: n)
        guard let base = p.baseAddress else { return h }
        let raw = UnsafeRawPointer(base)
        var i = 0
        while i + 8 <= n {
            h = (h ^ raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)) &* 0xFF51_AFD7_ED55_8CCD
            h ^= h >> 32
            i += 8
        }
        if i < n {
            var w: UInt64 = 0
            var shift: UInt64 = 0
            while i < n { w |= UInt64(base[i]) << shift; shift += 8; i += 1 }
            h = (h ^ w) &* 0xC4CE_B9FE_1A85_EC53
        }
        return h ^ (h >> 29)
    }

    @inline(__always) private func equal(_ id: Int, _ p: UnsafeBufferPointer<UInt8>) -> Bool {
        let lo = Int(offsets[id]), hi = Int(offsets[id + 1])
        guard hi - lo == p.count else { return false }
        return bytes.withUnsafeBufferPointer { b in
            p.count == 0 || memcmp(b.baseAddress! + lo, p.baseAddress!, p.count) == 0
        }
    }

    func lookup(bytes p: UnsafeBufferPointer<UInt8>) -> UInt32? {
        let h = Self.hash(p)
        let fingerprint = h & 0xFFFF_FFFF_0000_0000
        let mask = slots.count - 1
        var s = Int(truncatingIfNeeded: h) & mask
        while true {
            let v = slots[s]
            if v == 0 { return nil }
            let id = Int(v & 0xFFFF_FFFF) - 1
            if v & 0xFFFF_FFFF_0000_0000 == fingerprint, equal(id, p) { return UInt32(id) }
            s = (s + 1) & mask
        }
    }

    /// Lookup by `String`, canonicalised exactly as `intern(_:)` stores it.
    func lookup(_ string: String) -> UInt32? {
        var s = string
        if let found = s.withUTF8({ buf -> UInt32?? in
            SportsText.isASCII(buf) ? .some(lookup(bytes: buf)) : nil
        }) { return found }
        var nfc = string.precomposedStringWithCanonicalMapping
        return nfc.withUTF8 { lookup(bytes: $0) }
    }

    /// Interns ASCII (or already-canonical) bytes with a known Character count.
    mutating func intern(bytes p: UnsafeBufferPointer<UInt8>, ascii: Bool, charCount: Int) -> UInt32 {
        let h = Self.hash(p)
        let fingerprint = h & 0xFFFF_FFFF_0000_0000
        let mask = slots.count - 1
        var s = Int(truncatingIfNeeded: h) & mask
        while true {
            let v = slots[s]
            if v == 0 { break }
            let id = Int(v & 0xFFFF_FFFF) - 1
            if v & 0xFFFF_FFFF_0000_0000 == fingerprint, equal(id, p) { return UInt32(id) }
            s = (s + 1) & mask
        }
        let id = UInt32(info.count)
        bytes.append(contentsOf: p)
        offsets.append(UInt32(bytes.count))
        hashes.append(h)
        info.append(UInt32(min(charCount, 0xFFFF)) | (ascii ? Self.asciiBit : 0) | (charCount >= 2 ? Self.indexableBit : 0))
        slots[s] = fingerprint | UInt64(id + 1)
        if info.count * 2 > slots.count { grow() }
        return id
    }

    mutating func intern(_ string: String) -> UInt32 {
        var s = string
        if let id = s.withUTF8({ buf -> UInt32? in
            SportsText.isASCII(buf) ? intern(bytes: buf, ascii: true, charCount: buf.count) : nil
        }) { return id }
        var nfc = string.precomposedStringWithCanonicalMapping
        let count = string.count
        return nfc.withUTF8 { intern(bytes: $0, ascii: false, charCount: count) }
    }

    private mutating func grow() {
        let size = slots.count * 2
        var next = [UInt64](repeating: 0, count: size)
        let mask = size - 1
        for id in 0..<hashes.count {
            let h = hashes[id]
            var s = Int(truncatingIfNeeded: h) & mask
            while next[s] != 0 { s = (s + 1) & mask }
            next[s] = (h & 0xFFFF_FFFF_0000_0000) | UInt64(id + 1)
        }
        slots = next
    }
}

// MARK: - Byte-level text primitives

nonisolated enum SportsText {
    @inline(__always) static func isASCII(_ p: UnsafeBufferPointer<UInt8>) -> Bool {
        var acc: UInt8 = 0
        for b in p { acc |= b }
        return acc < 0x80
    }

    @inline(__always) static func isAlnum(_ b: UInt8) -> Bool {
        (b &- 48) < 10 || ((b | 0x20) &- 97) < 26
    }

    @inline(__always) static func isLetter(_ b: UInt8) -> Bool { ((b | 0x20) &- 97) < 26 }

    /// Exact prefilter: a needle can only occur if every adjacent byte pair
    /// of it hashes to a bit also set in the haystack's mask.
    @inline(__always) static func bigramMask(_ p: UnsafeBufferPointer<UInt8>) -> UInt64 {
        guard p.count >= 2 else { return 0 }
        var m: UInt64 = 0
        var prev = UInt32(p[0])
        for i in 1..<p.count {
            let cur = UInt32(p[i])
            let h = ((prev << 8) | cur) &* 0x9E37_79B1
            m |= 1 << UInt64(h >> 26)
            prev = cur
        }
        return m
    }

    static func bigramMask(_ bytes: [UInt8]) -> UInt64 { bytes.withUnsafeBufferPointer(bigramMask) }

    /// Leftmost occurrence of `n` in `h` at or after `from` (memchr on the
    /// first byte, memcmp for the rest); returns the absolute start offset.
    @inline(__always) static func find(_ h: UnsafeBufferPointer<UInt8>, from: Int, _ n: UnsafeBufferPointer<UInt8>) -> Int? {
        let nLen = n.count
        guard nLen > 0, h.count - from >= nLen, let hb = h.baseAddress, let nb = n.baseAddress else { return nil }
        let first = Int32(nb[0])
        let last = h.count - nLen
        var i = from
        while i <= last {
            guard let p = memchr(hb + i, first, last - i + 1) else { return nil }
            let j = hb.distance(to: p.assumingMemoryBound(to: UInt8.self))
            if nLen == 1 || memcmp(hb + j + 1, nb + 1, nLen - 1) == 0 { return j }
            i = j + 1
        }
        return nil
    }

    /// Per-row known/found bits for up to 128 distinct needles of one event.
    struct SlotBits {
        var lo: UInt64 = 0
        var hi: UInt64 = 0
        @inline(__always) func has(_ slot: Int) -> Bool {
            slot < 64 ? lo & (1 << UInt64(slot)) != 0 : hi & (1 << UInt64(slot - 64)) != 0
        }
        @inline(__always) mutating func set(_ slot: Int) {
            if slot < 64 { lo |= 1 << UInt64(slot) } else { hi |= 1 << UInt64(slot - 64) }
        }
    }

    /// Known/found bits for fuzzy-term presence in one text.
    struct TermCache {
        var known = SlotBits()
        var found = SlotBits()
    }

    /// Memoises a pure needle test within one haystack (one row or name).
    @inline(__always) static func cached(_ slot: Int, _ known: inout SlotBits, _ found: inout SlotBits, _ compute: () -> Bool) -> Bool {
        guard slot >= 0 && slot < 128 else { return compute() }
        if known.has(slot) { return found.has(slot) }
        let result = compute()
        known.set(slot)
        if result { found.set(slot) }
        return result
    }

    enum Tri { case yes, no, unknown }

    /// Appends at most `capacity` bytes written by `body` (returning the
    /// count) without per-byte append bookkeeping.
    @inline(__always) static func appendBytes(_ capacity: Int, to out: inout [UInt8],
                                              _ body: (UnsafeMutablePointer<UInt8>) -> Int) {
        let old = out.count
        out.append(contentsOf: repeatElement(0, count: capacity))
        let written = out.withUnsafeMutableBufferPointer { body($0.baseAddress! + old) }
        if written < capacity { out.removeLast(capacity - written) }
    }

    /// 256-bit bigram bloom for long text (descriptions), computed lazily.
    struct Mask256 {
        var w0: UInt64 = 0, w1: UInt64 = 0, w2: UInt64 = 0, w3: UInt64 = 0

        init() {}

        init(_ p: UnsafeBufferPointer<UInt8>) {
            guard p.count >= 2 else { return }
            var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
            withUnsafeMutableBytes(of: &words) { raw in
                let w = raw.bindMemory(to: UInt64.self)
                var prev = UInt32(p[0])
                for i in 1..<p.count {
                    let cur = UInt32(p[i])
                    let h = (((prev << 8) | cur) &* 0x9E37_79B1) >> 24
                    w[Int(h >> 6)] |= 1 << UInt64(h & 63)
                    prev = cur
                }
            }
            (w0, w1, w2, w3) = words
        }

        /// True when every bigram bit of `needle` is present here.
        @inline(__always) func covers(_ needle: Mask256) -> Bool {
            (needle.w0 & ~w0) | (needle.w1 & ~w1) | (needle.w2 & ~w2) | (needle.w3 & ~w3) == 0
        }
    }
}

// MARK: - Flat search index

/// Structure-of-arrays sports search index. Built once per catalog/guide
/// publication; matching walks integer IDs, posting lists and packed columns.
nonisolated struct StreamSearchIndex: Sendable {
    // Tokens
    let tokens: SportsTokenTable
    // Groups (unique channel group strings)
    let groupNames: [String]
    // Names (unique raw channel names): [lower][compact][acronym] in nameBytes
    let nameTextStart: [UInt32]      // count + 1
    let nameLowerLen: [UInt32]
    let nameCompactLen: [UInt32]
    let nameBytes: [UInt8]
    let nameWordStart: [UInt32]      // count + 1 into nameWordIDs
    let nameWordIDs: [UInt32]
    let nameFlags: [UInt8]           // NameFlag bits
    let nameMask: [UInt64]           // bigram mask of lower
    let nameCompactMask: [UInt64]
    let nameHeight: [UInt16]         // advertised resolution class
    let nameTokenStart: [UInt32]     // count + 1 into nameTokenIDs (indexable, sorted)
    let nameTokenIDs: [UInt32]
    // Entries (one per channel)
    let channels: [Channel]
    /// nameID in the low 29 bits; EntryFlag bits in the top three.
    let entryNameAndFlags: [UInt32]
    let entryGroup: [UInt32]
    let entryGuide: [UInt32]         // SportsTokenTable.absent when unguided
    // Guides (unique scoped guide keys)
    let guideKeys: [String]
    let guideRowStart: [UInt32]      // count + 1 into programme rows
    let guideEntryStart: [UInt32]    // count + 1 into guideEntries
    let guideEntries: [UInt32]
    let guideTokenStart: [UInt32]    // count + 1 into guideTokenIDs
    let guideTokenIDs: [UInt32]
    // Programme rows (SoA)
    let rowStart: [Double]           // timeIntervalSinceReferenceDate
    let rowEnd: [Double]
    let rowTitle: [String]
    let rowDescription: [String]
    let rowTextStart: [UInt32]       // count + 1: [titleLower][descLower][titleCompact]
    let rowTitleLen: [UInt32]
    let rowDescLen: [UInt32]
    let textBytes: [UInt8]
    let rowWordStart: [UInt32]       // count + 1: title words then description words
    let rowTitleWordCount: [UInt32]
    let rowWordIDs: [UInt32]
    let rowFlags: [UInt8]            // RowFlag bits
    let rowTitleMask: [UInt64]
    let rowCompactMask: [UInt64]
    /// Precomputed head-to-head separator span (lo << 32 | hi) in titleLower;
    /// `noSeparator` when absent. Only meaningful for ASCII titles.
    let rowSeparator: [UInt64]
    // Postings: token → entries (names) and token → guides (programmes)
    let namePostingStart: [UInt32]   // tokens.count + 1
    let namePostings: [UInt32]
    let guidePostingStart: [UInt32]  // tokens.count + 1
    let guidePostings: [UInt32]

    let programKeyCount: Int
    let epgTitleCount: Int
    let earliestProgramStart: Date?
    let latestProgramEnd: Date?

    enum NameFlag {
        static let lowerASCII: UInt8 = 1
        static let compactASCII: UInt8 = 2
        static let acronymASCII: UInt8 = 4
        static let radioPrefix: UInt8 = 8
    }
    enum EntryFlag {
        static let sports: UInt32 = 1 << 31
        static let audio: UInt32 = 1 << 30
        static let hidden: UInt32 = 1 << 29
        static let nameMask: UInt32 = (1 << 29) - 1
    }
    enum RowFlag {
        static let titleASCII: UInt8 = 1
        static let descASCII: UInt8 = 2
        static let compactASCII: UInt8 = 4
    }
    static let noSeparator = UInt64.max

    static let empty = StreamSearchIndex(builder: .init(), programKeyCount: 0)

    var entryCount: Int { channels.count }

    /// Materialized per-channel view, for diagnostics and tests only.
    var entries: Entries { Entries(index: self) }

    struct Entries: RandomAccessCollection, Sendable {
        let index: StreamSearchIndex
        var startIndex: Int { 0 }
        var endIndex: Int { index.channels.count }
        subscript(position: Int) -> ChannelSearchIndex { index.materialize(position) }
    }

    @inline(__always) func nameID(ofEntry e: Int) -> Int { Int(entryNameAndFlags[e] & EntryFlag.nameMask) }

    func nameLowerString(_ n: Int) -> String {
        let lo = Int(nameTextStart[n])
        return String(decoding: nameBytes[lo..<(lo + Int(nameLowerLen[n]))], as: UTF8.self)
    }
    func nameCompactString(_ n: Int) -> String {
        let lo = Int(nameTextStart[n]) + Int(nameLowerLen[n])
        return String(decoding: nameBytes[lo..<(lo + Int(nameCompactLen[n]))], as: UTF8.self)
    }
    func nameAcronymString(_ n: Int) -> String {
        let lo = Int(nameTextStart[n]) + Int(nameLowerLen[n]) + Int(nameCompactLen[n])
        return String(decoding: nameBytes[lo..<Int(nameTextStart[n + 1])], as: UTF8.self)
    }

    func materialize(_ e: Int) -> ChannelSearchIndex {
        let n = nameID(ofEntry: e)
        let flags = entryNameAndFlags[e]
        let g = entryGuide[e]
        var titles = ContiguousArray<ChannelSearchIndex.EPGTitle>()
        if g != SportsTokenTable.absent {
            for r in Int(guideRowStart[Int(g)])..<Int(guideRowStart[Int(g) + 1]) {
                let t = Int(rowTextStart[r]), tl = Int(rowTitleLen[r]), dl = Int(rowDescLen[r])
                let w = Int(rowWordStart[r])
                titles.append(.init(
                    title: rowTitle[r], description: rowDescription[r],
                    titleLower: ContiguousArray(textBytes[t..<(t + tl)]),
                    descLower: ContiguousArray(textBytes[(t + tl)..<(t + tl + dl)]),
                    titleWords: ContiguousArray(rowWordIDs[w..<(w + Int(rowTitleWordCount[r]))].map { tokens.string($0) }),
                    titleCompact: String(decoding: textBytes[(t + tl + dl)..<Int(rowTextStart[r + 1])], as: UTF8.self),
                    start: Date(timeIntervalSinceReferenceDate: rowStart[r]),
                    end: Date(timeIntervalSinceReferenceDate: rowEnd[r])))
            }
        }
        return ChannelSearchIndex(
            channel: channels[e], nameLower: nameLowerString(n),
            nameWords: ContiguousArray(nameWordIDs[Int(nameWordStart[n])..<Int(nameWordStart[n + 1])].map { tokens.string($0) }),
            nameCompact: nameCompactString(n), nameAcronym: nameAcronymString(n),
            group: groupNames[Int(entryGroup[e])],
            inSportsGroup: flags & EntryFlag.sports != 0, isAudioOnlyGroup: flags & EntryFlag.audio != 0,
            isHidden: flags & EntryFlag.hidden != 0,
            guideKey: g == SportsTokenTable.absent ? nil : guideKeys[Int(g)],
            epgTitles: titles)
    }

    /// Indexed token → entries, expanded from the name and guide posting
    /// lists (diagnostics and tests).
    var tokenToEntryIndices: [String: ContiguousArray<Int>] {
        var out: [String: ContiguousArray<Int>] = [:]
        for t in 0..<tokens.count {
            var set = Set<Int>()
            for p in Int(namePostingStart[t])..<Int(namePostingStart[t + 1]) { set.insert(Int(namePostings[p])) }
            for p in Int(guidePostingStart[t])..<Int(guidePostingStart[t + 1]) {
                let g = Int(guidePostings[p])
                for q in Int(guideEntryStart[g])..<Int(guideEntryStart[g + 1]) { set.insert(Int(guideEntries[q])) }
            }
            guard !set.isEmpty else { continue }
            out[tokens.string(UInt32(t)), default: []].append(contentsOf: set.sorted())
        }
        return out
    }

    var inverseDocumentFrequency: [String: Double] {
        guard entryCount > 0 else { return [:] }
        let total = Double(entryCount)
        return tokenToEntryIndices.mapValues { indices in
            let df = Double(indices.count)
            return log((total - df + 0.5) / (df + 0.5) + 1.0)
        }
    }
}

// MARK: - Index builder

nonisolated struct SportsIndexBuilder {
    struct GuideRef: Hashable {
        let source: UUID?
        let epg: String
    }

    var tokens = SportsTokenTable(trivial: StreamMatcher.trivialWordList)
    var heightIDs: [UInt32: UInt16] = [:]
    // groups
    var groupIDs: [String: UInt32] = [:]
    var groupNames: [String] = []
    var groupFlags: [UInt32] = []
    // names
    var rawNameIDs: [String: UInt32] = [:]
    var nameTextStart: [UInt32] = [0]
    var nameLowerLen: [UInt32] = []
    var nameCompactLen: [UInt32] = []
    var nameBytes: [UInt8] = []
    var nameWordStart: [UInt32] = [0]
    var nameWordIDs: [UInt32] = []
    var nameFlags: [UInt8] = []
    var nameMask: [UInt64] = []
    var nameCompactMask: [UInt64] = []
    var nameHeight: [UInt16] = []
    var nameTokenStart: [UInt32] = [0]
    var nameTokenIDs: [UInt32] = []
    // entries
    var channels: [Channel] = []
    var entryNameAndFlags: [UInt32] = []
    var entryGroup: [UInt32] = []
    var entryGuide: [UInt32] = []
    // guides
    var guideIDs: [GuideRef: UInt32] = [:]
    var guideKeys: [String] = []
    var guideRowStart: [UInt32] = [0]
    var guideTokenStart: [UInt32] = [0]
    var guideTokenIDs: [UInt32] = []
    var pendingGuideRows: [[EPGProgram]] = []
    var tokenStamp: [UInt32] = []
    // rows
    var rowStart: [Double] = []
    var rowEnd: [Double] = []
    var rowTitle: [String] = []
    var rowDescription: [String] = []
    var rowTextStart: [UInt32] = [0]
    var rowTitleLen: [UInt32] = []
    var rowDescLen: [UInt32] = []
    var textBytes: [UInt8] = []
    var rowWordStart: [UInt32] = [0]
    var rowTitleWordCount: [UInt32] = []
    var rowWordIDs: [UInt32] = []
    var rowFlags: [UInt8] = []
    var rowTitleMask: [UInt64] = []
    var rowCompactMask: [UInt64] = []
    var rowSeparator: [UInt64] = []

    init() {
        let heights: [(String, UInt16)] = [("4k", 2160), ("uhd", 2160), ("2160p", 2160), ("fhd", 1080), ("1080p", 1080),
                                           ("1080", 1080), ("hd", 720), ("720p", 720), ("720", 720), ("sd", 576)]
        for (word, height) in heights { heightIDs[tokens.intern(word)] = height }
    }

    mutating func reserveExact(rows: Int, textBytes text: Int, words: Int, guideTokens: Int) {
        reserve(programmes: rows)
        textBytes.reserveCapacity(text)
        rowWordIDs.reserveCapacity(words)
        guideTokenIDs.reserveCapacity(guideTokens)
    }

    /// Reserves programme columns for an upper bound of guide rows.
    mutating func reserve(programmes: Int) {
        rowStart.reserveCapacity(programmes); rowEnd.reserveCapacity(programmes)
        rowTitle.reserveCapacity(programmes); rowDescription.reserveCapacity(programmes)
        rowTextStart.reserveCapacity(programmes + 1); rowTitleLen.reserveCapacity(programmes)
        rowDescLen.reserveCapacity(programmes); rowWordStart.reserveCapacity(programmes + 1)
        rowTitleWordCount.reserveCapacity(programmes); rowFlags.reserveCapacity(programmes)
        rowTitleMask.reserveCapacity(programmes); rowCompactMask.reserveCapacity(programmes)
        rowSeparator.reserveCapacity(programmes)
    }

    /// Worker estimate for text and word columns (temporary storage).
    mutating func reserveText(programmes: Int) {
        textBytes.reserveCapacity(programmes * 160)
        rowWordIDs.reserveCapacity(programmes * 24)
    }

    // MARK: Text

    /// Appends `normalise(s)` to `out`, returning whether the result is ASCII.
    @inline(__always) static func appendNormalised(_ s: String, to out: inout [UInt8]) -> Bool {
        var copy = s
        let done = copy.withUTF8 { buf -> Bool? in
            guard SportsText.isASCII(buf) else { return SportsUnicode.appendNormalised(buf, to: &out) }
            SportsText.appendBytes(buf.count, to: &out) { dst in
                for i in 0..<buf.count { let b = buf[i]; dst[i] = (b &- 65) < 26 ? b | 0x20 : b }
                return buf.count
            }
            return true
        }
        if let done { return done }
        var normalised = StreamMatcher.normaliseString(s)
        return normalised.withUTF8 { buf in
            out.append(contentsOf: buf)
            return SportsText.isASCII(buf)
        }
    }

    /// Interns `tokenWords(in:)` of the normalised region and appends IDs.
    /// Returns the word Strings only on the non-ASCII path (for acronyms).
    @discardableResult
    static func appendWords(_ blob: [UInt8], _ range: Range<Int>, ascii: Bool, tokens: inout SportsTokenTable,
                            into ids: inout [UInt32], acronym: inout [UInt8]) -> [String]? {
        if ascii {
            // At most one word per three bytes; gather IDs, then append once.
            withUnsafeTemporaryAllocation(of: UInt32.self, capacity: range.count / 3 + 1) { found in
                var count = 0
                blob.withUnsafeBufferPointer { b in
                    var i = range.lowerBound
                    let end = range.upperBound
                    while i < end {
                        guard SportsText.isAlnum(b[i]) else { i &+= 1; continue }
                        let start = i
                        while i < end, SportsText.isAlnum(b[i]) { i &+= 1 }
                        if i - start >= 2 {
                            let slice = UnsafeBufferPointer(rebasing: b[start..<i])
                            found[count] = tokens.intern(bytes: slice, ascii: true, charCount: i - start)
                            count += 1
                            acronym.append(b[start])
                        }
                    }
                }
                ids.append(contentsOf: UnsafeBufferPointer(rebasing: found[0..<count]))
            }
            return nil
        }
        let simple = blob.withUnsafeBufferPointer { b -> Bool in
            let region = UnsafeBufferPointer(rebasing: b[range])
            return SportsUnicode.forEachWord(region) { start, end, characters, wordASCII, nfc in
                let word = UnsafeBufferPointer(rebasing: region[start..<end])
                if wordASCII || nfc {
                    ids.append(tokens.intern(bytes: word, ascii: wordASCII, charCount: characters))
                } else {
                    ids.append(tokens.intern(String(decoding: word, as: UTF8.self)))
                }
                let firstLength = word[0] < 0x80 ? 1 : SportsUnicode.decode(word, 0).1
                acronym.append(contentsOf: UnsafeBufferPointer(rebasing: word[0..<firstLength]))
            }
        }
        if simple { return nil }
        let words = StreamMatcher.tokenWords(in: String(decoding: blob[range], as: UTF8.self))
        for word in words { ids.append(tokens.intern(word)) }
        return words
    }

    /// `compactKey` of a normalised region, appended to `out`; returns ASCII.
    static func appendCompact(_ source: [UInt8], _ range: Range<Int>, ascii: Bool, to out: inout [UInt8]) -> Bool {
        if ascii {
            for i in range where SportsText.isAlnum(source[i]) { out.append(source[i]) }
            return true
        }
        let mark = out.count
        let simple = source.withUnsafeBufferPointer { SportsUnicode.appendCompact(UnsafeBufferPointer(rebasing: $0[range]), to: &out) }
        if simple { return out[mark...].allSatisfy { $0 < 0x80 } }
        let compact = StreamMatcher.compactKey(String(decoding: source[range], as: UTF8.self))
        var c = compact
        return c.withUTF8 { buf in
            out.append(contentsOf: buf)
            return SportsText.isASCII(buf)
        }
    }

    // MARK: Groups

    mutating func groupID(_ group: String, hiddenGroups: Set<String>, hiddenGroupPaths: [[String]]) -> UInt32 {
        if let id = groupIDs[group] { return id }
        let id = UInt32(groupNames.count)
        let groupLower = StreamMatcher.normaliseString(group)
        var flags: UInt32 = 0
        if groupLower.contains("sport") || groupLower.contains("ppv") { flags |= StreamSearchIndex.EntryFlag.sports }
        if groupLower.contains("radio") { flags |= StreamSearchIndex.EntryFlag.audio }
        if StreamMatcher.isGroupHidden(group, hiddenGroups: hiddenGroups, hiddenGroupPaths: hiddenGroupPaths) {
            flags |= StreamSearchIndex.EntryFlag.hidden
        }
        groupIDs[group] = id
        groupNames.append(group)
        groupFlags.append(flags)
        return id
    }

    // MARK: Names

    mutating func nameID(_ raw: String) -> UInt32 {
        if let id = rawNameIDs[raw] { return id }
        let id = UInt32(nameLowerLen.count)
        let lowerStart = nameBytes.count
        let ascii = Self.appendNormalised(raw, to: &nameBytes)
        let lowerRange = lowerStart..<nameBytes.count
        let wordsBegin = nameWordIDs.count
        var acronym: [UInt8] = []
        if let words = Self.appendWords(nameBytes, lowerRange, ascii: ascii, tokens: &tokens,
                                        into: &nameWordIDs, acronym: &acronym) {
            var a = StreamMatcher.acronym(for: ContiguousArray(words))
            acronym = a.withUTF8 { Array($0) }
        }
        let acronymASCII = acronym.allSatisfy { $0 < 0x80 }
        var compact: [UInt8] = []
        let compactASCII = Self.appendCompact(nameBytes, lowerRange, ascii: ascii, to: &compact)
        let lowerMask = nameBytes.withUnsafeBufferPointer { SportsText.bigramMask(UnsafeBufferPointer(rebasing: $0[lowerRange])) }
        let radio = ascii
            ? nameBytes[lowerRange].starts(with: Array("radio:".utf8))
            : String(decoding: nameBytes[lowerRange], as: UTF8.self).hasPrefix("radio:")
        nameLowerLen.append(UInt32(lowerRange.count))
        nameCompactLen.append(UInt32(compact.count))
        nameMask.append(lowerMask)
        nameCompactMask.append(SportsText.bigramMask(compact))
        nameBytes.append(contentsOf: compact)
        nameBytes.append(contentsOf: acronym)
        nameTextStart.append(UInt32(nameBytes.count))
        nameWordStart.append(UInt32(nameWordIDs.count))
        nameFlags.append((ascii ? StreamSearchIndex.NameFlag.lowerASCII : 0)
            | (compactASCII ? StreamSearchIndex.NameFlag.compactASCII : 0)
            | (acronymASCII ? StreamSearchIndex.NameFlag.acronymASCII : 0)
            | (radio ? StreamSearchIndex.NameFlag.radioPrefix : 0))
        // Advertised height and indexed tokens.
        var has2160 = false, has1080 = false, has720 = false, has576 = false
        var nameTokens: [UInt32] = []
        for w in nameWordIDs[wordsBegin...] {
            if let h = heightIDs[w] {
                switch h { case 2160: has2160 = true; case 1080: has1080 = true; case 720: has720 = true; default: has576 = true }
            }
            if tokens.isIndexable(w) { nameTokens.append(w) }
        }
        nameHeight.append(has2160 ? 2160 : has1080 ? 1080 : has720 ? 720 : has576 ? 576 : 0)
        if !acronym.isEmpty {
            let acronymID = acronymASCII
                ? acronym.withUnsafeBufferPointer { tokens.intern(bytes: $0, ascii: true, charCount: $0.count) }
                : tokens.intern(String(decoding: acronym, as: UTF8.self))
            if tokens.isIndexable(acronymID) { nameTokens.append(acronymID) }
        }
        nameTokens.sort()
        var last = SportsTokenTable.absent
        for t in nameTokens where t != last { nameTokenIDs.append(t); last = t }
        nameTokenStart.append(UInt32(nameTokenIDs.count))
        rawNameIDs[raw] = id
        return id
    }

    // MARK: Guides

    /// Registers the channel's source-scoped guide; its programmes are laid
    /// out later (in parallel chunks) by `appendGuide`.
    mutating func guideID(for channel: Channel, programs: [String: [EPGProgram]]) -> UInt32 {
        guard let epg = channel.epgChannelID else { return SportsTokenTable.absent }
        let ref = GuideRef(source: channel.sourceChannelIdentity?.sourceID, epg: epg)
        if let id = guideIDs[ref] { return id }
        let id = UInt32(guideKeys.count)
        let key = ref.source.map { $0.uuidString.lowercased() + "|" + epg } ?? epg
        guideKeys.append(key)
        guideIDs[ref] = id
        pendingGuideRows.append(programs[key] ?? programs[epg] ?? [])
        return id
    }

    /// Lays out one guide's in-window programme rows and its distinct
    /// indexable tokens. `stamp` must be unique per guide in this builder.
    mutating func appendGuide(_ rows: [EPGProgram], stamp: UInt32, cutoff: Double, horizon: Double) {
        if tokenStamp.count < tokens.count + 4096 { tokenStamp.append(contentsOf: repeatElement(0, count: tokens.count + 8192 - tokenStamp.count)) }
        var guideTokens: [UInt32] = []
        for p in rows {
            let start = p.start.timeIntervalSinceReferenceDate, end = p.end.timeIntervalSinceReferenceDate
            guard end > cutoff && start < horizon else { continue }
            appendRow(p, start: start, end: end)
            let words = Int(rowWordStart[rowWordStart.count - 2])..<rowWordIDs.count
            if tokenStamp.count < tokens.count { tokenStamp.append(contentsOf: repeatElement(0, count: tokens.count + 8192 - tokenStamp.count)) }
            for w in rowWordIDs[words] where tokens.isIndexable(w) && tokenStamp[Int(w)] != stamp {
                tokenStamp[Int(w)] = stamp
                guideTokens.append(w)
            }
        }
        guideTokenIDs.append(contentsOf: guideTokens)
        guideTokenStart.append(UInt32(guideTokenIDs.count))
        guideRowStart.append(UInt32(rowStart.count))
    }

    /// Appends a worker's guides (in order), re-interning its local tokens.
    mutating func merge(_ w: SportsIndexBuilder) {
        var map = [UInt32](repeating: 0, count: w.tokens.count)
        w.tokens.bytes.withUnsafeBufferPointer { blob in
            for id in 0..<w.tokens.count {
                let t = UInt32(id)
                map[id] = tokens.intern(bytes: UnsafeBufferPointer(rebasing: blob[w.tokens.range(t)]),
                                        ascii: w.tokens.isASCII(t), charCount: w.tokens.charCount(t))
            }
        }
        let textBase = UInt32(textBytes.count), wordBase = UInt32(rowWordIDs.count)
        let rowBase = UInt32(rowStart.count), guideTokenBase = UInt32(guideTokenIDs.count)
        textBytes.append(contentsOf: w.textBytes)
        map.withUnsafeBufferPointer { m in
            rowWordIDs.append(contentsOf: w.rowWordIDs.lazy.map { m[Int($0)] })
            guideTokenIDs.append(contentsOf: w.guideTokenIDs.lazy.map { m[Int($0)] })
        }
        rowTextStart.append(contentsOf: w.rowTextStart.dropFirst().lazy.map { $0 + textBase })
        rowWordStart.append(contentsOf: w.rowWordStart.dropFirst().lazy.map { $0 + wordBase })
        guideRowStart.append(contentsOf: w.guideRowStart.dropFirst().lazy.map { $0 + rowBase })
        guideTokenStart.append(contentsOf: w.guideTokenStart.dropFirst().lazy.map { $0 + guideTokenBase })
        rowStart.append(contentsOf: w.rowStart); rowEnd.append(contentsOf: w.rowEnd)
        rowTitle.append(contentsOf: w.rowTitle); rowDescription.append(contentsOf: w.rowDescription)
        rowTitleLen.append(contentsOf: w.rowTitleLen); rowDescLen.append(contentsOf: w.rowDescLen)
        rowTitleWordCount.append(contentsOf: w.rowTitleWordCount); rowFlags.append(contentsOf: w.rowFlags)
        rowTitleMask.append(contentsOf: w.rowTitleMask); rowCompactMask.append(contentsOf: w.rowCompactMask)
        rowSeparator.append(contentsOf: w.rowSeparator)
    }

    /// Lays out every registered guide, splitting contiguous guide ranges
    /// across cores; output order is identical to a sequential build.
    /// Returns false when cancelled.
    mutating func layOutGuides(cutoff: Double, horizon: Double, shouldCancel: @Sendable () -> Bool) -> Bool {
        let guides = pendingGuideRows
        pendingGuideRows = []
        let rowTotal = guides.reduce(0) { $0 + $1.count }
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunkCount = rowTotal < 20_000 ? 1 : min(guides.count, cores * 3)
        guard chunkCount > 1 else {
            reserve(programmes: rowTotal)
            reserveText(programmes: rowTotal)
            for (g, rows) in guides.enumerated() {
                guard !shouldCancel() else { return false }
                appendGuide(rows, stamp: UInt32(g + 1), cutoff: cutoff, horizon: horizon)
            }
            return true
        }
        // Balance chunks by programme count, keeping guide order.
        var bounds = [0]
        let target = (rowTotal + chunkCount - 1) / chunkCount
        var running = 0
        for (g, rows) in guides.enumerated() {
            running += rows.count
            if running >= target * bounds.count, bounds.count < chunkCount { bounds.append(g + 1) }
        }
        if bounds.last != guides.count { bounds.append(guides.count) }
        let chunks = bounds.count - 1
        nonisolated(unsafe) let results = UnsafeMutableBufferPointer<SportsIndexBuilder?>.allocate(capacity: chunks)
        results.initialize(repeating: nil)
        defer { results.deinitialize(); results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            var worker = SportsIndexBuilder()
            let range = bounds[c]..<bounds[c + 1]
            let programmes = guides[range].reduce(0) { $0 + $1.count }
            worker.reserve(programmes: programmes)
            worker.reserveText(programmes: programmes)
            for g in range {
                if shouldCancel() { return }
                worker.appendGuide(guides[g], stamp: UInt32(g - range.lowerBound + 1), cutoff: cutoff, horizon: horizon)
            }
            results[c] = worker
        }
        guard results.allSatisfy({ $0 != nil }), !shouldCancel() else { return false }
        // Exact capacities: the merged columns are the index's final storage.
        let rows = results.reduce(0) { $0 + $1!.rowStart.count }
        reserveExact(rows: rows,
                     textBytes: results.reduce(0) { $0 + $1!.textBytes.count },
                     words: results.reduce(0) { $0 + $1!.rowWordIDs.count },
                     guideTokens: results.reduce(0) { $0 + $1!.guideTokenIDs.count })
        for c in 0..<chunks { merge(results[c]!) }
        return true
    }

    /// Description is capped to 256 Characters: athlete names and key
    /// details are near the start.
    @inline(__always) static func descriptionPrefix(_ desc: String) -> String {
        var copy = desc
        let fast = copy.withUTF8 { buf -> Int in
            // 0: unchanged, 1: ASCII byte prefix, 2: needs Character count
            if buf.count <= 256 { return 0 }
            return SportsText.isASCII(buf) && memchr(buf.baseAddress!, 0x0D, buf.count) == nil ? 1 : 2
        }
        switch fast {
        case 0: return desc
        case 1: return String(Substring(desc.utf8.prefix(256)))
        default:
            var text = desc
            let cut = text.withUTF8 { SportsUnicode.prefixLength(of: $0, characters: 256) }
            switch cut {
            case .some(nil): return desc
            case .some(let length?): return String(Substring(desc.utf8.prefix(length)))
            case nil: return desc.count > 256 ? String(desc.prefix(256)) : desc
            }
        }
    }

    mutating func appendRow(_ p: EPGProgram, start: Double, end: Double) {
        let descPrefix = Self.descriptionPrefix(p.description)
        let textBegin = textBytes.count
        let titleASCII = Self.appendNormalised(p.title, to: &textBytes)
        let titleRange = textBegin..<textBytes.count
        let descASCII = Self.appendNormalised(descPrefix, to: &textBytes)
        let descRange = titleRange.upperBound..<textBytes.count
        var unusedAcronym: [UInt8] = []
        Self.appendWords(textBytes, titleRange, ascii: titleASCII, tokens: &tokens, into: &rowWordIDs, acronym: &unusedAcronym)
        let titleWordCount = rowWordIDs.count - Int(rowWordStart[rowWordStart.count - 1])
        Self.appendWords(textBytes, descRange, ascii: descASCII, tokens: &tokens, into: &rowWordIDs, acronym: &unusedAcronym)
        var compact: [UInt8] = []
        let compactASCII = Self.appendCompact(textBytes, titleRange, ascii: titleASCII, to: &compact)
        let (titleMask, separator) = textBytes.withUnsafeBufferPointer { b -> (UInt64, UInt64) in
            let title = UnsafeBufferPointer(rebasing: b[titleRange])
            return (SportsText.bigramMask(title), titleASCII ? StreamMatcher.FixtureTerms.separatorSpan(title) : StreamSearchIndex.noSeparator)
        }
        textBytes.append(contentsOf: compact)
        rowStart.append(start)
        rowEnd.append(end)
        rowTitle.append(p.title)
        rowDescription.append(descPrefix)
        rowTextStart.append(UInt32(textBytes.count))
        rowTitleLen.append(UInt32(titleRange.count))
        rowDescLen.append(UInt32(descRange.count))
        rowWordStart.append(UInt32(rowWordIDs.count))
        rowTitleWordCount.append(UInt32(titleWordCount))
        rowFlags.append((titleASCII ? StreamSearchIndex.RowFlag.titleASCII : 0)
            | (descASCII ? StreamSearchIndex.RowFlag.descASCII : 0)
            | (compactASCII ? StreamSearchIndex.RowFlag.compactASCII : 0))
        rowTitleMask.append(titleMask)
        rowCompactMask.append(SportsText.bigramMask(compact))
        rowSeparator.append(separator)
    }

    mutating func addEntry(_ channel: Channel, nameID: UInt32, groupID: UInt32, guideID: UInt32) {
        var flags = groupFlags[Int(groupID)]
        if nameFlags[Int(nameID)] & StreamSearchIndex.NameFlag.radioPrefix != 0 { flags |= StreamSearchIndex.EntryFlag.audio }
        channels.append(channel)
        entryNameAndFlags.append(nameID | flags)
        entryGroup.append(groupID)
        entryGuide.append(guideID)
    }

    /// CSR of `keys`' lists (start offsets + flat ids) into token-major postings.
    static func invert(tokenCount: Int, ownerCount: Int, listStart: (Int) -> Range<Int>, ids: [UInt32]) -> ([UInt32], [UInt32]) {
        var counts = [UInt32](repeating: 0, count: tokenCount + 1)
        for owner in 0..<ownerCount { for p in listStart(owner) { counts[Int(ids[p]) + 1] &+= 1 } }
        for t in 0..<tokenCount { counts[t + 1] &+= counts[t] }
        var cursor = counts
        var postings = [UInt32](repeating: 0, count: Int(counts[tokenCount]))
        for owner in 0..<ownerCount {
            for p in listStart(owner) {
                let t = Int(ids[p])
                postings[Int(cursor[t])] = UInt32(owner)
                cursor[t] &+= 1
            }
        }
        return (counts, postings)
    }
}

extension StreamSearchIndex {
    nonisolated init(builder b: SportsIndexBuilder, programKeyCount: Int) {
        tokens = b.tokens
        groupNames = b.groupNames
        nameTextStart = b.nameTextStart; nameLowerLen = b.nameLowerLen; nameCompactLen = b.nameCompactLen
        nameBytes = b.nameBytes; nameWordStart = b.nameWordStart; nameWordIDs = b.nameWordIDs
        nameFlags = b.nameFlags; nameMask = b.nameMask; nameCompactMask = b.nameCompactMask; nameHeight = b.nameHeight
        nameTokenStart = b.nameTokenStart; nameTokenIDs = b.nameTokenIDs
        channels = b.channels; entryNameAndFlags = b.entryNameAndFlags; entryGroup = b.entryGroup; entryGuide = b.entryGuide
        guideKeys = b.guideKeys; guideRowStart = b.guideRowStart
        guideTokenStart = b.guideTokenStart; guideTokenIDs = b.guideTokenIDs
        rowStart = b.rowStart; rowEnd = b.rowEnd; rowTitle = b.rowTitle; rowDescription = b.rowDescription
        rowTextStart = b.rowTextStart; rowTitleLen = b.rowTitleLen; rowDescLen = b.rowDescLen; textBytes = b.textBytes
        rowWordStart = b.rowWordStart; rowTitleWordCount = b.rowTitleWordCount; rowWordIDs = b.rowWordIDs
        rowFlags = b.rowFlags; rowTitleMask = b.rowTitleMask; rowCompactMask = b.rowCompactMask; rowSeparator = b.rowSeparator
        self.programKeyCount = programKeyCount

        let guideCount = b.guideKeys.count
        // guide → entries (ascending)
        var gStart = [UInt32](repeating: 0, count: guideCount + 1)
        for g in b.entryGuide where g != SportsTokenTable.absent { gStart[Int(g) + 1] &+= 1 }
        for g in 0..<guideCount { gStart[g + 1] &+= gStart[g] }
        var cursor = gStart
        var gEntries = [UInt32](repeating: 0, count: Int(gStart[guideCount]))
        var titleCount = 0
        for (e, g) in b.entryGuide.enumerated() where g != SportsTokenTable.absent {
            gEntries[Int(cursor[Int(g)])] = UInt32(e)
            cursor[Int(g)] &+= 1
            titleCount += Int(b.guideRowStart[Int(g) + 1] - b.guideRowStart[Int(g)])
        }
        guideEntryStart = gStart
        guideEntries = gEntries
        epgTitleCount = titleCount
        if b.rowStart.isEmpty {
            earliestProgramStart = nil
            latestProgramEnd = nil
        } else {
            earliestProgramStart = Date(timeIntervalSinceReferenceDate: b.rowStart.min()!)
            latestProgramEnd = Date(timeIntervalSinceReferenceDate: b.rowEnd.max()!)
        }
        let tokenCount = b.tokens.count
        let nameTokenStart = b.nameTokenStart, entryNames = b.entryNameAndFlags
        // token → entries via each entry's name tokens.
        var entryTokenStart = [UInt32](repeating: 0, count: entryNames.count + 1)
        var entryTokens: [UInt32] = []
        entryTokens.reserveCapacity(entryNames.count * 4)
        for (e, packed) in entryNames.enumerated() {
            let n = Int(packed & EntryFlag.nameMask)
            entryTokens.append(contentsOf: b.nameTokenIDs[Int(nameTokenStart[n])..<Int(nameTokenStart[n + 1])])
            entryTokenStart[e + 1] = UInt32(entryTokens.count)
        }
        let names = SportsIndexBuilder.invert(
            tokenCount: tokenCount, ownerCount: entryNames.count,
            listStart: { Int(entryTokenStart[$0])..<Int(entryTokenStart[$0 + 1]) }, ids: entryTokens)
        namePostingStart = names.0
        namePostings = names.1
        let guideTokenStart = b.guideTokenStart
        let guides = SportsIndexBuilder.invert(
            tokenCount: tokenCount, ownerCount: guideCount,
            listStart: { Int(guideTokenStart[$0])..<Int(guideTokenStart[$0 + 1]) }, ids: b.guideTokenIDs)
        guidePostingStart = guides.0
        guidePostings = guides.1
    }
}

// MARK: - Unicode fast path

/// Exact per-scalar normalisation for Latin, Cyrillic and general
/// punctuation text. Every scalar in these blocks (combining marks and
/// joiners excluded) is its own grapheme with a context-free lowercase
/// mapping, so `normalise(text)` is the concatenation of each scalar's
/// `normalise`, Characters are scalars, and `isLetter`/`isNumber` are
/// per-scalar. The table is computed once from Foundation itself; any other
/// scalar sends the whole text down the original String path.
nonisolated enum SportsUnicode {
    static let limit: UInt32 = 0x2070
    static let allowedFlag: UInt8 = 1, wordFlag: UInt8 = 2, nfcFlag: UInt8 = 4

    struct Table: Sendable {
        let flags: [UInt8]       // by scalar value below `limit`
        let start: [UInt32]      // by scalar value; folded bytes offsets (limit + 1)
        let bytes: [UInt8]
        /// Upper bound of output bytes per input byte.
        let maxExpansion: Int
    }

    static let table: Table = {
        var flags = [UInt8](repeating: 0, count: Int(limit))
        var start = [UInt32](repeating: 0, count: Int(limit) + 1)
        var bytes: [UInt8] = []
        var maxExpansion = 1
        for v in UInt32(0)..<limit {
            start[Int(v)] = UInt32(bytes.count)
            guard v >= 0x80, let scalar = Unicode.Scalar(v), included(v, scalar) else { continue }
            let character = Character(scalar)
            let lone = String(character)
            var f = allowedFlag
            if character.isLetter || character.isNumber { f |= wordFlag }
            if lone.precomposedStringWithCanonicalMapping.utf8.elementsEqual(lone.utf8) { f |= nfcFlag }
            flags[Int(v)] = f
            let folded = Array(StreamMatcher.normaliseString(lone).utf8)
            maxExpansion = max(maxExpansion, (folded.count + lone.utf8.count - 1) / lone.utf8.count)
            bytes.append(contentsOf: folded)
        }
        start[Int(limit)] = UInt32(bytes.count)
        return Table(flags: flags, start: start, bytes: bytes, maxExpansion: maxExpansion)
    }()

    private static func included(_ v: UInt32, _ scalar: Unicode.Scalar) -> Bool {
        let inBlock = (v < 0x300) || (v >= 0x400 && v < 0x530) || (v >= 0x2000 && v < limit)
        guard inBlock, v != 0x200C, v != 0x200D else { return false }
        let p = scalar.properties
        if p.isGraphemeExtend { return false }
        switch p.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .surrogate, .unassigned: return false
        default: return true
        }
    }

    /// Decodes one scalar at `i` of valid UTF-8; returns (value, length).
    @inline(__always) static func decode(_ b: UnsafeBufferPointer<UInt8>, _ i: Int) -> (UInt32, Int) {
        let b0 = UInt32(b[i])
        if b0 < 0x80 { return (b0, 1) }
        if b0 < 0xE0 { return ((b0 & 0x1F) << 6 | UInt32(b[i + 1] & 0x3F), 2) }
        if b0 < 0xF0 { return ((b0 & 0x0F) << 12 | UInt32(b[i + 1] & 0x3F) << 6 | UInt32(b[i + 2] & 0x3F), 3) }
        return ((b0 & 0x07) << 18 | UInt32(b[i + 1] & 0x3F) << 12 | UInt32(b[i + 2] & 0x3F) << 6 | UInt32(b[i + 3] & 0x3F), 4)
    }

    @inline(__always) static func flags(_ v: UInt32, _ t: Table) -> UInt8 { v < limit ? t.flags[Int(v)] : 0 }

    /// True when every scalar is ASCII or in the table.
    static func isSimple(_ b: UnsafeBufferPointer<UInt8>) -> Bool {
        let t = table
        var i = 0
        while i < b.count {
            if b[i] < 0x80 { i &+= 1; continue }
            let (v, len) = decode(b, i)
            guard flags(v, t) & allowedFlag != 0 else { return false }
            i &+= len
        }
        return true
    }

    /// `normalise` of simple text; nil (and `out` untouched) otherwise.
    static func appendNormalised(_ b: UnsafeBufferPointer<UInt8>, to out: inout [UInt8]) -> Bool? {
        let t = table
        guard isSimple(b) else { return nil }
        var ascii = true
        SportsText.appendBytes(b.count * t.maxExpansion, to: &out) { dst in
            var n = 0
            var i = 0
            t.bytes.withUnsafeBufferPointer { folded in
                while i < b.count {
                    let byte = b[i]
                    if byte < 0x80 { dst[n] = (byte &- 65) < 26 ? byte | 0x20 : byte; n &+= 1; i &+= 1; continue }
                    let (v, len) = decode(b, i)
                    for k in Int(t.start[Int(v)])..<Int(t.start[Int(v) + 1]) {
                        let f = folded[k]
                        if f >= 0x80 { ascii = false }
                        dst[n] = f
                        n &+= 1
                    }
                    i &+= len
                }
            }
            return n
        }
        return ascii
    }

    /// For text whose scalars up to the cut are simple: `.some(nil)` when it
    /// has at most `characters` graphemes, else `.some(byteLength)` of the
    /// first `characters` graphemes. nil when a non-table scalar is reached.
    static func prefixLength(of b: UnsafeBufferPointer<UInt8>, characters: Int) -> Int?? {
        let t = table
        var count = 0
        var i = 0
        while i < b.count {
            let byte = b[i]
            var next: Int
            if byte < 0x80 {
                next = byte == 0x0D && i + 1 < b.count && b[i + 1] == 0x0A ? i + 2 : i + 1
            } else {
                let (v, len) = decode(b, i)
                guard flags(v, t) & allowedFlag != 0 else { return nil }
                next = i + len
            }
            // The grapheme after the cut must be a simple base too.
            if count == characters { return .some(i) }
            count += 1
            i = next
        }
        return .some(nil)
    }

    /// `tokenWords(in:)` over simple normalised text: runs of letter/number
    /// scalars of at least two Characters. `body(start, end, characters,
    /// ascii, nfcStable)`. Returns false (emitting nothing) for other text.
    static func forEachWord(_ b: UnsafeBufferPointer<UInt8>,
                            _ body: (Int, Int, Int, Bool, Bool) -> Void) -> Bool {
        guard isSimple(b) else { return false }
        let t = table
        var i = 0
        while i < b.count {
            var (v, len) = b[i] < 0x80 ? (UInt32(b[i]), 1) : decode(b, i)
            guard isWord(v, t) else { i &+= len; continue }
            let start = i
            var characters = 0
            var ascii = true, nfc = true
            while i < b.count {
                (v, len) = b[i] < 0x80 ? (UInt32(b[i]), 1) : decode(b, i)
                guard isWord(v, t) else { break }
                if v >= 0x80 { ascii = false; if t.flags[Int(v)] & nfcFlag == 0 { nfc = false } }
                characters += 1
                i &+= len
            }
            if characters >= 2 { body(start, i, characters, ascii, nfc) }
        }
        return true
    }

    @inline(__always) private static func isWord(_ v: UInt32, _ t: Table) -> Bool {
        v < 0x80 ? SportsText.isAlnum(UInt8(v)) : t.flags[Int(v)] & wordFlag != 0
    }

    /// `compactKey` of simple normalised text; false for other text.
    static func appendCompact(_ b: UnsafeBufferPointer<UInt8>, to out: inout [UInt8]) -> Bool {
        guard isSimple(b) else { return false }
        let t = table
        var i = 0
        while i < b.count {
            let (v, len) = b[i] < 0x80 ? (UInt32(b[i]), 1) : decode(b, i)
            if isWord(v, t) { out.append(contentsOf: UnsafeBufferPointer(rebasing: b[i..<(i + len)])) }
            i &+= len
        }
        return true
    }
}

/// A matched stream for a sport event.
nonisolated struct StreamMatch: Identifiable, Sendable {
    var id: String { channel.preferenceIdentity }
    let channel: Channel
    let score: Double
    let reason: String         // channel group / folder
    let programTitle: String?  // matched EPG program title, if any
    let programDescription: String?
    let programStart: Date?
    let programEnd: Date?
    let isHidden: Bool         // from a user-hidden group (fallback only)
    var relevance: Relevance = .channelHint

    enum Relevance: Int, Sendable {
        case channelHint
        case relatedProgramme
        case eventProgramme
    }
}

/// Only current endpoint-bound observations belong here. Unknown format does
/// not become a measured format merely because a channel name says UHD.
nonisolated struct StreamMatchQuality: Sendable, Equatable {
    enum Availability: Int, Sendable { case failed, unknown, observedAvailable }
    var availability: Availability = .unknown
    var isUnstable = false
    var healthySeconds: Double = 0
    var observedHeight: Int = 0
    var observedFPS: Double = 0
    /// Probed transport bitrate in bits/sec; 0 when unknown.
    var observedBitRate: Int64 = 0
    var observedSeconds: Double = 0
    var bufferingSeconds: Double = 0
    /// Set only by a fresh measurement of moving startup / true broadcast
    /// delay. First-picture, probe-duration and replay-window proxies do not qualify.
    var startupSeconds: Double? = nil
    var liveDelaySeconds: Double? = nil
}

/// High-performance sport event → channel matcher.
/// All methods are nonisolated. Designed for parallel execution.
nonisolated enum StreamMatcher {

    // MARK: - Normalisation

    /// Lowercase and strip diacritics so accented text matches plain ASCII.
    /// e.g. "Atlético" → "atletico", "São Paulo" → "sao paulo"
    static func normaliseString(_ string: String) -> String {
        string.lowercased().folding(options: .diacriticInsensitive, locale: nil)
    }

    private static func normalise(_ string: String) -> String { normaliseString(string) }

    // MARK: - Index building

    /// Interns every name/guide token once, lays channels, names, guides and
    /// programme rows out as parallel columns, and inverts tokens into sorted
    /// `UInt32` posting lists (names → entries, programmes → guides).
    static func buildIndex(
        channels: [Channel],
        programs: [String: [EPGProgram]],
        hiddenGroups: Set<String> = [],
        now: Date = Date(),
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> StreamSearchIndex {
        guard !shouldCancel() else { return .empty }
        let cutoff = now.addingTimeInterval(-3600).timeIntervalSinceReferenceDate
        let horizon = now.addingTimeInterval(48 * 3600).timeIntervalSinceReferenceDate
        let hiddenGroupPaths = hiddenGroups.map(splitGroupPath)

        var builder = SportsIndexBuilder()
        builder.channels.reserveCapacity(channels.count)
        builder.entryNameAndFlags.reserveCapacity(channels.count)
        builder.entryGroup.reserveCapacity(channels.count)
        builder.entryGuide.reserveCapacity(channels.count)
        for channel in channels {
            guard !shouldCancel() else { return .empty }
            let group = builder.groupID(channel.group, hiddenGroups: hiddenGroups, hiddenGroupPaths: hiddenGroupPaths)
            let name = builder.nameID(channel.name)
            let guide = builder.guideID(for: channel, programs: programs)
            builder.addEntry(channel, nameID: name, groupID: group, guideID: guide)
        }
        guard !shouldCancel(),
              builder.layOutGuides(cutoff: cutoff, horizon: horizon, shouldCancel: shouldCancel),
              !shouldCancel() else { return .empty }
        return StreamSearchIndex(builder: builder, programKeyCount: programs.count)
    }

    static func guideKey(for channel: Channel) -> String? {
        guard let guideID = channel.epgChannelID else { return nil }
        guard let sourceID = channel.sourceChannelIdentity?.sourceID else { return guideID }
        return sourceID.uuidString.lowercased() + "|" + guideID
    }

    static func isGroupHidden(
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

    /// Best programme evidence for one guide: value, relevance and the row
    /// that supplied it (-1 when none).
    private struct GuideBest {
        var value: Double = 0
        var relevance: StreamMatch.Relevance = .channelHint
        var row: Int32 = -1

        @inline(__always) mutating func record(_ v: Double, row r: Int, relevance newRelevance: StreamMatch.Relevance) {
            if newRelevance.rawValue > relevance.rawValue || (newRelevance == relevance && v > value) {
                value = v
                relevance = newRelevance
                row = Int32(r)
            }
        }
    }

    static func findMatches(
        for event: SportEvent,
        index: StreamSearchIndex,
        now: Date = Date(),
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [StreamMatch] {
        guard !shouldCancel() else { return [] }
        let rawQueries = buildQueries(for: event).sorted { $0.score > $1.score }
        guard !rawQueries.isEmpty else { return [] }
        guard index.entryCount > 0 else { return [] }

        let broadcastLower: [PText] = event.broadcast.compactMap { b -> PText? in
            let l = normalise(b)
            return l.count >= 3 ? PText(l, tokens: nil) : nil
        }

        // Sport-context keywords used to validate single-token EPG matches.
        // e.g. "giants" alone in an EPG title is ambiguous, but "giants" in
        // a title that also contains "mlb" or "baseball" is a strong signal.
        let contextKeywords = (sportKeywords(for: event) + competitionKeywords(for: event)).map(normalise)

        // Tournament sports get a much wider EPG window because:
        // - EPG entries often span the whole day ("ATP Tennis 10am-8pm")
        // - Individual match times within the block are approximate
        let isTournament = tournamentSports.contains(event.sport)
        let isEventLive = event.status.isLive
        let allowCurrentlyLiveEPG = isEventLive || (!event.status.isFinished && event.startDate <= now)
        let eventStart = event.startDate.timeIntervalSinceReferenceDate
        let nowRef = now.timeIntervalSinceReferenceDate
        let windowStart = event.startDate.addingTimeInterval(isTournament ? -6 * 3600 : -1800).timeIntervalSinceReferenceDate
        let windowEnd = event.startDate.addingTimeInterval(isTournament ? 12 * 3600 : 7200).timeIntervalSinceReferenceDate
        let fixture = FixtureTerms(event: event)
        let plan = EventPlan(queries: rawQueries, contextKeywords: contextKeywords, fixture: fixture, tokens: index.tokens)
        defer { withExtendedLifetime(plan) {} }

        guard let candidates = candidateEntries(for: plan, in: index, shouldCancel: shouldCancel),
              !shouldCancel() else { return [] }

        var scorer = EventScorer(index: index, plan: plan, broadcast: broadcastLower, fixture: fixture,
                                 eventStart: eventStart, now: nowRef, windowStart: windowStart, windowEnd: windowEnd,
                                 allowCurrentlyLiveEPG: allowCurrentlyLiveEPG, isTournament: isTournament)
        var matches: [StreamMatch] = []
        var heights: [Int] = []
        matches.reserveCapacity(32)
        heights.reserveCapacity(32)
        var anyVisible = false

        // Iterate candidate entries in ascending order straight off the bitset.
        for (wordIndex, word) in candidates.enumerated() where word != 0 {
            var bits = word
            while bits != 0 {
                let e = wordIndex << 6 | bits.trailingZeroBitCount
                bits &= bits &- 1
                guard !shouldCancel() else { return [] }
                guard let best = scorer.score(entry: e, shouldCancel: shouldCancel) else { return [] }
                guard !shouldCancel() else { return [] }
                guard best.value >= minimumScore else { continue }
                let packed = index.entryNameAndFlags[e]
                let hidden = packed & StreamSearchIndex.EntryFlag.hidden != 0
                anyVisible = anyVisible || !hidden
                let row = Int(best.row)
                let hasRow = row >= 0
                matches.append(StreamMatch(
                    channel: index.channels[e],
                    score: best.value,
                    reason: index.groupNames[Int(index.entryGroup[e])],
                    programTitle: hasRow ? index.rowTitle[row] : nil,
                    programDescription: hasRow ? index.rowDescription[row] : nil,
                    programStart: hasRow ? Date(timeIntervalSinceReferenceDate: index.rowStart[row]) : nil,
                    programEnd: hasRow ? Date(timeIntervalSinceReferenceDate: index.rowEnd[row]) : nil,
                    isHidden: hidden,
                    relevance: best.relevance
                ))
                heights.append(Int(index.nameHeight[Int(packed & StreamSearchIndex.EntryFlag.nameMask)]))
            }
        }

        // Prefer non-hidden matches. Only surface hidden-group matches when
        // nothing else is available.
        if anyVisible {
            var keptMatches: [StreamMatch] = []
            var keptHeights: [Int] = []
            keptMatches.reserveCapacity(matches.count)
            keptHeights.reserveCapacity(matches.count)
            for (i, match) in matches.enumerated() where !match.isHidden {
                keptMatches.append(match)
                keptHeights.append(heights[i])
            }
            matches = keptMatches
            heights = keptHeights
        }
        return rank(matches, advertisedHeights: heights, qualityByChannel: [:], favoriteChannelIDs: [],
                    channelScores: [:], groupScores: [:])
    }

    /// Relevance is categorical so a known broadcaster or favorite cannot
    /// outrank the programme that actually names this event. Within that
    /// evidence tier, reliability and sports motion precede useful resolution.
    static func rankedMatches(
        _ matches: [StreamMatch],
        qualityByChannel: [String: StreamMatchQuality] = [:],
        favoriteChannelIDs: Set<String> = [],
        channelScores: [String: Double] = [:],
        groupScores: [String: Double] = [:]
    ) -> [StreamMatch] {
        rank(matches, advertisedHeights: nil, qualityByChannel: qualityByChannel, favoriteChannelIDs: favoriteChannelIDs,
             channelScores: channelScores, groupScores: groupScores)
    }

    private static func rank(
        _ matches: [StreamMatch],
        advertisedHeights: [Int]?,
        qualityByChannel: [String: StreamMatchQuality],
        favoriteChannelIDs: Set<String>,
        channelScores: [String: Double],
        groupScores: [String: Double]
    ) -> [StreamMatch] {
        // Compute identity, normalization and quality once per result into
        // concrete key columns, then stably sort a permutation; the
        // comparator never touches the matches themselves.
        var keys: [RankKey] = []
        keys.reserveCapacity(matches.count)
        for i in matches.indices {
            let match = matches[i]
            let key = match.channel.preferenceIdentity
            let quality = qualityByChannel.isEmpty ? StreamMatchQuality() : qualityByChannel[key] ?? StreamMatchQuality()
            keys.append(RankKey(
                relevance: match.relevance.rawValue, availability: quality.availability.rawValue,
                unstable: quality.isUnstable, healthy: healthyClass(quality.healthySeconds),
                stallRatio: quality.observedSeconds >= 180 && quality.observedSeconds.isFinite && quality.bufferingSeconds >= 0 && quality.bufferingSeconds.isFinite
                    ? min(1, quality.bufferingSeconds / quality.observedSeconds) : nil,
                startup: measuredSeconds(quality.startupSeconds), delay: measuredSeconds(quality.liveDelaySeconds),
                motion: motionClass(quality.observedFPS),
                height: quality.observedHeight > 0 ? quality.observedHeight : (advertisedHeights?[i] ?? advertisedHeight(match.channel)),
                bitrate: bitrateClass(quality.observedBitRate),
                preference: preferenceBoost(key: key, group: match.channel.group, favorites: favoriteChannelIDs,
                                            channels: channelScores, groups: groupScores),
                score: match.score, name: match.channel.name.lowercased(), key: key))
        }
        var order = Array(0..<matches.count)
        keys.withUnsafeBufferPointer { k in
            order.sort { RankKey.precedes(k[$0], k[$1]) }
        }
        return order.map { matches[$0] }
    }

    private struct RankKey {
        let relevance: Int
        let availability: Int
        let unstable: Bool
        let healthy: Int
        let stallRatio: Double?
        let startup: Double?
        let delay: Double?
        let motion: Int
        let height: Int
        let bitrate: Int
        let preference: Double
        let score: Double
        let name: String
        let key: String

        @inline(__always) static func precedes(_ lhs: RankKey, _ rhs: RankKey) -> Bool {
            if lhs.relevance != rhs.relevance { return lhs.relevance > rhs.relevance }
            if lhs.availability != rhs.availability { return lhs.availability > rhs.availability }
            if lhs.unstable != rhs.unstable { return !lhs.unstable }
            if lhs.healthy != rhs.healthy { return lhs.healthy > rhs.healthy }
            if lhs.stallRatio != rhs.stallRatio {
                if let l = lhs.stallRatio, let r = rhs.stallRatio { return l < r }
                return lhs.stallRatio != nil
            }
            if lhs.delay != rhs.delay {
                if let l = lhs.delay, let r = rhs.delay { return l < r }
                return lhs.delay != nil
            }
            if lhs.startup != rhs.startup {
                if let l = lhs.startup, let r = rhs.startup { return l < r }
                return lhs.startup != nil
            }
            if lhs.motion != rhs.motion { return lhs.motion > rhs.motion }
            if lhs.height != rhs.height { return lhs.height > rhs.height }
            if lhs.bitrate != rhs.bitrate { return lhs.bitrate > rhs.bitrate }
            if lhs.preference != rhs.preference { return lhs.preference > rhs.preference }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.key < rhs.key
        }
    }

    /// Broadcaster-only hints ("a FOX affiliate") can number in the
    /// hundreds for a national event. Keep every programme match, and only
    /// the best-ranked hints, fewer when real programme evidence exists.
    static func presentable(_ ranked: [StreamMatch], hintLimit: Int = 12, hintLimitWithoutEvidence: Int = 24) -> [StreamMatch] {
        let hasEvidence = ranked.contains { $0.relevance != .channelHint }
        let limit = hasEvidence ? hintLimit : hintLimitWithoutEvidence
        var hints = 0
        return ranked.filter { match in
            guard match.relevance == .channelHint else { return true }
            hints += 1
            return hints <= limit
        }
    }

    private static func measuredSeconds(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func healthyClass(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int(min(3, max(0, seconds) / 30))
    }

    private static func motionClass(_ fps: Double) -> Int {
        guard fps.isFinite else { return 0 }
        if fps >= 45 { return 2 }
        if fps >= 23 { return 1 }
        return 0
    }

    /// Coarse 2 Mb/s steps so probe noise between near-identical feeds of the
    /// same resolution does not reorder them; unknown sorts below measured.
    private static func bitrateClass(_ bitsPerSecond: Int64) -> Int {
        guard bitsPerSecond > 0 else { return 0 }
        return 1 + Int(min(bitsPerSecond, 40_000_000) / 2_000_000)
    }

    /// Used only as an advertised preference when no current measured height
    /// exists. The row's badge retains its observed/unknown provenance.
    /// ASCII names are scanned in place; others use the Unicode tokenizer.
    static func advertisedHeight(_ channel: Channel) -> Int {
        var name = channel.name
        let fast = name.withUTF8 { buf -> Int? in
            guard SportsText.isASCII(buf) else { return nil }
            var classes: UInt8 = 0
            var i = 0
            let n = buf.count
            while i < n {
                guard SportsText.isAlnum(buf[i]) else { i &+= 1; continue }
                let start = i
                while i < n, SportsText.isAlnum(buf[i]) { i &+= 1 }
                classes |= heightClass(UnsafeBufferPointer(rebasing: buf[start..<i]))
            }
            if classes & 8 != 0 { return 2160 }
            if classes & 4 != 0 { return 1080 }
            if classes & 2 != 0 { return 720 }
            if classes & 1 != 0 { return 576 }
            return 0
        }
        if let fast { return fast }
        let words = Set(tokenWords(in: normalise(channel.name)))
        if !words.isDisjoint(with: ["4k", "uhd", "2160p"]) { return 2160 }
        if !words.isDisjoint(with: ["fhd", "1080p", "1080"]) { return 1080 }
        if !words.isDisjoint(with: ["hd", "720p", "720"]) { return 720 }
        if words.contains("sd") { return 576 }
        return 0
    }

    /// Case-insensitive ASCII word → resolution bit (8 UHD, 4 FHD, 2 HD, 1 SD).
    @inline(__always) private static func heightClass(_ w: UnsafeBufferPointer<UInt8>) -> UInt8 {
        @inline(__always) func lower(_ i: Int) -> UInt8 { w[i] | (SportsText.isLetter(w[i]) ? 0x20 : 0) }
        @inline(__always) func eq(_ s: StaticString) -> Bool {
            guard s.utf8CodeUnitCount == w.count else { return false }
            let p = s.utf8Start
            for i in 0..<w.count where lower(i) != p[i] { return false }
            return true
        }
        switch w.count {
        case 2: return eq("4k") ? 8 : eq("hd") ? 2 : eq("sd") ? 1 : 0
        case 3: return eq("uhd") ? 8 : eq("fhd") ? 4 : eq("720") ? 2 : 0
        case 4: return eq("720p") ? 2 : eq("1080") ? 4 : 0
        case 5: return eq("2160p") ? 8 : eq("1080p") ? 4 : 0
        default: return 0
        }
    }

    private static func preferenceBoost(key: String, group: String, favorites: Set<String>,
                                        channels: [String: Double], groups: [String: Double]) -> Double {
        (favorites.contains(key) ? 0.08 : 0)
            + min(0.08, max(0, channels[key] ?? 0) * 0.08)
            + min(0.05, max(0, groups[group] ?? 0) * 0.05)
    }

    // MARK: - Candidate generation

    /// Union over queries of entries whose indexed token set (name tokens ∪
    /// guide tokens) contains at least `threshold` of the query's terms.
    /// Each query's terms get one bit; name postings set bits per entry and
    /// guide postings per guide, so an entry's hits are
    /// `popcount(nameBits[e] | guideBits[guide(e)])`.
    private static func candidateEntries(
        for plan: EventPlan,
        in index: StreamSearchIndex,
        shouldCancel: @Sendable () -> Bool
    ) -> [UInt64]? {
        let entryCount = index.entryCount
        let guideCount = index.guideKeys.count
        var candidates = [UInt64](repeating: 0, count: (entryCount + 63) >> 6)
        var nameBits = [UInt64](repeating: 0, count: entryCount)
        var guideBits = [UInt64](repeating: 0, count: guideCount)
        var touchedEntries: [UInt32] = []
        var touchedGuides: [UInt32] = []
        var examined = 0
        var seenQueries = Set<String>()
        for qi in 0..<plan.queryCount {
            guard !shouldCancel() else { return nil }
            let terms = plan.candidateTerms[qi]
            guard !terms.isEmpty else { continue }
            // Exact evidence needs all terms. A fuzzy repair may miss one
            // term, but never lets the generic league keyword alone admit
            // every NFL channel into a two-team event's expensive scoring.
            let threshold = plan.candidateFuzzy[qi] && terms.count > 1 ? terms.count - 1 : terms.count
            let queryKey = String(threshold) + "|" + plan.candidateKeys[qi]
            guard seenQueries.insert(queryKey).inserted else { continue }
            if terms.count > 64 {
                guard countLargeQuery(terms, threshold: threshold, index: index, into: &candidates,
                                      examined: &examined, shouldCancel: shouldCancel) else { return nil }
                continue
            }
            for (bit, term) in terms.enumerated() where term != SportsTokenTable.absent {
                let flag: UInt64 = 1 << UInt64(bit)
                let t = Int(term)
                for p in Int(index.namePostingStart[t])..<Int(index.namePostingStart[t + 1]) {
                    if examined & 63 == 0, shouldCancel() { return nil }
                    examined &+= 1
                    let e = Int(index.namePostings[p])
                    if nameBits[e] == 0 { touchedEntries.append(UInt32(e)) }
                    nameBits[e] |= flag
                }
                for p in Int(index.guidePostingStart[t])..<Int(index.guidePostingStart[t + 1]) {
                    if examined & 63 == 0, shouldCancel() { return nil }
                    examined &+= 1
                    let g = Int(index.guidePostings[p])
                    if guideBits[g] == 0 { touchedGuides.append(UInt32(g)) }
                    guideBits[g] |= flag
                }
            }
            for e in touchedEntries {
                let g = index.entryGuide[Int(e)]
                let bits = nameBits[Int(e)] | (g == SportsTokenTable.absent ? 0 : guideBits[Int(g)])
                if bits.nonzeroBitCount >= threshold { candidates[Int(e) >> 6] |= 1 << UInt64(e & 63) }
            }
            for g in touchedGuides {
                let guideFlags = guideBits[Int(g)]
                for q in Int(index.guideEntryStart[Int(g)])..<Int(index.guideEntryStart[Int(g) + 1]) {
                    let e = Int(index.guideEntries[q])
                    if (nameBits[e] | guideFlags).nonzeroBitCount >= threshold { candidates[e >> 6] |= 1 << UInt64(e & 63) }
                }
            }
            for e in touchedEntries { nameBits[Int(e)] = 0 }
            for g in touchedGuides { guideBits[Int(g)] = 0 }
            touchedEntries.removeAll(keepingCapacity: true)
            touchedGuides.removeAll(keepingCapacity: true)
        }
        guard !shouldCancel() else { return nil }
        // A repeated local network can occupy hundreds of entries. A fixed
        // candidate cap excluded exact UHD event matches before scoring them.
        // Score every plausible inverted-index hit; shared guide scores reuse.
        return candidates
    }

    /// Exact fallback for a query with more than 64 distinct terms.
    private static func countLargeQuery(_ terms: [UInt32], threshold: Int, index: StreamSearchIndex,
                                        into candidates: inout [UInt64], examined: inout Int,
                                        shouldCancel: @Sendable () -> Bool) -> Bool {
        var touched = Set<Int>()
        for term in terms where term != SportsTokenTable.absent {
            let t = Int(term)
            for p in Int(index.namePostingStart[t])..<Int(index.namePostingStart[t + 1]) {
                if examined & 63 == 0, shouldCancel() { return false }
                examined &+= 1
                touched.insert(Int(index.namePostings[p]))
            }
            for p in Int(index.guidePostingStart[t])..<Int(index.guidePostingStart[t + 1]) {
                let g = Int(index.guidePostings[p])
                for q in Int(index.guideEntryStart[g])..<Int(index.guideEntryStart[g + 1]) { touched.insert(Int(index.guideEntries[q])) }
            }
        }
        for e in touched {
            let n = index.nameID(ofEntry: e)
            let nameTokens = index.nameTokenIDs[Int(index.nameTokenStart[n])..<Int(index.nameTokenStart[n + 1])]
            let g = index.entryGuide[e]
            let guideTokens = g == SportsTokenTable.absent ? [][...]
                : index.guideTokenIDs[Int(index.guideTokenStart[Int(g)])..<Int(index.guideTokenStart[Int(g) + 1])]
            var hits = 0
            for term in terms where term != SportsTokenTable.absent {
                if nameTokens.contains(term) || guideTokens.contains(term) { hits += 1 }
            }
            if hits >= threshold { candidates[e >> 6] |= 1 << UInt64(e & 63) }
        }
        return true
    }

    // MARK: - Prepared query text

    /// A query string prepared once per event: UTF-8 bytes, bigram masks,
    /// Character count and interned ID. `safe` marks needles whose byte
    /// search is exactly equivalent to `String` search on ASCII haystacks.
    struct PText {
        let string: String
        let bytes: [UInt8]
        let isASCII: Bool
        let safe: Bool
        let charCount: Int
        let mask: UInt64
        let wideMask: SportsText.Mask256
        let id: UInt32

        init(_ string: String, tokens: SportsTokenTable?) {
            self.string = string
            bytes = Array(string.utf8)
            isASCII = bytes.allSatisfy { $0 < 0x80 }
            safe = isASCII && !bytes.isEmpty && !bytes.contains { $0 == 0x3B || $0 == 0x60 || $0 == 0x0D || $0 == 0x0A }
            charCount = isASCII ? bytes.count : string.count
            mask = SportsText.bigramMask(bytes)
            wideMask = bytes.withUnsafeBufferPointer { SportsText.Mask256($0) }
            id = tokens?.lookup(string) ?? SportsTokenTable.absent
        }
    }

    /// Trivially copyable SoA view of a set of distinct needles.
    struct NeedleView {
        static let asciiFlag: UInt8 = 1, safeFlag: UInt8 = 2
        let bytes: UnsafeBufferPointer<UInt8>
        let start: UnsafeBufferPointer<Int32>
        let mask: UnsafeBufferPointer<UInt64>
        let wide: UnsafeBufferPointer<SportsText.Mask256>
        let charCount: UnsafeBufferPointer<Int32>
        let id: UnsafeBufferPointer<UInt32>
        let flags: UnsafeBufferPointer<UInt8>
        var count: Int { mask.count }

        @inline(__always) func needle(_ s: Int) -> UnsafeBufferPointer<UInt8> {
            UnsafeBufferPointer(rebasing: bytes[Int(start[s])..<Int(start[s + 1])])
        }
        @inline(__always) func isASCII(_ s: Int) -> Bool { flags[s] & Self.asciiFlag != 0 }
        @inline(__always) func isSafe(_ s: Int) -> Bool { flags[s] & Self.safeFlag != 0 }
    }

    /// Per-event plan: every query's tokens, fuzzy terms, context keywords
    /// and fixture names deduplicated into needle tables, and per-query
    /// score/target/slot columns, all in owned flat memory so the scoring
    /// loops never retain or copy query values.
    final class EventPlan {
        static let both: UInt8 = 0, epgOnly: UInt8 = 1, channelOnly: UInt8 = 2

        let tokens: NeedleView
        let fuzzy: NeedleView
        let keywords: NeedleView
        let home: NeedleView
        let away: NeedleView
        let tokenStrings: [String]
        let fuzzyStrings: [String]
        let queryCount: Int
        let queryScore: UnsafeBufferPointer<Double>
        let queryTarget: UnsafeBufferPointer<UInt8>
        /// allowsFuzzy && score >= 100
        let queryFuzzy: UnsafeBufferPointer<Bool>
        let querySingleFuzzyOK: UnsafeBufferPointer<Bool>
        let tokenStart: UnsafeBufferPointer<Int32>
        let tokenSlots: UnsafeBufferPointer<Int32>
        let fuzzyStart: UnsafeBufferPointer<Int32>
        let fuzzySlots: UnsafeBufferPointer<Int32>
        // Candidate generation (per query)
        let candidateTerms: [[UInt32]]
        let candidateKeys: [String]
        let candidateFuzzy: [Bool]
        private var owned: [UnsafeMutableRawPointer] = []

        init(queries: [SearchQuery], contextKeywords: [String], fixture: FixtureTerms?, tokens table: SportsTokenTable) {
            var tokenTexts: [PText] = [], tokenSlotOf: [[UInt8]: Int32] = [:]
            var fuzzyTexts: [PText] = [], fuzzySlotOf: [[UInt8]: Int32] = [:]
            var scores: [Double] = [], targets: [UInt8] = [], fuzzyOK: [Bool] = [], single: [Bool] = []
            var tStart: [Int32] = [0], tSlots: [Int32] = [], fStart: [Int32] = [0], fSlots: [Int32] = []
            var cTerms: [[UInt32]] = [], cKeys: [String] = [], cFuzzy: [Bool] = []
            func slot(_ s: String, _ texts: inout [PText], _ map: inout [[UInt8]: Int32]) -> Int32 {
                let bytes = Array(s.utf8)
                if let existing = map[bytes] { return existing }
                let id = Int32(texts.count)
                texts.append(PText(s, tokens: table))
                map[bytes] = id
                return id
            }
            for q in queries {
                scores.append(q.score)
                targets.append(q.target == .both ? Self.both : q.target == .epgOnly ? Self.epgOnly : Self.channelOnly)
                fuzzyOK.append(q.allowsFuzzy && q.score >= 100)
                if q.fuzzyTerms.count == 1, let term = q.fuzzyTerms.first {
                    single.append(term.count >= 6 && q.score >= 110
                        && !StreamMatcher.ambiguousTeamNames.contains(term) && !StreamMatcher.ambiguousCityNames.contains(term))
                } else {
                    single.append(true)
                }
                for t in q.tokens { tSlots.append(slot(t, &tokenTexts, &tokenSlotOf)) }
                tStart.append(Int32(tSlots.count))
                for t in q.fuzzyTerms { fSlots.append(slot(t, &fuzzyTexts, &fuzzySlotOf)) }
                fStart.append(Int32(fSlots.count))
                let terms = Set(q.fuzzyTerms).filter { $0.count >= 2 }.sorted()
                cTerms.append(terms.map { table.lookup($0) ?? SportsTokenTable.absent })
                cKeys.append(terms.joined(separator: "|"))
                cFuzzy.append(q.allowsFuzzy && q.score >= 100)
            }
            queryCount = queries.count
            tokenStrings = tokenTexts.map(\.string)
            fuzzyStrings = fuzzyTexts.map(\.string)
            candidateTerms = cTerms
            candidateKeys = cKeys
            candidateFuzzy = cFuzzy
            var owned: [UnsafeMutableRawPointer] = []
            func copy<T>(_ values: [T]) -> UnsafeBufferPointer<T> {
                let p = UnsafeMutablePointer<T>.allocate(capacity: max(1, values.count))
                p.initialize(from: values, count: values.count)
                owned.append(UnsafeMutableRawPointer(p))
                return UnsafeBufferPointer(start: p, count: values.count)
            }
            func view(_ texts: [PText]) -> NeedleView {
                var bytes: [UInt8] = [], start: [Int32] = [0]
                for t in texts { bytes.append(contentsOf: t.bytes); start.append(Int32(bytes.count)) }
                return NeedleView(bytes: copy(bytes), start: copy(start), mask: copy(texts.map(\.mask)),
                                  wide: copy(texts.map(\.wideMask)), charCount: copy(texts.map { Int32(clamping: $0.charCount) }),
                                  id: copy(texts.map(\.id)),
                                  flags: copy(texts.map { ($0.isASCII ? NeedleView.asciiFlag : 0) | ($0.safe ? NeedleView.safeFlag : 0) }))
            }
            tokens = view(tokenTexts)
            fuzzy = view(fuzzyTexts)
            keywords = view(contextKeywords.map { PText($0, tokens: nil) })
            home = view((fixture?.home ?? []).map { PText($0, tokens: nil) })
            away = view((fixture?.away ?? []).map { PText($0, tokens: nil) })
            queryScore = copy(scores)
            queryTarget = copy(targets)
            queryFuzzy = copy(fuzzyOK)
            querySingleFuzzyOK = copy(single)
            tokenStart = copy(tStart)
            tokenSlots = copy(tSlots)
            fuzzyStart = copy(fStart)
            fuzzySlots = copy(fSlots)
            self.owned = owned
        }

        deinit { for p in owned { p.deallocate() } }
    }

    // MARK: - Exact byte searches with String-semantics fallbacks

    /// `String.contains` for a safe ASCII needle. Mixed haystacks report
    /// `.unknown` when a byte hit borders non-ASCII (grapheme ambiguity).
    @inline(__always)
    static func containsTri(_ h: UnsafeBufferPointer<UInt8>, ascii: Bool, mask: UInt64,
                            _ n: UnsafeBufferPointer<UInt8>, needleMask: UInt64, safe: Bool) -> SportsText.Tri {
        guard safe else { return .unknown }
        if needleMask & ~mask != 0 { return .no }
        guard let i = SportsText.find(h, from: 0, n) else { return .no }
        if !ascii, (i > 0 && h[i - 1] >= 0x80) || (i + n.count < h.count && h[i + n.count] >= 0x80) { return .unknown }
        return .yes
    }

    /// `wordBoundaryMatch(_:in:)` (Foundation search, Character letters,
    /// resuming after each hit) for a safe ASCII needle.
    @inline(__always)
    static func wordBoundaryTri(_ h: UnsafeBufferPointer<UInt8>, ascii: Bool, mask: UInt64,
                                _ n: UnsafeBufferPointer<UInt8>, needleMask: UInt64, safe: Bool) -> SportsText.Tri {
        guard safe else { return .unknown }
        if needleMask & ~mask != 0 { return .no }
        let len = n.count, hLen = h.count
        var pos = 0
        while let i = SportsText.find(h, from: pos, n) {
            let after = i + len
            if !ascii, (i > 0 && h[i - 1] >= 0x80) || (i > 1 && h[i - 2] >= 0x80)
                || (after < hLen && h[after] >= 0x80) || (after + 1 < hLen && h[after + 1] >= 0x80) {
                return .unknown
            }
            let beforeOK = i == 0 || !SportsText.isLetter(h[i - 1])
            let afterOK = after >= hLen || !SportsText.isLetter(h[after])
            if beforeOK && afterOK { return .yes }
            pos = after
        }
        return .no
    }

    @inline(__always)
    static func containsTri(_ h: UnsafeBufferPointer<UInt8>, ascii: Bool, mask: UInt64, _ n: PText) -> SportsText.Tri {
        n.bytes.withUnsafeBufferPointer { containsTri(h, ascii: ascii, mask: mask, $0, needleMask: n.mask, safe: n.safe) }
    }

    @inline(__always) static func stringContains(_ text: String, _ needle: String) -> Bool { text.contains(needle) }

    /// One needle of the byte-exact `allBytesMatch` (raw UTF-8, ASCII-letter
    /// boundaries for needles of at most four bytes, one-byte stepping).
    @inline(__always)
    static func bytesMatch(_ nb: UnsafeBufferPointer<UInt8>, in h: UnsafeBufferPointer<UInt8>, mayContain: Bool) -> Bool {
        let hLen = h.count
        let nLen = nb.count
        guard nLen <= hLen, mayContain else { return false }
        guard nLen > 0 else { return emptyNeedleBoundary(h) }
        if nLen > 4 { return SportsText.find(h, from: 0, nb) != nil }
        var pos = 0
        while let i = SportsText.find(h, from: pos, nb) {
            let beforeOK = i == 0 || !SportsText.isLetter(h[i - 1])
            let afterIdx = i + nLen
            let afterOK = afterIdx >= hLen || !SportsText.isLetter(h[afterIdx])
            if beforeOK && afterOK { return true }
            pos = i + 1
        }
        return false
    }

    /// `_wordBoundaryFind` with a zero-length needle.
    private static func emptyNeedleBoundary(_ h: UnsafeBufferPointer<UInt8>) -> Bool {
        guard h.baseAddress != nil else { return false }
        var i = 0
        while i <= h.count {
            let beforeOK = i == 0 || !SportsText.isLetter(h[i - 1])
            let afterOK = i >= h.count || !SportsText.isLetter(h[i])
            if beforeOK && afterOK { return true }
            i += 1
        }
        return false
    }

    @inline(__always)
    static func containsBytes(_ needle: UnsafeBufferPointer<UInt8>, in h: UnsafeBufferPointer<UInt8>) -> Bool {
        guard needle.count > 0 && needle.count <= h.count else { return false }
        return SportsText.find(h, from: 0, needle) != nil
    }

    /// Per-row lazily evaluated needle tests (memoised in slot bitsets) and
    /// the description's 256-bit bigram mask.
    struct RowProbe {
        let title: UnsafeBufferPointer<UInt8>
        let desc: UnsafeBufferPointer<UInt8>
        let titleMask: UInt64
        let tokens: NeedleView
        let keywords: NeedleView
        let slots: UnsafeBufferPointer<Int32>
        var descMask = SportsText.Mask256()
        var descMaskReady = false
        var titleKnown = SportsText.SlotBits(), titleFound = SportsText.SlotBits()
        var descKnown = SportsText.SlotBits(), descFound = SportsText.SlotBits()
        /// Fuzzy-term presence in the title words/compact and description words/compact.
        var titleTerms = SportsText.TermCache(), descTerms = SportsText.TermCache()
        var sportContext: Int8 = -1

        init(title: UnsafeBufferPointer<UInt8>, desc: UnsafeBufferPointer<UInt8>, titleMask: UInt64, plan: EventPlan) {
            self.title = title
            self.desc = desc
            self.titleMask = titleMask
            tokens = plan.tokens
            keywords = plan.keywords
            slots = plan.tokenSlots
        }

        @inline(__always) mutating func wide() -> SportsText.Mask256 {
            if !descMaskReady { descMask = SportsText.Mask256(desc); descMaskReady = true }
            return descMask
        }

        @inline(__always) mutating func titleMatches(_ range: Range<Int>) -> Bool {
            for i in range {
                let s = Int(slots[i])
                if titleKnown.has(s) { if !titleFound.has(s) { return false }; continue }
                let hit = StreamMatcher.bytesMatch(tokens.needle(s), in: title, mayContain: tokens.mask[s] & ~titleMask == 0)
                if s < 128 { titleKnown.set(s); if hit { titleFound.set(s) } }
                if !hit { return false }
            }
            return true
        }

        @inline(__always) mutating func descMatches(_ range: Range<Int>) -> Bool {
            for i in range {
                let s = Int(slots[i])
                if descKnown.has(s) { if !descFound.has(s) { return false }; continue }
                let hit = StreamMatcher.bytesMatch(tokens.needle(s), in: desc, mayContain: wide().covers(tokens.wide[s]))
                if s < 128 { descKnown.set(s); if hit { descFound.set(s) } }
                if !hit { return false }
            }
            return true
        }

        @inline(__always) mutating func hasSportContext() -> Bool {
            if sportContext < 0 {
                var found = false
                for s in 0..<keywords.count {
                    let n = keywords.needle(s)
                    if keywords.mask[s] & ~titleMask == 0, StreamMatcher.containsBytes(n, in: title) { found = true; break }
                    if !desc.isEmpty, wide().covers(keywords.wide[s]), StreamMatcher.containsBytes(n, in: desc) { found = true; break }
                }
                sportContext = found ? 1 : 0
            }
            return sportContext == 1
        }
    }

    // MARK: - Per-event scorer

    /// Scores candidate entries for one event. Programme evidence is computed
    /// once per guide and channel-name evidence once per unique name, in flat
    /// per-call arrays indexed by guide / name ID.
    private struct EventScorer {
        let index: StreamSearchIndex
        let plan: EventPlan
        let broadcast: [PText]
        let fixture: FixtureTerms?
        let fixtureSafe: Bool
        let eventStart: Double
        let now: Double
        let windowStart: Double
        let windowEnd: Double
        let allowCurrentlyLiveEPG: Bool
        let isTournament: Bool

        var guideDone: [UInt64]
        var guideBest: [GuideBest]
        /// Two slots per name (outside/inside a sports group); NaN = unknown.
        var nameValue: [Double]
        /// Per name: 0 unknown, 1 no broadcaster, 2 broadcaster in name.
        var nameBroadcast: [UInt8]

        init(index: StreamSearchIndex, plan: EventPlan, broadcast: [PText], fixture: FixtureTerms?,
             eventStart: Double, now: Double, windowStart: Double, windowEnd: Double,
             allowCurrentlyLiveEPG: Bool, isTournament: Bool) {
            self.index = index
            self.plan = plan
            self.broadcast = broadcast
            self.fixture = fixture
            fixtureSafe = (0..<plan.home.count).allSatisfy(plan.home.isSafe) && (0..<plan.away.count).allSatisfy(plan.away.isSafe)
            self.eventStart = eventStart
            self.now = now
            self.windowStart = windowStart
            self.windowEnd = windowEnd
            self.allowCurrentlyLiveEPG = allowCurrentlyLiveEPG
            self.isTournament = isTournament
            guideDone = [UInt64](repeating: 0, count: (index.guideKeys.count + 63) >> 6)
            guideBest = [GuideBest](repeating: GuideBest(), count: index.guideKeys.count)
            nameValue = [Double](repeating: .nan, count: index.nameLowerLen.count * 2)
            nameBroadcast = [UInt8](repeating: 0, count: index.nameLowerLen.count)
        }

        /// nil when cancelled.
        mutating func score(entry e: Int, shouldCancel: @Sendable () -> Bool) -> GuideBest? {
            var best = GuideBest()
            let g = index.entryGuide[e]
            if g != SportsTokenTable.absent {
                let gi = Int(g)
                if guideDone[gi >> 6] & (1 << UInt64(gi & 63)) != 0 {
                    best = guideBest[gi]
                } else if index.guideRowStart[gi + 1] > index.guideRowStart[gi] {
                    guard let computed = scoreGuide(gi, shouldCancel: shouldCancel) else { return nil }
                    guideBest[gi] = computed
                    guideDone[gi >> 6] |= 1 << UInt64(gi & 63)
                    best = computed
                }
            }
            let packed = index.entryNameAndFlags[e]
            let n = Int(packed & StreamSearchIndex.EntryFlag.nameMask)
            let sports = packed & StreamSearchIndex.EntryFlag.sports != 0
            // ── Channel name ──
            let slot = n << 1 | (sports ? 1 : 0)
            var value = nameValue[slot]
            if value.isNaN {
                value = scoreName(n, inSportsGroup: sports)
                nameValue[slot] = value
            }
            if value > 0, best.relevance == .channelHint, value > best.value {
                best = GuideBest(value: value, relevance: .channelHint, row: -1)
            }
            // ── Multipliers (never standalone) ──
            if best.value > 0 {
                if nameBroadcast[n] == 0 { nameBroadcast[n] = nameHasBroadcaster(n) ? 2 : 1 }
                if nameBroadcast[n] == 2 { best.value *= 1.3 }
                if sports { best.value *= 1.15 }
                if packed & StreamSearchIndex.EntryFlag.audio != 0 { best.value *= 0.55 }
            }
            return best
        }

        // MARK: Programme evidence

        private func scoreGuide(_ g: Int, shouldCancel: @Sendable () -> Bool) -> GuideBest? {
            var best = GuideBest()
            var examined = 0
            let rows = Int(index.guideRowStart[g])..<Int(index.guideRowStart[g + 1])
            let plan = self.plan
            let fixture = self.fixture
            return index.textBytes.withUnsafeBufferPointer { text -> GuideBest? in
                for r in rows {
                    if examined & 15 == 0, shouldCancel() { return nil }
                    examined &+= 1
                    let start = index.rowStart[r], end = index.rowEnd[r]
                    let overlapsEventWindow = start < windowEnd && end > windowStart
                    let isCurrentlyLive = allowCurrentlyLiveEPG && start <= now && end > now
                    guard overlapsEventWindow || isCurrentlyLive else { continue }
                    let timeBonus = overlapsEventWindow
                        ? StreamMatcher.matchTimeBonus(eventStart: eventStart, epgStart: start, isTournament: isTournament)
                        : 12
                    let t = Int(index.rowTextStart[r]), tl = Int(index.rowTitleLen[r]), dl = Int(index.rowDescLen[r])
                    let title = UnsafeBufferPointer(rebasing: text[t..<(t + tl)])
                    let flags = index.rowFlags[r]
                    // A title naming this team against someone else is another
                    // fixture, whichever query found it; one naming both sides
                    // is the event itself even when only one team term matched.
                    var verdict = FixtureTerms.Verdict.undetermined
                    if let fixture {
                        verdict = self.verdict(fixture, row: r, title: title, ascii: flags & StreamSearchIndex.RowFlag.titleASCII != 0)
                    }
                    if verdict == .conflicting {
                        PerfMetrics.shared.increment("sports.match.fixtureConflictsRejected")
                        continue
                    }
                    let confirmed = verdict == .confirmed
                    let fixtureBonus: Double = confirmed ? 40 : 0
                    // Fuzzy and description-only evidence is weaker than a title
                    // naming the event: it needs a sport/league word in the listing,
                    // and a description alone never claims to be the event itself.
                    let descriptionRelevance: StreamMatch.Relevance = confirmed ? .eventProgramme : .relatedProgramme
                    var probe = RowProbe(title: title, desc: UnsafeBufferPointer(rebasing: text[(t + tl)..<(t + tl + dl)]),
                                         titleMask: index.rowTitleMask[r], plan: plan)
                    let w = Int(index.rowWordStart[r]), tw = Int(index.rowTitleWordCount[r])
                    let wEnd = Int(index.rowWordStart[r + 1])
                    var descCompact: (bytes: [UInt8], ascii: Bool, mask: UInt64)?

                    for qi in 0..<plan.queryCount {
                        guard plan.queryTarget[qi] != EventPlan.channelOnly else { continue }
                        let score = plan.queryScore[qi]
                        let slots = Int(plan.tokenStart[qi])..<Int(plan.tokenStart[qi + 1])
                        let tokenCount = slots.count
                        if probe.titleMatches(slots) {
                            // Single-token EPG title matches are ambiguous across
                            // sports (e.g. "giants" in both MLB and IPL cricket).
                            // Require a sport-context signal: the EPG title or
                            // description must also contain a sport/league keyword.
                            if tokenCount == 1, !probe.hasSportContext() { continue }
                            best.record(score + 50 + timeBonus + fixtureBonus, row: r,
                                        relevance: confirmed || score >= 140 ? .eventProgramme : .relatedProgramme)
                            break
                        }
                        let fuzzy = plan.queryFuzzy[qi]
                        if fuzzy, tw > 0, confirmed || probe.hasSportContext(),
                           let coverage = index.rowWordIDs.withUnsafeBufferPointer({ words in
                               fuzzyCoverage(qi, words: UnsafeBufferPointer(rebasing: words[w..<(w + tw)]),
                                             compact: UnsafeBufferPointer(rebasing: text[(t + tl + dl)..<Int(index.rowTextStart[r + 1])]),
                                             compactASCII: flags & StreamSearchIndex.RowFlag.compactASCII != 0,
                                             compactMask: index.rowCompactMask[r], requireExactAnchor: false,
                                             cache: &probe.titleTerms)
                           }) {
                            best.record(score + 28 + (coverage * 18) + (timeBonus * 0.8) + fixtureBonus, row: r,
                                        relevance: confirmed || score >= 140 ? .eventProgramme : .relatedProgramme)
                            break
                        }
                        // Description search: only for multi-token queries.
                        // A single word in a description is too weak a signal.
                        if tokenCount >= 2 && dl > 0 && probe.descMatches(slots) {
                            best.record(score + 35 + (timeBonus * 0.8), row: r, relevance: descriptionRelevance)
                            break
                        }
                        if tokenCount >= 2, fuzzy, dl > 0, wEnd > w + tw, probe.hasSportContext(),
                           let coverage = descriptionFuzzyCoverage(qi, desc: probe.desc,
                                                                   descASCII: flags & StreamSearchIndex.RowFlag.descASCII != 0,
                                                                   words: (w + tw)..<wEnd, compact: &descCompact,
                                                                   cache: &probe.descTerms) {
                            best.record(score + 18 + (coverage * 14) + (timeBonus * 0.6), row: r, relevance: descriptionRelevance)
                            break
                        }
                    }
                }
                return best
            }
        }

        private func verdict(_ fixture: FixtureTerms, row r: Int, title: UnsafeBufferPointer<UInt8>, ascii: Bool) -> FixtureTerms.Verdict {
            guard ascii, fixtureSafe else { return fixture.verdict(forTitle: index.rowTitle[r]) }
            let span = index.rowSeparator[r]
            guard span != StreamSearchIndex.noSeparator else { return .undetermined }
            let lo = Int(span >> 32), hi = Int(span & 0xFFFF_FFFF)
            let left = UnsafeBufferPointer(rebasing: title[0..<lo])
            let right = UnsafeBufferPointer(rebasing: title[hi..<title.count])
            let leftMask = SportsText.bigramMask(left), rightMask = SportsText.bigramMask(right)
            @inline(__always) func side(_ text: UnsafeBufferPointer<UInt8>, _ mask: UInt64, _ names: NeedleView) -> Bool {
                for s in 0..<names.count
                where StreamMatcher.wordBoundaryTri(text, ascii: true, mask: mask, names.needle(s), needleMask: names.mask[s], safe: true) == .yes {
                    return true
                }
                return false
            }
            let leftHome = side(left, leftMask, plan.home), leftAway = side(left, leftMask, plan.away)
            let rightHome = side(right, rightMask, plan.home), rightAway = side(right, rightMask, plan.away)
            if (leftHome && rightAway) || (leftAway && rightHome) { return .confirmed }
            let leftNamed = leftHome || leftAway, rightNamed = rightHome || rightAway
            if leftNamed != rightNamed {
                let other = String(decoding: leftNamed ? right : left, as: UTF8.self)
                return fixture.opponentVerdict(other: other, leftNamed: leftNamed, leftHome: leftHome, rightHome: rightHome)
            }
            return .undetermined
        }

        /// The description's compact key is derived once per row, on first use.
        private func descriptionFuzzyCoverage(_ qi: Int, desc: UnsafeBufferPointer<UInt8>, descASCII: Bool,
                                              words: Range<Int>,
                                              compact cached: inout (bytes: [UInt8], ascii: Bool, mask: UInt64)?,
                                              cache: inout SportsText.TermCache) -> Double? {
            if cached == nil {
                var bytes: [UInt8] = []
                let ascii: Bool
                if descASCII {
                    bytes.reserveCapacity(desc.count)
                    for b in desc where SportsText.isAlnum(b) { bytes.append(b) }
                    ascii = true
                } else {
                    var compact = StreamMatcher.compactKey(String(decoding: desc, as: UTF8.self))
                    ascii = compact.withUTF8 { buf in
                        bytes.append(contentsOf: buf)
                        return SportsText.isASCII(buf)
                    }
                }
                cached = (bytes, ascii, SportsText.bigramMask(bytes))
            }
            let c = cached!
            return index.rowWordIDs.withUnsafeBufferPointer { ids in
                c.bytes.withUnsafeBufferPointer { compact in
                    fuzzyCoverage(qi, words: UnsafeBufferPointer(rebasing: ids[words]), compact: compact,
                                  compactASCII: c.ascii, compactMask: c.mask, requireExactAnchor: false, cache: &cache)
                }
            }
        }

        // MARK: Channel-name evidence

        private func scoreName(_ n: Int, inSportsGroup: Bool) -> Double {
            let lowerStart = Int(index.nameTextStart[n])
            let lowerLen = Int(index.nameLowerLen[n]), compactLen = Int(index.nameCompactLen[n])
            let acronymEnd = Int(index.nameTextStart[n + 1])
            let flags = index.nameFlags[n]
            let wordCount = Int(index.nameWordStart[n + 1] - index.nameWordStart[n])
            let plan = self.plan
            let tokens = plan.tokens
            return index.nameBytes.withUnsafeBufferPointer { bytes in
                index.nameWordIDs.withUnsafeBufferPointer { ids in
                    let lower = UnsafeBufferPointer(rebasing: bytes[lowerStart..<(lowerStart + lowerLen)])
                    let compact = UnsafeBufferPointer(rebasing: bytes[(lowerStart + lowerLen)..<(lowerStart + lowerLen + compactLen)])
                    let acronym = UnsafeBufferPointer(rebasing: bytes[(lowerStart + lowerLen + compactLen)..<acronymEnd])
                    let words = UnsafeBufferPointer(rebasing: ids[Int(index.nameWordStart[n])..<Int(index.nameWordStart[n + 1])])
                    let lowerASCII = flags & StreamSearchIndex.NameFlag.lowerASCII != 0
                    let acronymASCII = flags & StreamSearchIndex.NameFlag.acronymASCII != 0
                    let compactASCII = flags & StreamSearchIndex.NameFlag.compactASCII != 0
                    let lowerMask = index.nameMask[n]
                    var known = SportsText.SlotBits(), found = SportsText.SlotBits()
                    var termCache = SportsText.TermCache()
                    /// One token of the String `allTokensMatch` against this name.
                    @inline(__always) func tokenMatches(_ s: Int) -> Bool {
                        let needle = tokens.needle(s), mask = tokens.mask[s], safe = tokens.isSafe(s)
                        if tokens.charCount[s] <= 4 {
                            let id = tokens.id[s]
                            if id != SportsTokenTable.absent, words.contains(id) { return true }
                            if !acronym.isEmpty {
                                var hit = StreamMatcher.containsTri(acronym, ascii: acronymASCII, mask: ~0, needle, needleMask: mask, safe: safe)
                                if hit == .unknown {
                                    hit = StreamMatcher.stringContains(index.nameAcronymString(n), plan.tokenStrings[s]) ? .yes : .no
                                }
                                if hit == .yes { return true }
                            }
                            var hit = StreamMatcher.wordBoundaryTri(lower, ascii: lowerASCII, mask: lowerMask, needle, needleMask: mask, safe: safe)
                            if hit == .unknown {
                                hit = StreamMatcher.wordBoundaryMatch(plan.tokenStrings[s], in: index.nameLowerString(n)) ? .yes : .no
                            }
                            return hit == .yes
                        }
                        var hit = StreamMatcher.containsTri(lower, ascii: lowerASCII, mask: lowerMask, needle, needleMask: mask, safe: safe)
                        if hit == .unknown {
                            hit = StreamMatcher.stringContains(index.nameLowerString(n), plan.tokenStrings[s]) ? .yes : .no
                        }
                        return hit == .yes
                    }
                    for qi in 0..<plan.queryCount {
                        guard plan.queryTarget[qi] != EventPlan.epgOnly else { continue }
                        let score = plan.queryScore[qi]
                        let range = Int(plan.tokenStart[qi])..<Int(plan.tokenStart[qi + 1])
                        // A weak single-token channel query only counts inside a
                        // sports group on a short channel name.
                        if range.count == 1, score <= 110, !inSportsGroup || wordCount > 4 { continue }
                        var all = true
                        for i in range {
                            let s = Int(plan.tokenSlots[i])
                            if !SportsText.cached(s, &known, &found, { tokenMatches(s) }) { all = false; break }
                        }
                        if all { return score }
                        if let coverage = fuzzyCoverage(qi, words: words, compact: compact, compactASCII: compactASCII,
                                                        compactMask: index.nameCompactMask[n], requireExactAnchor: true,
                                                        cache: &termCache) {
                            return score * (0.78 + coverage * 0.12)
                        }
                    }
                    return 0
                }
            }
        }

        private func nameHasBroadcaster(_ n: Int) -> Bool {
            guard !broadcast.isEmpty else { return false }
            let lowerStart = Int(index.nameTextStart[n]), lowerLen = Int(index.nameLowerLen[n])
            let ascii = index.nameFlags[n] & StreamSearchIndex.NameFlag.lowerASCII != 0
            return index.nameBytes.withUnsafeBufferPointer { bytes in
                let lower = UnsafeBufferPointer(rebasing: bytes[lowerStart..<(lowerStart + lowerLen)])
                for net in broadcast {
                    var hit = StreamMatcher.containsTri(lower, ascii: ascii, mask: index.nameMask[n], net)
                    if hit == .unknown { hit = StreamMatcher.stringContains(index.nameLowerString(n), net.string) ? .yes : .no }
                    if hit == .yes { return true }
                }
                return false
            }
        }

        // MARK: Fuzzy repair

        /// Exact port of the String `fuzzyTokenCoverage` over interned word
        /// IDs and compact bytes.
        private func fuzzyCoverage(_ qi: Int, words: UnsafeBufferPointer<UInt32>, compact: UnsafeBufferPointer<UInt8>,
                                   compactASCII: Bool, compactMask: UInt64, requireExactAnchor: Bool,
                                   cache: inout SportsText.TermCache) -> Double? {
            guard plan.queryFuzzy[qi], !words.isEmpty else { return nil }
            let range = Int(plan.fuzzyStart[qi])..<Int(plan.fuzzyStart[qi + 1])
            guard !range.isEmpty else { return nil }
            // Single fuzzy terms are prone to cross-sport false positives. Keep
            // them only for long, high-signal names such as athletes or nicknames.
            if range.count == 1 { guard plan.querySingleFuzzyOK[qi] else { return nil } }
            let terms = plan.fuzzy

            var total = 0.0
            var exactHits = 0
            var missing = -1
            for i in range {
                let s = Int(plan.fuzzySlots[i])
                // Presence is a pure function of (term, text): words only for
                // short terms, words or compact text otherwise.
                let present = SportsText.cached(s, &cache.known, &cache.found) {
                    let id = terms.id[s]
                    let inWords = id != SportsTokenTable.absent && words.contains(id)
                    if inWords || terms.charCount[s] <= 3 { return inWords }
                    return compactContains(compact, ascii: compactASCII, mask: compactMask, slot: s)
                }
                if terms.charCount[s] <= 3 {
                    guard present else { return nil }
                    total += 1.0
                    exactHits += 1
                    continue
                }
                if present {
                    total += 1.0
                    exactHits += 1
                    continue
                }
                // Fuzzy repair is intentionally narrow: one misspelled word
                // (a second missing term can only end in nil).
                guard missing < 0 else { return nil }
                missing = s
            }
            if requireExactAnchor || range.count >= 2 {
                guard exactHits > 0 else { return nil }
            }
            if missing >= 0 {
                let best = bestSimilarity(missing, words: words)
                let threshold = terms.charCount[missing] <= 5 ? 0.91 : 0.86
                guard best >= threshold else { return nil }
                total += best
            }
            let coverage = total / Double(range.count)
            return coverage >= 0.88 ? coverage : nil
        }

        @inline(__always)
        private func compactContains(_ compact: UnsafeBufferPointer<UInt8>, ascii: Bool, mask: UInt64, slot s: Int) -> Bool {
            let terms = plan.fuzzy
            let hit = StreamMatcher.containsTri(compact, ascii: ascii, mask: mask, terms.needle(s), needleMask: terms.mask[s], safe: terms.isSafe(s))
            if hit != .unknown { return hit == .yes }
            return StreamMatcher.stringContains(String(decoding: compact, as: UTF8.self), plan.fuzzyStrings[s])
        }

        private func bestSimilarity(_ s: Int, words: UnsafeBufferPointer<UInt32>) -> Double {
            var best = 0.0
            let tokens = index.tokens
            let terms = plan.fuzzy
            let termCount = Int(terms.charCount[s])
            let term = terms.needle(s)
            for word in words {
                let wordCount = tokens.charCount(word)
                guard wordCount >= 4 else { continue }
                let lengthDelta = abs(wordCount - termCount)
                guard lengthDelta <= max(3, termCount / 3) else { continue }
                let score: Double
                if terms.isASCII(s), tokens.isASCII(word), term.count <= 64, wordCount <= 64 {
                    score = tokens.bytes.withUnsafeBufferPointer { blob -> Double in
                        let w = UnsafeBufferPointer(rebasing: blob[tokens.range(word)])
                        guard StreamMatcher.comparableShape(term, w) else { return -1 }
                        return max(StreamMatcher.jaroWinkler(term, w), StreamMatcher.diceCoefficient(term, w))
                    }
                    if score < 0 { continue }
                } else {
                    let termString = plan.fuzzyStrings[s]
                    let wordString = tokens.string(word)
                    guard StreamMatcher.hasComparableShape(termString, wordString) else { continue }
                    score = max(StreamMatcher.jaroWinkler(termString, wordString), StreamMatcher.diceCoefficient(termString, wordString))
                }
                if score > best { best = score }
            }
            return best
        }
    }

    // MARK: - Query generation

    struct SearchQuery {
        let tokens: [String]
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
            self.fuzzyTerms = tokens.flatMap { tokenWords(in: $0, minimumLength: 2) }
            self.score = score
            self.label = label
            self.target = target
            self.allowsFuzzy = allowsFuzzy
        }
    }

    enum QueryTarget {
        case both
        case epgOnly
        case channelOnly
    }

    static func matchTimeBonus(
        eventStart: Double,
        epgStart: Double,
        isTournament: Bool
    ) -> Double {
        let delta = abs(epgStart - eventStart)
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

    // MARK: - Similarity (String reference and ASCII byte ports)

    static func bestSimilarity(for term: String, in words: ContiguousArray<String>) -> Double {
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

    static func hasComparableShape(_ lhs: String, _ rhs: String) -> Bool {
        guard let lFirst = lhs.first, let rFirst = rhs.first else { return false }
        if lFirst == rFirst { return true }

        guard let lLast = lhs.last, let rLast = rhs.last else { return false }
        return lhs.count >= 7 && rhs.count >= 7 && lLast == rLast
    }

    @inline(__always)
    static func comparableShape(_ lhs: UnsafeBufferPointer<UInt8>, _ rhs: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs[0] == rhs[0] { return true }
        return lhs.count >= 7 && rhs.count >= 7 && lhs[lhs.count - 1] == rhs[rhs.count - 1]
    }

    static func jaroWinkler(_ lhs: String, _ rhs: String) -> Double {
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

    /// Byte port of `jaroWinkler` for ASCII words of at most 64 bytes; match
    /// flags are bitsets instead of Bool arrays.
    static func jaroWinkler(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Double {
        if a.count == b.count, a.count == 0 || memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0 { return 1 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let matchDistance = max(a.count, b.count) / 2 - 1
        var aMatches: UInt64 = 0
        var bMatches: UInt64 = 0
        var matches = 0
        for i in 0..<a.count {
            let start = max(0, i - matchDistance)
            let end = min(i + matchDistance + 1, b.count)
            var j = start
            while j < end {
                if bMatches & (1 << UInt64(j)) == 0, a[i] == b[j] {
                    aMatches |= 1 << UInt64(i)
                    bMatches |= 1 << UInt64(j)
                    matches += 1
                    break
                }
                j += 1
            }
        }
        guard matches > 0 else { return 0 }
        var transpositions = 0
        var k = 0
        for i in 0..<a.count where aMatches & (1 << UInt64(i)) != 0 {
            while bMatches & (1 << UInt64(k)) == 0 { k += 1 }
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

    static func diceCoefficient(_ lhs: String, _ rhs: String) -> Double {
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

    /// Byte port of `diceCoefficient`: multiset bigram intersection with a
    /// used-bit mask over the left word's bigrams (at most 63).
    static func diceCoefficient(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Double {
        guard a.count >= 2, b.count >= 2 else {
            return a.count == b.count && (a.count == 0 || memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0) ? 1 : 0
        }
        var used: UInt64 = 0
        var intersection = 0
        for j in 0..<(b.count - 1) {
            let gram = UInt16(b[j]) << 8 | UInt16(b[j + 1])
            var i = 0
            while i < a.count - 1 {
                if used & (1 << UInt64(i)) == 0, UInt16(a[i]) << 8 | UInt16(a[i + 1]) == gram {
                    used |= 1 << UInt64(i)
                    intersection += 1
                    break
                }
                i += 1
            }
        }
        return (2.0 * Double(intersection)) / Double(a.count + b.count - 2)
    }

    // MARK: - String reference matching (Unicode fallback)

    static func wordBoundaryMatch(_ needle: String, in haystack: String) -> Bool {
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


    // MARK: - Query text helpers

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
        tokenWords(in: normalise(text), minimumLength: minimumLength)
            .filter { !stopWords.contains($0) }
    }

    static func tokenWords(in normalisedText: String, minimumLength: Int = 2) -> [String] {
        if let ascii = asciiTokenWords(in: normalisedText, minimumLength: minimumLength) {
            return ascii
        }

        return normalisedText
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= minimumLength }
    }

    static func compactKey(_ normalisedText: String) -> String {
        if let ascii = asciiCompactKey(normalisedText) {
            return ascii
        }

        return normalisedText.filter { $0.isLetter || $0.isNumber }
    }

    private static func asciiTokenWords(in text: String, minimumLength: Int) -> [String]? {
        var words: [String] = []
        words.reserveCapacity(8)

        let bytes = text.utf8
        var tokenStart: String.UTF8View.Index?
        var tokenLength = 0

        func appendToken(endingAt end: String.UTF8View.Index) {
            guard let start = tokenStart, tokenLength >= minimumLength else { return }
            words.append(String(decoding: bytes[start..<end], as: UTF8.self))
        }

        var index = bytes.startIndex
        while index != bytes.endIndex {
            let byte = bytes[index]
            guard byte < 128 else { return nil }

            if isASCIIAlphaNumeric(byte) {
                if tokenStart == nil {
                    tokenStart = index
                    tokenLength = 0
                }
                tokenLength += 1
            } else {
                appendToken(endingAt: index)
                tokenStart = nil
                tokenLength = 0
            }

            index = bytes.index(after: index)
        }

        appendToken(endingAt: bytes.endIndex)
        return words
    }

    private static func asciiCompactKey(_ text: String) -> String? {
        var compact: [UInt8] = []
        compact.reserveCapacity(text.utf8.count)

        for byte in text.utf8 {
            guard byte < 128 else { return nil }
            if isASCIIAlphaNumeric(byte) {
                compact.append(byte)
            }
        }

        return String(decoding: compact, as: UTF8.self)
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }

    static func acronym(for words: ContiguousArray<String>) -> String {
        String(words.compactMap(\.first))
    }

    /// Head-to-head check for guide titles of the form "A v B".
    struct FixtureTerms: Sendable {
        enum Verdict: Sendable { case confirmed, conflicting, undetermined }

        let home: [String]
        let away: [String]

        init?(event: SportEvent) {
            guard let homeTeam = event.homeTeam, let awayTeam = event.awayTeam else { return nil }
            home = StreamMatcher.teamSearchTerms(for: homeTeam)
            away = StreamMatcher.teamSearchTerms(for: awayTeam)
            guard !home.isEmpty, !away.isEmpty else { return nil }
        }

        private static let separators = [" versus ", " vs. ", " vs ", " v. ", " v ", " @ "]
        // Placeholder opponents and broadcast suffixes carry no fixture identity.
        private static let neutralWords: Set<String> = ["tbc", "tba", "tbd", "live", "replay", "highlights", "hd", "fhd", "uhd", "4k"]

        func verdict(forTitle title: String) -> Verdict {
            let lower = StreamMatcher.normalise(title)
            guard let range = Self.separators.lazy.compactMap({ lower.range(of: $0) }).first else { return .undetermined }
            let left = String(lower[..<range.lowerBound])
            let right = String(lower[range.upperBound...])
            let leftHome = Self.side(left, names: home), leftAway = Self.side(left, names: away)
            let rightHome = Self.side(right, names: home), rightAway = Self.side(right, names: away)
            if (leftHome && rightAway) || (leftAway && rightHome) { return .confirmed }
            let leftNamed = leftHome || leftAway, rightNamed = rightHome || rightAway
            // One side is ours; the other names a real, different opponent.
            if leftNamed != rightNamed {
                return opponentVerdict(other: leftNamed ? right : left, leftNamed: leftNamed,
                                       leftHome: leftHome, rightHome: rightHome)
            }
            return .undetermined
        }

        /// Exactly one side named this fixture; decide whether the other
        /// side names a real, different opponent.
        func opponentVerdict(other: String, leftNamed: Bool, leftHome: Bool, rightHome: Bool) -> Verdict {
            // The opponent side may run into trailing context, e.g.
            // "Liverpool v Everton: Live" or "Liverpool v Everton (R)".
            let opponent = other.split(whereSeparator: { ":(|[".contains($0) }).first.map(String.init) ?? other
            let words = StreamMatcher.tokenWords(in: opponent).filter { !Self.neutralWords.contains($0) && $0.count >= 3 }
            if !words.isEmpty, !Self.fuzzySide(words, names: leftNamed ? (leftHome ? away : home) : (rightHome ? away : home)) {
                return .conflicting
            }
            return .undetermined
        }

        /// The first separator (in priority order) found in an ASCII
        /// normalised title, at its first occurrence, as `lo << 32 | hi`.
        static func separatorSpan(_ title: UnsafeBufferPointer<UInt8>) -> UInt64 {
            for separator in separatorBytes {
                let hit = separator.withUnsafeBufferPointer { SportsText.find(title, from: 0, $0) }
                if let lo = hit { return UInt64(lo) << 32 | UInt64(lo + separator.count) }
            }
            return StreamSearchIndex.noSeparator
        }

        private static let separatorBytes = separators.map { Array($0.utf8) }

        private static func side(_ text: String, names: [String]) -> Bool {
            names.contains { StreamMatcher.wordBoundaryMatch($0, in: text) }
        }

        /// Tolerates guide misspellings of the expected opponent so a typo
        /// is never treated as a different team.
        private static func fuzzySide(_ words: [String], names: [String]) -> Bool {
            let contiguous = ContiguousArray(words)
            return names.contains { name in
                StreamMatcher.tokenWords(in: name).contains { term in
                    term.count >= 4 && StreamMatcher.bestSimilarity(for: term, in: contiguous) >= 0.88
                }
            }
        }
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
    static let trivialWords: Set<String> = Set(trivialWordList)
    static let trivialWordList: [String] = [
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

    static let ambiguousTeamNames: Set<String> = [
        "city", "united", "real", "sporting", "racing", "fc",
        "inter", "athletic", "roma", "paris", "milan",
    ]

    static let ambiguousCityNames: Set<String> = [
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
