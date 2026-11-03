import Foundation

/// Oracle test: the flat interned matcher must return exactly what the
/// pre-redesign String matcher (benchmarks/legacy_stream_matcher.swift)
/// returns: same channels, scores, reasons, programmes, hidden flags,
/// relevance and ordering, before and after preference ranking.
@main struct SportsMatchingEquivalenceTests {
    static func line(_ m: StreamMatch) -> String {
        "\(m.id)|\(m.score)|\(m.reason)|\(m.programTitle ?? "-")|\(m.programDescription ?? "-")|"
            + "\(m.programStart?.timeIntervalSinceReferenceDate ?? -1)|\(m.programEnd?.timeIntervalSinceReferenceDate ?? -1)|"
            + "\(m.isHidden)|\(m.relevance.rawValue)|\(m.channel.streamURL.absoluteString)"
    }

    static func compare(_ name: String, _ fixture: SportsMatchingFixture, nowOffsets: [TimeInterval]) -> Int {
        let legacyIndex = LegacyStreamMatcher.buildIndex(channels: fixture.channels, programs: fixture.programs,
                                                         hiddenGroups: fixture.hiddenGroups, now: fixture.now)
        let index = StreamMatcher.buildIndex(channels: fixture.channels, programs: fixture.programs,
                                             hiddenGroups: fixture.hiddenGroups, now: fixture.now)
        precondition(index.entryCount == legacyIndex.entries.count, "\(name): entry count")
        precondition(index.epgTitleCount == legacyIndex.epgTitleCount, "\(name): epg title count")
        precondition(index.programKeyCount == legacyIndex.programKeyCount, "\(name): programme keys")
        precondition(index.earliestProgramStart == legacyIndex.earliestProgramStart
                     && index.latestProgramEnd == legacyIndex.latestProgramEnd, "\(name): programme bounds")
        var compared = 0
        for offset in nowOffsets {
            let now = fixture.now.addingTimeInterval(offset)
            for event in fixture.events {
                let legacy = LegacyStreamMatcher.findMatches(for: event, index: legacyIndex, now: now)
                let current = StreamMatcher.findMatches(for: event, index: index, now: now)
                let l = legacy.map(line), c = current.map(line)
                if l != c {
                    let first = zip(l, c).enumerated().first { $0.element.0 != $0.element.1 }
                    print("MISMATCH \(name) event=\(event.id) '\(event.title)' legacy=\(l.count) current=\(c.count)")
                    if let first { print("  at \(first.offset)\n  legacy:  \(first.element.0)\n  current: \(first.element.1)") }
                    preconditionFailure("findMatches diverged")
                }
                let ranked = StreamMatcher.rankedMatches(current, qualityByChannel: fixture.quality,
                    favoriteChannelIDs: fixture.favorites, channelScores: fixture.channelScores, groupScores: fixture.groupScores)
                let legacyRanked = LegacyStreamMatcher.rankedMatches(legacy, qualityByChannel: fixture.quality,
                    favoriteChannelIDs: fixture.favorites, channelScores: fixture.channelScores, groupScores: fixture.groupScores)
                precondition(ranked.map(line) == legacyRanked.map(line), "\(name): rankedMatches diverged for \(event.id)")
                precondition(StreamMatcher.presentable(ranked).map(line) == LegacyStreamMatcher.presentable(legacyRanked).map(line))
                compared += current.count
            }
        }
        return compared
    }

    /// The per-scalar Unicode fast path must equal Foundation/String exactly:
    /// normalise, Character count/prefix, tokenWords, compactKey, acronym.
    static func unicodeFastPathMatchesFoundation() {
        var pool: [Character] = Array("abcXYZ019 -:|()[]&'.,/\r\n\t")
        for v in [0xA0, 0xAA, 0xB2, 0xB5, 0xBA, 0xBD, 0xC0, 0xC4, 0xC5, 0xC6, 0xC7, 0xD0, 0xD7, 0xD8, 0xDE, 0xDF, 0xE9, 0xF1,
                  0xF8, 0xFF, 0x100, 0x130, 0x131, 0x138, 0x141, 0x149, 0x152, 0x17F, 0x180, 0x1C4, 0x1C5, 0x1F0, 0x218,
                  0x250, 0x2B0, 0x2BC, 0x2C6, 0x401, 0x410, 0x419, 0x439, 0x451, 0x4C0, 0x4D0, 0x2002, 0x2013, 0x2019,
                  0x201C, 0x2026, 0x2032, 0x2044, 0x2060] {
            pool.append(Character(Unicode.Scalar(UInt32(v))!))
        }
        // Outside the table: must fall back, never produce a different answer.
        pool += Array("\u{0301}ᴴᴰΩςΣ가👍🏽\u{200D}\u{0600}")
        var rng = SportsMatchingFixture.RNG(state: 77)
        var simpleCount = 0
        for _ in 0..<40_000 {
            var s = ""
            for _ in 0..<(1 + rng.int(40)) { s.append(rng.pick(pool)) }
            var out: [UInt8] = []
            let ascii = SportsIndexBuilder.appendNormalised(s, to: &out)
            let expected = StreamMatcher.normaliseString(s)
            precondition(out.elementsEqual(expected.utf8), "normalise: \(s.debugDescription)")
            precondition(ascii == expected.utf8.allSatisfy { $0 < 0x80 })
            var longText = String(repeating: s, count: 1 + 300 / max(1, s.count))
            longText += s
            precondition(SportsIndexBuilder.descriptionPrefix(longText) == (longText.count > 256 ? String(longText.prefix(256)) : longText),
                         "prefix: \(s.debugDescription)")
            var tokens = SportsTokenTable()
            var ids: [UInt32] = []
            var acronym: [UInt8] = []
            let words = SportsIndexBuilder.appendWords(out, 0..<out.count, ascii: ascii, tokens: &tokens, into: &ids, acronym: &acronym)
            let expectedWords = StreamMatcher.tokenWords(in: expected)
            precondition(ids.map { tokens.string($0) } == expectedWords, "words: \(s.debugDescription)")
            precondition(ids.map { tokens.charCount($0) } == expectedWords.map(\.count), "word counts: \(s.debugDescription)")
            let expectedAcronym = StreamMatcher.acronym(for: ContiguousArray(expectedWords))
            if let words {
                precondition(StreamMatcher.acronym(for: ContiguousArray(words)) == expectedAcronym)
            } else {
                simpleCount += 1
                precondition(String(decoding: acronym, as: UTF8.self) == expectedAcronym, "acronym: \(s.debugDescription)")
            }
            var compact: [UInt8] = []
            _ = SportsIndexBuilder.appendCompact(out, 0..<out.count, ascii: ascii, to: &compact)
            precondition(compact.elementsEqual(StreamMatcher.compactKey(expected).utf8), "compact: \(s.debugDescription)")
        }
        precondition(simpleCount > 5_000, "fast path barely exercised")
        print("PASS Unicode fast path equals Foundation normalise/tokenWords/compactKey/prefix on 40000 random strings (\(simpleCount) via table)")
    }

    static func main() {
        let full = CommandLine.arguments.contains("--full")
        unicodeFastPathMatchesFoundation()
        var total = 0
        let small = SportsMatchingFixture.make(channelsPerAccount: 3_000, accounts: 3, fixtures: 120, seed: 7)
        total += compare("small", small, nowOffsets: [0, 3 * 3600])
        let unicode = SportsMatchingFixture.make(channelsPerAccount: 1_500, accounts: 2, fixtures: 80, seed: 99)
        total += compare("unicode", unicodeVariant(unicode), nowOffsets: [0])
        if full {
            let big = SportsMatchingFixture.make()
            total += compare("full", big, nowOffsets: [0])
        }
        print("PASS flat matcher equals legacy matcher: \(total) matches, results/order/rank/presentable identical\(full ? " (incl. 60k full day)" : "")")
    }

    /// Re-labels part of the library with non-ASCII names, groups and guide
    /// text (accents, superscript quality tags, Cyrillic, Greek, NFD) so the
    /// Unicode fallbacks are exercised against the legacy String paths.
    static func unicodeVariant(_ f: SportsMatchingFixture) -> SportsMatchingFixture {
        let decorations = ["ᴴᴰ", "ᵁᴴᴰ", "◉", "✪", "|", "é", "Ö", "\u{0301}", "Россия ", "Ελλάδα ", "e\u{0301}", "ß", "；"]
        var rng = SportsMatchingFixture.RNG(state: 1234)
        let channels = f.channels.map { c -> Channel in
            guard rng.chance(0.4) else { return c }
            let d = rng.pick(decorations)
            let name = rng.chance(0.5) ? c.name + " " + d : d + c.name
            let group = rng.chance(0.2) ? c.group + " " + rng.pick(decorations) : c.group
            return Channel(id: c.id, name: name, logoURL: c.logoURL, group: group, streamURL: c.streamURL,
                           epgChannelID: c.epgChannelID, catchup: c.catchup, contentType: c.contentType,
                           sourceOwnership: c.sourceOwnership)
        }
        var programs: [String: [EPGProgram]] = [:]
        for (key, rows) in f.programs.sorted(by: { $0.key < $1.key }) {
            programs[key] = rows.map { p in
                guard rng.chance(0.3) else { return p }
                let d = rng.pick(decorations)
                let title = rng.chance(0.5) ? p.title + " " + d : "Fútbol: " + p.title
                let desc = rng.chance(0.5) ? d + " " + p.description + "\r\n" + String(repeating: "Ü ", count: 140) : p.description
                return EPGProgram(id: p.id, channelID: p.channelID, title: title, description: desc, start: p.start, end: p.end)
            }
        }
        return SportsMatchingFixture(now: f.now, channels: channels, programs: programs, hiddenGroups: f.hiddenGroups,
                                     events: f.events, quality: f.quality, favorites: f.favorites,
                                     channelScores: f.channelScores, groupScores: f.groupScores)
    }
}
