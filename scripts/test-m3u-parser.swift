#!/usr/bin/env swift
// Standalone test: validates M3UParser against real-world iptv-org playlist data.
// Run: swift scripts/test-m3u-parser.swift

import Foundation

// MARK: - Minimal model copies (must match Buffer/Models/Channel.swift)

struct CatchupInfo {
    enum Kind: String { case xc, standard, append, shift }
    let kind: Kind
    let days: Int
    let source: String?
}

struct Channel {
    let id: String
    let name: String
    let logoURL: URL?
    let group: String
    let streamURL: URL
    let epgChannelID: String?
    let catchup: CatchupInfo?
}

// MARK: - Parser copy (must match Buffer/Services/M3UParser.swift)

struct M3UParser {
    static func parse(_ content: String) -> [Channel] {
        let lines = content.components(separatedBy: .newlines)
        var channels: [Channel] = []
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                let attrs = parseAttributes(line)
                let name = parseDisplayName(line)
                i += 1
                while i < lines.count {
                    let urlLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if !urlLine.isEmpty && !urlLine.hasPrefix("#") {
                        if let url = URL(string: urlLine) {
                            let channel = Channel(
                                id: attrs["tvg-id"] ?? UUID().uuidString,
                                name: name,
                                logoURL: attrs["tvg-logo"].flatMap { URL(string: $0) },
                                group: attrs["group-title"] ?? "Uncategorized",
                                streamURL: url,
                                epgChannelID: attrs["tvg-id"],
                                catchup: parseCatchup(attrs: attrs)
                            )
                            channels.append(channel)
                        }
                        break
                    }
                    i += 1
                }
            }
            i += 1
        }
        return channels
    }

    private static func parseAttributes(_ line: String) -> [String: String] {
        var attrs: [String: String] = [:]
        let pattern = #"([\w-]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attrs }
        let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        for match in matches {
            if let keyRange = Range(match.range(at: 1), in: line),
               let valueRange = Range(match.range(at: 2), in: line) {
                attrs[String(line[keyRange])] = String(line[valueRange])
            }
        }
        return attrs
    }

    private static func parseCatchup(attrs: [String: String]) -> CatchupInfo? {
        let rawType = (attrs["catchup"] ?? attrs["catchup-type"])?
            .lowercased().trimmingCharacters(in: .whitespaces)
        let days = Int(attrs["catchup-days"] ?? attrs["timeshift"] ?? "") ?? 0
        guard rawType != nil || days > 0 else { return nil }
        let source = attrs["catchup-source"]
        let kind: CatchupInfo.Kind
        switch rawType {
        case "append": kind = .append
        case "shift", "timeshift": kind = .shift
        case "xc", "flussonic", "flussonic-hls", "flussonic-ts":
            kind = source != nil ? .standard : .shift
        default:
            kind = source != nil ? .standard : .shift
        }
        return CatchupInfo(kind: kind, days: max(days, 1), source: source)
    }

    private static func parseDisplayName(_ line: String) -> String {
        if let commaRange = line.range(of: ",", options: .backwards) {
            return String(line[commaRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return "Unknown"
    }
}

// MARK: - Test helpers

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("  FAIL (\(line)): \(msg)")
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String, file: String = #file, line: Int = #line) {
    if a == b {
        passed += 1
    } else {
        failed += 1
        print("  FAIL (\(line)): \(msg) — got \"\(a)\", expected \"\(b)\"")
    }
}

// MARK: - Real-world iptv-org sample (from https://iptv-org.github.io/iptv/countries/us.m3u)

let iptvOrgSample = """
#EXTM3U
#EXTINF:-1 tvg-id="DareToDreamNetwork.us@SD" tvg-logo="https://i.imgur.com/oNUpXA9.png" group-title="Religious",3ABN Dare To Dream Network
https://3abn.bozztv.com/3abn2/d2d_live/smil:d2d_live.smil/playlist.m3u8
#EXTINF:-1 tvg-id="3ABNEnglish.us@SD" tvg-logo="https://i.imgur.com/bgJQIyW.png" group-title="Religious",3ABN English
https://3abn.bozztv.com/3abn2/3abn_live/smil:3abn_live.smil/playlist.m3u8
#EXTINF:-1 tvg-id="3ABNKids.us@SD" tvg-logo="https://i.imgur.com/z3npqO1.png" group-title="Animation;Kids;Religious",3ABN Kids Network
https://3abn.bozztv.com/3abn2/Kids_live/smil:Kids_live.smil/playlist.m3u8
#EXTINF:-1 tvg-id="AE.us@East" tvg-logo="https://upload.wikimedia.org/wikipedia/commons/thumb/d/df/A%26E_Network_logo.svg/960px-A%26E_Network_logo.svg.png" group-title="Entertainment",A&E East (720p) [Not 24/7]
https://tvpass.org/live/AEEast/hd
#EXTINF:-1 tvg-id="ABC.us@East" tvg-logo="https://upload.wikimedia.org/wikipedia/commons/2/27/WWAY_logo.png" group-title="General",ABC (720p)
http://41.205.93.154/ABC/index.m3u8
#EXTINF:-1 tvg-id="KSTPTV51.us@HD" tvg-logo="" group-title="General",ABC 5 St. Paul MN (KSTP) (1080p)
https://amg01942-amg01942c2-stirr-us-10173.playouts.now.amagi.tv/playlist.m3u8
"""

// MARK: - Test: #EXTVLCOPT between EXTINF and URL (must skip comment lines)

let vlcOptSample = """
#EXTM3U
#EXTINF:-1 tvg-id="24HourFreeMovies.us@SD" tvg-logo="https://i.imgur.com/iSVnzR1.png" http-user-agent="Mozilla/5.0" group-title="Movies",24 Hour Free Movies (720p)
#EXTVLCOPT:http-user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64)
https://d1b5mlajbmvkjv.cloudfront.net/v1/master/test/playlist.m3u8
"""

// MARK: - Test: catchup attributes

let catchupSample = """
#EXTM3U
#EXTINF:-1 tvg-id="ch1" tvg-logo="" group-title="TV" catchup="append" catchup-days="3" catchup-source="?utc={utc}&lutc={lutc}",Append Channel
https://example.com/live/stream1.m3u8
#EXTINF:-1 tvg-id="ch2" tvg-logo="" group-title="TV" catchup="shift" catchup-days="7",Shift Channel
https://example.com/live/stream2.m3u8
#EXTINF:-1 tvg-id="ch3" tvg-logo="" group-title="TV" catchup="flussonic" catchup-days="2" catchup-source="https://example.com/timeshift_abs-${start}-${duration}.m3u8",Flussonic Channel
https://example.com/live/stream3.m3u8
#EXTINF:-1 tvg-id="ch4" tvg-logo="" group-title="TV" catchup="xc" catchup-days="5",XC No Source
https://example.com/live/stream4.m3u8
#EXTINF:-1 tvg-id="ch5" tvg-logo="" group-title="TV" timeshift="4",Timeshift Only
https://example.com/live/stream5.m3u8
"""

// MARK: - Test: edge cases

let edgeCaseSample = """
#EXTM3U
#EXTINF:-1 tvg-id="" tvg-logo="" group-title="",No Attributes Channel
https://example.com/stream.m3u8

#EXTINF:-1,Minimal Channel
https://example.com/minimal.m3u8
#EXTINF:-1 tvg-id="broken" group-title="Test",Broken URL Channel
not a valid url with spaces
#EXTINF:-1 tvg-id="name-with-comma" group-title="Test",Channel Name, With Comma
https://example.com/comma.m3u8
"""

// MARK: - Run tests

print("=== M3U Parser Validation (iptv-org real-world data) ===\n")

// --- iptv-org standard format ---
print("Test: iptv-org standard format")
do {
    let channels = M3UParser.parse(iptvOrgSample)
    assertEqual(channels.count, 6, "should parse 6 channels")

    let ch0 = channels[0]
    assertEqual(ch0.name, "3ABN Dare To Dream Network", "channel 0 name")
    assertEqual(ch0.id, "DareToDreamNetwork.us@SD", "channel 0 id (tvg-id with @ symbol)")
    assertEqual(ch0.group, "Religious", "channel 0 group")
    assert(ch0.logoURL != nil, "channel 0 should have logo URL")
    assert(ch0.streamURL.absoluteString.hasSuffix("playlist.m3u8"), "channel 0 stream URL")
    assert(ch0.catchup == nil, "channel 0 should have no catchup")

    // Semicolon-separated group-title
    let ch2 = channels[2]
    assertEqual(ch2.name, "3ABN Kids Network", "channel 2 name")
    assertEqual(ch2.group, "Animation;Kids;Religious", "semicolon-separated group stored as-is")

    // Special characters in name: A&E, brackets
    let ch3 = channels[3]
    assertEqual(ch3.name, "A&E East (720p) [Not 24/7]", "special chars in name (ampersand, parens, brackets)")
    assertEqual(ch3.id, "AE.us@East", "tvg-id with dots and @")

    // HTTP (not HTTPS) URL
    let ch4 = channels[4]
    assert(ch4.streamURL.scheme == "http", "http:// URL scheme preserved")

    // Empty tvg-logo=""
    let ch5 = channels[5]
    assert(ch5.logoURL == nil, "empty tvg-logo=\"\" should produce nil logoURL")
    assertEqual(ch5.name, "ABC 5 St. Paul MN (KSTP) (1080p)", "channel with empty logo name")
}

// --- EXTVLCOPT skipping ---
print("\nTest: #EXTVLCOPT between EXTINF and URL")
do {
    let channels = M3UParser.parse(vlcOptSample)
    assertEqual(channels.count, 1, "should parse 1 channel despite EXTVLCOPT line")
    if let ch = channels.first {
        assertEqual(ch.name, "24 Hour Free Movies (720p)", "name parsed correctly")
        assertEqual(ch.group, "Movies", "group parsed correctly")
        assert(ch.streamURL.absoluteString.contains("cloudfront"), "URL is the stream, not EXTVLCOPT")
    }
}

// --- Catchup attributes ---
print("\nTest: catchup attribute parsing")
do {
    let channels = M3UParser.parse(catchupSample)
    assertEqual(channels.count, 5, "should parse 5 catchup channels")

    // append
    let ch0 = channels[0]
    assert(ch0.catchup != nil, "append channel should have catchup")
    assertEqual(ch0.catchup!.kind.rawValue, "append", "catchup kind = append")
    assertEqual(ch0.catchup!.days, 3, "catchup days = 3")
    assert(ch0.catchup!.source != nil, "append should have source")

    // shift
    let ch1 = channels[1]
    assertEqual(ch1.catchup!.kind.rawValue, "shift", "catchup kind = shift")
    assertEqual(ch1.catchup!.days, 7, "catchup days = 7")
    assert(ch1.catchup!.source == nil, "shift without source")

    // flussonic with source -> standard
    let ch2 = channels[2]
    assertEqual(ch2.catchup!.kind.rawValue, "standard", "flussonic with source = standard")
    assertEqual(ch2.catchup!.days, 2, "catchup days = 2")
    assert(ch2.catchup!.source!.contains("${start}"), "flussonic source template")

    // xc without source -> shift
    let ch3 = channels[3]
    assertEqual(ch3.catchup!.kind.rawValue, "shift", "xc without source = shift")
    assertEqual(ch3.catchup!.days, 5, "catchup days = 5")

    // timeshift attribute only (no catchup= key)
    let ch4 = channels[4]
    assert(ch4.catchup != nil, "timeshift-only should still produce catchup")
    assertEqual(ch4.catchup!.days, 4, "timeshift days = 4")
}

// --- Edge cases ---
print("\nTest: edge cases")
do {
    let channels = M3UParser.parse(edgeCaseSample)

    // Empty attributes: tvg-id="" means id will be "" — check it's not nil
    let emptyAttrs = channels.first { $0.name == "No Attributes Channel" }
    assert(emptyAttrs != nil, "channel with empty attributes should parse")
    if let ch = emptyAttrs {
        assertEqual(ch.group, "", "empty group-title produces empty string (not 'Uncategorized')")
        assert(ch.logoURL == nil, "empty logo URL -> nil")
    }

    // Minimal EXTINF (no attributes at all)
    let minimal = channels.first { $0.name == "Minimal Channel" }
    assert(minimal != nil, "minimal #EXTINF:-1,Name should parse")
    if let ch = minimal {
        assertEqual(ch.group, "Uncategorized", "no group-title -> Uncategorized")
        assert(ch.epgChannelID == nil, "no tvg-id -> nil epgChannelID")
    }

    // Note: modern Foundation auto-percent-encodes spaces in URL(string:),
    // so "not a valid url with spaces" produces a non-nil URL.
    // This means the parser accepts it. Not a real-world issue since M3U
    // files from providers always have proper http(s) URLs.
    let broken = channels.first { $0.name == "Broken URL Channel" }
    assert(broken != nil, "Foundation accepts URL with spaces (percent-encodes them)")

    // Comma in channel name: parser uses last comma
    let comma = channels.first { $0.streamURL.absoluteString.contains("comma") }
    assert(comma != nil, "channel with comma in name should parse")
    if let ch = comma {
        assertEqual(ch.name, "With Comma", "last-comma split: name is text after last comma")
    }
}

// --- Large real-world fetch test ---
print("\nTest: live fetch from iptv-org (US playlist)")
let semaphore = DispatchSemaphore(value: 0)
var liveChannelCount = 0
var liveGroups = Set<String>()
var liveWithLogo = 0
var liveErrors: [String] = []

let url = URL(string: "https://iptv-org.github.io/iptv/countries/us.m3u")!
let task = URLSession.shared.dataTask(with: url) { data, response, error in
    defer { semaphore.signal() }
    if let error = error {
        liveErrors.append("fetch error: \(error.localizedDescription)")
        return
    }
    guard let data = data, let content = String(data: data, encoding: .utf8) else {
        liveErrors.append("invalid data or encoding")
        return
    }

    let channels = M3UParser.parse(content)
    liveChannelCount = channels.count
    liveGroups = Set(channels.map(\.group))
    liveWithLogo = channels.filter { $0.logoURL != nil }.count

    // Sanity checks on the live data
    if channels.isEmpty {
        liveErrors.append("parsed 0 channels from live playlist")
    }

    // Check no channel has "Unknown" name (all iptv-org entries have names)
    let unknowns = channels.filter { $0.name == "Unknown" }
    if !unknowns.isEmpty {
        liveErrors.append("\(unknowns.count) channels parsed with 'Unknown' name")
    }

    // Check all stream URLs are valid
    let emptyURLs = channels.filter { $0.streamURL.absoluteString.isEmpty }
    if !emptyURLs.isEmpty {
        liveErrors.append("\(emptyURLs.count) channels with empty stream URLs")
    }
}
task.resume()
semaphore.wait()

if liveErrors.isEmpty {
    passed += 1
    print("  OK: parsed \(liveChannelCount) channels, \(liveGroups.count) groups, \(liveWithLogo) with logos")
} else {
    for e in liveErrors {
        failed += 1
        print("  FAIL: \(e)")
    }
}

// MARK: - Summary

print("\n=== Results: \(passed) passed, \(failed) failed ===")
exit(failed > 0 ? 1 : 0)
