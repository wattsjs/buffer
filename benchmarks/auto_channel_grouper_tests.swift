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
        precondition(feeds.count == 2, "Expected Sky + BBC only, got \(feeds.map(\.name))")
        precondition(byName["Sky Sports Main Event"]?.variants.count == 3)
        precondition(byName["Sky Sports Main Event"]?.edition == "Sports" && byName["BBC One"]?.edition == "Entertainment" || byName["BBC One"]?.edition == "Channels")
        precondition(feeds.allSatisfy { AutoChannelGrouper.isAutomatic(feedID: $0.id) && $0.country == "UK" })
        // Stable identity across refreshes.
        precondition(AutoChannelGrouper.feeds(from: snapshots.reversed()).map(\.id) == feeds.map(\.id))
        // Curated endpoints keep their curated feed.
        let curated: Set<SmartSportsEndpointKey> = [.init(sourceID: a, nativeID: "a1")]
        precondition(!AutoChannelGrouper.feeds(from: snapshots, excluding: curated).contains { $0.name == "Sky Sports Main Event" })
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

        print("PASS auto channel grouping: region/quality normalisation, distinct timeshift/region, event-slot exclusion, cross-source feeds, stable IDs, curated precedence, language regions, region/category filter, inventory")
    }
}
