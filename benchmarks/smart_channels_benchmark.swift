import Foundation

// Smart Channels rebuild benchmark: 3 accounts x 20k live channels.
//   1. full automatic discovery under a region filter
//   2. filter toggle (regroup under a different filter)
//   3. reconcile + per-feed selection (what the coordinator's rebuild runs)
//   4. probe-result ranking for 600 measured variants
// When compiled with benchmarks/legacy_auto_channel_grouper.swift and
// -D LEGACY_ORACLE, every discovery result is also compared field by field
// with the frozen pre-rewrite grouper.

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
}

enum Dataset {
    static let regions: [(code: String, country: String, language: String?)] = [
        ("UK", "United Kingdom", nil), ("US", "USA", nil), ("CA", "Canada", nil), ("AU", "Australia", nil),
        ("DE", "Germany", "German"), ("FR", "France", "French"), ("ES", "Spain", "Spanish"), ("IT", "Italy", "Italian"),
        ("IN", "India", "Hindi"), ("NL", "Netherlands", "Dutch"), ("PL", "Poland", "Polish"), ("TR", "Turkey", "Turkish"),
        ("", "", "Arabic"), ("", "", "Portuguese"), ("BR", "Brazil", nil), ("MX", "Mexico", nil),
    ]
    static let brands = ["Sky", "BBC", "ITV", "ESPN", "Fox", "TSN", "Sportsnet", "beIN", "Eurosport", "DAZN",
        "Canal", "Rai", "Mediaset", "Star", "Sony", "Zee", "Colors", "Nickelodeon", "Disney", "Cartoon",
        "Discovery", "National Geographic", "History", "CNN", "Al Jazeera", "Bloomberg", "MTV", "VH1",
        "Comedy Central", "AMC", "HBO", "Showtime", "Cinemax", "TNT", "TBS", "USA Network", "Bravo", "E!",
        "Optus", "Kayo", "Stan", "Seven", "Nine", "Ten", "SBS", "Polsat", "TVP", "RTL", "Pro7", "Sat1",
        "TF1", "M6", "Antena", "Movistar", "Telemundo", "Univision", "Globo", "SporTV", "Premiere", "Arena"]
    static let kinds = ["Sports", "News", "Movies", "Kids", "Docs", "Music", "One", "Two", "Plus", "Max",
        "Action", "Comedy", "Drama", "Family", "Classic", "Gold", "Premier League", "Cricket", "Football",
        "Golf", "Racing", "Tennis", "Arena", "Extra", "Life", "World", "Cinema", "Junior", "Xtra", "Hits"]
    static let groups = ["Sports", "News", "Movies", "Kids", "Documentary", "Music", "Entertainment", "General"]
    static let tags = ["", "", "", " HD", " FHD", " UHD", " 4K", " SD", " HEVC", " 50fps", " 1080p", " HD Raw"]

    struct Base { let region: Int; let name: String; let group: String; let guide: String? }

    /// ~26k distinct broadcasts; each account carries ~20k with its own naming.
    static func bases(_ rng: inout SplitMix64) -> [Base] {
        var bases: [Base] = []
        var seen = Set<String>()
        while bases.count < 26_000 {
            let region = rng.int(regions.count)
            var name = brands[rng.int(brands.count)] + " " + kinds[rng.int(kinds.count)]
            if rng.chance(0.55) { name += " \(1 + rng.int(12))" }
            guard seen.insert("\(region)|\(name)").inserted else { continue }
            let group = groups[rng.int(groups.count)]
            let code = regions[region].code.lowercased()
            let guide: String? = rng.chance(0.6)
                ? name.lowercased().replacingOccurrences(of: " ", with: "") + (code.isEmpty ? "" : "." + code)
                : nil
            bases.append(.init(region: region, name: name, group: group, guide: guide))
        }
        return bases
    }

    static func account(_ index: Int, bases: [Base], rng: inout SplitMix64) -> SmartSportsSourceSnapshot {
        let sourceID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
        var channels: [Channel] = []
        channels.reserveCapacity(20_000)
        var nextID = 0
        for base in bases where channels.count < 20_000 {
            guard rng.chance(0.77) else { continue }
            let region = regions[base.region]
            let tag = tags[rng.int(tags.count)]
            var name: String
            var group: String
            switch (index + rng.int(3)) % 3 {
            case 0:
                name = region.code.isEmpty ? base.name + tag : "\(region.code): \(base.name)\(tag)"
                group = region.code.isEmpty ? "\(region.language!) | \(base.group)" : "\(region.code) | \(base.group)"
            case 1:
                name = base.name + tag
                group = region.country.isEmpty ? "\(region.language!) \(base.group)" : "\(region.country) - \(base.group)"
            default:
                name = region.code.isEmpty ? base.name + tag : "[\(region.code)] \(base.name)\(tag)"
                group = base.group
            }
            nextID += 1
            // Real lists carry accents, superscript tags, odd whitespace.
            switch rng.int(60) {
            case 0: name = name.replacingOccurrences(of: "e", with: "é")
            case 1: name += " ᴴᴰ"
            case 2: group = "Deportes España | " + group
            case 3: name = "  " + name + " \t"
            case 4: name = name.lowercased() + " (" + (region.code.isEmpty ? "xx" : region.code.lowercased()) + ")"
            case 5: name = "Ü " + name
            default: break
            }
            let guide = base.guide.map { rng.chance(0.15) ? $0.uppercased() : (rng.chance(0.02) ? " \($0)é " : $0) }
                ?? (rng.chance(0.3) ? "xtream-stream-\(nextID)" : nil)
            channels.append(Channel(id: "\(index)-\(nextID)", name: name, logoURL: nil, group: group,
                streamURL: URL(string: "http://provider\(index).test/live/u/p/\(nextID).ts")!, epgChannelID: guide))
        }
        // Event slots and VOD rows a real list also carries.
        for slot in 0..<300 {
            nextID += 1
            channels.append(Channel(id: "\(index)-\(nextID)", name: "PPV \(slot)", logoURL: nil, group: "PPV Events",
                streamURL: URL(string: "http://provider\(index).test/live/u/p/\(nextID).ts")!, epgChannelID: nil))
        }
        return .init(sourceID: sourceID, sourceName: "Account \(index + 1)", channels: channels)
    }
}

func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

func measure(_ label: String, runs: Int = 7, _ body: () -> Int) -> Double {
    var times: [Double] = []
    var sink = 0
    for _ in 0..<runs {
        let start = ContinuousClock.now
        sink &+= body()
        let elapsed = ContinuousClock.now - start
        times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
    }
    let m = median(times)
    print(String(format: "%-46@ median %9.2f ms  (min %.2f, max %.2f)  [%d]", label as NSString, m,
                 times.min()!, times.max()!, sink % 1000))
    return m
}

@main struct SmartChannelsBenchmark {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        var rng = SplitMix64(state: 42)
        let bases = Dataset.bases(&rng)
        let snapshots = (0..<3).map { Dataset.account($0, bases: bases, rng: &rng) }
        print("channels:", snapshots.map(\.channels.count))

        var regionFilter = SmartChannelFilter(isEnabled: true)
        regionFilter.regions = ["UK": .everything, "US": .sportsOnly, "AU": .categories(["Sports", "News"])]
        regionFilter.alwaysInclude = ["Kids"]
        var toggled = regionFilter
        toggled.regions["CA"] = .everything
        toggled.regions["Arabic"] = .sportsOnly

        #if LEGACY_ORACLE
        verify(snapshots, filter: SmartChannelFilter())
        verify(snapshots, filter: regionFilter)
        verify(snapshots, filter: toggled)
        let curated = Set(snapshots[0].channels.prefix(400).map {
            SmartSportsEndpointKey(sourceID: snapshots[0].sourceID, nativeID: $0.id) })
        verify(snapshots, filter: SmartChannelFilter(), curated: curated)
        verify(Array(snapshots.reversed()), filter: regionFilter)
        print("PASS equivalence with legacy grouper on 60k-channel dataset (unfiltered, region filter, toggled filter, curated, reversed order)")
        #endif

        _ = measure("discovery: unfiltered (min 2 sources)") {
            AutoChannelGrouper.analyze(snapshots).feeds.count
        }
        let discovery = measure("discovery: region filter") {
            AutoChannelGrouper.analyze(snapshots, filter: regionFilter).feeds.count
        }
        #if !LEGACY_BASELINE
        _ = measure("  index build only") { AutoChannelGrouper.GroupIndex(snapshots).groupCount }
        let built = AutoChannelGrouper.GroupIndex(snapshots)
        _ = measure("  bitset filter + feed materialise only") {
            built.feeds(excluding: [], minimumSources: 2, filter: toggled).count
        }
        _ = measure("  parse only (60k)") {
            var n = 0
            for snapshot in snapshots { for c in snapshot.channels where AutoChannelGrouper.parse(c) != nil { n += 1 } }
            return n
        }
        #endif
        let toggle = measure("filter toggle: regroup under new filter") {
            AutoChannelGrouper.analyze(snapshots, filter: toggled).feeds.count
        }

        // Coordinator rebuild hot path: reconcile, then select per feed.
        let feeds = AutoChannelGrouper.analyze(snapshots, filter: regionFilter).feeds
        let definition = SmartSportsDefinition(schemaVersion: 1, playlistID: "smart:sports:v1", name: "Smart Channels",
            provenance: "bench", feeds: feeds, heldEndpoints: [])
        let stamped = snapshots.map { snapshot in
            SmartSportsSourceSnapshot(sourceID: snapshot.sourceID, sourceName: snapshot.sourceName,
                channels: snapshot.channels.map { stamp($0, sourceID: snapshot.sourceID) })
        }
        print("feeds under region filter:", feeds.count, "variants:", feeds.reduce(0) { $0 + $1.variants.count })

        // 600 measured variants with endpoint-bound observations.
        var observations: [SmartSportsEndpointKey: SmartSportsObservation] = [:]
        var channelByKey: [SmartSportsEndpointKey: Channel] = [:]
        for snapshot in stamped { for c in snapshot.channels { channelByKey[c.sourceChannelIdentity!] = c } }
        var probeRNG = SplitMix64(state: 7)
        let now = Date()
        let measuredFeeds = feeds.filter { $0.variants.count >= 2 }.prefix(300)
        for feed in measuredFeeds {
            for variant in feed.variants where observations.count < 600 {
                guard let channel = channelByKey[variant.key] else { continue }
                var o = SmartSportsObservation(observedAt: now.addingTimeInterval(-Double(probeRNG.int(3600))),
                                               provenance: .formatProbe)
                o.endpointFingerprint = SmartSportsCatalog.endpointFingerprint(for: channel)
                o.height = [576, 720, 1080, 2160][probeRNG.int(4)]
                o.width = o.height! * 16 / 9
                o.fps = [25, 30, 50, 60][probeRNG.int(4)]
                o.bitRate = Int64(1_000_000 + probeRNG.int(15_000_000))
                o.liveDelaySeconds = Double(probeRNG.int(30))
                o.startupSeconds = Double(probeRNG.int(4000)) / 1000
                observations[variant.key] = o
            }
        }
        print("measured variants:", observations.count)
        var overrides = SmartSportsOverrides()
        for feed in measuredFeeds.prefix(40) { overrides.preferredVariants[feed.id] = feed.variants.last!.key.rawValue }

        let reconcile = measure("reconcile catalog (600 observations)") {
            definition.reconcile(snapshots: stamped, overrides: overrides, observations: observations).feeds.count
        }
        let catalog = definition.reconcile(snapshots: stamped, overrides: overrides, observations: observations)
        let selectAll = measure("select every feed (rebuild display pass)") {
            var n = 0
            for feed in catalog.feeds where catalog.selection(for: feed.id) != nil { n += 1 }
            return n
        }
        let measuredIDs = measuredFeeds.map(\.id)
        let ranking = measure("probe ranking: 600 variants / \(measuredIDs.count) feeds") {
            var n = 0
            for id in measuredIDs { n &+= catalog.selection(for: id)?.alternatives.count ?? 0 }
            return n
        }
        print(String(format: "TOTAL rebuild (discovery+reconcile+select): %.2f ms; toggle %.2f ms; ranking %.2f ms",
                     discovery + reconcile + selectAll, toggle, ranking))
    }

    static func stamp(_ channel: Channel, sourceID: UUID) -> Channel {
        Channel(id: channel.id, name: channel.name, logoURL: channel.logoURL, group: channel.group,
                streamURL: channel.streamURL, epgChannelID: channel.epgChannelID, catchup: channel.catchup,
                contentType: channel.contentType,
                sourceOwnership: .init(channelIdentity: .init(sourceID: sourceID, nativeID: channel.id),
                                       accountKey: .unconfiguredSource(sourceID),
                                       guideBinding: channel.epgChannelID.map { .init(sourceID: sourceID, epgChannelID: $0) }))
    }

    #if LEGACY_ORACLE
    /// Strict field-by-field equality, except where the legacy grouper was
    /// itself order-dependent: when guide-ID merges chain three or more
    /// identities, the surviving identity (feed ID, region) depended on
    /// Dictionary iteration order. The member partition must still match.
    static func verify(_ snapshots: [SmartSportsSourceSnapshot], filter: SmartChannelFilter,
                       curated: Set<SmartSportsEndpointKey> = []) {
        let new = AutoChannelGrouper.analyze(snapshots, excluding: curated, filter: filter)
        let old = LegacyAutoChannelGrouper.analyze(snapshots, excluding: curated, filter: filter)
        func members(_ feed: SmartSportsFeedDefinition) -> String {
            feed.variants.map { "\($0.sourceID)|\($0.nativeID)" }.sorted().joined(separator: ",")
        }
        func chained(_ feed: SmartSportsFeedDefinition) -> Bool {
            // Three or more identities chain, or two same-named identities
            // tie on (size, name), which legacy ordered by hash seed.
            let identities = Set(feed.variants.compactMap { v in
                LegacyAutoChannelGrouper.parse(Channel(id: "x", name: v.identity.name, logoURL: nil, group: v.identity.group,
                    streamURL: URL(string: "http://x")!, epgChannelID: v.identity.epgChannelID))?.identity })
            return identities.count >= 3 || Set(identities.map(\.name)).count < identities.count
        }
        let oldByMembers = Dictionary(old.feeds.map { (members($0), $0) }, uniquingKeysWith: { a, _ in a })
        let newByMembers = Dictionary(new.feeds.map { (members($0), $0) }, uniquingKeysWith: { a, _ in a })
        var tolerated = 0
        for n in new.feeds {
            guard let o = oldByMembers[members(n)] else {
                precondition(chained(n), "new-only feed \(n.id) \(n.variants.map(\.identity.name))")
                tolerated += 1; continue
            }
            precondition(n.name == o.name && n.edition == o.edition && n.language == o.language
                && n.guideStatus == o.guideStatus && n.caveats == o.caveats, "feed mismatch \(n.id) vs \(o.id)")
            if n.id != o.id || n.country != o.country {
                precondition(chained(n), "id mismatch \(n.id) vs \(o.id)")
                tolerated += 1
            }
            let nv = n.variants.map { "\($0.sourceID)|\($0.nativeID)|\($0.sourceName)|\($0.advertisedFormat)|\(String(describing: $0.advertisedFPS))|\($0.identity)" }
            let ov = o.variants.map { "\($0.sourceID)|\($0.nativeID)|\($0.sourceName)|\($0.advertisedFormat)|\(String(describing: $0.advertisedFPS))|\($0.identity)" }
            precondition(nv.sorted() == ov.sorted(), "variants differ for \(n.id)")
        }
        for o in old.feeds where newByMembers[members(o)] == nil {
            precondition(chained(o), "old-only feed \(o.id) \(o.variants.map(\.identity.name))")
            tolerated += 1
        }
        precondition(new.feeds.map(\.id) == new.feeds.map(\.id).sorted(), "feeds not sorted by id")
        let ni = Dictionary(uniqueKeysWithValues: new.inventory.map { ($0.region, $0.categoryCounts) })
        let oi = Dictionary(uniqueKeysWithValues: old.inventory.map { ($0.region, $0.categoryCounts) })
        precondition(ni == oi, "inventory counts differ")
        // Every parsed identity of every channel agrees too.
        var parseChecked = 0
        for snapshot in snapshots { for c in snapshot.channels {
            let a = AutoChannelGrouper.parse(c), b = LegacyAutoChannelGrouper.parse(c)
            precondition(a?.identity.country == b?.identity.country && a?.identity.name == b?.identity.name
                && a?.displayName == b?.displayName && a?.format == b?.format && a?.fps == b?.fps,
                "parse differs for \(c.name) | \(c.group): \(String(describing: a)) vs \(String(describing: b))")
            parseChecked += 1
        } }
        print("  verified \(new.feeds.count) feeds (\(tolerated) legacy order-dependent chain merges), \(parseChecked) parses")
    }
    #endif
}
