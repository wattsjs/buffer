import Foundation

// Primitive-level equivalence of the connector scanner against the Foundation
// calls it replaces. Build: swiftc -O Buffer/Services/ConnectorJSONScanner.swift
//   benchmarks/connector_scanner_tests.swift -o .local/bench/connector-scanner-tests

struct IntBox: Decodable { let a: Int }
struct StrBox: Decodable { let a: String }

func cursorRun<R>(_ text: String, _ body: (inout ConnectorJSONCursor) throws -> R) -> R? {
    try? ConnectorJSONCursor.withCursor(Data(text.utf8), body)
}

@main
struct ConnectorScannerTests {
    static func main() {
        var rng = SystemRandomNumberGenerator()
        var failures = 0
        func check(_ ok: Bool, _ message: @autoclosure () -> String) {
            if !ok { failures += 1; if failures < 30 { print("FAIL", message()) } }
        }

        // codableInt == JSONDecoder Int decoding (or declines).
        let numbers = ["0", "-0", "1", "42", "-17", "1.0", "1.5", "3.6", "1e2", "1E2", "100e-2", "-1.0e0", "2.5e1", "0.0",
                       "9223372036854775807", "-9223372036854775808", "9223372036854775808", "123456789012345678",
                       "1234567890123456789", "1e19", "1.0000000000000001", "7.25", "1e-5", "12e0", "0.1e1"]
        for text in numbers {
            let reference = (try? JSONDecoder().decode(IntBox.self, from: Data("{\"a\":\(text)}".utf8)))?.a
            let fast: Int?? = cursorRun(text) { c -> Int? in
                let span = try c.readValue()
                return try c.codableInt(span)
            }
            if let fast { check(fast == reference, "codableInt \(text) fast=\(String(describing: fast)) ref=\(String(describing: reference))") }
        }

        // Int(String) and TimeInterval(String).
        let intTexts = ["", "+", "-", "0", "+5", "-0", "007", "12a", " 1", "1 ", "9223372036854775807", "9223372036854775808",
                        "-9223372036854775808", "-9223372036854775809", "1.0", "１２", "1700000000", "inf", "0x10", "1e9", "nan", ".5", "5."]
        for text in intTexts {
            let bytes = Array(text.utf8)
            let fastInt = bytes.withUnsafeBufferPointer { ConnectorText.swiftInt($0.baseAddress ?? UnsafePointer(bitPattern: 1)!, $0.count) }
            check(fastInt == Int(text), "swiftInt \(text)")
            let fastTime = bytes.withUnsafeBufferPointer { ConnectorText.timeInterval($0.baseAddress ?? UnsafePointer(bitPattern: 1)!, $0.count) }
            let refTime = TimeInterval(text)
            check(fastTime == refTime || (fastTime?.isNaN == true && refTime?.isNaN == true), "timeInterval \(text)")
        }

        // Base64 + UTF-8 decoding == Data(base64Encoded:) + String(data:encoding:).
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf8) + [0x20, 0x0A, 0x2D, 0x5F]
        var base64Cases: [[UInt8]] = ["QQ==", "QUI=", "QUJD", "Q===", "=QQ=", "QQ=A", "QQ", "Q", "", "QUJD\n", "QUJ D", "AAAA",
                                       "77u/QQ==", "wA==", "7aCA", "9JCAgA==", "4oCK", "IA==", "Q-_A"].map { Array($0.utf8) }
        for _ in 0..<20_000 {
            let n = Int.random(in: 1...16, using: &rng)
            base64Cases.append((0..<n).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
        }
        for _ in 0..<5_000 {
            let raw = (0..<Int.random(in: 1...12, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            base64Cases.append(Array(Data(raw).base64EncodedString().utf8))
        }
        for bytes in base64Cases {
            let text = String(decoding: bytes, as: UTF8.self)
            let reference = Data(base64Encoded: text).map(Array.init)
            var out: [UInt8] = []
            let result = bytes.withUnsafeBufferPointer { ConnectorText.decodeBase64($0.baseAddress ?? UnsafePointer(bitPattern: 1)!, $0.count, into: &out) }
            switch result {
            case .decoded: check(out == reference, "base64 decoded \(text)")
            case .notBase64: check(reference == nil && out.isEmpty, "base64 rejected \(text)")
            case .undetermined: check(out.isEmpty, "base64 undetermined left bytes \(text)")
            }
        }

        // UTF-8 validity == String(data:encoding: .utf8) acceptance; BOM handling.
        var utf8Cases: [[UInt8]] = [[0xEF, 0xBB, 0xBF, 0x41], [0xEF, 0xBB, 0xBF], [0xC0, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80],
                                    [0xF0, 0x9F, 0x98, 0x80], [0xE2, 0x82], [0x00], [0x41, 0xEF, 0xBB, 0xBF]]
        for _ in 0..<50_000 {
            utf8Cases.append((0..<Int.random(in: 1...6, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
        }
        var bomStripped = false
        for bytes in utf8Cases {
            let reference = String(data: Data(bytes), encoding: .utf8)
            let valid = bytes.withUnsafeBufferPointer { ConnectorText.isValidUTF8($0.baseAddress!, $0.count) }
            check(valid == (reference != nil), "utf8 validity \(bytes)")
            if let reference, valid, Array(reference.utf8) != bytes {
                if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bomStripped = true } else { check(false, "utf8 content \(bytes)") }
            }
        }
        print("String(data:encoding:.utf8) strips a leading BOM:", bomStripped)

        // The whitespace table is exactly CharacterSet.whitespacesAndNewlines.
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            if ConnectorText.isTrimmedWhitespace(value) != CharacterSet.whitespacesAndNewlines.contains(scalar) {
                check(false, "whitespace table U+\(String(value, radix: 16))")
            }
        }

        // Trimming == trimmingCharacters(in: .whitespacesAndNewlines).
        let pieces = [" ", "\t", "\n", "\u{0B}", "\u{0C}", "\r", "\u{85}", "\u{A0}", "\u{1680}", "\u{2000}", "\u{200A}", "\u{200B}",
                      "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}", "a", "é", "e\u{301}", "\u{301}", "日", "😀", "x y"]
        for _ in 0..<20_000 {
            let s = (0..<Int.random(in: 0...5, using: &rng)).map { _ in pieces[Int.random(in: 0..<pieces.count, using: &rng)] }.joined()
            let bytes = Array(s.utf8)
            let (a, b) = bytes.withUnsafeBufferPointer { ConnectorText.trimmedRange($0.baseAddress ?? UnsafePointer(bitPattern: 1)!, 0, $0.count) }
            let fast = String(decoding: bytes[a..<b], as: UTF8.self)
            let reference = s.trimmingCharacters(in: .whitespacesAndNewlines)
            check(Array(fast.utf8) == Array(reference.utf8), "trim \(s.debugDescription) fast=\(fast.debugDescription) ref=\(reference.debugDescription)")
        }

        // String spans: escapes and unicode == JSONDecoder; invalid input declines.
        let stringCases = ["plain", "with \\/ slash", "q\\\"uote", "\\u00e9t\\u00E9", "\\ud83d\\ude00", "\\ud83d", "\\ude00", "tab\\tnl\\n",
                           "\\b\\f\\r", "\\x", "\\u12", "\\u0000z", "caf\u{e9}", "日本語", "a\\\\b", "end\\"]
        for body in stringCases {
            let json = "{\"a\":\"\(body)\"}"
            let reference = (try? JSONDecoder().decode(StrBox.self, from: Data(json.utf8)))?.a
            let fast: String? = cursorRun("\"\(body)\"") { c -> String in
                let span = try c.readValue()
                try c.finish()
                var scratch: [UInt8] = []
                return c.string(span, scratch: &scratch)
            }
            check(fast.map { Array($0.utf8) } == reference.map { Array($0.utf8) } || fast == nil, "string \(body) fast=\(String(describing: fast)) ref=\(String(describing: reference))")
            if reference == nil { check(fast == nil, "accepted invalid \(body)") }
        }

        // Grammar: anything the cursor accepts, both reference parsers accept.
        let documents = ["[1,2]", "[1,2,]", "{\"a\":1,}", "[01]", "[-]", "[1.]", "[.5]", "[1e]", "[tru]", "[true]", "[null, false]",
                         "  [ ]  ", "[] x", "{\"a\" 1}", "{\"a\":}", "[\"\\u0041\"]", "{\"a\":{\"b\":[{}]}}", "[1e999]", "[\"\t\"]", "[-0.0e-0]"]
        for doc in documents {
            let accepted = cursorRun(doc) { c -> Bool in try c.skipValue(); try c.finish(); return true } ?? false
            let serialization = (try? JSONSerialization.jsonObject(with: Data(doc.utf8))) != nil
            if accepted { check(serialization, "cursor accepted \(doc) rejected by JSONSerialization") }
        }

        // Keys with escapes match their unescaped literal.
        let escapedKey: Bool? = cursorRun("{\"n\\u0061me\":1}") { c -> Bool in
            _ = try c.beginObject()
            let key = try c.readKey()
            return c.keyEquals(key, "name")
        }
        check(escapedKey == true, "escaped key")

        // String table round trip and decimal formatting.
        var table = ConnectorStringTable()
        for value in [0, 7, -7, 1234567, Int.max, Int.min + 1] {
            let ref = table.append(decimal: value)
            check(table.string(ref) == String(value), "decimal \(value)")
        }

        if failures > 0 { print("FAILURES \(failures)"); exit(1) }
        print("PASS connector scanner primitives (codable Int, Int/TimeInterval(String), base64, UTF-8, trimming, escapes, grammar subset)")
    }
}
