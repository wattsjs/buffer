import Foundation

@main struct AutoChannelGrouperTests {
    static func main() {
        let a = UUID(), b = UUID(), c = UUID()
        func ch(_ id: String, _ name: String, group: String = "Sports", guide: String? = nil) -> Channel {
            Channel(id: id, name: name, logoURL: nil, group: group,
                    streamURL: URL(string: "http://127.0.0.1/\(id)")!, epgChannelID: guide)
        }
        func parsed(_ name: String, group: String = "Entertainment", guide: String? = nil) -> AutoChannelGrouper.Parsed? {
            AutoChannelGrouper.parse(ch("x", name, group: group, guide: guide))
        }

        // Region prefixes, quality tags, encodings and superscripts normalise away.
        let sky = parsed("UK: Sky Sports Main Event FHD")
        precondition(sky?.identity == .init(country: "uk", name: "sky sports main event"))
        precondition(sky?.format == "FHD" && sky?.displayName == "Sky Sports Main Event")
        precondition(parsed("[UK] Sky Sports Main Event ᴴᴰ")?.identity == sky?.identity)
        precondition(parsed("Sky Sports Main Event HEVC 50fps", group: "UK | Sports")?.identity == sky?.identity)
        precondition(parsed("Sky Sports Main Event 50fps", group: "UK | Sports")?.fps == 50)
        precondition(parsed("Sky Sports Main Event (UK)")?.identity == sky?.identity)
        precondition(parsed("ESPN", guide: "ESPN.au")?.identity == .init(country: "au", name: "espn"))
        // Distinct channels stay distinct.
        precondition(parsed("UK: Sky Sports Main Event")?.identity != parsed("UK: Sky Sports Premier League")?.identity)
        precondition(parsed("UK: Sky Sports Main Event")?.identity != parsed("US: Sky Sports Main Event")?.identity)
        precondition(parsed("UK: Channel 4")?.identity != parsed("UK: Channel 4 +1")?.identity, "Timeshift merged with live")
        // Provider-specific numbered event slots never merge.
        precondition(parsed("PPV 3") == nil && parsed("UK: Live Event 12") == nil && parsed("Sports 24/7 1") == nil)
        precondition(parsed("BT Sport 1") != nil && parsed("ESPN 2") != nil, "Numbered networks were treated as slots")

        let snapshots = [
            SmartSportsSourceSnapshot(sourceID: a, sourceName: "A", channels: [
                ch("a1", "UK: Sky Sports Main Event FHD"), ch("a2", "UK: BBC One HD", group: "UK | Entertainment"),
                ch("a3", "PPV 1"), ch("a4", "UK: Only Here"),
            ]),
            SmartSportsSourceSnapshot(sourceID: b, sourceName: "B", channels: [
                ch("b1", "Sky Sports Main Event UHD", group: "UK | Sports"), ch("b2", "BBC One", group: "UK | Entertainment"),
                ch("b3", "PPV 1"),
            ]),
            SmartSportsSourceSnapshot(sourceID: c, sourceName: "C", channels: [
                ch("c1", "Sky Sports Main Event"), // no region: joins the single UK feed
            ]),
        ]
        let feeds = AutoChannelGrouper.feeds(from: snapshots)
        let byName = Dictionary(uniqueKeysWithValues: feeds.map { ($0.name, $0) })
        // "UK: Only Here" is a sports channel on one account: kept. PPV is not.
        precondition(feeds.count == 3 && byName["Only Here"]?.variants.count == 1,
                     "Expected Sky, BBC and single-source sport, got \(feeds.map(\.name))")
        precondition(byName["Sky Sports Main Event"]?.variants.count == 3)
        precondition(byName["Sky Sports Main Event"]?.edition == "Sports" && byName["BBC One"]?.edition == "Entertainment" || byName["BBC One"]?.edition == "Channels")
        precondition(feeds.allSatisfy { AutoChannelGrouper.isAutomatic(feedID: $0.id) && $0.country == "UK" })
        // Stable identity across refreshes.
        precondition(AutoChannelGrouper.feeds(from: snapshots.reversed()).map(\.id) == feeds.map(\.id))
        // Curated endpoints keep their curated feed.
        let curated: Set<SmartSportsEndpointKey> = [.init(sourceID: a, nativeID: "a1")]
        precondition(!AutoChannelGrouper.feeds(from: snapshots, excluding: curated).contains { $0.name == "Sky Sports Main Event" })
        // Country names in group titles set the region.
        precondition(parsed("ESPN", group: "Australia | Sports")?.identity.country == "au")
        precondition(parsed("Sky One", group: "United Kingdom - Entertainment")?.identity.country == "uk")
        precondition(parsed("TSN 1", group: "Canada Sports")?.identity.country == "ca")

        // Differently named channels sharing a specific guide ID merge;
        // synthetic per-stream IDs never do.
        let merged = AutoChannelGrouper.feeds(from: [
            SmartSportsSourceSnapshot(sourceID: a, sourceName: "A", channels: [
                ch("m1", "AU: Fox Sports 501", group: "AU | Sports", guide: "FoxSports501.au"),
                ch("m3", "AU: Channel X", group: "AU | Sports", guide: "xtream-stream-1")]),
            SmartSportsSourceSnapshot(sourceID: b, sourceName: "B", channels: [
                ch("m2", "Fox Sports 501 Cricket", group: "Australia | Sports", guide: "foxsports501.au"),
                ch("m4", "AU: Channel Y", group: "AU | Sports", guide: "xtream-stream-1")]),
        ])
        precondition(merged.contains { $0.variants.count == 2 && Set($0.variants.map(\.nativeID)) == ["m1", "m2"] },
                     "Shared guide ID did not merge: \(merged.map { ($0.name, $0.variants.count) })")
        precondition(!merged.contains { Set($0.variants.map(\.nativeID)) == ["m3", "m4"] }, "Synthetic guide IDs merged")

        // Language-only labels become their own switchable region.
        precondition(AutoChannelGrouper.regionLabel(parsed("beIN Sports 1", group: "Arabic | Sports")!.identity.country) == "Arabic")
        precondition(AutoChannelGrouper.regionLabel(parsed("Some Channel", group: "Misc")!.identity.country) == SmartChannelFilter.unknownRegion)

        // Filter: US sport only, UK everything, Kids from anywhere. Allowed
        // single-source channels appear; everything else is dropped.
        var filter = SmartChannelFilter(isEnabled: true)
        filter.regions = ["US": .sportsOnly, "UK": .everything]
        filter.alwaysInclude = ["Kids"]
        let filtered = AutoChannelGrouper.analyze([
            SmartSportsSourceSnapshot(sourceID: a, sourceName: "A", channels: [
                ch("f1", "US: ESPN", group: "US | Sports"), ch("f2", "US: CNN", group: "US | News"),
                ch("f3", "UK: BBC One", group: "UK | Entertainment"), ch("f4", "FR: TF1", group: "FR | General"),
                ch("f5", "DE: KiKA", group: "DE | Kids"), ch("f6", "beIN 1", group: "Arabic | Sports"),
            ]),
        ], filter: filter)
        let names = Set(filtered.feeds.map(\.name))
        precondition(names == ["ESPN", "BBC One", "KiKA"], "Filter kept \(names)")
        let inventory = Dictionary(uniqueKeysWithValues: filtered.inventory.map { ($0.region, $0) })
        precondition(inventory["US"]?.categoryCounts["Sports"] == 1 && inventory["US"]?.categoryCounts["News"] == 1
            && inventory["Arabic"]?.total == 1 && inventory["FR"]?.total == 1, "Inventory miscounted")
        precondition(!SmartChannelFilter(isEnabled: true).allows(region: "US", category: "Sports"), "Unlisted region allowed")
        precondition(SmartChannelFilter().allows(region: "FR", category: "News"), "Disabled filter rejected")

        // Flat containers behind the grouper.
        var interner = ByteInterner()
        func intern(_ text: String) -> UInt32 { Array(text.utf8).withUnsafeBufferPointer { interner.intern($0) } }
        let skyToken = intern("sky sports"), emptyToken = intern("")
        precondition(intern("sky sports") == skyToken && intern("") == emptyToken && skyToken != emptyToken)
        var tokens: [UInt32] = []
        for i in 0..<5_000 { tokens.append(intern("name \(i)")) }
        precondition(Set(tokens).count == 5_000 && interner.count == 5_002, "Interner grew without collisions")
        for i in stride(from: 0, to: 5_000, by: 97) { precondition(intern("name \(i)") == tokens[i] && interner.string(tokens[i]) == "name \(i)") }
        precondition(Array("name 7".utf8).withUnsafeBufferPointer { interner.find($0) } == tokens[7])
        precondition(Array("absent".utf8).withUnsafeBufferPointer { interner.find($0) } == nil)
        precondition(interner.dashed(skyToken) == "sky-sports")
        let (aToken, bToken, accented, plain) = (intern("a"), intern("b"), intern("é"), intern("e"))
        precondition(interner.compare(aToken, bToken) < 0 && interner.compare(accented, plain) > 0
            && interner.compare(aToken, aToken) == 0, "Token order follows String order")

        var map = UInt64Map(capacity: 4)
        var inserted = 0
        for key in 0..<10_000 as Range<UInt64> {
            precondition(map.insert(key &* 0x9E37_79B9, next: UInt32(key)) { _ in inserted += 1 } == UInt32(key))
        }
        precondition(inserted == 10_000 && map.insert(5 &* 0x9E37_79B9, next: 99) { _ in inserted += 1 } == 5 && inserted == 10_000)
        precondition(map.find(42 &* 0x9E37_79B9) == 42 && map.find(UInt64(1) << 60) == nil)

        var evens = Bitset(count: 200), low = Bitset(count: 200)
        for i in stride(from: 0, to: 200, by: 2) { evens.insert(i) }
        for i in 0..<64 { low.insert(i) }
        precondition(evens.popcount == 100 && (evens & low).popcount == 32 && (evens | low).popcount == 132)
        evens.remove(198)
        precondition(!evens.contains(198) && evens.contains(196) && !evens.contains(199))

        let table = PackedWordTable([(AutoChannelGrouper.Words.pack("hd"), 2), (AutoChannelGrouper.Words.pack("hd"), 8),
                                     (AutoChannelGrouper.Words.pack("raw"), 8)])
        precondition(table[AutoChannelGrouper.Words.pack("hd")] == 10 && table[AutoChannelGrouper.Words.pack("raw")] == 8
            && table[AutoChannelGrouper.Words.pack("sd")] == 0 && table[0] == 0, "Packed vocabulary ORs and misses")
        precondition(AutoChannelGrouper.Words.pack("HD") == AutoChannelGrouper.Words.pack("hd")
            && AutoChannelGrouper.Words.pack("abcdefghijk") == 0 && AutoChannelGrouper.Words.pack("a.b") == 0,
            "Packing is case-insensitive and rejects long or foreign words")

        // The filter-independent index answers several filters.
        let index = AutoChannelGrouper.GroupIndex(snapshots)
        precondition(index.feeds(excluding: [], minimumSources: 2, filter: .init()).map(\.id) == feeds.map(\.id))
        var ukOnly = SmartChannelFilter(isEnabled: true)
        ukOnly.regions = ["UK": .categories(["Sports"])]
        precondition(index.feeds(excluding: [], minimumSources: 2, filter: ukOnly).map(\.name) == ["Only Here", "Sky Sports Main Event"])

        // Rank columns pack the source ordinal above the variant ordinal.
        let catalog = SmartSportsDefinition(schemaVersion: 1, playlistID: "p", name: "n", provenance: "t",
                                            feeds: feeds, heldEndpoints: []).reconcile(snapshots: [])
        let columns = VariantRankColumns(feeds: catalog.feeds)
        precondition(columns.handles.count == catalog.feeds.reduce(0) { $0 + $1.variants.count }
            && columns.handles.enumerated().allSatisfy { UInt32(truncatingIfNeeded: $1) == UInt32($0) }
            && Set(columns.handles.map { $0 >> 32 }).count == 3, "Handles carry source and ordinal")

        // Single-source country filter: classify once, then one bit test per channel.
        let source = [ch("1", "UK: Sky Sports Main Event", group: "UK | Sports"),
                      ch("2", "FR: TF1", group: "France"),
                      ch("3", "Cartoon Network", group: "FR | Kids"),
                      ch("4", "##### USA #####", group: "USA | News"),
                      ch("5", "Mystery Channel", group: "Misc")]
        let regions = AutoChannelGrouper.classify(source)
        let label = { (i: Int) in AutoChannelGrouper.Countries.labels[Int(regions.region[i])] }
        let category = { (i: Int) in SmartChannelFilter.categories[Int(regions.category[i])] }
        precondition(regions.count == 5 && label(0) == "UK" && category(0) == "Sports", "Prefixed sports channel classified")
        precondition(label(1) == "FR" && label(2) == "FR" && category(2) == "Kids", "Group title supplies region and category")
        precondition(label(3) == "US" && category(3) == "News", "Separator rows fall back to their group's region")
        precondition(label(4) == SmartChannelFilter.unknownRegion, "No detectable region is Global")
        var keepUK = SmartChannelFilter(isEnabled: true)
        keepUK.regions = ["UK": .sportsOnly]
        keepUK.alwaysInclude = ["Kids"]
        let compiled = CompiledRegionFilter(keepUK)
        let kept = (0..<regions.count).filter { compiled.allows(region: regions.region[$0], category: regions.category[$0]) }
        precondition(kept == [0, 2], "Compiled filter matches SmartChannelFilter.allows: \(kept)")
        for region in 0..<AutoChannelGrouper.Countries.labels.count {
            for (c, name) in SmartChannelFilter.categories.enumerated() {
                precondition(compiled.allows(region: UInt8(region), category: UInt8(c))
                    == keepUK.allows(region: AutoChannelGrouper.Countries.labels[region], category: name), "Compiled bit table is exact")
            }
        }
        let sourceInventory = AutoChannelGrouper.inventory(regions)
        precondition(sourceInventory.reduce(0) { $0 + $1.total } == 5
            && sourceInventory.first(where: { $0.region == "FR" })?.total == 2, "Source inventory counts every channel once")

        print("PASS auto channel grouping: region/quality normalisation, distinct timeshift/region, event-slot exclusion, cross-source feeds, stable IDs, curated precedence, language regions, region/category filter, inventory, guide-ID merging, country names, single-source sports, interner/map/bitset/packed vocabulary, rank handles, single-source country classification and compiled filter")
    }
}
