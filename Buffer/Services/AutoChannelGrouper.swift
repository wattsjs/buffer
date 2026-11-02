import Foundation

/// Groups the same broadcast channel across configured sources into Smart
/// feeds, so one row plays whichever account currently has the best stream.
/// Pure metadata grouping: candidates still pass the catalog's identity,
/// capacity and recovery rules before anything plays.
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
        struct Member: GuideKeyed {
            let snapshot: SmartSportsSourceSnapshot; let channel: Channel; let parsed: Parsed
            var guideID: String? { channel.epgChannelID }
        }
        var groups: [Identity: [Member]] = [:]
        var inventory: [String: [String: Int]] = [:]
        for snapshot in snapshots {
            for channel in snapshot.channels where channel.contentType == .live {
                guard let parsed = parse(channel) else { continue }
                groups[parsed.identity, default: []].append(.init(snapshot: snapshot, channel: channel, parsed: parsed))
                inventory[regionLabel(parsed.identity.country), default: [:]][category(for: [channel.group]), default: 0] += 1
            }
        }
        // A provider that omits the country joins the single regional feed
        // of the same name; with several regions it stays ambiguous and alone.
        var countriesByName: [String: Set<String>] = [:]
        for identity in groups.keys where !identity.country.isEmpty {
            countriesByName[identity.name, default: []].insert(identity.country)
        }
        for (identity, members) in groups where identity.country.isEmpty {
            guard let countries = countriesByName[identity.name], countries.count == 1, let country = countries.first else { continue }
            groups[Identity(country: country, name: identity.name), default: []].append(contentsOf: members)
            groups[identity] = nil
        }

        mergeGroupsSharingGuideIDs(&groups)

        var feeds: [SmartSportsFeedDefinition] = []
        for (identity, members) in groups {
            let category = category(for: members.map(\.channel.group))
            if filter.isEnabled {
                guard filter.allows(region: regionLabel(identity.country), category: category) else { continue }
            } else {
                // Sports channels are kept even when one account carries
                // them; everything else needs several sources to group.
                guard category == "Sports" || Set(members.map(\.snapshot.sourceID)).count >= minimumSources else { continue }
            }
            let keys = members.map { SmartSportsEndpointKey(sourceID: $0.snapshot.sourceID, nativeID: nativeID(of: $0.channel)) }
            guard Set(keys).count == keys.count, curated.isDisjoint(with: keys) else { continue }
            let variants = members.map { member in
                SmartSportsVariantDefinition(
                    sourceID: member.snapshot.sourceID, sourceName: member.snapshot.sourceName,
                    nativeID: nativeID(of: member.channel), identity: .init(channel: member.channel),
                    advertisedFormat: member.parsed.format, advertisedFPS: member.parsed.fps,
                    width: nil, height: nil, fps: nil, measuredAt: nil, measurementContext: "Automatic")
            }
            let displayName = members.map(\.parsed.displayName).min { ($0.count, $0) < ($1.count, $1) } ?? identity.name
            feeds.append(SmartSportsFeedDefinition(
                id: feedPrefix + (identity.country.isEmpty ? "global" : identity.country) + ":" + identity.name.replacingOccurrences(of: " ", with: "-"),
                name: displayName,
                country: regionLabel(identity.country),
                language: "",
                edition: category,
                guideStatus: "Automatic grouping",
                caveats: ["Grouped automatically by name and region across \(Set(keys.map(\.sourceID)).count) sources."],
                variants: variants))
        }
        let summaries = inventory.map { SmartRegionSummary(region: $0.key, categoryCounts: $0.value) }
            .sorted { $0.total > $1.total }
        return (feeds.sorted { $0.id < $1.id }, summaries)
    }

    /// Display label and filter key for a parsed region.
    static func regionLabel(_ country: String) -> String {
        if country.isEmpty { return SmartChannelFilter.unknownRegion }
        if country.hasPrefix(languagePrefix) { return String(country.dropFirst(languagePrefix.count)).capitalized }
        return country.uppercased()
    }

    private static let languagePrefix = "lang-"
    /// Language-only labels ("Arabic | Sports") become their own region so
    /// they can be switched off like a country.
    private static let languages: [String: String] = [
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

    /// "Australia | Sports", "United Kingdom - Entertainment", "USA Sports".
    private static func countryName(in text: String) -> String? {
        let lower = " " + text.lowercased().map { $0.isLetter ? $0 : " " }.reduce(into: "") { $0.append($1) } + " "
        for (name, code) in countryNames where lower.contains(" \(name) ") { return code }
        return nil
    }

    private static let countryNames: [(String, String)] = [
        ("united kingdom", "uk"), ("great britain", "uk"), ("england", "uk"), ("scotland", "uk"), ("britain", "uk"),
        ("united states", "us"), ("usa", "us"), ("america", "us"), ("australia", "au"), ("aussie", "au"),
        ("new zealand", "nz"), ("canada", "ca"), ("ireland", "ie"), ("india", "in"), ("germany", "de"),
        ("france", "fr"), ("spain", "es"), ("italy", "it"), ("portugal", "pt"), ("netherlands", "nl"),
        ("brazil", "br"), ("mexico", "mx"), ("argentina", "ar"), ("south africa", "za"), ("turkey", "tr"),
        ("poland", "pl"), ("sweden", "se"), ("norway", "no"), ("denmark", "dk"), ("finland", "fi"),
    ]

    private static func language(in text: String) -> String? {
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            if let language = languages[String(word)] { return language }
        }
        return nil
    }

    static func isAutomatic(feedID: String) -> Bool { feedID.hasPrefix(feedPrefix) }

    /// Providers often name one broadcast differently ("Fox Sports 501" and
    /// "Fox Sports 501 Cricket") but give it the same guide ID. Groups in a
    /// compatible region that share a specific guide ID become one group,
    /// keeping the largest group's identity. Synthetic or widely shared IDs
    /// (placeholders reused across many channels) never merge.
    private static func mergeGroupsSharingGuideIDs<Member>(_ groups: inout [Identity: [Member]]) where Member: GuideKeyed {
        var identitiesByGuide: [String: Set<Identity>] = [:]
        for (identity, members) in groups {
            for member in members {
                guard let raw = member.guideID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      raw.count >= 3, !raw.hasPrefix("xtream-stream-") else { continue }
                identitiesByGuide[raw, default: []].insert(identity)
            }
        }
        var parent: [Identity: Identity] = [:]
        func root(_ identity: Identity) -> Identity {
            var current = identity
            while let next = parent[current], next != current { current = next }
            return current
        }
        for identities in identitiesByGuide.values where identities.count > 1 && identities.count <= 4 {
            let countries = Set(identities.map(\.country).filter { !$0.isEmpty })
            guard countries.count <= 1 else { continue }
            let ordered = identities.sorted { (groups[$0]?.count ?? 0, $1.name) > (groups[$1]?.count ?? 0, $0.name) }
            let keep = root(ordered[0])
            for other in ordered.dropFirst() {
                let r = root(other)
                if r != keep { parent[r] = keep }
            }
        }
        guard !parent.isEmpty else { return }
        var merged: [Identity: [Member]] = [:]
        for (identity, members) in groups {
            merged[root(identity), default: []].append(contentsOf: members)
        }
        groups = merged
    }

    // MARK: - Name parsing

    static func parse(_ channel: Channel) -> Parsed? {
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
        // Numbered event slots ("PPV 3", "Live Event 12") differ per provider.
        if words.contains(where: { $0.allSatisfy(\.isNumber) }),
           words.allSatisfy({ $0.allSatisfy(\.isNumber) || slotWords.contains($0) }) { return nil }
        let name = words.joined(separator: " ")
        guard name.count >= 2 else { return nil }
        return Parsed(identity: .init(country: country, name: name),
                      displayName: displayName(channel.name), format: format, fps: fps)
    }

    /// Original casing without region prefix or quality tags.
    private static func displayName(_ original: String) -> String {
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

    // Hand-rolled scanners: Swift Regex costs tens of microseconds per call,
    // which dominated grouping time across tens of thousands of names.

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

    private static func nativeID(of channel: Channel) -> String {
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

    private static let knownCountries: Set<String> = [
        "uk", "us", "au", "nz", "ca", "ie", "de", "fr", "es", "it", "nl", "be", "pt", "br", "mx", "ar",
        "in", "pk", "za", "ae", "sa", "qa", "tr", "pl", "se", "no", "dk", "fi", "gr", "ro", "at", "ch",
        "cz", "hu", "rs", "hr", "bg", "il", "jp", "kr", "ph", "my", "sg", "id", "th", "vn", "cl", "co",
    ]
    private static let countryAliases: [String: String] = ["gb": "uk", "usa": "us", "aus": "au", "can": "ca", "eng": "uk", "irl": "ie"]

    private static let qualityTags: [String: String] = [
        "sd": "SD", "480p": "SD", "576p": "SD",
        "hd": "HD", "720p": "HD", "720": "HD",
        "fhd": "FHD", "1080p": "FHD", "1080": "FHD", "1080i": "FHD",
        "uhd": "UHD", "4k": "UHD", "2160p": "UHD", "8k": "UHD",
    ]
    /// Encoding/feed decorations that do not change the broadcast channel.
    private static let droppedWords: Set<String> = [
        "hevc", "h265", "h264", "hdr", "raw", "vip", "backup", "alt", "multi", "audio", "direct", "orig", "original",
    ]
    private static let slotWords: Set<String> = [
        "ppv", "event", "events", "live", "channel", "ch", "sport", "sports", "extra", "game", "match", "feed", "stream", "only", "24", "7",
    ]
}
