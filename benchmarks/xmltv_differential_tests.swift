import Foundation

/// Differential checks of the XMLTV byte scanner against libxml2 alone
/// (`XMLTVIngest.parseWithLibxml2`, the parser it replaces): whole buffer,
/// network-style slices and forced parallel split points must produce the
/// same programmes for valid, unusual and malformed documents.
enum XMLTVDifferentialTests {
    struct Generator {
        var seed: UInt64
        mutating func next(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(limit))
        }
        mutating func pick<T>(_ items: [T]) -> T { items[next(items.count)] }
        mutating func chance(_ percent: Int) -> Bool { next(100) < percent }
    }

    static func encode(_ programs: [EPGProgram]) -> [String] {
        programs.map { "\($0.id)|\($0.channelID)|\($0.title)|\($0.description)|\($0.start.timeIntervalSince1970)|\($0.end.timeIntervalSince1970)" }
    }

    static func organizedReference(_ programs: [EPGProgram]) -> [String: [EPGProgram]] {
        var organized: [String: [EPGProgram]] = [:]
        for program in programs { organized[program.channelID, default: []].append(program) }
        for (key, value) in organized where zip(value, value.dropFirst()).contains(where: { $1.start < $0.start }) {
            organized[key] = value.sorted { $0.start < $1.start }
        }
        return organized
    }

    static let texts: [[UInt8]] = [
        Array("News".utf8), Array(" Équipe &amp; 日本語 ".utf8), Array("A &lt;b&gt; &quot;q&quot; &apos;".utf8),
        Array("&#65;&#x42;&#x1F600;".utf8), Array("line1\r\nline2\rline3\n".utf8), Array("<![CDATA[raw <x> & \r\n]]>".utf8),
        Array("a<!-- note -->b".utf8), Array("a<?pi data?>b".utf8), Array("x<b>bold</b>y".utf8), Array("  ".utf8),
        Array("[S1] ] ]] done".utf8), Array("bad ]]> marker".utf8), Array("&nbsp;undefined".utf8), Array("&#0;".utf8),
        Array("&#xD800;".utf8), Array("& bare".utf8), [0x61, 0xFF, 0x62], [0x61, 0x01, 0x62], [0xC3, 0x28],
        Array("café\u{2028}".utf8), [0xEF, 0xBF, 0xBE], Array("tab\there".utf8), Array("<![CDATA[]]>".utf8),
        Array("&#13;&#10;".utf8), Array("multi <!-- a -- b --> comment".utf8), Array("<sub/>after".utf8),
    ]

    static func attribute(_ g: inout Generator, _ name: String, _ value: String) -> String {
        let quote = g.chance(15) ? "'" : "\""
        let eq = g.chance(10) ? " = " : "="
        return "\(name)\(eq)\(quote)\(value)\(quote)"
    }

    static func programme(_ g: inout Generator, index: Int, channels: Int) -> [UInt8] {
        let starts = ["20261004000000 +0000", "20261004003000 -0530", "20261004010000", "2026100401", "20261304000000 +0000",
                      "20261004013000  +0100", "20261004020000 +01", "19500101000000 +0000", "99991231235959 +1400",
                      "20261004&#50;00000 +0000", "20261004\t000000", ""]
        let channelValues = ["c\(index % channels)", "c\(index % channels)", "A&amp;E", "", "ch \(index % 3)", "日本", "x&nbsp;y", "a\nb"]
        var attrs: [String] = []
        if !g.chance(5) { attrs.append(attribute(&g, "start", g.chance(85) ? starts[index % 3] : g.pick(starts))) }
        if !g.chance(5) { attrs.append(attribute(&g, "stop", g.chance(85) ? "20261004\(String(format: "%02d", index % 24))3000 +0000" : g.pick(starts))) }
        if !g.chance(5) { attrs.append(attribute(&g, "channel", g.chance(85) ? "c\(index % channels)" : g.pick(channelValues))) }
        if g.chance(10) { attrs.append(attribute(&g, "xml:lang", "en")) }
        if g.chance(5) { attrs.append(attribute(&g, "g:start", "20261004000000")) }
        if g.chance(4) { attrs.append(attribute(&g, "start", "20261005000000")) }
        if g.chance(8) { attrs.append(attribute(&g, "catchup-id", "x&amp;y")) }
        if g.chance(3) { attrs.append(attribute(&g, "bad", "a<b")) }
        for _ in 0..<(g.chance(30) && attrs.count > 1 ? 3 : 0) { attrs.swapAt(g.next(attrs.count), g.next(attrs.count)) }
        let tag = g.chance(3) ? "g:programme" : "programme"
        var out = Array("<\(tag) \(attrs.joined(separator: g.chance(5) ? "" : " "))".utf8)
        if g.chance(4) { out += Array("/>".utf8); return out }
        out += Array(">".utf8)
        for _ in 0..<g.next(4) {
            let element = g.pick(["title", "desc", "title", "desc", "category", "sub-title", "programme", "credits"])
            var body = g.chance(70) ? Array("Text \(index)".utf8) : g.pick(texts)
            if element == "programme" { body = programme(&g, index: index + 1, channels: channels) }
            out += Array("\n    <\(element)\(g.chance(30) ? " lang=\"en\"" : "")>".utf8) + body
            if !g.chance(2) { out += Array("</\(g.chance(2) ? "titel" : element)>".utf8) }
        }
        if g.chance(5) { out += g.pick(texts) }
        if !g.chance(2) { out += Array("\n  </\(tag)>".utf8) }
        return out
    }

    static func document(_ g: inout Generator, size: Int) -> [UInt8] {
        var out: [UInt8] = []
        if g.chance(5) { out += [0xEF, 0xBB, 0xBF] }
        switch g.next(12) {
        case 0: break
        case 1: out += Array("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n".utf8)
        case 2: out += Array("<?xml version='1.0' encoding='utf-8' standalone='yes'?>\n".utf8)
        case 3: out += Array(" <?xml version=\"1.0\"?>".utf8)
        default: out += Array("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n".utf8)
        }
        if g.chance(60) { out += Array("<!DOCTYPE tv SYSTEM \"xmltv.dtd\">\n".utf8) }
        if g.chance(4) { out += Array("<!DOCTYPE tv [<!ENTITY nbsp \"&#160;\">]>\n".utf8) }
        if g.chance(10) { out += Array("<!-- generated -->\n<?stylesheet x?>\n".utf8) }
        if g.chance(2) { out += Array("junk".utf8) }
        let root = g.chance(3) ? "g:tv xmlns:g=\"http://127.0.0.1/g\"" : (g.chance(5) ? "tv xmlns=\"http://127.0.0.1/ns\"" : "tv generator-info-name=\"fixture\"")
        out += Array("<\(root)>\n".utf8)
        let channels = 1 + g.next(6)
        var index = 0
        let wrapper = g.chance(10)
        if wrapper { out += Array("<day>".utf8) }
        while out.count < size {
            if g.chance(5) { out += Array("  <channel id=\"c\(index % channels)\"><display-name>Channel</display-name></channel>\n".utf8) }
            if g.chance(2) { out += g.pick(texts) }
            out += Array("  ".utf8) + programme(&g, index: index, channels: channels) + Array("\n".utf8)
            index += 1
        }
        if wrapper { out += Array("</day>".utf8) }
        if !g.chance(5) { out += Array("</\(root.split(separator: " ")[0])>\n".utf8) }
        if g.chance(5) { out += Array("<!-- tail -->\n".utf8) }
        if g.chance(3) { out += Array("<programme start=\"20261004000000\" stop=\"20261004010000\" channel=\"after\"><title>After</title></programme>".utf8) }
        if g.chance(3) { out += Array("trailing".utf8) }
        if g.chance(4), out.count > 10 { out.removeLast(g.next(min(40, out.count))) }
        return out
    }

    static func dumpIfDifferent(_ actual: [String], _ expected: [String], _ data: Data) {
        guard actual != expected, let path = ProcessInfo.processInfo.environment["XMLTV_DUMP"] else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("expected \(expected)\nactual   \(actual)\n".utf8))
    }

    static func run() {
        var g = Generator(seed: 0x5EED_0000_1234)
        var checks = 0, fastPathDocuments = 0
        for round in 0..<3000 {
            let size = round % 10 == 0 ? 20_000 : 50 + g.next(1500)
            let bytes = document(&g, size: size)
            let data = Data(bytes)
            let reference = XMLTVIngest.parseWithLibxml2(data).programs()
            let expected = encode(reference)
            let whole = XMLTVParser.parseGuide(data: data)
            if encode(whole.programs()) != expected, let path = ProcessInfo.processInfo.environment["XMLTV_DUMP"] {
                try? data.write(to: URL(fileURLWithPath: path))
                FileHandle.standardError.write(Data(("expected \(expected)\n").utf8))
                FileHandle.standardError.write(Data(("actual   \(encode(whole.programs()))\n").utf8))
            }
            precondition(encode(whole.programs()) == expected, "whole-buffer scan differs from libxml2 (round \(round))")
            let slices = [1 + g.next(7), 1 + g.next(300), 1 + g.next(5000)]
            // libxml2 itself is sensitive to chunking around invalid bytes;
            // the network path must match it fed whole or in the same slices.
            let streamed = encode(XMLTVIngest.parseStreaming(data, sliceSizes: slices).programs())
            if streamed != expected {
                dumpIfDifferent(streamed, encode(XMLTVIngest.parseWithLibxml2(data, sliceSizes: slices).programs()), data)
                precondition(streamed == encode(XMLTVIngest.parseWithLibxml2(data, sliceSizes: slices).programs()),
                             "streamed scan differs from libxml2 (round \(round), slices \(slices))")
            }
            let splits = (0..<(1 + g.next(6))).map { _ in g.next(max(1, bytes.count)) }.sorted()
            let split = XMLTVIngest.parse(data, splitPoints: splits)
            dumpIfDifferent(encode(split.programs()), expected, data)
            precondition(encode(split.programs()) == expected, "parallel scan differs from libxml2 (round \(round), splits \(splits))")
            // Column assembly equals organize() over the flat output.
            let organized = split.programsByChannel(), referenceOrganized = organizedReference(reference)
            if organized.count != referenceOrganized.count, let path = ProcessInfo.processInfo.environment["XMLTV_DUMP"] {
                try? data.write(to: URL(fileURLWithPath: path))
                FileHandle.standardError.write(Data("ref \(referenceOrganized.keys.map { Array($0.utf8) })\nact \(organized.keys.map { Array($0.utf8) })\n".utf8))
            }
            precondition(organized.count == referenceOrganized.count, "channel grouping differs (round \(round))")
            for (key, list) in referenceOrganized { precondition(encode(organized[key] ?? []) == encode(list), "per-channel order differs (round \(round))") }
            precondition(whole.count == reference.count && whole.earliestStart == reference.map(\.start).min()
                         && whole.latestEnd == reference.map(\.end).max(), "guide bounds differ (round \(round))")
            if !reference.isEmpty { fastPathDocuments += 1 }
            checks += 4
        }
        // A large regular document across many forced split points.
        var regular = Array("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv>\n".utf8)
        for index in 0..<20_000 {
            let channel = index % 7 == 0 ? (index * 31) % 50 : index / 400
            regular += Array("<programme start=\"2026100\(index % 9)\(String(format: "%02d", index % 24))0000 +0100\" stop=\"20261009000000 +0000\" channel=\"c\(channel)\"><title>T\(index % 97) &amp; co</title><desc>D\(index)\r\n</desc></programme>\n".utf8)
        }
        regular += Array("</tv>\n".utf8)
        let regularData = Data(regular)
        let expected = encode(XMLTVIngest.parseWithLibxml2(regularData).programs())
        for parts in [2, 7, 33, 63] {
            let splits = (1..<parts).map { regular.count / parts * $0 }
            let guide = XMLTVIngest.parse(regularData, splitPoints: splits)
            precondition(encode(guide.programs()) == expected, "regular document split \(parts) differs")
        }
        precondition(encode(XMLTVParser.parse(data: regularData)) == expected)
        print("PASS \(checks) XMLTV differential checks against libxml2 (\(fastPathDocuments) documents with programmes; whole, streamed, parallel splits, per-channel assembly)")
    }
}
