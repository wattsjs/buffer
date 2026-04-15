#!/usr/bin/env swift
// Test: false positive scenarios from real usage

import Foundation

func normalise(_ string: String) -> String {
    string.lowercased().folding(options: .diacriticInsensitive, locale: nil)
}

@inline(__always)
func _substringFind(_ nBase: UnsafePointer<UInt8>, _ nLen: Int,
                     _ hBase: UnsafePointer<UInt8>, _ hLen: Int) -> Bool {
    let limit = hLen - nLen
    var i = 0
    while i <= limit {
        if memcmp(hBase + i, nBase, nLen) == 0 { return true }
        i &+= 1
    }
    return false
}

@inline(__always)
func _isASCIILetter(_ byte: UInt8) -> Bool {
    (byte &- 0x41) < 26 || (byte &- 0x61) < 26
}

@inline(__always)
func _wordBoundaryFind(_ nBase: UnsafePointer<UInt8>, _ nLen: Int,
                        _ hBase: UnsafePointer<UInt8>, _ hLen: Int) -> Bool {
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

func allBytesMatch(_ needles: [ContiguousArray<UInt8>], in haystack: ContiguousArray<UInt8>) -> Bool {
    let hLen = haystack.count
    return haystack.withUnsafeBufferPointer { hBuf in
        guard let hBase = hBuf.baseAddress else { return false }
        for needle in needles {
            let nLen = needle.count
            guard nLen <= hLen else { return false }
            let found = needle.withUnsafeBufferPointer { nBuf -> Bool in
                guard let nBase = nBuf.baseAddress else { return false }
                if nLen <= 3 { return _wordBoundaryFind(nBase, nLen, hBase, hLen) }
                else { return _substringFind(nBase, nLen, hBase, hLen) }
            }
            if !found { return false }
        }
        return true
    }
}

// ─── Helpers ───

struct Query {
    let tokens: [String]
    let tokenBytes: [ContiguousArray<UInt8>]
    let score: Double
    let label: String

    init(_ tokens: [String], score: Double, label: String) {
        self.tokens = tokens
        self.tokenBytes = tokens.map { ContiguousArray($0.utf8) }
        self.score = score
        self.label = label
    }
}

let ambiguousTeamNames: Set<String> = [
    "city", "united", "real", "sporting", "racing", "fc",
    "inter", "athletic", "roma", "paris", "milan",
    "giants", "warriors", "kings", "royals", "rangers",
    "lions", "tigers", "bears", "eagles", "hawks",
    "reds", "blues", "heat", "thunder", "storm",
]

let minimumScore: Double = 80

func testMatch(queries: [Query], titleText: String, descText: String, channelName: String, isSportsGroup: Bool) -> (score: Double, reason: String) {
    let titleBytes = ContiguousArray(normalise(titleText).utf8)
    let descBytes = ContiguousArray(normalise(descText).utf8)

    var bestScore = 0.0
    var bestReason = ""

    // EPG title
    for q in queries {
        if allBytesMatch(q.tokenBytes, in: titleBytes) {
            let s = q.score + 50
            if s > bestScore { bestScore = s; bestReason = "title: \(q.label)" }
        }
        // Description: only multi-token queries
        if q.tokenBytes.count >= 2 && !descBytes.isEmpty && allBytesMatch(q.tokenBytes, in: descBytes) {
            let s = q.score + 35
            if s > bestScore { bestScore = s; bestReason = "desc: \(q.label)" }
        }
    }

    // Channel name
    let nameLower = normalise(channelName)
    for q in queries {
        let matched = q.tokens.allSatisfy { token in
            if token.count <= 3 {
                return nameLower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: token))\\b",
                                        options: .regularExpression) != nil
            }
            return nameLower.contains(token)
        }
        if matched && q.score > bestScore {
            bestScore = q.score; bestReason = "channel: \(q.label)"
        }
    }

    // Multipliers
    if bestScore > 0 && isSportsGroup { bestScore *= 1.15 }

    return (bestScore, bestReason)
}

// ─── Scenario 1: MLB "Giants vs Reds" should NOT match cricket ───

print("=== Scenario 1: SF Giants vs Reds (MLB) ===\n")

var mlbQueries: [Query] = []
let g = normalise("Giants"), r = normalise("Reds")
// Both names + comp
mlbQueries.append(Query([g, r, "mlb"], score: 200, label: "Giants+Reds+MLB"))
// Both names
mlbQueries.append(Query([g, r], score: 170, label: "Giants vs Reds"))
// Abbreviations (SF=2 chars, CIN=3 chars → SF filtered by >= 3 rule)
// mlbQueries.append(Query(["sf", "cin"], score: 150, label: "SF vs CIN"))  // NOW BLOCKED
// Display name + abbrev (SF only 2 chars → blocked by >= 3 rule)
mlbQueries.append(Query([normalise("San Francisco Giants"), "cin"], score: 160, label: "SFG+CIN"))
mlbQueries.append(Query([normalise("Cincinnati Reds")], score: 130, label: "Cincinnati Reds"))
mlbQueries.append(Query([normalise("San Francisco Giants")], score: 130, label: "San Francisco Giants"))
// Single names → "giants" and "reds" are now ambiguous!
if !ambiguousTeamNames.contains(g) {
    mlbQueries.append(Query([g], score: 110, label: "Giants"))
}
if !ambiguousTeamNames.contains(r) {
    mlbQueries.append(Query([r], score: 110, label: "Reds"))
}
// Cities
mlbQueries.append(Query([normalise("San Francisco")], score: 90, label: "City: San Francisco"))
mlbQueries.append(Query([normalise("Cincinnati")], score: 90, label: "City: Cincinnati"))

print("  Queries generated:")
for q in mlbQueries { print("    [\(q.tokens.joined(separator: ", "))] score=\(q.score) — \(q.label)") }

// Test against cricket channel
let cricket = testMatch(
    queries: mlbQueries,
    titleText: "IPL: Royal Challengers Bengaluru v Lucknow Super Giants",
    descText: "Live T20 cricket from Bengaluru. RCB take on LSG in a crucial league stage encounter.",
    channelName: "Sky Sports Cricket FHD 5.1",
    isSportsGroup: true
)
print("\n  Sky Sports Cricket: score=\(String(format: "%.0f", cricket.score)) via \(cricket.reason)")
print("  Match: \(cricket.score >= minimumScore ? "YES ❌ (false positive)" : "NO ✅ (correctly rejected)")")

// Test against correct channel
let nbcsn = testMatch(
    queries: mlbQueries,
    titleText: "MLB: San Francisco Giants vs Cincinnati Reds",
    descText: "Regular season baseball from Oracle Park.",
    channelName: "NBC Sports Bay Area",
    isSportsGroup: true
)
print("\n  NBC Sports Bay Area: score=\(String(format: "%.0f", nbcsn.score)) via \(nbcsn.reason)")
print("  Match: \(nbcsn.score >= minimumScore ? "YES ✅" : "NO ❌ (missed)")")

// ─── Scenario 2: Tennis "Ann Li vs Rakhimova" should NOT match random channels ───

print("\n=== Scenario 2: Ann Li vs Kamilla Rakhimova (WTA) ===\n")

var wtaQueries: [Query] = []
let li = normalise("Li"), rakh = normalise("Rakhimova")
// Both names: li is 2 chars < 3 → skipped
// Abbreviations: likely country codes USA (3), RUS (3) → passes >= 3
wtaQueries.append(Query(["usa", "rus"], score: 150, label: "USA vs RUS"))
// Display names
wtaQueries.append(Query([normalise("Ann Li")], score: 130, label: "Ann Li"))
wtaQueries.append(Query([normalise("Kamilla Rakhimova")], score: 130, label: "Kamilla Rakhimova"))
// Single name: "li" is 2 chars < 4 → skipped, "rakhimova" passes
wtaQueries.append(Query([rakh], score: 110, label: "Rakhimova"))
// Surname: "li" 2 chars < 4 → skipped, "rakhimova" same as name → skipped
// City: "kamilla" (from "Kamilla Rakhimova" drop "Rakhimova")
wtaQueries.append(Query([normalise("Kamilla")], score: 90, label: "City: Kamilla"))
// Tournament sport queries
wtaQueries.append(Query(["wta", "tennis"], score: 70, label: "League: WTA+tennis"))
wtaQueries.append(Query(["tennis"], score: 60, label: "Sport: tennis"))

print("  Queries generated:")
for q in wtaQueries { print("    [\(q.tokens.joined(separator: ", "))] score=\(q.score) — \(q.label)") }

// Test against random channels
let ewtn = testMatch(
    queries: wtaQueries,
    titleText: "Daily Mass",
    descText: "Catholic Mass celebrated live from the Eternal Word Television Network chapel in Irondale, Alabama, USA.",
    channelName: "EWTN Catholic",
    isSportsGroup: false
)
print("\n  EWTN Catholic: score=\(String(format: "%.0f", ewtn.score)) via \(ewtn.reason)")
print("  Match: \(ewtn.score >= minimumScore ? "YES ❌ (false positive)" : "NO ✅ (correctly rejected)")")

let modernFamily = testMatch(
    queries: wtaQueries,
    titleText: "Closer? You'll Love It!",
    descText: "Phil and Claire try to spice up their anniversary while the kids get into trouble at home.",
    channelName: "Modern Family",
    isSportsGroup: false
)
print("\n  Modern Family: score=\(String(format: "%.0f", modernFamily.score)) via \(modernFamily.reason)")
print("  Match: \(modernFamily.score >= minimumScore ? "YES ❌ (false positive)" : "NO ✅ (correctly rejected)")")

// Test against correct channel
let skySports = testMatch(
    queries: wtaQueries,
    titleText: "WTA Stuttgart Open & Open de Rouen",
    descText: "Live tennis coverage from the WTA Stuttgart Open. Ann Li faces Kamilla Rakhimova in the first round.",
    channelName: "Sky Sports Main Event HEVC",
    isSportsGroup: true
)
print("\n  Sky Sports Main Event: score=\(String(format: "%.0f", skySports.score)) via \(skySports.reason)")
print("  Match: \(skySports.score >= minimumScore ? "YES ✅" : "NO ❌ (missed)")")

print("\nDone.")
