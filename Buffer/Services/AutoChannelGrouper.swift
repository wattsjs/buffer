import Foundation

/// Groups the same broadcast channel across configured sources into Smart
/// feeds, so one row plays whichever account currently has the best stream.
/// Pure metadata grouping: candidates still pass the catalog's identity,
/// capacity and recovery rules before anything plays.
///
/// Layout: every live channel of every source becomes one *member* row in
/// flat columns. Normalised names and guide IDs are interned once into byte
/// tables and compared as `UInt32` tokens; an identity is a packed
/// (country, name token) pair. Region joins and guide-ID merges are a
/// union-find over a flat `UInt32` parent array, groups are contiguous
/// ranges of one member permutation, and the region/category filter is a
/// word-wide AND/OR over per-region and per-category feed bitsets. Strings
/// are only materialised for the feeds that survive the filter.
nonisolated protocol GuideKeyed {
    var guideID: String? { get }
}

nonisolated enum AutoChannelGrouper {
    static let feedPrefix = "smart:auto:"

    struct Identity: Hashable, Sendable {
        let country: String
        let name: String
    }

    struct Parsed: Sendable {
        let identity: Identity
        let displayName: String
        let format: String
        let fps: Double?
    }

    /// Feeds for channels offered by at least `minimumSources` distinct
    /// sources. Groups touching an endpoint the curated catalog already owns
    /// are left to that catalog.
    static func feeds(from snapshots: [SmartSportsSourceSnapshot],
                      excluding curated: Set<SmartSportsEndpointKey> = [],
                      minimumSources: Int = 2,
                      filter: SmartChannelFilter = .init()) -> [SmartSportsFeedDefinition] {
        analyze(snapshots, excluding: curated, minimumSources: minimumSources, filter: filter).feeds
    }

    /// Feeds plus per-region/category channel counts from one parse pass.
    /// With an enabled filter, channels it allows become feeds even when only
    /// one source carries them; everything it rejects is left out entirely.
    static func analyze(_ snapshots: [SmartSportsSourceSnapshot],
                        excluding curated: Set<SmartSportsEndpointKey> = [],
                        minimumSources: Int = 2,
                        filter: SmartChannelFilter = .init())
        -> (feeds: [SmartSportsFeedDefinition], inventory: [SmartRegionSummary]) {
        let index = GroupIndex(snapshots)
        return (index.feeds(excluding: curated, minimumSources: minimumSources, filter: filter), index.inventory())
    }

    /// Display label and filter key for a parsed region.
    static func regionLabel(_ country: String) -> String {
        if country.isEmpty { return SmartChannelFilter.unknownRegion }
        if country.hasPrefix(languagePrefix) { return String(country.dropFirst(languagePrefix.count)).capitalized }
        return country.uppercased()
    }

    static func isAutomatic(feedID: String) -> Bool { feedID.hasPrefix(feedPrefix) }

    /// One channel's grouping identity. The flat scanner handles ASCII names
    /// (nearly every IPTV row); anything else takes the Foundation path.
    static func parse(_ channel: Channel) -> Parsed? {
        var scratch = Scanner.Scratch()
        var groups = GroupFacts.Table()
        let facts = groups.facts(for: channel.group)
        switch Scanner.scan(channel.name, facts: facts, guide: channel.epgChannelID, scratch: &scratch) {
        case .rejected: return nil
        case .needsFoundation: return parseFoundation(channel)
        case .parsed(let country, let format, let fps):
            let name = String(decoding: scratch.name, as: UTF8.self)
            return Parsed(identity: .init(country: Countries.names[Int(country)], name: name),
                          displayName: displayString(channel.name, scratch: &scratch),
                          format: Words.formatNames[Int(format)], fps: fps.isNaN ? nil : fps)
        }
    }

    /// Display name through the byte scanner, or Foundation for non-ASCII.
    static func displayString(_ name: String, scratch: inout Scanner.Scratch) -> String {
        let bytes = name.utf8.withContiguousStorageIfAvailable { Scanner.displayName($0, scratch: &scratch) } ?? nil
        return bytes.map { String(decoding: $0, as: UTF8.self) } ?? displayNameFoundation(name)
    }

    // MARK: - Flat group index

    /// Grouping is independent of the filter: build once per discovery,
    /// then select feeds with bitset algebra.
    struct GroupIndex {
        let snapshots: [SmartSportsSourceSnapshot]
        /// Member columns, one row per parsed live channel, in input order.
        private(set) var memberSnapshot: [UInt16] = []
        private(set) var memberChannel: [UInt32] = []
        /// Identity after joining a country-less name to its single region.
        private(set) var memberIdentity: [UInt32] = []
        /// Region as parsed from this row, before any join (inventory key).
        private(set) var memberCountry: [UInt8] = []
        private(set) var memberCategory: [UInt8] = []
        private(set) var memberFormat: [UInt8] = []
        private(set) var memberFPS: [Double] = []
        /// Bit set when the member joined its identity through the region rule.
        private(set) var memberJoined = Bitset()
        /// Identity columns: packed (country, name token).
        private(set) var identityCountry: [UInt8] = []
        private(set) var identityName: [UInt32] = []
        private(set) var names = ByteInterner()
        /// Groups: `groupMembers[groupStart[g]..<groupStart[g+1]]` are member rows.
        private(set) var groupStart: [UInt32] = []
        private(set) var groupMembers: [UInt32] = []
        private(set) var groupRoot: [UInt32] = []
        private(set) var groupCategory: [UInt8] = []
        private var snapshotCanon: [UInt16] = []

        init(_ snapshots: [SmartSportsSourceSnapshot]) {
            self.snapshots = snapshots
            var firstSnapshot: [UUID: UInt16] = [:]
            for (index, snapshot) in snapshots.enumerated() {
                snapshotCanon.append(firstSnapshot[snapshot.sourceID, default: UInt16(index)])
                if firstSnapshot[snapshot.sourceID] == nil { firstSnapshot[snapshot.sourceID] = UInt16(index) }
            }
            build()
        }

        var groupCount: Int { groupRoot.count }

        private mutating func build() {
            let total = snapshots.reduce(0) { $0 + $1.channels.count }
            memberSnapshot.reserveCapacity(total); memberChannel.reserveCapacity(total)
            memberIdentity.reserveCapacity(total); memberCountry.reserveCapacity(total)
            memberCategory.reserveCapacity(total); memberFormat.reserveCapacity(total); memberFPS.reserveCapacity(total)
            var identities = UInt64Map(capacity: total)
            var groups = GroupFacts.Table()
            var scratch = Scanner.Scratch()
            // Guide tokens per member (UInt32.max = none), interned lazily.
            var guides = ByteInterner()
            var memberGuide: [UInt32] = []
            memberGuide.reserveCapacity(total)

            func identity(country: UInt8, nameToken: UInt32) -> UInt32 {
                let key = UInt64(country) << 32 | UInt64(nameToken)
                return identities.insert(key, next: UInt32(identityCountry.count)) { _ in
                    identityCountry.append(country); identityName.append(nameToken)
                }
            }

            for (snapshotIndex, snapshot) in snapshots.enumerated() {
                for (channelIndex, channel) in snapshot.channels.enumerated() where channel.contentType == .live {
                    let facts = groups.facts(for: channel.group)
                    var country: UInt8 = 0, format: UInt8 = 0, fps = Double.nan
                    let nameToken: UInt32
                    switch Scanner.scan(channel.name, facts: facts, guide: channel.epgChannelID, scratch: &scratch) {
                    case .rejected: continue
                    case .parsed(let c, let f, let r):
                        country = c; format = f; fps = r
                        nameToken = scratch.name.withUnsafeBufferPointer { names.intern($0) }
                    case .needsFoundation:
                        guard let parsed = parseFoundation(channel) else { continue }
                        country = Countries.id(of: parsed.identity.country)
                        format = Words.formatRank(parsed.format)
                        fps = parsed.fps ?? .nan
                        nameToken = Array(parsed.identity.name.utf8).withUnsafeBufferPointer { names.intern($0) }
                    }
                    memberSnapshot.append(UInt16(snapshotIndex))
                    memberChannel.append(UInt32(channelIndex))
                    memberIdentity.append(identity(country: country, nameToken: nameToken))
                    memberCountry.append(country)
                    memberCategory.append(facts.category)
                    memberFormat.append(format)
                    memberFPS.append(fps)
                    memberGuide.append(Scanner.guideToken(channel.epgChannelID, into: &guides, scratch: &scratch))
                }
            }
            let memberCount = memberIdentity.count
            memberJoined = Bitset(count: memberCount)
            let identityCount = identityCountry.count

            // A provider that omits the country joins the single regional
            // feed of the same name; with several regions it stays alone.
            let none: UInt8 = 0xFF, many: UInt8 = 0xFE
            var regionOfName = [UInt8](repeating: none, count: names.count)
            for id in 0..<identityCount where identityCountry[id] != 0 {
                let name = Int(identityName[id]), country = identityCountry[id]
                if regionOfName[name] == none { regionOfName[name] = country }
                else if regionOfName[name] != country { regionOfName[name] = many }
            }
            var joinTarget = [UInt32](unsafeUninitializedCapacity: identityCount) { buffer, count in
                for id in 0..<identityCount { buffer[id] = UInt32(id) }
                count = identityCount
            }
            for id in 0..<identityCount where identityCountry[id] == 0 {
                let region = regionOfName[Int(identityName[id])]
                guard region != none, region != many else { continue }
                joinTarget[id] = identities.find(UInt64(region) << 32 | UInt64(identityName[id]))!
            }
            var identitySize = [UInt32](repeating: 0, count: identityCount)
            for m in 0..<memberCount {
                let original = memberIdentity[m], target = joinTarget[Int(original)]
                if target != original { memberIdentity[m] = target; memberJoined.insert(m) }
                identitySize[Int(target)] += 1
            }

            // Providers often name one broadcast differently but give it the
            // same guide ID. Pairs (guide, identity), sorted and unique, give
            // each guide's identity set as one contiguous run.
            var pairs: [UInt64] = []
            pairs.reserveCapacity(memberCount)
            for m in 0..<memberCount where memberGuide[m] != .max {
                pairs.append(UInt64(memberGuide[m]) << 32 | UInt64(memberIdentity[m]))
            }
            pairs.sort()
            var parent = (0..<identityCount).map { UInt32($0) }
            func root(_ id: UInt32) -> UInt32 {
                var current = id
                while parent[Int(current)] != current {
                    parent[Int(current)] = parent[Int(parent[Int(current)])]
                    current = parent[Int(current)]
                }
                return current
            }
            // Runs of 2...4 identities, processed in guide byte order so
            // chained merges pick the same surviving identity every refresh.
            var runs: [(guide: UInt32, start: Int, count: Int)] = []
            var i = 0
            while i < pairs.count {
                let guide = UInt32(truncatingIfNeeded: pairs[i] >> 32)
                var j = i + 1, distinct = 1
                var last = UInt32(truncatingIfNeeded: pairs[i])
                while j < pairs.count, UInt32(truncatingIfNeeded: pairs[j] >> 32) == guide {
                    let id = UInt32(truncatingIfNeeded: pairs[j])
                    if id != last { distinct += 1; last = id; if distinct > 4 { break } }
                    j += 1
                }
                if distinct > 4 {
                    while j < pairs.count, UInt32(truncatingIfNeeded: pairs[j] >> 32) == guide { j += 1 }
                } else if distinct > 1 {
                    runs.append((guide, i, j - i))
                }
                i = j
            }
            runs.sort { guides.compare($0.guide, $1.guide) < 0 }
            var set: [UInt32] = []
            for run in runs {
                set.removeAll(keepingCapacity: true)
                for k in run.start..<(run.start + run.count) {
                    let id = UInt32(truncatingIfNeeded: pairs[k])
                    if set.last != id { set.append(id) }
                }
                var country: UInt8 = 0, conflicting = false
                for id in set where identityCountry[Int(id)] != 0 {
                    if country == 0 { country = identityCountry[Int(id)] }
                    else if country != identityCountry[Int(id)] { conflicting = true }
                }
                guard !conflicting else { continue }
                set.sort { lhs, rhs in
                    let l = identitySize[Int(lhs)], r = identitySize[Int(rhs)]
                    if l != r { return l > r }
                    let order = names.compare(identityName[Int(lhs)], identityName[Int(rhs)])
                    return order != 0 ? order < 0 : lhs < rhs
                }
                let keep = root(set[0])
                for other in set.dropFirst() {
                    let r = root(other)
                    if r != keep { parent[Int(r)] = keep }
                }
            }

            // Groups as contiguous ranges: counting sort members by root.
            var groupOfRoot = [UInt32](repeating: .max, count: identityCount)
            var memberGroup = [UInt32](repeating: 0, count: memberCount)
            for m in 0..<memberCount {
                let r = Int(root(memberIdentity[m]))
                if groupOfRoot[r] == .max {
                    groupOfRoot[r] = UInt32(groupRoot.count)
                    groupRoot.append(UInt32(r))
                    groupCategory.append(UInt8.max)
                }
                let g = groupOfRoot[r]
                memberGroup[m] = g
                groupCategory[Int(g)] = min(groupCategory[Int(g)], memberCategory[m])
            }
            let groupCount = groupRoot.count
            groupStart = [UInt32](repeating: 0, count: groupCount + 1)
            for m in 0..<memberCount { groupStart[Int(memberGroup[m]) + 1] += 1 }
            for g in 0..<groupCount { groupStart[g + 1] += groupStart[g] }
            var cursor = Array(groupStart.dropLast())
            groupMembers = [UInt32](repeating: 0, count: memberCount)
            for m in 0..<memberCount {
                let g = Int(memberGroup[m])
                groupMembers[Int(cursor[g])] = UInt32(m)
                cursor[g] += 1
            }
            // Within a group: each identity's own rows, then rows that
            // joined it by region, in input order.
            for g in 0..<groupCount {
                let lo = Int(groupStart[g]), hi = Int(groupStart[g + 1])
                guard hi - lo > 1 else { continue }
                var ordered = true
                for k in (lo + 1)..<hi where memberIdentity[Int(groupMembers[k])] != memberIdentity[Int(groupMembers[lo])]
                    || memberJoined.contains(Int(groupMembers[k])) != memberJoined.contains(Int(groupMembers[lo])) {
                    ordered = false; break
                }
                if ordered { continue }
                groupMembers[lo..<hi].sort { a, b in
                    let ia = memberIdentity[Int(a)], ib = memberIdentity[Int(b)]
                    if ia != ib { return ia < ib }
                    let ja = memberJoined.contains(Int(a)), jb = memberJoined.contains(Int(b))
                    if ja != jb { return !ja }
                    return a < b
                }
            }
        }

        /// Feeds the filter allows, sorted by ID.
        func feeds(excluding curated: Set<SmartSportsEndpointKey>, minimumSources: Int,
                   filter: SmartChannelFilter) -> [SmartSportsFeedDefinition] {
            let groupCount = self.groupCount
            let words = (groupCount + 63) >> 6
            var allowed = [UInt64](repeating: 0, count: words)
            if filter.isEnabled {
                // Per-category and per-region membership bitsets; a region's
                // allowed categories are one OR, the whole filter one AND each.
                let categoryCount = SmartChannelFilter.categories.count
                var categoryBits = [UInt64](repeating: 0, count: categoryCount * words)
                var regionBits = [UInt64](repeating: 0, count: Countries.names.count * words)
                for g in 0..<groupCount {
                    let word = g >> 6, bit = UInt64(1) << UInt64(g & 63)
                    categoryBits[Int(groupCategory[g]) * words + word] |= bit
                    regionBits[Int(identityCountry[Int(groupRoot[g])]) * words + word] |= bit
                }
                var union = [UInt64](repeating: 0, count: words)
                func categoryUnion(_ mask: UInt8) {
                    for w in 0..<words { union[w] = 0 }
                    for c in 0..<categoryCount where mask & (1 << c) != 0 {
                        for w in 0..<words { union[w] |= categoryBits[c * words + w] }
                    }
                }
                let always = Self.categoryMask(filter.alwaysInclude)
                if always != 0 {
                    categoryUnion(always)
                    for w in 0..<words { allowed[w] |= union[w] }
                }
                for country in 0..<Countries.names.count {
                    let mask: UInt8
                    switch filter.regions[Countries.labels[country]] ?? .off {
                    case .off: mask = 0
                    case .everything: mask = 0x7F
                    case .categories(let set): mask = Self.categoryMask(set)
                    }
                    guard mask != 0 else { continue }
                    categoryUnion(mask)
                    let base = country * words
                    for w in 0..<words { allowed[w] |= regionBits[base + w] & union[w] }
                }
            } else {
                // Sports channels are kept even when one account carries
                // them; everything else needs several sources to group.
                for g in 0..<groupCount {
                    if groupCategory[g] == 0 || distinctSources(group: g) >= minimumSources {
                        allowed[g >> 6] |= UInt64(1) << UInt64(g & 63)
                    }
                }
            }

            var feeds: [SmartSportsFeedDefinition] = []
            var scratch = Scanner.Scratch()
            for w in 0..<words {
                var word = allowed[w]
                while word != 0 {
                    let g = w << 6 | word.trailingZeroBitCount
                    word &= word - 1
                    if let feed = feed(group: g, curated: curated, scratch: &scratch) { feeds.append(feed) }
                }
            }
            return feeds.sorted { $0.id < $1.id }
        }

        private static func categoryMask(_ categories: Set<String>) -> UInt8 {
            var mask: UInt8 = 0
            for (index, name) in SmartChannelFilter.categories.enumerated() where categories.contains(name) {
                mask |= 1 << index
            }
            return mask
        }

        private func distinctSources(group g: Int) -> Int {
            let lo = Int(groupStart[g]), hi = Int(groupStart[g + 1])
            if snapshots.count <= 64 {
                var mask: UInt64 = 0
                for k in lo..<hi { mask |= 1 << UInt64(snapshotCanon[Int(memberSnapshot[Int(groupMembers[k])])]) }
                return mask.nonzeroBitCount
            }
            return Set((lo..<hi).map { snapshotCanon[Int(memberSnapshot[Int(groupMembers[$0])])] }).count
        }

        private func channel(_ member: Int) -> Channel {
            snapshots[Int(memberSnapshot[member])].channels[Int(memberChannel[member])]
        }

        private func feed(group g: Int, curated: Set<SmartSportsEndpointKey>,
                          scratch: inout Scanner.Scratch) -> SmartSportsFeedDefinition? {
            let lo = Int(groupStart[g]), hi = Int(groupStart[g + 1])
            // One endpoint may not appear twice in a feed.
            var nativeIDs: [String] = []
            nativeIDs.reserveCapacity(hi - lo)
            var keys: Set<SmartSportsEndpointKey> = []
            for k in lo..<hi {
                let m = Int(groupMembers[k])
                let nativeID = nativeIDOf(channel(m))
                let canon = snapshotCanon[Int(memberSnapshot[m])]
                if hi - lo <= 16 {
                    for j in lo..<k where snapshotCanon[Int(memberSnapshot[Int(groupMembers[j])])] == canon
                        && nativeIDs[j - lo] == nativeID { return nil }
                } else if !keys.insert(.init(sourceID: snapshots[Int(canon)].sourceID, nativeID: nativeID)).inserted {
                    return nil
                }
                nativeIDs.append(nativeID)
            }
            if !curated.isEmpty {
                for k in lo..<hi {
                    let snapshot = snapshots[Int(memberSnapshot[Int(groupMembers[k])])]
                    if curated.contains(.init(sourceID: snapshot.sourceID, nativeID: nativeIDs[k - lo])) { return nil }
                }
            }
            var variants: [SmartSportsVariantDefinition] = []
            variants.reserveCapacity(hi - lo)
            var displayName: String?
            for k in lo..<hi {
                let m = Int(groupMembers[k])
                let snapshot = snapshots[Int(memberSnapshot[m])]
                let channel = snapshot.channels[Int(memberChannel[m])]
                let fps = memberFPS[m]
                variants.append(SmartSportsVariantDefinition(
                    sourceID: snapshot.sourceID, sourceName: snapshot.sourceName,
                    nativeID: nativeIDs[k - lo], identity: .init(channel: channel),
                    advertisedFormat: Words.formatNames[Int(memberFormat[m])], advertisedFPS: fps.isNaN ? nil : fps,
                    width: nil, height: nil, fps: nil, measuredAt: nil, measurementContext: "Automatic"))
                let display = displayString(channel.name, scratch: &scratch)
                if let current = displayName {
                    if (display.count, display) < (current.count, current) { displayName = display }
                } else {
                    displayName = display
                }
            }
            let root = Int(groupRoot[g])
            let country = Countries.names[Int(identityCountry[root])]
            let name = names.string(identityName[root])
            var sources = 0
            if snapshots.count <= 64 {
                var mask: UInt64 = 0
                for k in lo..<hi { mask |= 1 << UInt64(snapshotCanon[Int(memberSnapshot[Int(groupMembers[k])])]) }
                sources = mask.nonzeroBitCount
            } else {
                sources = Set(variants.map(\.sourceID)).count
            }
            return SmartSportsFeedDefinition(
                id: feedPrefix + (country.isEmpty ? "global" : country) + ":" + names.dashed(identityName[root]),
                name: displayName ?? name,
                country: Countries.labels[Int(identityCountry[root])],
                language: "",
                edition: SmartChannelFilter.categories[Int(groupCategory[g])],
                guideStatus: "Automatic grouping",
                caveats: ["Grouped automatically by name and region across \(sources) sources."],
                variants: variants)
        }

        /// Per-region/category channel counts, keyed by each row's own region.
        func inventory() -> [SmartRegionSummary] {
            let categoryCount = SmartChannelFilter.categories.count
            var counts = [Int](repeating: 0, count: Countries.names.count * categoryCount)
            for m in 0..<memberCountry.count {
                counts[Int(memberCountry[m]) * categoryCount + Int(memberCategory[m])] += 1
            }
            var summaries: [SmartRegionSummary] = []
            for country in 0..<Countries.names.count {
                var categoryCounts: [String: Int] = [:]
                for c in 0..<categoryCount where counts[country * categoryCount + c] > 0 {
                    categoryCounts[SmartChannelFilter.categories[c]] = counts[country * categoryCount + c]
                }
                if !categoryCounts.isEmpty {
                    summaries.append(SmartRegionSummary(region: Countries.labels[country], categoryCounts: categoryCounts))
                }
            }
            return summaries.sorted { ($0.total, $1.region) > ($1.total, $0.region) }
        }
    }

    // MARK: - Interned vocabulary

    static let languagePrefix = "lang-"
    /// Language-only labels ("Arabic | Sports") become their own region so
    /// they can be switched off like a country.
    static let languages: [String: String] = [
        "arabic": "arabic", "arab": "arabic", "hindi": "hindi", "urdu": "urdu", "punjabi": "punjabi",
        "tamil": "tamil", "telugu": "telugu", "malayalam": "malayalam", "bengali": "bengali", "bangla": "bengali",
        "turkish": "turkish", "persian": "persian", "farsi": "persian", "kurdish": "kurdish",
        "spanish": "spanish", "espanol": "spanish", "latino": "spanish", "latin": "spanish",
        "portuguese": "portuguese", "brasil": "portuguese", "french": "french", "francais": "french",
        "german": "german", "deutsch": "german", "italian": "italian", "italia": "italian",
        "polish": "polish", "polska": "polish", "russian": "russian", "ukrainian": "ukrainian",
        "albanian": "albanian", "greek": "greek", "romanian": "romanian", "bulgarian": "bulgarian",
        "serbian": "serbian", "croatian": "croatian", "balkan": "balkan", "exyu": "balkan", "somali": "somali",
        "african": "african", "afrikaans": "african", "chinese": "chinese", "mandarin": "chinese",
        "cantonese": "chinese", "korean": "korean", "japanese": "japanese", "filipino": "filipino",
        "pinoy": "filipino", "vietnamese": "vietnamese", "thai": "thai", "malay": "malay", "indonesian": "indonesian",
        "dutch": "dutch", "swedish": "swedish", "norwegian": "norwegian", "danish": "danish", "finnish": "finnish",
        "hebrew": "hebrew", "armenian": "armenian", "pashto": "pashto", "afghan": "pashto",
    ]

    static let countryNames: [(String, String)] = [
        ("united kingdom", "uk"), ("great britain", "uk"), ("england", "uk"), ("scotland", "uk"), ("britain", "uk"),
        ("united states", "us"), ("usa", "us"), ("america", "us"), ("australia", "au"), ("aussie", "au"),
        ("new zealand", "nz"), ("canada", "ca"), ("ireland", "ie"), ("india", "in"), ("germany", "de"),
        ("france", "fr"), ("spain", "es"), ("italy", "it"), ("portugal", "pt"), ("netherlands", "nl"),
        ("brazil", "br"), ("mexico", "mx"), ("argentina", "ar"), ("south africa", "za"), ("turkey", "tr"),
        ("poland", "pl"), ("sweden", "se"), ("norway", "no"), ("denmark", "dk"), ("finland", "fi"),
    ]

    static let knownCountries: [String] = [
        "uk", "us", "au", "nz", "ca", "ie", "de", "fr", "es", "it", "nl", "be", "pt", "br", "mx", "ar",
        "in", "pk", "za", "ae", "sa", "qa", "tr", "pl", "se", "no", "dk", "fi", "gr", "ro", "at", "ch",
        "cz", "hu", "rs", "hr", "bg", "il", "jp", "kr", "ph", "my", "sg", "id", "th", "vn", "cl", "co",
    ]
    static let countryAliases: [String: String] = ["gb": "uk", "usa": "us", "aus": "au", "can": "ca", "eng": "uk", "irl": "ie"]

    static let qualityTags: [String: String] = [
        "sd": "SD", "480p": "SD", "576p": "SD",
        "hd": "HD", "720p": "HD", "720": "HD",
        "fhd": "FHD", "1080p": "FHD", "1080": "FHD", "1080i": "FHD",
        "uhd": "UHD", "4k": "UHD", "2160p": "UHD", "8k": "UHD",
    ]
    /// Encoding/feed decorations that do not change the broadcast channel.
    static let droppedWords: Set<String> = [
        "hevc", "h265", "h264", "hdr", "raw", "vip", "backup", "alt", "multi", "audio", "direct", "orig", "original",
    ]
    static let slotWords: Set<String> = [
        "ppv", "event", "events", "live", "channel", "ch", "sport", "sports", "extra", "game", "match", "feed", "stream", "only", "24", "7",
    ]

    /// Every region a channel can carry, as a dense `UInt8` id. 0 is "none".
    enum Countries {
        static let names: [String] = {
            var names = [""] + knownCountries
            for language in Set(languages.values).sorted() { names.append(languagePrefix + language) }
            return names
        }()
        static let labels: [String] = names.map { regionLabel($0) }
        private static let idByName: [String: UInt8] = Dictionary(uniqueKeysWithValues:
            names.enumerated().map { ($1, UInt8($0)) })
        /// Packed 2–3 letter code (aliases included) -> id; 0 when unknown.
        static let byCode = PackedWordTable(
            knownCountries.map { (Words.pack($0), idByName[$0]!) }
                + countryAliases.map { (Words.pack($0.key), idByName[$0.value]!) })
        /// Packed language word -> id of its "lang-" region; 0 when unknown.
        static let byLanguageWord = PackedWordTable(
            languages.map { (Words.pack($0.key), idByName[languagePrefix + $0.value]!) })
        static func id(of country: String) -> UInt8 { idByName[country] ?? 0 }
    }

    /// Fixed vocabulary as 6-bit packed words: one integer compare per word.
    enum Words {
        static let formatNames = ["", "SD", "HD", "FHD", "UHD"]
        static let dropped: UInt8 = 8, slot: UInt8 = 16, rankMask: UInt8 = 7
        /// Case-insensitive: a-z/A-Z 1...26, 0-9 27...36, + 37, & 38, else 0.
        static let code: [UInt8] = (0..<256).map { byte -> UInt8 in
            switch UInt8(byte) {
            case UInt8(ascii: "a")...UInt8(ascii: "z"): return UInt8(byte) - UInt8(ascii: "a") + 1
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): return UInt8(byte) - UInt8(ascii: "A") + 1
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt8(byte) - UInt8(ascii: "0") + 27
            case UInt8(ascii: "+"): return 37
            case UInt8(ascii: "&"): return 38
            default: return 0
            }
        }
        /// 0 when the word is longer than 10 or holds an unpackable byte.
        static func pack(_ word: String) -> UInt64 {
            Array(word.utf8).withUnsafeBufferPointer { pack($0, 0, $0.count) }
        }
        @inline(__always)
        static func pack(_ bytes: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int) -> UInt64 {
            guard hi - lo <= 10 else { return 0 }
            var key: UInt64 = 0
            for i in lo..<hi {
                let c = code[Int(bytes[i])]
                if c == 0 { return 0 }
                key = key << 6 | UInt64(c)
            }
            return key
        }
        /// Quality rank (bits 0-2), dropped and slot flags per packed word.
        static let flags = PackedWordTable(
            qualityTags.map { (pack($0.key), formatRank($0.value)) }
                + droppedWords.map { (pack($0), dropped) } + slotWords.map { (pack($0), slot) })
        static func formatRank(_ tag: String) -> UInt8 {
            UInt8(formatNames.firstIndex(of: tag) ?? 0)
        }
    }

    /// Byte classes for the ASCII scanner, taken from the same CharacterSets
    /// the Foundation path uses so both paths agree exactly.
    enum ASCII {
        static let letter: UInt8 = 1, digit: UInt8 = 2, whitespace: UInt8 = 4, whitespaceOrNewline: UInt8 = 8
        static let punctuation: UInt8 = 16, alphanumeric: UInt8 = 32
        static let classes: [UInt8] = (0..<256).map { value -> UInt8 in
            guard value < 128, let scalar = Unicode.Scalar(value) else { return 0 }
            var c: UInt8 = 0
            if Character(scalar).isLetter { c |= letter }
            if Character(scalar).isNumber { c |= digit }
            if CharacterSet.whitespaces.contains(scalar) { c |= whitespace }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { c |= whitespaceOrNewline }
            if CharacterSet.punctuationCharacters.contains(scalar) { c |= punctuation }
            if CharacterSet.alphanumerics.contains(scalar) { c |= alphanumeric }
            return c
        }
        @inline(__always) static func lower(_ b: UInt8) -> UInt8 {
            b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z") ? b | 0x20 : b
        }
        /// Plain ASCII without CR (CRLF is one Character, two bytes).
        @inline(__always) static func isPlain(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
            for b in bytes where b >= 0x80 || b == 0x0D { return false }
            return true
        }
    }

    /// Facts derived from a group title, computed once per distinct title.
    struct GroupFacts {
        static let none: UInt8 = 0xFF
        var leadingCountry: UInt8 = none
        var namedCountry: UInt8 = none
        var language: UInt8 = none
        var category: UInt8 = 6

        struct Table {
            private var interner = ByteInterner()
            private var facts: [GroupFacts] = []

            mutating func facts(for group: String) -> GroupFacts {
                let token = group.utf8.withContiguousStorageIfAvailable { interner.intern($0) }
                    ?? Array(group.utf8).withUnsafeBufferPointer { interner.intern($0) }
                if Int(token) < facts.count { return facts[Int(token)] }
                let value = GroupFacts.compute(group)
                facts.append(value)
                return value
            }
        }

        static func compute(_ group: String) -> GroupFacts {
            let fast = group.utf8.withContiguousStorageIfAvailable { g -> GroupFacts? in
                if g.contains(where: { $0 >= 0x80 || $0 == 0x0D }) { return nil }
                var value = GroupFacts()
                let lower = g.map(ASCII.lower)
                // " " + letters-or-space + " ", as the Foundation path builds it.
                var spaced: [UInt8] = [0x20]
                spaced.reserveCapacity(g.count + 2)
                for b in lower { spaced.append(ASCII.classes[Int(b)] & ASCII.letter != 0 ? b : 0x20) }
                spaced.append(0x20)
                lower.withUnsafeBufferPointer { t in
                    if let (code, _) = Scanner.leadingCountry(t) { value.leadingCountry = code }
                    if let language = Scanner.language(t) { value.language = language }
                    value.category = Self.categoryRank(t)
                }
                spaced.withUnsafeBufferPointer { t in
                    for (pattern, code) in Self.countryPatterns where Self.contains(t, pattern) {
                        value.namedCountry = code
                        break
                    }
                }
                return value
            } ?? nil
            if let fast { return fast }
            var value = GroupFacts()
            if let (code, _) = AutoChannelGrouper.leadingCountry(in: group.lowercased()) { value.leadingCountry = Countries.id(of: code) }
            if let code = AutoChannelGrouper.countryName(in: group) { value.namedCountry = Countries.id(of: code) }
            if let language = AutoChannelGrouper.language(in: group) { value.language = Countries.id(of: languagePrefix + language) }
            value.category = UInt8(SmartChannelFilter.categories.firstIndex(of: AutoChannelGrouper.category(for: [group]))!)
            return value
        }

        private static let countryPatterns: [([UInt8], UInt8)] = countryNames.map { name, code in
            (Array(" \(name) ".utf8), Countries.id(of: code))
        }
        /// Category keywords in precedence order; index = category rank.
        private static let categoryKeywords: [[[UInt8]]] = [
            ["sport"], ["news"], ["movie", "cinema", "film"], ["kid", "child", "cartoon"], ["doc"], ["music"],
        ].map { $0.map { Array($0.utf8) } }

        private static func categoryRank(_ lower: UnsafeBufferPointer<UInt8>) -> UInt8 {
            for (rank, keywords) in categoryKeywords.enumerated() where keywords.contains(where: { contains(lower, $0) }) {
                return UInt8(rank)
            }
            return 6
        }

        private static func contains(_ text: UnsafeBufferPointer<UInt8>, _ pattern: [UInt8]) -> Bool {
            let n = text.count, m = pattern.count
            guard m <= n else { return false }
            let first = pattern[0]
            var i = 0
            while i <= n - m {
                if text[i] == first {
                    var k = 1
                    while k < m, text[i + k] == pattern[k] { k += 1 }
                    if k == m { return true }
                }
                i += 1
            }
            return false
        }
    }

    // MARK: - ASCII scanner

    /// Works on raw bytes, lowercasing on the fly; no per-row copies.
    enum Scanner {
        enum Result { case rejected, needsFoundation, parsed(country: UInt8, format: UInt8, fps: Double) }

        struct Scratch {
            var name: [UInt8] = []
            var display: [UInt8] = []
        }

        @inline(__always) private static func isSeparator(_ b: UInt8) -> Bool {
            b == UInt8(ascii: ":") || b == UInt8(ascii: "|") || b == UInt8(ascii: "-")
        }
        @inline(__always) private static func isAlpha(_ b: UInt8) -> Bool {
            let l = b | 0x20
            return l >= UInt8(ascii: "a") && l <= UInt8(ascii: "z")
        }
        @inline(__always) private static func isFPSSuffix(_ t: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int) -> Bool {
            hi - lo == 5 && ASCII.lower(t[hi - 3]) == UInt8(ascii: "f") && ASCII.lower(t[hi - 2]) == UInt8(ascii: "p")
                && ASCII.lower(t[hi - 1]) == UInt8(ascii: "s")
        }
        /// `Double(word.prefix(2))` of the lowercased word.
        @inline(__always) private static func fpsValue(_ t: UnsafeBufferPointer<UInt8>, _ lo: Int) -> Double? {
            Double(String(decoding: [ASCII.lower(t[lo]), ASCII.lower(t[lo + 1])], as: UTF8.self))
        }

        /// "UK: Sky", "AU | ESPN", "[US] ESPN": end of the prefix and its region.
        static func leadingCountry(_ t: UnsafeBufferPointer<UInt8>) -> (UInt8, Int)? {
            let n = t.count
            var i = 0
            while i < n, t[i] == 0x20 { i += 1 }
            let bracketed = i < n && (t[i] == UInt8(ascii: "[") || t[i] == UInt8(ascii: "("))
            if bracketed { i += 1 }
            let codeStart = i
            while i < n, isAlpha(t[i]) { i += 1 }
            let codeEnd = i
            guard (2...3).contains(codeEnd - codeStart) else { return nil }
            if bracketed {
                guard i < n, t[i] == UInt8(ascii: "]") || t[i] == UInt8(ascii: ")") else { return nil }
                i += 1
                while i < n, t[i] == 0x20 { i += 1 }
                if i < n, isSeparator(t[i]) { i += 1 }
            } else {
                while i < n, t[i] == 0x20 { i += 1 }
                guard i < n, isSeparator(t[i]) else { return nil }
                i += 1
            }
            while i < n, t[i] == 0x20 { i += 1 }
            let country = Countries.byCode[Words.pack(t, codeStart, codeEnd)]
            guard country != 0 else { return nil }
            return (country, i)
        }

        /// Scans a plain-ASCII channel name (already folded when it came
        /// through Foundation); the normalised name is left in `scratch.name`.
        /// `foldedFrom` is the original name when `t` is its folded form.
        static func scan(name t: UnsafeBufferPointer<UInt8>, facts: GroupFacts, guide: String?,
                         scratch: inout Scratch, foldedFrom original: String? = nil) -> Result {
            guard ASCII.isPlain(t) else { return .needsFoundation }
            let n = t.count
            var country: UInt8 = 0
            // Bytes left after removing a leading or trailing region tag.
            var words = 0..<n
            if let (code, end) = leadingCountry(t) {
                country = code; words = end..<n
            } else {
                // "Sky Sports (UK)": the trailing tag, then to the end.
                var lo = 0, hi = n
                while lo < hi, ASCII.classes[Int(t[lo])] & ASCII.whitespace != 0 { lo += 1 }
                while hi > lo, ASCII.classes[Int(t[hi - 1])] & ASCII.whitespace != 0 { hi -= 1 }
                if hi > lo, t[hi - 1] == UInt8(ascii: ")") || t[hi - 1] == UInt8(ascii: "]") {
                    var open = hi - 1
                    while open > lo, t[open - 1] != UInt8(ascii: "(") && t[open - 1] != UInt8(ascii: "[") { open -= 1 }
                    open -= 1
                    if open >= lo, (2...3).contains(hi - 2 - open), (open + 1..<hi - 1).allSatisfy({ isAlpha(t[$0]) }) {
                        let code = Countries.byCode[Words.pack(t, open + 1, hi - 1)]
                        if code != 0 { country = code; words = 0..<open }
                    }
                }
            }
            if country == 0 {
                if facts.leadingCountry != GroupFacts.none { country = facts.leadingCountry }
                else if facts.namedCountry != GroupFacts.none { country = facts.namedCountry }
                else if let guide, let code = guideCountry(guide) { country = code }
                else if facts.language != GroupFacts.none { country = facts.language }
                else if let original {
                    if let language = AutoChannelGrouper.language(in: original) {
                        country = Countries.id(of: languagePrefix + language)
                    }
                } else if let language = language(t) { country = language }
            }

            var format: UInt8 = 0
            var fps = Double.nan
            var count = 0
            var anyLetter = false, anyNumeric = false, onlySlotsOrNumbers = true
            scratch.name.removeAll(keepingCapacity: true)
            let end = words.upperBound
            var i = words.lowerBound
            while i < end {
                guard Words.code[Int(t[i])] != 0 else { i += 1; continue }
                let start = i
                var letters = false, numeric = true
                while i < end {
                    let b = t[i]
                    guard Words.code[Int(b)] != 0 else { break }
                    let c = ASCII.classes[Int(b)]
                    letters = letters || c & ASCII.letter != 0
                    numeric = numeric && c & ASCII.digit != 0
                    i += 1
                }
                let flags = Words.flags[Words.pack(t, start, i)]
                let rank = flags & Words.rankMask
                if rank != 0 {
                    if rank > format { format = rank }
                    continue
                }
                if isFPSSuffix(t, start, i), let value = fpsValue(t, start) {
                    fps = value
                    continue
                }
                if flags & Words.dropped != 0 { continue }
                anyLetter = anyLetter || letters
                anyNumeric = anyNumeric || numeric
                if !numeric && flags & Words.slot == 0 { onlySlotsOrNumbers = false }
                if count > 0 { scratch.name.append(0x20) }
                for k in start..<i { scratch.name.append(ASCII.lower(t[k])) }
                count += 1
            }
            guard count > 0, anyLetter else { return .rejected }
            // Numbered event slots ("PPV 3", "Live Event 12") differ per provider.
            if anyNumeric && onlySlotsOrNumbers { return .rejected }
            guard scratch.name.count >= 2 else { return .rejected }
            return .parsed(country: country, format: format, fps: fps)
        }

        /// Scans `name`, folding through Foundation only when it is not
        /// plain ASCII; `.needsFoundation` means even the folded text is not.
        static func scan(_ name: String, facts: GroupFacts, guide: String?, scratch: inout Scratch) -> Result {
            let direct = name.utf8.withContiguousStorageIfAvailable {
                scan(name: $0, facts: facts, guide: guide, scratch: &scratch)
            } ?? .needsFoundation
            guard case .needsFoundation = direct else { return direct }
            var folded = name.precomposedStringWithCompatibilityMapping
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            return folded.withUTF8 { scan(name: $0, facts: facts, guide: guide, scratch: &scratch, foldedFrom: name) }
        }

        /// First language word in ASCII text.
        static func language(_ name: UnsafeBufferPointer<UInt8>) -> UInt8? {
            var i = 0
            let n = name.count
            while i < n {
                guard ASCII.classes[Int(name[i])] & ASCII.letter != 0 else { i += 1; continue }
                let start = i
                while i < n, ASCII.classes[Int(name[i])] & ASCII.letter != 0 { i += 1 }
                let id = Countries.byLanguageWord[Words.pack(name, start, i)]
                if id != 0 { return id }
            }
            return nil
        }

        /// "espn.au" -> au.
        private static func guideCountry(_ guide: String) -> UInt8? {
            let result = guide.utf8.withContiguousStorageIfAvailable { g -> UInt8?? in
                guard ASCII.isPlain(g) else { return .none }
                guard let dot = g.lastIndex(of: UInt8(ascii: ".")) else { return .some(nil) }
                var lo = dot + 1, hi = g.count
                while lo < hi, ASCII.classes[Int(g[lo])] & ASCII.whitespace != 0 { lo += 1 }
                while hi > lo, ASCII.classes[Int(g[hi - 1])] & ASCII.whitespace != 0 { hi -= 1 }
                guard (2...3).contains(hi - lo), (lo..<hi).allSatisfy({ isAlpha(g[$0]) }) else { return .some(nil) }
                let code = Countries.byCode[Words.pack(g, lo, hi)]
                return .some(code == 0 ? nil : code)
            }
            if let result, let decided = result { return decided }
            // Non-ASCII or non-contiguous guide IDs: the Foundation path.
            let lower = guide.lowercased()
            guard let dot = lower.lastIndex(of: "."),
                  let code = countryCode(String(lower[lower.index(after: dot)...])) else { return nil }
            return Countries.id(of: code)
        }

        /// Guide IDs specific enough to merge differently named groups:
        /// trimmed, lowercased, at least 3 characters, not synthetic.
        static func guideToken(_ guide: String?, into interner: inout ByteInterner, scratch: inout Scratch) -> UInt32 {
            guard let guide else { return .max }
            let ascii = guide.utf8.withContiguousStorageIfAvailable { g -> Bool in
                guard ASCII.isPlain(g) else { return false }
                var lo = 0, hi = g.count
                while lo < hi, ASCII.classes[Int(g[lo])] & ASCII.whitespaceOrNewline != 0 { lo += 1 }
                while hi > lo, ASCII.classes[Int(g[hi - 1])] & ASCII.whitespaceOrNewline != 0 { hi -= 1 }
                scratch.display.removeAll(keepingCapacity: true)
                for i in lo..<hi { scratch.display.append(ASCII.lower(g[i])) }
                return true
            } ?? false
            if !ascii {
                let raw = guide.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard raw.count >= 3, !raw.hasPrefix("xtream-stream-") else { return .max }
                return Array(raw.utf8).withUnsafeBufferPointer { interner.intern($0) }
            }
            guard scratch.display.count >= 3, !scratch.display.starts(with: syntheticGuidePrefix) else { return .max }
            return scratch.display.withUnsafeBufferPointer { interner.intern($0) }
        }
        private static let syntheticGuidePrefix = Array("xtream-stream-".utf8)

        /// Original casing without region prefix or quality tags; nil when
        /// the name is not plain ASCII and Foundation must decide.
        static func displayName(_ original: UnsafeBufferPointer<UInt8>, scratch: inout Scratch) -> [UInt8]? {
            guard ASCII.isPlain(original) else { return nil }
            let n = original.count
            let start = leadingCountry(original)?.1 ?? 0
            scratch.display.removeAll(keepingCapacity: true)
            var i = start
            while i < n {
                if original[i] == 0x20 { i += 1; continue }
                let wordStart = i
                while i < n, original[i] != 0x20 { i += 1 }
                var lo = wordStart, hi = i
                while lo < hi, ASCII.classes[Int(original[lo])] & ASCII.alphanumeric == 0 { lo += 1 }
                while hi > lo, ASCII.classes[Int(original[hi - 1])] & ASCII.alphanumeric == 0 { hi -= 1 }
                guard hi > lo else { continue }
                if Words.flags[Words.pack(original, lo, hi)] & (Words.rankMask | Words.dropped) != 0 { continue }
                if isFPSSuffix(original, lo, hi), fpsValue(original, lo) != nil { continue }
                if !scratch.display.isEmpty { scratch.display.append(0x20) }
                scratch.display.append(contentsOf: UnsafeBufferPointer(rebasing: original[wordStart..<i]))
            }
            let trim = ASCII.whitespaceOrNewline | ASCII.punctuation
            var lo = 0, hi = scratch.display.count
            while lo < hi, ASCII.classes[Int(scratch.display[lo])] & trim != 0 { lo += 1 }
            while hi > lo, ASCII.classes[Int(scratch.display[hi - 1])] & trim != 0 { hi -= 1 }
            if lo == hi { return Array(original) }
            return Array(scratch.display[lo..<hi])
        }
    }

    // MARK: - Foundation path (non-ASCII names, group titles)

    static func parseFoundation(_ channel: Channel) -> Parsed? {
        var text = channel.name.precomposedStringWithCompatibilityMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var country = ""
        if let (code, range) = leadingCountry(in: text) {
            country = code
            text.removeSubrange(range)
        } else if let (code, range) = trailingCountry(in: text) {
            country = code
            text.removeSubrange(range)
        }
        if country.isEmpty, let (code, _) = leadingCountry(in: channel.group.lowercased()) {
            country = code
        }
        if country.isEmpty, let code = countryName(in: channel.group) {
            country = code
        }
        if country.isEmpty, let guide = channel.epgChannelID?.lowercased(),
           let dot = guide.lastIndex(of: "."), let code = countryCode(String(guide[guide.index(after: dot)...])) {
            country = code
        }
        if country.isEmpty, let language = language(in: channel.group) ?? language(in: channel.name) {
            country = languagePrefix + language
        }

        var format = ""
        var fps: Double?
        var words: [String] = []
        for raw in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "+" && $0 != "&" }) {
            let word = String(raw)
            if let tag = qualityTags[word] {
                if formatRank(tag) > formatRank(format) { format = tag }
                continue
            }
            if let value = frameRate(word) {
                fps = value
                continue
            }
            if droppedWords.contains(word) { continue }
            words.append(word)
        }
        guard !words.isEmpty, words.contains(where: { $0.contains(where: \.isLetter) }) else { return nil }
        if words.contains(where: { $0.allSatisfy(\.isNumber) }),
           words.allSatisfy({ $0.allSatisfy(\.isNumber) || slotWords.contains($0) }) { return nil }
        let name = words.joined(separator: " ")
        guard name.count >= 2 else { return nil }
        return Parsed(identity: .init(country: country, name: name),
                      displayName: displayNameFoundation(channel.name), format: format, fps: fps)
    }

    /// "Australia | Sports", "United Kingdom - Entertainment", "USA Sports".
    private static func countryName(in text: String) -> String? {
        let lower = " " + text.lowercased().map { $0.isLetter ? $0 : " " }.reduce(into: "") { $0.append($1) } + " "
        for (name, code) in countryNames where lower.contains(" \(name) ") { return code }
        return nil
    }

    private static func language(in text: String) -> String? {
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            if let language = languages[String(word)] { return language }
        }
        return nil
    }

    private static func displayNameFoundation(_ original: String) -> String {
        var text = original.precomposedStringWithCompatibilityMapping
        let lower = text.lowercased()
        if let (_, range) = leadingCountry(in: lower), lower.count == text.count {
            text = String(text.dropFirst(lower.distance(from: lower.startIndex, to: range.upperBound)))
        }
        let kept = text.split(separator: " ").filter { word in
            let core = word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard !core.isEmpty else { return false }
            return qualityTags[core] == nil && !droppedWords.contains(core) && frameRate(core) == nil
        }
        let joined = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return joined.isEmpty ? original : joined
    }

    /// "UK: Sky", "AU | ESPN", "CA - TSN", "[US] ESPN", "(UK) Sky".
    private static func leadingCountry(in text: String) -> (String, Range<String.Index>)? {
        var index = text.startIndex
        func skipSpaces() { while index < text.endIndex, text[index] == " " { index = text.index(after: index) } }
        func skipSeparator() -> Bool {
            guard index < text.endIndex, ":|-–".contains(text[index]) else { return false }
            index = text.index(after: index)
            return true
        }
        skipSpaces()
        let bracketed = index < text.endIndex && (text[index] == "[" || text[index] == "(")
        if bracketed { index = text.index(after: index) }
        let codeStart = index
        while index < text.endIndex, text[index].isASCII, text[index].isLetter { index = text.index(after: index) }
        let code = String(text[codeStart..<index])
        guard (2...3).contains(code.count) else { return nil }
        if bracketed {
            guard index < text.endIndex, text[index] == "]" || text[index] == ")" else { return nil }
            index = text.index(after: index)
            skipSpaces()
            _ = skipSeparator()
        } else {
            skipSpaces()
            guard skipSeparator() else { return nil }
        }
        skipSpaces()
        guard let country = countryCode(code) else { return nil }
        return (country, text.startIndex..<index)
    }

    /// "Sky Sports (UK)", "ESPN [US]".
    private static func trailingCountry(in text: String) -> (String, Range<String.Index>)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, last == ")" || last == "]",
              let open = trimmed.lastIndex(where: { $0 == "(" || $0 == "[" }) else { return nil }
        let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        guard (2...3).contains(inner.count), inner.allSatisfy({ $0.isASCII && $0.isLetter }),
              let country = countryCode(String(inner)),
              let start = text.range(of: trimmed)?.lowerBound else { return nil }
        return (country, text.index(start, offsetBy: trimmed.distance(from: trimmed.startIndex, to: open))..<text.endIndex)
    }

    /// "50fps" -> 50.
    private static func frameRate(_ word: String) -> Double? {
        guard word.count == 5, word.hasSuffix("fps") else { return nil }
        return Double(word.prefix(2))
    }

    private static func category(for groups: [String]) -> String {
        let text = groups.joined(separator: " ").lowercased()
        if text.contains("sport") { return "Sports" }
        if text.contains("news") { return "News" }
        if text.contains("movie") || text.contains("cinema") || text.contains("film") { return "Movies" }
        if text.contains("kid") || text.contains("child") || text.contains("cartoon") { return "Kids" }
        if text.contains("doc") { return "Documentary" }
        if text.contains("music") { return "Music" }
        return "Channels"
    }

    private static func nativeIDOf(_ channel: Channel) -> String {
        channel.sourceChannelIdentity?.nativeID ?? channel.id
    }

    private static func formatRank(_ tag: String) -> Int {
        ["": 0, "SD": 1, "HD": 2, "FHD": 3, "UHD": 4][tag] ?? 0
    }

    private static func countryCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let alias = countryAliases[code] { return alias }
        return knownCountries.contains(code) ? code : nil
    }
}

// MARK: - Flat containers

/// Interns byte strings into one blob; equal bytes share one `UInt32` token.
/// Open addressing over a power-of-two slot array of token+1 (0 = empty).
nonisolated struct ByteInterner: Sendable {
    private(set) var blob: [UInt8] = []
    private var offsets: [UInt32] = [0]
    private var hashes: [UInt32] = []
    private var slots: [UInt32] = Array(repeating: 0, count: 64)

    var count: Int { hashes.count }

    /// Eight bytes per multiply-mix step.
    @inline(__always) private static func hash(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var h: UInt64 = 0x9E3779B97F4A7C15 ^ UInt64(bytes.count)
        var i = 0
        let n = bytes.count
        guard let base = UnsafeRawPointer(bytes.baseAddress) else { return h }
        while i + 8 <= n {
            h = (h ^ base.loadUnaligned(fromByteOffset: i, as: UInt64.self)) &* 0xFF51AFD7ED558CCD
            h ^= h >> 32
            i += 8
        }
        if i < n {
            var tail: UInt64 = 0
            for k in i..<n { tail |= UInt64(bytes[k]) << UInt64((k - i) * 8) }
            h = (h ^ tail) &* 0xC4CEB9FE1A85EC53
        }
        h ^= h >> 29
        h = h &* 0xBF58476D1CE4E5B9
        return h ^ (h >> 32)
    }

    mutating func intern(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        let h = Self.hash(bytes)
        let tag = UInt32(truncatingIfNeeded: h >> 32)
        let mask = slots.count - 1
        var slot = Int(truncatingIfNeeded: h) & mask
        while true {
            let entry = slots[slot]
            if entry == 0 { break }
            let token = Int(entry - 1)
            if hashes[token] == tag, equal(token, bytes) { return UInt32(token) }
            slot = (slot + 1) & mask
        }
        let token = UInt32(hashes.count)
        blob.append(contentsOf: bytes)
        offsets.append(UInt32(blob.count))
        hashes.append(tag)
        if hashes.count * 2 > slots.count {
            grow()   // rehashes every token, the new one included
            return token
        }
        slots[slot] = token + 1
        return token
    }

    func find(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32? {
        let h = Self.hash(bytes)
        let tag = UInt32(truncatingIfNeeded: h >> 32)
        let mask = slots.count - 1
        var slot = Int(truncatingIfNeeded: h) & mask
        while slots[slot] != 0 {
            let token = Int(slots[slot] - 1)
            if hashes[token] == tag, equal(token, bytes) { return UInt32(token) }
            slot = (slot + 1) & mask
        }
        return nil
    }

    private func equal(_ token: Int, _ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let lo = Int(offsets[token]), hi = Int(offsets[token + 1])
        guard hi - lo == bytes.count else { return false }
        if bytes.isEmpty { return true }
        return blob.withUnsafeBufferPointer { blob in
            memcmp(blob.baseAddress! + lo, bytes.baseAddress!, bytes.count) == 0
        }
    }

    private mutating func grow() {
        var next = [UInt32](repeating: 0, count: slots.count * 2)
        let mask = next.count - 1
        for token in 0..<hashes.count {
            let h = blob.withUnsafeBufferPointer { blob in
                Self.hash(UnsafeBufferPointer(rebasing: blob[Int(offsets[token])..<Int(offsets[token + 1])]))
            }
            var slot = Int(truncatingIfNeeded: h) & mask
            while next[slot] != 0 { slot = (slot + 1) & mask }
            next[slot] = UInt32(token + 1)
        }
        slots = next
    }

    func bytes(_ token: UInt32) -> ArraySlice<UInt8> {
        blob[Int(offsets[Int(token)])..<Int(offsets[Int(token) + 1])]
    }

    func string(_ token: UInt32) -> String { String(decoding: bytes(token), as: UTF8.self) }

    /// The token with spaces as dashes, for feed IDs.
    func dashed(_ token: UInt32) -> String {
        let slice = bytes(token)
        if slice.allSatisfy({ $0 < 0x80 }) {
            return String(decoding: slice.map { $0 == 0x20 ? UInt8(ascii: "-") : $0 }, as: UTF8.self)
        }
        return string(token).replacingOccurrences(of: " ", with: "-")
    }

    /// Orders tokens as `String` comparison orders their text.
    func compare(_ lhs: UInt32, _ rhs: UInt32) -> Int {
        let l = bytes(lhs), r = bytes(rhs)
        if l.allSatisfy({ $0 < 0x80 }) && r.allSatisfy({ $0 < 0x80 }) {
            return l.lexicographicallyPrecedes(r) ? -1 : (l == r ? 0 : 1)
        }
        let ls = string(lhs), rs = string(rhs)
        return ls < rs ? -1 : (ls == rs ? 0 : 1)
    }
}

/// Fixed vocabulary lookup: packed word -> small value, 0 when absent.
/// Static open addressing over 256 slots; packed keys are never 0.
nonisolated struct PackedWordTable: Sendable {
    private var keys = [UInt64](repeating: 0, count: 256)
    private var values = [UInt8](repeating: 0, count: 256)

    /// Entries with the same key OR their values together.
    init(_ entries: [(UInt64, UInt8)]) {
        precondition(entries.count < 128)
        for (key, value) in entries where key != 0 {
            var slot = Self.slot(key)
            while keys[slot] != 0 && keys[slot] != key { slot = (slot + 1) & 255 }
            keys[slot] = key
            values[slot] |= value
        }
    }

    @inline(__always) private static func slot(_ key: UInt64) -> Int {
        Int(truncatingIfNeeded: (key &* 0x9E3779B97F4A7C15) >> 56)
    }

    @inline(__always) subscript(_ key: UInt64) -> UInt8 {
        guard key != 0 else { return 0 }
        var slot = Self.slot(key)
        while true {
            let k = keys[slot]
            if k == key { return values[slot] }
            if k == 0 { return 0 }
            slot = (slot + 1) & 255
        }
    }
}

/// Open-addressing `UInt64 -> UInt32` map over flat key/value columns.
nonisolated struct UInt64Map: Sendable {
    private var keys: [UInt64]
    private var values: [UInt32]
    private var used: Int = 0
    private static let empty = UInt64.max

    init(capacity: Int = 16) {
        var size = 16
        while size < capacity * 2 { size <<= 1 }
        keys = Array(repeating: Self.empty, count: size)
        values = Array(repeating: 0, count: size)
    }

    @inline(__always) private static func slot(_ key: UInt64, _ mask: Int) -> Int {
        var h = key &* 0x9E3779B97F4A7C15
        h ^= h >> 32
        return Int(truncatingIfNeeded: h) & mask
    }

    func find(_ key: UInt64) -> UInt32? {
        let mask = keys.count - 1
        var slot = Self.slot(key, mask)
        while keys[slot] != Self.empty {
            if keys[slot] == key { return values[slot] }
            slot = (slot + 1) & mask
        }
        return nil
    }

    /// Returns the existing value, or stores `next` and calls `inserted`.
    @inline(__always)
    mutating func insert(_ key: UInt64, next: UInt32, inserted: (UInt32) -> Void) -> UInt32 {
        var mask = keys.count - 1
        var slot = Self.slot(key, mask)
        while keys[slot] != Self.empty {
            if keys[slot] == key { return values[slot] }
            slot = (slot + 1) & mask
        }
        if (used + 1) * 2 > keys.count {
            grow()
            mask = keys.count - 1
            slot = Self.slot(key, mask)
            while keys[slot] != Self.empty { slot = (slot + 1) & mask }
        }
        keys[slot] = key
        values[slot] = next
        used += 1
        inserted(next)
        return next
    }

    private mutating func grow() {
        let oldKeys = keys, oldValues = values
        keys = Array(repeating: Self.empty, count: oldKeys.count * 2)
        values = Array(repeating: 0, count: oldKeys.count * 2)
        let mask = keys.count - 1
        for i in 0..<oldKeys.count where oldKeys[i] != Self.empty {
            var slot = Self.slot(oldKeys[i], mask)
            while keys[slot] != Self.empty { slot = (slot + 1) & mask }
            keys[slot] = oldKeys[i]
            values[slot] = oldValues[i]
        }
    }
}

/// Fixed-size bitset over `UInt64` words.
nonisolated struct Bitset: Equatable, Sendable {
    private(set) var words: [UInt64]
    let count: Int

    init(count: Int = 0) {
        self.count = count
        words = Array(repeating: 0, count: (count + 63) >> 6)
    }

    @inline(__always) func contains(_ i: Int) -> Bool { words[i >> 6] & (1 << UInt64(i & 63)) != 0 }
    @inline(__always) mutating func insert(_ i: Int) { words[i >> 6] |= 1 << UInt64(i & 63) }
    @inline(__always) mutating func remove(_ i: Int) { words[i >> 6] &= ~(1 << UInt64(i & 63)) }
    var popcount: Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }

    static func & (lhs: Bitset, rhs: Bitset) -> Bitset {
        var result = lhs
        for i in 0..<min(lhs.words.count, rhs.words.count) { result.words[i] &= rhs.words[i] }
        return result
    }

    static func | (lhs: Bitset, rhs: Bitset) -> Bitset {
        var result = lhs
        for i in 0..<min(lhs.words.count, rhs.words.count) { result.words[i] |= rhs.words[i] }
        return result
    }
}
