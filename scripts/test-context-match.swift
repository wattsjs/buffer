#!/usr/bin/env swift
// Test: sport-context gating for single-token EPG matches

import Foundation

func normalise(_ s: String) -> String {
    s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
}

@inline(__always)
func substringFind(_ nBase: UnsafePointer<UInt8>, _ nLen: Int,
                    _ hBase: UnsafePointer<UInt8>, _ hLen: Int) -> Bool {
    let limit = hLen - nLen
    var i = 0
    while i <= limit {
        if memcmp(hBase + i, nBase, nLen) == 0 { return true }
        i &+= 1
    }
    return false
}

func containsBytes(_ needle: ContiguousArray<UInt8>, in haystack: ContiguousArray<UInt8>) -> Bool {
    let nLen = needle.count, hLen = haystack.count
    guard nLen > 0 && nLen <= hLen else { return false }
    return haystack.withUnsafeBufferPointer { hBuf in
        needle.withUnsafeBufferPointer { nBuf in
            guard let h = hBuf.baseAddress, let n = nBuf.baseAddress else { return false }
            return substringFind(n, nLen, h, hLen)
        }
    }
}

// Context keywords for MLB baseball
let mlbContext = ["baseball", "mlb"].map { ContiguousArray(normalise($0).utf8) }

// The "giants" query (single token)
let giantsToken = ContiguousArray(normalise("Giants").utf8)

struct TestCase {
    let label: String
    let epgTitle: String
    let epgDesc: String
    let expected: Bool
}

let tests = [
    TestCase(
        label: "IPL cricket (should REJECT)",
        epgTitle: "IPL: Royal Challengers Bengaluru v Lucknow Super Giants",
        epgDesc: "Live T20 cricket from Bengaluru. RCB take on LSG.",
        expected: false
    ),
    TestCase(
        label: "MLB game (should ACCEPT)",
        epgTitle: "MLB: San Francisco Giants at Dodgers",
        epgDesc: "Regular season baseball from Dodger Stadium.",
        expected: true
    ),
    TestCase(
        label: "MLB game - context in desc only (should ACCEPT)",
        epgTitle: "San Francisco Giants at Dodgers",
        epgDesc: "Regular season MLB baseball from Dodger Stadium.",
        expected: true
    ),
    TestCase(
        label: "NFL football Giants (should REJECT for MLB)",
        epgTitle: "NFL: New York Giants at Eagles",
        epgDesc: "NFC East divisional game from Philadelphia.",
        expected: false
    ),
]

print("=== Sport-context gating for single-token EPG matches ===\n")
var allPassed = true

for test in tests {
    let titleBytes = ContiguousArray(normalise(test.epgTitle).utf8)
    let descBytes = ContiguousArray(normalise(test.epgDesc).utf8)

    // Does "giants" appear in the EPG title?
    let giantsInTitle = containsBytes(giantsToken, in: titleBytes)

    // Does any MLB context keyword appear in title or desc?
    let hasContext = mlbContext.contains { kw in
        containsBytes(kw, in: titleBytes) || containsBytes(kw, in: descBytes)
    }

    // With context gating: match only if token found AND context present
    let wouldMatch = giantsInTitle && hasContext

    let passed = wouldMatch == test.expected
    print("  \(passed ? "PASS" : "FAIL") \(test.label)")
    print("       giants_in_title=\(giantsInTitle) has_mlb_context=\(hasContext) → \(wouldMatch ? "MATCH" : "REJECT")")
    if !passed { allPassed = false }
}

print("\n\(allPassed ? "All tests passed." : "FAILURES detected!")")
