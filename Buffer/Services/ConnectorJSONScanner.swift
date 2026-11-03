import Foundation

// Single-pass byte-level JSON scanning for provider responses.
//
// The fast decoders accept a strict subset of what JSONDecoder and
// JSONSerialization accept (RFC 8259, valid UTF-8, no trailing commas,
// bounded nesting) and of the value shapes the reference decoders turn into
// successful results. Anything else raises `ConnectorJSONDecline` and the
// caller re-runs the reference decoder, so every outcome — including errors
// and provider quirks — is the reference outcome.

/// The fast path cannot prove equivalence for this input; use the reference decoder.
nonisolated struct ConnectorJSONDecline: Error {
    init() {
        #if CONNECTOR_TESTING
        ConnectorJSONDecline.count += 1
        #endif
    }
    #if CONNECTOR_TESTING
    /// Declines raised so far (tests assert the fast path handles fixtures).
    nonisolated(unsafe) static var count = 0
    #endif
}

/// One located JSON value inside the response bytes.
nonisolated struct ConnectorJSONSpan {
    enum Kind: UInt8 { case absent = 0, string, number, trueLiteral, falseLiteral, null, object, array }
    var kind: Kind = .absent
    /// Strings: first content byte (after the quote). Others: first byte.
    var start: Int = 0
    /// Exclusive. Strings: the closing quote.
    var end: Int = 0
    /// String contains backslash escapes.
    var escaped = false
    /// Number has a fraction or exponent.
    var fractional = false

    @inline(__always) var isPresent: Bool { kind != .absent }
    @inline(__always) var isNullOrAbsent: Bool { kind == .absent || kind == .null }
    static let absent = ConnectorJSONSpan()
}

nonisolated struct ConnectorJSONCursor {
    let base: UnsafePointer<UInt8>
    let count: Int
    var pos = 0
    /// Nesting limit well inside both reference decoders' limits.
    static let maxDepth = 96

    /// Runs `body` over the bytes of `data`; empty data declines.
    static func withCursor<R>(_ data: Data, _ body: (inout ConnectorJSONCursor) throws -> R) throws -> R {
        guard !data.isEmpty, data.count < Int(Int32.max) else { throw ConnectorJSONDecline() }
        return try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw ConnectorJSONDecline() }
            var cursor = ConnectorJSONCursor(base: base, count: raw.count)
            // Both reference decoders accept and ignore a UTF-8 BOM.
            if cursor.count >= 3, base[0] == 0xEF, base[1] == 0xBB, base[2] == 0xBF { cursor.pos = 3 }
            return try body(&cursor)
        }
    }

    @inline(__always) func byte(_ index: Int) -> UInt8 { base[index] }

    @inline(__always) mutating func skipWhitespace() {
        while pos < count {
            let b = base[pos]
            guard b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 else { return }
            pos += 1
        }
    }

    @inline(__always) mutating func peek() -> UInt8 {
        skipWhitespace()
        return pos < count ? base[pos] : 0
    }

    @inline(__always) mutating func expect(_ b: UInt8) throws {
        skipWhitespace()
        guard pos < count, base[pos] == b else { throw ConnectorJSONDecline() }
        pos += 1
    }

    /// After the top-level value only whitespace may remain.
    mutating func finish() throws {
        skipWhitespace()
        guard pos == count else { throw ConnectorJSONDecline() }
    }

    // MARK: Containers

    /// Consumes `[`; true when the array has a first element.
    @inline(__always) mutating func beginArray() throws -> Bool {
        try expect(0x5B)
        if peek() == 0x5D { pos += 1; return false }
        return true
    }

    /// After an element: true when another follows, false at `]`.
    @inline(__always) mutating func nextElement() throws -> Bool {
        skipWhitespace()
        guard pos < count else { throw ConnectorJSONDecline() }
        let b = base[pos]
        pos += 1
        if b == 0x2C {
            if peek() == 0x5D { throw ConnectorJSONDecline() } // trailing comma
            return true
        }
        if b == 0x5D { return false }
        throw ConnectorJSONDecline()
    }

    /// Consumes `{`; true when the object has a first member.
    @inline(__always) mutating func beginObject() throws -> Bool {
        try expect(0x7B)
        if peek() == 0x7D { pos += 1; return false }
        return true
    }

    @inline(__always) mutating func nextMember() throws -> Bool {
        skipWhitespace()
        guard pos < count else { throw ConnectorJSONDecline() }
        let b = base[pos]
        pos += 1
        if b == 0x2C {
            if peek() == 0x7D { throw ConnectorJSONDecline() }
            return true
        }
        if b == 0x7D { return false }
        throw ConnectorJSONDecline()
    }

    /// Reads `"key" :` and leaves the cursor at the value.
    @inline(__always) mutating func readKey() throws -> ConnectorJSONSpan {
        skipWhitespace()
        guard pos < count, base[pos] == 0x22 else { throw ConnectorJSONDecline() }
        let key = try scanString()
        try expect(0x3A)
        skipWhitespace()
        return key
    }

    /// True when `key` is exactly `literal` (after unescaping).
    @inline(__always) func keyEquals(_ key: ConnectorJSONSpan, _ literal: StaticString) -> Bool {
        let n = literal.utf8CodeUnitCount
        if key.escaped { return unescapedEquals(key, literal) }
        guard key.end - key.start == n else { return false }
        return memcmp(base + key.start, literal.utf8Start, n) == 0
    }

    private func unescapedEquals(_ key: ConnectorJSONSpan, _ literal: StaticString) -> Bool {
        var scratch: [UInt8] = []
        appendUnescaped(key, to: &scratch)
        guard scratch.count == literal.utf8CodeUnitCount else { return false }
        return scratch.withUnsafeBufferPointer { memcmp($0.baseAddress!, literal.utf8Start, scratch.count) == 0 }
    }

    // MARK: Values

    /// Reads any value; containers are validated and skipped, returning their byte extent.
    mutating func readValue(depth: Int = 0) throws -> ConnectorJSONSpan {
        skipWhitespace()
        guard pos < count else { throw ConnectorJSONDecline() }
        switch base[pos] {
        case 0x22: return try scanString()
        case 0x7B, 0x5B:
            let start = pos
            let kind: ConnectorJSONSpan.Kind = base[pos] == 0x7B ? .object : .array
            try skipValue(depth: depth)
            return ConnectorJSONSpan(kind: kind, start: start, end: pos)
        case 0x74: try literal("true"); return ConnectorJSONSpan(kind: .trueLiteral, start: pos - 4, end: pos)
        case 0x66: try literal("false"); return ConnectorJSONSpan(kind: .falseLiteral, start: pos - 5, end: pos)
        case 0x6E: try literal("null"); return ConnectorJSONSpan(kind: .null, start: pos - 4, end: pos)
        default: return try scanNumber()
        }
    }

    /// Validates and skips one value of any kind.
    mutating func skipValue(depth: Int = 0) throws {
        skipWhitespace()
        guard pos < count else { throw ConnectorJSONDecline() }
        switch base[pos] {
        case 0x22: _ = try scanString()
        case 0x7B:
            guard depth < Self.maxDepth else { throw ConnectorJSONDecline() }
            guard try beginObject() else { return }
            repeat {
                _ = try readKey()
                try skipValue(depth: depth + 1)
            } while try nextMember()
        case 0x5B:
            guard depth < Self.maxDepth else { throw ConnectorJSONDecline() }
            guard try beginArray() else { return }
            repeat { try skipValue(depth: depth + 1) } while try nextElement()
        case 0x74: try literal("true")
        case 0x66: try literal("false")
        case 0x6E: try literal("null")
        default: _ = try scanNumber()
        }
    }

    @inline(__always) private mutating func literal(_ text: StaticString) throws {
        let n = text.utf8CodeUnitCount
        guard count - pos >= n, memcmp(base + pos, text.utf8Start, n) == 0 else { throw ConnectorJSONDecline() }
        pos += n
    }

    /// Scans a string at the opening quote; validates escapes and UTF-8.
    mutating func scanString() throws -> ConnectorJSONSpan {
        pos += 1
        let start = pos
        var escaped = false
        var highBits: UInt64 = 0
        let ones: UInt64 = 0x0101_0101_0101_0101
        let highs: UInt64 = 0x8080_8080_8080_8080
        while true {
            // Eight bytes at a time until a quote, backslash or control byte
            // (SWAR zero-byte tests; non-ASCII bytes are only accumulated).
            while count - pos >= 8 {
                let v = UnsafeRawPointer(base + pos).loadUnaligned(as: UInt64.self)
                let q = v ^ 0x2222_2222_2222_2222, s = v ^ 0x5C5C_5C5C_5C5C_5C5C
                let special = (((q &- ones) & ~q) | ((s &- ones) & ~s) | ((v &- 0x2020_2020_2020_2020) & ~v)) & highs
                if special != 0 { break }
                highBits |= v
                pos += 8
            }
            guard pos < count else { throw ConnectorJSONDecline() }
            let b = base[pos]
            if b == 0x22 { break }
            if b == 0x5C {
                escaped = true
                try validateEscape()
                continue
            }
            if b < 0x20 { throw ConnectorJSONDecline() }
            highBits |= UInt64(b)
            pos += 1
        }
        let end = pos
        pos += 1
        if highBits & highs != 0, !ConnectorText.isValidUTF8(base + start, end - start) { throw ConnectorJSONDecline() }
        return ConnectorJSONSpan(kind: .string, start: start, end: end, escaped: escaped)
    }

    private mutating func validateEscape() throws {
        guard count - pos >= 2 else { throw ConnectorJSONDecline() }
        switch base[pos + 1] {
        case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
            pos += 2
        case 0x75:
            let unit = try hex4(at: pos + 2)
            pos += 6
            if unit >= 0xD800, unit <= 0xDBFF {
                guard count - pos >= 6, base[pos] == 0x5C, base[pos + 1] == 0x75 else { throw ConnectorJSONDecline() }
                let low = try hex4(at: pos + 2)
                guard low >= 0xDC00, low <= 0xDFFF else { throw ConnectorJSONDecline() }
                pos += 6
            } else if unit >= 0xDC00, unit <= 0xDFFF {
                throw ConnectorJSONDecline()
            }
        default:
            throw ConnectorJSONDecline()
        }
    }

    @inline(__always) private func hex4(at index: Int) throws -> UInt32 {
        guard count - index >= 4 else { throw ConnectorJSONDecline() }
        var value: UInt32 = 0
        for k in 0..<4 {
            let b = base[index + k]
            let digit: UInt32
            switch b {
            case 0x30...0x39: digit = UInt32(b - 0x30)
            case 0x41...0x46: digit = UInt32(b - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(b - 0x61 + 10)
            default: throw ConnectorJSONDecline()
            }
            value = value << 4 | digit
        }
        return value
    }

    /// Strict RFC 8259 number grammar.
    mutating func scanNumber() throws -> ConnectorJSONSpan {
        let start = pos
        var fractional = false
        if pos < count, base[pos] == 0x2D { pos += 1 }
        guard pos < count else { throw ConnectorJSONDecline() }
        if base[pos] == 0x30 {
            pos += 1
        } else if base[pos] >= 0x31, base[pos] <= 0x39 {
            while pos < count, base[pos] >= 0x30, base[pos] <= 0x39 { pos += 1 }
        } else {
            throw ConnectorJSONDecline()
        }
        if pos < count, base[pos] == 0x2E {
            fractional = true
            pos += 1
            let digits = pos
            while pos < count, base[pos] >= 0x30, base[pos] <= 0x39 { pos += 1 }
            guard pos > digits else { throw ConnectorJSONDecline() }
        }
        if pos < count, base[pos] == 0x65 || base[pos] == 0x45 {
            fractional = true
            pos += 1
            if pos < count, base[pos] == 0x2B || base[pos] == 0x2D { pos += 1 }
            let digits = pos
            while pos < count, base[pos] >= 0x30, base[pos] <= 0x39 { pos += 1 }
            guard pos > digits, pos - digits <= 2 else { throw ConnectorJSONDecline() }
        }
        // A number must be followed by a structural byte, whitespace or EOF.
        if pos < count {
            switch base[pos] {
            case 0x2C, 0x5D, 0x7D, 0x20, 0x0A, 0x0D, 0x09: break
            default: throw ConnectorJSONDecline()
            }
        }
        guard pos - start <= 40 else { throw ConnectorJSONDecline() }
        return ConnectorJSONSpan(kind: .number, start: start, end: pos, fractional: fractional)
    }

    // MARK: Interpretation

    /// Appends the unescaped UTF-8 bytes of a string span.
    func appendUnescaped(_ span: ConnectorJSONSpan, to out: inout [UInt8]) {
        var i = span.start
        let end = span.end
        guard span.escaped else {
            out.append(contentsOf: UnsafeBufferPointer(start: base + i, count: end - i))
            return
        }
        while i < end {
            var run = i
            while run < end, base[run] != 0x5C { run += 1 }
            if run > i { out.append(contentsOf: UnsafeBufferPointer(start: base + i, count: run - i)) }
            i = run
            guard i < end else { break }
            let e = base[i + 1]
            switch e {
            case 0x62: out.append(0x08); i += 2
            case 0x66: out.append(0x0C); i += 2
            case 0x6E: out.append(0x0A); i += 2
            case 0x72: out.append(0x0D); i += 2
            case 0x74: out.append(0x09); i += 2
            case 0x75:
                var scalar = (try? hex4(at: i + 2)) ?? 0xFFFD
                i += 6
                if scalar >= 0xD800, scalar <= 0xDBFF {
                    let low = (try? hex4(at: i + 2)) ?? 0xDC00
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    i += 6
                }
                ConnectorText.appendUTF8(scalar, to: &out)
            default: out.append(e); i += 2 // " \ /
            }
        }
    }

    /// The string value; `scratch` is reused for escaped strings.
    @inline(__always) func string(_ span: ConnectorJSONSpan, scratch: inout [UInt8]) -> String {
        if !span.escaped {
            return String(decoding: UnsafeBufferPointer(start: base + span.start, count: span.end - span.start), as: UTF8.self)
        }
        scratch.removeAll(keepingCapacity: true)
        appendUnescaped(span, to: &scratch)
        return String(decoding: scratch, as: UTF8.self)
    }

    /// The literal ASCII text of a number span.
    func numberText(_ span: ConnectorJSONSpan) -> String {
        String(decoding: UnsafeBufferPointer(start: base + span.start, count: span.end - span.start), as: UTF8.self)
    }

    /// Value of an integer-grammar number of at most 18 digits.
    @inline(__always) func plainInteger(_ span: ConnectorJSONSpan) -> Int? {
        guard span.kind == .number, !span.fractional else { return nil }
        var i = span.start
        let negative = base[i] == 0x2D
        if negative { i += 1 }
        guard span.end - i <= 18 else { return nil }
        var value = 0
        while i < span.end { value = value &* 10 &+ Int(base[i] &- 0x30); i += 1 }
        return negative ? -value : value
    }

    /// `JSONDecoder.decode(Int.self)` on a number: integral values convert,
    /// fractional values fail. Declines where exactness is not provable.
    func codableInt(_ span: ConnectorJSONSpan) throws -> Int? {
        if let value = plainInteger(span) { return value }
        if !span.fractional {
            // 19+ digit integers: exact checked parse.
            var i = span.start
            let negative = base[i] == 0x2D
            if negative { i += 1 }
            var magnitude: UInt64 = 0
            while i < span.end {
                let (m, o1) = magnitude.multipliedReportingOverflow(by: 10)
                let (s, o2) = m.addingReportingOverflow(UInt64(base[i] - 0x30))
                if o1 || o2 { return nil }
                magnitude = s
                i += 1
            }
            if negative { return magnitude <= UInt64(Int.max) + 1 ? Int(truncatingIfNeeded: 0 &- magnitude) : nil }
            return magnitude <= UInt64(Int.max) ? Int(magnitude) : nil
        }
        // Fraction/exponent: decline unless the value is clearly small.
        guard significantDigits(span) <= 15, let double = Double(numberText(span)), double.isFinite else { throw ConnectorJSONDecline() }
        guard double.rounded(.towardZero) == double else { return nil }
        guard abs(double) < 9_007_199_254_740_992 else { throw ConnectorJSONDecline() }
        return Int(double)
    }

    private func significantDigits(_ span: ConnectorJSONSpan) -> Int {
        var digits = 0
        var leading = true
        var i = span.start
        while i < span.end {
            let b = base[i]
            if b == 0x65 || b == 0x45 { break }
            if b >= 0x30, b <= 0x39 {
                if b != 0x30 || !leading { leading = false; digits += 1 }
            }
            i += 1
        }
        return digits
    }

    /// `Int(String)` semantics on the unescaped bytes of an ASCII string span.
    @inline(__always) func swiftInt(_ span: ConnectorJSONSpan) -> Int? {
        guard span.kind == .string, !span.escaped else { return nil }
        return ConnectorText.swiftInt(base + span.start, span.end - span.start)
    }
}

/// Byte-level equivalents of the String/Foundation calls the reference
/// mappers make, each exact or explicitly falling back to Foundation.
nonisolated enum ConnectorText {
    static func appendUTF8(_ scalar: UInt32, to out: inout [UInt8]) {
        switch scalar {
        case 0..<0x80: out.append(UInt8(scalar))
        case 0x80..<0x800:
            out.append(UInt8(0xC0 | (scalar >> 6))); out.append(UInt8(0x80 | (scalar & 0x3F)))
        case 0x800..<0x10000:
            out.append(UInt8(0xE0 | (scalar >> 12))); out.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (scalar & 0x3F)))
        default:
            out.append(UInt8(0xF0 | (scalar >> 18))); out.append(UInt8(0x80 | ((scalar >> 12) & 0x3F)))
            out.append(UInt8(0x80 | ((scalar >> 6) & 0x3F))); out.append(UInt8(0x80 | (scalar & 0x3F)))
        }
    }

    /// Well-formed UTF-8 (no overlongs, surrogates or values above U+10FFFF).
    static func isValidUTF8(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var i = 0
        while i < n {
            let b0 = p[i]
            if b0 < 0x80 { i += 1; continue }
            if b0 < 0xC2 { return false }
            if b0 < 0xE0 {
                guard i + 1 < n, p[i + 1] & 0xC0 == 0x80 else { return false }
                i += 2
            } else if b0 < 0xF0 {
                guard i + 2 < n, p[i + 1] & 0xC0 == 0x80, p[i + 2] & 0xC0 == 0x80 else { return false }
                if b0 == 0xE0, p[i + 1] < 0xA0 { return false }
                if b0 == 0xED, p[i + 1] > 0x9F { return false }
                i += 3
            } else if b0 < 0xF5 {
                guard i + 3 < n, p[i + 1] & 0xC0 == 0x80, p[i + 2] & 0xC0 == 0x80, p[i + 3] & 0xC0 == 0x80 else { return false }
                if b0 == 0xF0, p[i + 1] < 0x90 { return false }
                if b0 == 0xF4, p[i + 1] > 0x8F { return false }
                i += 4
            } else {
                return false
            }
        }
        return true
    }

    /// `Int(String)`: optional sign, ASCII digits, overflow is nil.
    static func swiftInt(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int? {
        guard n > 0 else { return nil }
        var i = 0
        var negative = false
        if p[0] == 0x2D || p[0] == 0x2B { negative = p[0] == 0x2D; i = 1 }
        guard i < n else { return nil }
        var value = 0
        while i < n {
            let d = Int(p[i]) - 0x30
            guard d >= 0, d <= 9 else { return nil }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (s, o2) = negative ? m.subtractingReportingOverflow(d) : m.addingReportingOverflow(d)
            if o1 || o2 { return nil }
            value = s
            i += 1
        }
        return value
    }

    /// `TimeInterval(String)`: ASCII-digit fast path, Foundation otherwise.
    static func timeInterval(_ p: UnsafePointer<UInt8>, _ n: Int) -> Double? {
        if n > 0, n <= 15 {
            var value = 0
            var i = 0
            while i < n {
                let d = Int(p[i]) - 0x30
                guard d >= 0, d <= 9 else { break }
                value = value * 10 + d
                i += 1
            }
            if i == n { return Double(value) }
        }
        return Double(String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self))
    }

    @inline(__always) static func isASCIIWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || (b >= 0x09 && b <= 0x0D)
    }

    /// Membership in `CharacterSet.whitespacesAndNewlines` (verified against
    /// the set for every scalar by connector_scanner_tests).
    @inline(__always) static func isTrimmedWhitespace(_ v: UInt32) -> Bool {
        switch v {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200B, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// `trimmingCharacters(in: .whitespacesAndNewlines)` on valid UTF-8,
    /// returned as a byte range. Edge scalars outside ASCII are checked
    /// against the character set itself.
    static func trimmedRange(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> (Int, Int) {
        var s = start, e = end
        while s < e {
            let b = p[s]
            if b < 0x80 {
                guard isASCIIWhitespace(b) else { break }
                s += 1
            } else {
                let (scalar, width) = decodeScalar(p, s)
                guard isTrimmedWhitespace(scalar.value) else { break }
                s += width
            }
        }
        while e > s {
            let b = p[e - 1]
            if b < 0x80 {
                guard isASCIIWhitespace(b) else { break }
                e -= 1
            } else {
                var lead = e - 1
                while lead > s, p[lead] & 0xC0 == 0x80 { lead -= 1 }
                let (scalar, _) = decodeScalar(p, lead)
                guard isTrimmedWhitespace(scalar.value) else { break }
                e = lead
            }
        }
        return (s, e)
    }

    static func decodeScalar(_ p: UnsafePointer<UInt8>, _ i: Int) -> (Unicode.Scalar, Int) {
        let b0 = UInt32(p[i])
        let value: UInt32
        let width: Int
        if b0 < 0xE0 { value = (b0 & 0x1F) << 6 | UInt32(p[i + 1] & 0x3F); width = 2 }
        else if b0 < 0xF0 { value = (b0 & 0x0F) << 12 | UInt32(p[i + 1] & 0x3F) << 6 | UInt32(p[i + 2] & 0x3F); width = 3 }
        else { value = (b0 & 0x07) << 18 | UInt32(p[i + 1] & 0x3F) << 12 | UInt32(p[i + 2] & 0x3F) << 6 | UInt32(p[i + 3] & 0x3F); width = 4 }
        return (Unicode.Scalar(value) ?? "\u{FFFD}", width)
    }

    private static let base64Table: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        for (index, byte) in alphabet.enumerated() { table[Int(byte)] = UInt8(index) }
        return table
    }()

    enum Base64Result { case decoded, notBase64, undetermined }

    /// `Data(base64Encoded:)` (no options). Canonical input (length a
    /// multiple of four, `=` only as final padding) is decoded here; bytes
    /// outside the alphabet are never base64; other spellings, which
    /// Foundation decodes leniently, are `.undetermined`.
    static func decodeBase64(_ p: UnsafePointer<UInt8>, _ n: Int, into out: inout [UInt8]) -> Base64Result {
        guard n > 0 else { return .undetermined }
        guard n % 4 == 0 else { return classify(p, n) }
        var padding = 0
        if p[n - 1] == 0x3D { padding = p[n - 2] == 0x3D ? 2 : 1 }
        let body = n - padding
        let start = out.count
        let decodedLength = body / 4 * 3 + (body % 4 == 3 ? 2 : body % 4 == 2 ? 1 : 0)
        guard body % 4 != 1 else { return classify(p, n) }
        out.append(contentsOf: repeatElement(0, count: decodedLength))
        let ok: Bool = base64Table.withUnsafeBufferPointer { tableBuffer in
            out.withUnsafeMutableBufferPointer { outBuffer in
                let table = tableBuffer.baseAddress!
                var o = outBuffer.baseAddress! + start
                var i = 0
                var bad: UInt8 = 0
                while i + 4 <= body {
                    let a = table[Int(p[i])], b = table[Int(p[i + 1])], c = table[Int(p[i + 2])], d = table[Int(p[i + 3])]
                    bad |= a | b | c | d
                    let v = UInt32(a) << 18 | UInt32(b) << 12 | UInt32(c) << 6 | UInt32(d)
                    o[0] = UInt8(truncatingIfNeeded: v >> 16); o[1] = UInt8(truncatingIfNeeded: v >> 8); o[2] = UInt8(truncatingIfNeeded: v)
                    o += 3
                    i += 4
                }
                let rest = body - i
                if rest == 3 {
                    let a = table[Int(p[i])], b = table[Int(p[i + 1])], c = table[Int(p[i + 2])]
                    bad |= a | b | c
                    let v = UInt32(a) << 18 | UInt32(b) << 12 | UInt32(c) << 6
                    o[0] = UInt8(truncatingIfNeeded: v >> 16); o[1] = UInt8(truncatingIfNeeded: v >> 8)
                } else if rest == 2 {
                    let a = table[Int(p[i])], b = table[Int(p[i + 1])]
                    bad |= a | b
                    o[0] = UInt8(truncatingIfNeeded: UInt32(a) << 2 | UInt32(b) >> 4)
                }
                return bad & 0xC0 == 0
            }
        }
        guard ok else {
            out.removeSubrange(start...)
            return classify(p, n)
        }
        return .decoded
    }

    private static func classify(_ p: UnsafePointer<UInt8>, _ n: Int) -> Base64Result {
        for i in 0..<n where p[i] != 0x3D && base64Table[Int(p[i])] == 0xFF { return .notBase64 }
        return .undetermined
    }
}

/// Flat string table: all field bytes in one buffer, rows refer to them by
/// a packed (offset << 24 | length) reference; `nil` has its own sentinel.
nonisolated struct ConnectorStringTable: Sendable {
    typealias Ref = UInt64
    static let none: Ref = .max
    static let empty: Ref = 0
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 0) { bytes.reserveCapacity(capacity) }

    @inline(__always) static func length(_ ref: Ref) -> Int { Int(ref & 0xFF_FFFF) }
    @inline(__always) static func offset(_ ref: Ref) -> Int { Int(ref >> 24) }

    @inline(__always) mutating func append(_ p: UnsafePointer<UInt8>, _ n: Int) throws -> Ref {
        guard n < 0xFF_FFFF else { throw ConnectorJSONDecline() }
        let offset = bytes.count
        bytes.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
        return Ref(offset) << 24 | Ref(n)
    }

    mutating func append(_ source: [UInt8]) throws -> Ref {
        try source.withUnsafeBufferPointer { try append($0.baseAddress ?? UnsafePointer(bitPattern: 1)!, $0.count) }
    }

    /// Appends a string span (unescaped).
    @inline(__always) mutating func append(_ span: ConnectorJSONSpan, from cursor: ConnectorJSONCursor) throws -> Ref {
        if !span.escaped { return try append(cursor.base + span.start, span.end - span.start) }
        let offset = bytes.count
        cursor.appendUnescaped(span, to: &bytes)
        let n = bytes.count - offset
        guard n < 0xFF_FFFF else { throw ConnectorJSONDecline() }
        return Ref(offset) << 24 | Ref(n)
    }

    /// Appends the canonical decimal text of `value`.
    mutating func append(decimal value: Int) -> Ref {
        let offset = bytes.count
        if value == 0 { bytes.append(0x30); return Ref(offset) << 24 | 1 }
        var v = value.magnitude
        var digits: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var n = 0
        withUnsafeMutableBytes(of: &digits) { buffer in
            while v > 0 { buffer[n] = UInt8(0x30 + v % 10); v /= 10; n += 1 }
            if value < 0 { buffer[n] = 0x2D; n += 1 }
            for k in stride(from: n - 1, through: 0, by: -1) { bytes.append(buffer[k]) }
        }
        return Ref(offset) << 24 | Ref(n)
    }

    @inline(__always) func string(_ ref: Ref) -> String? {
        guard ref != Self.none else { return nil }
        guard Self.length(ref) > 0 else { return "" }
        return bytes.withUnsafeBufferPointer {
            String(decoding: UnsafeBufferPointer(start: $0.baseAddress! + Self.offset(ref), count: Self.length(ref)), as: UTF8.self)
        }
    }

    @inline(__always) func withBytes<R>(_ ref: Ref, _ body: (UnsafePointer<UInt8>, Int) throws -> R) rethrows -> R {
        try bytes.withUnsafeBufferPointer {
            try body(($0.baseAddress ?? UnsafePointer(bitPattern: 1)!) + Self.offset(ref), Self.length(ref))
        }
    }

    /// Reference to the whitespace-trimmed slice of `ref`.
    func trimmed(_ ref: Ref) -> Ref {
        guard ref != Self.none else { return ref }
        return withBytes(ref) { p, n in
            let (s, e) = ConnectorText.trimmedRange(p, 0, n)
            return Ref(Self.offset(ref) + s) << 24 | Ref(e - s)
        }
    }

    func equals(_ ref: Ref, _ literal: StaticString) -> Bool {
        guard ref != Self.none, Self.length(ref) == literal.utf8CodeUnitCount else { return false }
        return withBytes(ref) { p, n in memcmp(p, literal.utf8Start, n) == 0 }
    }

    func isASCII(_ ref: Ref) -> Bool {
        guard ref != Self.none else { return true }
        return withBytes(ref) { p, n in
            for i in 0..<n where p[i] >= 0x80 { return false }
            return true
        }
    }

    func hash(_ ref: Ref) -> UInt64 {
        withBytes(ref) { p, n in Self.hash(p, n) }
    }

    @inline(__always) static func hash(_ p: UnsafePointer<UInt8>, _ n: Int) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for i in 0..<n { h = (h ^ UInt64(p[i])) &* 0x100_0000_01B3 }
        return h
    }

    func bytesEqual(_ a: Ref, _ b: Ref) -> Bool {
        guard Self.length(a) == Self.length(b) else { return false }
        guard Self.length(a) > 0 else { return true }
        return bytes.withUnsafeBufferPointer {
            memcmp($0.baseAddress! + Self.offset(a), $0.baseAddress! + Self.offset(b), Self.length(a)) == 0
        }
    }
}

/// Fixed-width bitset over row indices.
nonisolated struct ConnectorBitset: Sendable {
    private(set) var words: [UInt64] = []
    init(capacity: Int = 0) { words.reserveCapacity((capacity + 63) / 64) }
    @inline(__always) mutating func set(_ index: Int) {
        let w = index >> 6
        while words.count <= w { words.append(0) }
        words[w] |= 1 << UInt64(index & 63)
    }
    @inline(__always) func contains(_ index: Int) -> Bool {
        let w = index >> 6
        return w < words.count && words[w] & (1 << UInt64(index & 63)) != 0
    }
    var count: Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }
}

// MARK: - JSONDecoder field semantics

nonisolated extension ConnectorStringTable {
    /// `decodeIfPresent(String.self)`: absent/null is nil, other kinds are a
    /// type mismatch (declined so the reference decoder raises it).
    @inline(__always) mutating func appendStrictString(_ span: ConnectorJSONSpan, _ cursor: ConnectorJSONCursor) throws -> Ref {
        switch span.kind {
        case .absent, .null: return Self.none
        case .string: return try append(span, from: cursor)
        default: throw ConnectorJSONDecline()
        }
    }

    /// `flexStringIfPresent` / `flexIntIfPresent` (identical outcomes): a
    /// string, an integral number's decimal text, otherwise nil.
    @inline(__always) mutating func appendFlexIfPresent(_ span: ConnectorJSONSpan, _ cursor: ConnectorJSONCursor) throws -> Ref {
        switch span.kind {
        case .string: return try append(span, from: cursor)
        case .number:
            if !span.fractional, span.end - span.start <= 18, cursor.byte(span.start) != 0x2D || cursor.byte(span.start + 1) != 0x30 {
                // Canonical integer text: reuse the bytes.
                return try append(cursor.base + span.start, span.end - span.start)
            }
            guard let value = try cursor.codableInt(span) else { return Self.none }
            return append(decimal: value)
        default: return Self.none
        }
    }

    /// Stalker `FlexibleString`: null → "", string → value, integral number
    /// → decimal, other number → `String(Int(double))`, other kinds → "".
    mutating func appendStalkerFlexible(_ span: ConnectorJSONSpan, _ cursor: ConnectorJSONCursor) throws -> Ref {
        switch span.kind {
        case .absent: return Self.none
        case .string: return try append(span, from: cursor)
        case .number:
            if let value = try cursor.codableInt(span) { return append(decimal: value) }
            guard let double = Double(cursor.numberText(span)), double.isFinite, abs(double) < 9.0e15 else { throw ConnectorJSONDecline() }
            return append(decimal: Int(double))
        default: return Self.empty
        }
    }

    /// `flexString` / `flexInt`: as above with "" for nil.
    @inline(__always) mutating func appendFlex(_ span: ConnectorJSONSpan, _ cursor: ConnectorJSONCursor) throws -> Ref {
        let ref = try appendFlexIfPresent(span, cursor)
        return ref == Self.none ? Self.empty : ref
    }
}

// MARK: - Parallel arrays

/// Large provider arrays (tens of MB) are decoded and materialized on
/// several cores. The array is cut at candidate `},{` element boundaries;
/// every chunk must parse whole elements and end exactly at the next chunk's
/// separator, so (by induction from the first, true, boundary) each chunk
/// reproduces the sequential parse. A failed chunk reruns sequentially.
nonisolated enum ConnectorParallel {
    /// Hands disjoint-index buffers and the caller's (synchronously used)
    /// closures to `concurrentPerform` workers.
    struct Shared<T>: @unchecked Sendable { let value: T }

    static var workerCount: Int {
        #if CONNECTOR_TESTING
        if let workerOverride { return workerOverride }
        #endif
        return max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
    }
    #if CONNECTOR_TESTING
    /// Tests shrink these to force chunk boundaries into tiny payloads.
    nonisolated(unsafe) static var minimumChunkBytes = 512 << 10
    nonisolated(unsafe) static var facadeRowsPerTask = 4096
    nonisolated(unsafe) static var parallelDecodes = 0
    /// Benchmarks pin the worker count (1 = single core).
    nonisolated(unsafe) static var workerOverride: Int?
    nonisolated(unsafe) static var chunkFallbacks = 0
    #else
    static let minimumChunkBytes = 512 << 10
    static let facadeRowsPerTask = 4096
    #endif

    /// Decodes the array at the cursor; one result per chunk, in order.
    static func decodeArray<R>(_ c: inout ConnectorJSONCursor, workers: Int = workerCount,
                               makeResult: (_ bytes: Int) -> R,
                               element: (inout ConnectorJSONCursor, inout R) throws -> Void) throws -> [R] {
        try decodeContainer(&c, object: false, workers: workers, makeResult: makeResult, element: element)
    }

    /// Object whose member values are arrays (`{"k": [...], ...}`); `member`
    /// reads the key and its value.
    static func decodeObjectOfArrays<R>(_ c: inout ConnectorJSONCursor, workers: Int = workerCount,
                                        makeResult: (_ bytes: Int) -> R,
                                        member: (inout ConnectorJSONCursor, inout R) throws -> Void) throws -> [R] {
        try decodeContainer(&c, object: true, workers: workers, makeResult: makeResult, element: member)
    }

    private static func decodeContainer<R>(_ c: inout ConnectorJSONCursor, object: Bool, workers: Int,
                                           makeResult: (_ bytes: Int) -> R,
                                           element: (inout ConnectorJSONCursor, inout R) throws -> Void) throws -> [R] {
        // Element boundaries: `}`,`{` between objects; `]`,`"` between array-valued members.
        let close: UInt8 = object ? 0x7D : 0x5D
        let (boundaryClose, boundaryOpen): (UInt8, UInt8) = object ? (0x5D, 0x22) : (0x7D, 0x7B)
        guard try (object ? c.beginObject() : c.beginArray()) else { return [makeResult(0)] }
        c.skipWhitespace()
        let first = c.pos
        let total = c.count - first
        var starts = [first]
        var separators: [Int] = []
        let chunkCount = workers > 1 ? min(workers, total / minimumChunkBytes) : 1
        if chunkCount > 1 {
            for k in 1..<chunkCount {
                guard let (comma, start) = boundary(c, from: first + total * k / chunkCount, close: boundaryClose, open: boundaryOpen),
                      start > starts.last! else { continue }
                separators.append(comma)
                starts.append(start)
            }
        }
        if starts.count > 1 {
            var results = [R?](repeating: nil, count: starts.count)
            var ends = [Int](repeating: -1, count: starts.count)
            let sharedBase = Shared(value: c.base), count = c.count
            let starts = starts, separators = separators
            withoutActuallyEscaping(makeResult) { makeResult in withoutActuallyEscaping(element) { element in
            let sharedMake = Shared(value: makeResult), sharedElement = Shared(value: element)
            results.withUnsafeMutableBufferPointer { resultBuffer in
                ends.withUnsafeMutableBufferPointer { endBuffer in
                    let outResults = Shared(value: resultBuffer), outEnds = Shared(value: endBuffer)
                    DispatchQueue.concurrentPerform(iterations: starts.count) { k in
                        let base = sharedBase.value
                        let makeResult = sharedMake.value, element = sharedElement.value
                        var cursor = ConnectorJSONCursor(base: base, count: count, pos: starts[k])
                        let last = k == starts.count - 1
                        var result = makeResult((last ? count : separators[k]) - starts[k])
                        do {
                            if last {
                                repeat { try element(&cursor, &result) } while try (object ? cursor.nextMember() : cursor.nextElement())
                            } else {
                                let stop = separators[k]
                                while true {
                                    try element(&cursor, &result)
                                    cursor.skipWhitespace()
                                    if cursor.pos == stop { break }
                                    guard cursor.pos < stop, cursor.byte(cursor.pos) == 0x2C else { throw ConnectorJSONDecline() }
                                    cursor.pos += 1
                                    if cursor.peek() == close { throw ConnectorJSONDecline() }
                                }
                            }
                            outResults.value[k] = result
                            outEnds.value[k] = cursor.pos
                        } catch {}
                    }
                }
            }
            } }
            #if CONNECTOR_TESTING
            if ends.allSatisfy({ $0 >= 0 }) { parallelDecodes += 1 } else { chunkFallbacks += 1 }
            #endif
            if ends.allSatisfy({ $0 >= 0 }) {
                c.pos = ends.last!
                return results.map { $0! }
            }
        }
        // Sequential (small arrays, or a chunk that did not line up).
        c.pos = first
        var result = makeResult(total)
        repeat { try element(&c, &result) } while try (object ? c.nextMember() : c.nextElement())
        return [result]
    }

    /// First `close` ws* `,` ws* `open` at or after `from`: (comma, element start).
    private static func boundary(_ c: ConnectorJSONCursor, from: Int, close: UInt8, open: UInt8) -> (Int, Int)? {
        var i = from
        let limit = c.count - 2
        while i < limit {
            guard let hit = memchr(c.base + i, Int32(close), limit - i) else { return nil }
            var j = c.base.distance(to: hit.assumingMemoryBound(to: UInt8.self)) + 1
            while j < c.count, ConnectorText.isJSONWhitespace(c.byte(j)) { j += 1 }
            if j < c.count, c.byte(j) == 0x2C {
                let comma = j
                j += 1
                while j < c.count, ConnectorText.isJSONWhitespace(c.byte(j)) { j += 1 }
                if j < c.count, c.byte(j) == open { return (comma, j) }
            }
            i = c.base.distance(to: hit.assumingMemoryBound(to: UInt8.self)) + 1
        }
        return nil
    }

    /// Materializes rows of every chunk on several cores, preserving order.
    static func materialize<Chunk, T>(_ chunks: [Chunk], rows: (Chunk) -> Int, workers: Int = workerCount,
                                      body: (Chunk, Range<Int>, inout [T]) -> Void) -> [T] {
        var tasks: [(chunk: Int, range: Range<Int>)] = []
        for (k, chunk) in chunks.enumerated() {
            let n = rows(chunk)
            var lower = 0
            while lower < n {
                let upper = min(n, lower + facadeRowsPerTask)
                tasks.append((k, lower..<upper))
                lower = upper
            }
        }
        if tasks.count <= 1 || workers <= 1 {
            var out: [T] = []
            for task in tasks { body(chunks[task.chunk], task.range, &out) }
            return out
        }
        var parts = [[T]](repeating: [], count: tasks.count)
        withoutActuallyEscaping(body) { body in
        let sharedChunks = Shared(value: chunks), sharedTasks = Shared(value: tasks), sharedBody = Shared(value: body)
        parts.withUnsafeMutableBufferPointer { buffer in
            let output = Shared(value: buffer)
            DispatchQueue.concurrentPerform(iterations: tasks.count) { t in
                let task = sharedTasks.value[t]
                var part: [T] = []
                part.reserveCapacity(task.range.count)
                sharedBody.value(sharedChunks.value[task.chunk], task.range, &part)
                output.value[t] = part
            }
        }
        }
        var out: [T] = []
        out.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for part in parts { out.append(contentsOf: part) }
        return out
    }
}

nonisolated extension ConnectorText {
    @inline(__always) static func isJSONWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09
    }
}

/// Row-major string references for provider list endpoints with a fixed
/// field set (Xtream `get_vod_streams`/`get_series`, Stalker lists). Field
/// kinds carry the reference decoder's semantics; unknown keys are validated
/// and skipped.
nonisolated struct ConnectorRecordColumns: Sendable {
    typealias Ref = ConnectorStringTable.Ref
    enum FieldKind: Sendable {
        /// `decodeIfPresent(String.self)`.
        case strictString
        /// Required `String` (absence or another kind fails the reference decode).
        case requiredString
        /// Xtream `flexStringIfPresent`/`flexIntIfPresent`.
        case flexIfPresent
        /// Xtream `flexString`/`flexInt`.
        case flex
        /// Stalker `FlexibleString?`: absent → nil; null/bool/containers → "".
        case stalkerFlexible
        /// `[Int]?` (decodeIfPresent): stored in `ints`; ref = offset << 24 | count.
        case intList
    }
    struct Field: Sendable {
        let key: StaticString
        let kind: FieldKind
    }

    private(set) var text = ConnectorStringTable()
    private(set) var refs: [Ref] = []
    /// Values of `.intList` fields.
    private(set) var ints: [Int] = []
    let fieldCount: Int
    var count: Int { fieldCount == 0 ? 0 : refs.count / fieldCount }

    @inline(__always) subscript(row: Int, field: Int) -> Ref { refs[row * fieldCount + field] }

    init(fieldCount: Int) { self.fieldCount = fieldCount }

    /// Decodes into element-aligned chunks (several cores for large responses).
    static func decode(_ data: Data, fields: [Field], workers: Int = ConnectorParallel.workerCount) throws -> [ConnectorRecordColumns] {
        try ConnectorJSONCursor.withCursor(data) { c in
            let chunks = try ConnectorParallel.decodeArray(&c, workers: workers, makeResult: { bytes -> ConnectorRecordColumns in
                var columns = ConnectorRecordColumns(fieldCount: fields.count)
                columns.text = ConnectorStringTable(capacity: bytes / 3)
                columns.refs.reserveCapacity(bytes / 400 * fields.count)
                return columns
            }, element: { cursor, columns in try columns.appendRecord(&cursor, fields: fields) })
            try c.finish()
            return chunks
        }
    }

    /// Decodes one object at the cursor (`depth` = the object's nesting level).
    mutating func appendRecord(_ c: inout ConnectorJSONCursor, fields: [Field], depth: Int = 1) throws {
        try withUnsafeTemporaryAllocation(of: ConnectorJSONSpan.self, capacity: fields.count) { spans in
            spans.initialize(repeating: .absent)
            if try c.beginObject() {
                repeat {
                    let key = try c.readKey()
                    var matched = -1
                    let length = key.end - key.start
                    for f in 0..<fields.count
                    where (key.escaped || fields[f].key.utf8CodeUnitCount == length) && c.keyEquals(key, fields[f].key) {
                        matched = f
                        break
                    }
                    if matched >= 0 {
                        let value = try c.readValue(depth: depth + 1)
                        if !spans[matched].isPresent { spans[matched] = value }
                    } else {
                        try c.skipValue(depth: depth + 1)
                    }
                } while try c.nextMember()
            }
            for f in 0..<fields.count {
                switch fields[f].kind {
                case .strictString: refs.append(try text.appendStrictString(spans[f], c))
                case .flexIfPresent: refs.append(try text.appendFlexIfPresent(spans[f], c))
                case .flex: refs.append(try text.appendFlex(spans[f], c))
                case .requiredString:
                    guard spans[f].kind == .string else { throw ConnectorJSONDecline() }
                    refs.append(try text.append(spans[f], from: c))
                case .stalkerFlexible: refs.append(try text.appendStalkerFlexible(spans[f], c))
                case .intList: refs.append(try appendIntList(spans[f], c))
                }
            }
        }
    }

    private mutating func appendIntList(_ span: ConnectorJSONSpan, _ c: ConnectorJSONCursor) throws -> Ref {
        switch span.kind {
        case .absent, .null: return ConnectorStringTable.none
        case .array:
            let offset = ints.count
            var cursor = c
            cursor.pos = span.start
            if try cursor.beginArray() {
                repeat {
                    let value = try cursor.readValue(depth: 3)
                    guard value.kind == .number, let int = try cursor.codableInt(value) else { throw ConnectorJSONDecline() }
                    ints.append(int)
                } while try cursor.nextElement()
            }
            return Ref(offset) << 24 | Ref(ints.count - offset)
        default: throw ConnectorJSONDecline()
        }
    }

    /// Values of an `.intList` field, nil when absent/null.
    func intList(_ row: Int, _ field: Int) -> [Int]? {
        let ref = self[row, field]
        guard ref != ConnectorStringTable.none else { return nil }
        let offset = ConnectorStringTable.offset(ref)
        return Array(ints[offset..<(offset + ConnectorStringTable.length(ref))])
    }

    @inline(__always) func string(_ row: Int, _ field: Int) -> String? { text.string(self[row, field]) }

    /// Reference trimmed of whitespace, or nil when that is empty (`nonEmpty`).
    func nonEmpty(_ row: Int, _ field: Int) -> String? {
        let ref = self[row, field]
        guard ref != ConnectorStringTable.none else { return nil }
        let trimmed = text.trimmed(ref)
        return ConnectorStringTable.length(trimmed) > 0 ? text.string(trimmed) : nil
    }

    func int(_ row: Int, _ field: Int) -> Int? {
        let ref = self[row, field]
        guard ref != ConnectorStringTable.none else { return nil }
        return text.withBytes(ref) { ConnectorText.swiftInt($0, $1) }
    }
}


// MARK: - Tape (navigable document)

/// A whole JSON document as flat node columns, for nested responses read by
/// key (ESPN). Children of a container follow it; `next` links siblings.
/// Object keys must be ASCII (non-ASCII keys decline: the reference
/// dictionaries' key equality is not byte equality for them).
nonisolated struct ConnectorJSONTape: Sendable {
    private(set) var kind: [ConnectorJSONSpan.Kind] = []
    private(set) var flags: [UInt8] = []          // bit0 escaped, bit1 fractional
    private(set) var start: [Int32] = []
    private(set) var end: [Int32] = []
    private(set) var keyStart: [Int32] = []
    private(set) var keyEnd: [Int32] = []
    private(set) var next: [Int32] = []
    private(set) var childCount: [Int32] = []
    let data: Data

    static let root: Int32 = 0

    init(_ data: Data) throws {
        self.data = data
        let estimate = data.count / 24 + 8
        kind.reserveCapacity(estimate); flags.reserveCapacity(estimate); start.reserveCapacity(estimate)
        end.reserveCapacity(estimate); keyStart.reserveCapacity(estimate); keyEnd.reserveCapacity(estimate)
        next.reserveCapacity(estimate); childCount.reserveCapacity(estimate)
        try ConnectorJSONCursor.withCursor(data) { c in
            _ = try build(&c, key: nil, depth: 0)
            try c.finish()
        }
    }

    private mutating func build(_ c: inout ConnectorJSONCursor, key: ConnectorJSONSpan?, depth: Int) throws -> Int32 {
        guard depth < ConnectorJSONCursor.maxDepth else { throw ConnectorJSONDecline() }
        let index = Int32(kind.count)
        let peek = c.peek()
        kind.append(.absent); flags.append(0); start.append(Int32(c.pos)); end.append(0)
        keyStart.append(Int32(key?.start ?? -1)); keyEnd.append(Int32(key?.end ?? -1))
        next.append(-1); childCount.append(0)
        if peek == 0x7B || peek == 0x5B {
            let isObject = peek == 0x7B
            kind[Int(index)] = isObject ? .object : .array
            var children: Int32 = 0
            var previous: Int32 = -1
            let hasFirst = isObject ? try c.beginObject() : try c.beginArray()
            if hasFirst {
                repeat {
                    var memberKey: ConnectorJSONSpan?
                    if isObject {
                        let k = try c.readKey()
                        for i in k.start..<k.end where c.byte(i) >= 0x80 { throw ConnectorJSONDecline() }
                        memberKey = k
                    }
                    let child = try build(&c, key: memberKey, depth: depth + 1)
                    if previous >= 0 { next[Int(previous)] = child }
                    previous = child
                    children += 1
                } while try (isObject ? c.nextMember() : c.nextElement())
            }
            childCount[Int(index)] = children
            end[Int(index)] = Int32(c.pos)
        } else {
            let span = try c.readValue(depth: depth)
            kind[Int(index)] = span.kind
            flags[Int(index)] = (span.escaped ? 1 : 0) | (span.fractional ? 2 : 0)
            start[Int(index)] = Int32(span.start)
            end[Int(index)] = Int32(span.end)
        }
        if let key, key.escaped { flags[Int(index)] |= 4 }
        return index
    }

    @inline(__always) func span(_ node: Int32) -> ConnectorJSONSpan {
        let i = Int(node)
        return ConnectorJSONSpan(kind: kind[i], start: Int(start[i]), end: Int(end[i]),
                                 escaped: flags[i] & 1 != 0, fractional: flags[i] & 2 != 0)
    }

    /// Runs `body` with a cursor over the document bytes.
    @inline(__always) func withCursor<R>(_ body: (ConnectorJSONCursor) throws -> R) rethrows -> R {
        try data.withUnsafeBytes { raw in
            try body(ConnectorJSONCursor(base: raw.bindMemory(to: UInt8.self).baseAddress!, count: raw.count))
        }
    }

    /// First member of object `node` named `key` (reference dictionaries
    /// keep the first of duplicate keys).
    func member(_ node: Int32, _ key: StaticString) -> Int32? {
        guard kind[Int(node)] == .object, childCount[Int(node)] > 0 else { return nil }
        let n = key.utf8CodeUnitCount
        return withCursor { c in
            var child = node + 1
            while child >= 0 {
                let i = Int(child)
                if flags[i] & 4 != 0 {
                    let k = ConnectorJSONSpan(kind: .string, start: Int(keyStart[i]), end: Int(keyEnd[i]), escaped: true)
                    if c.keyEquals(k, key) { return child }
                } else if Int(keyEnd[i] - keyStart[i]) == n, memcmp(c.base + Int(keyStart[i]), key.utf8Start, n) == 0 {
                    return child
                }
                child = next[i]
            }
            return nil
        }
    }

    /// Children of a container in order.
    func children(_ node: Int32) -> [Int32] {
        var result: [Int32] = []
        result.reserveCapacity(Int(childCount[Int(node)]))
        guard childCount[Int(node)] > 0 else { return result }
        var child = node + 1
        while child >= 0 { result.append(child); child = next[Int(child)] }
        return result
    }

    /// The string as JSONSerialization delivers it: like JSONDecoder, but
    /// one leading U+FEFF is dropped (NSString treats it as a byte-order mark).
    func string(_ node: Int32) -> String? {
        guard kind[Int(node)] == .string else { return nil }
        return withCursor { c in
            let s = span(node)
            if !s.escaped {
                var start = s.start
                if s.end - start >= 3, c.byte(start) == 0xEF, c.byte(start + 1) == 0xBB, c.byte(start + 2) == 0xBF { start += 3 }
                return String(decoding: UnsafeBufferPointer(start: c.base + start, count: s.end - start), as: UTF8.self)
            }
            var bytes: [UInt8] = []
            c.appendUnescaped(s, to: &bytes)
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// `as? Int` on a JSONSerialization value (NSNumber bridging; booleans are 1/0).
    func int(_ node: Int32) throws -> Int? {
        switch kind[Int(node)] {
        case .trueLiteral: return 1
        case .falseLiteral: return 0
        case .number: return try withCursor { try $0.codableInt(span(node)) }
        default: return nil
        }
    }

    /// `as? Double` on a JSONSerialization value.
    func double(_ node: Int32) throws -> Double? {
        switch kind[Int(node)] {
        case .trueLiteral: return 1
        case .falseLiteral: return 0
        case .number:
            return try withCursor { c in
                let s = span(node)
                if let int = c.plainInteger(s), abs(int) < 1 << 53 { return Double(int) }
                guard s.fractional, s.end - s.start <= 17, let value = Double(c.numberText(s)), value.isFinite else { throw ConnectorJSONDecline() }
                return value
            }
        default: return nil
        }
    }
}
