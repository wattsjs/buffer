import Foundation
import Darwin

// Guide connector ingest benchmark: XMLTV bytes -> per-channel guide store,
// and M3U playlist -> channels. Builds against the current parsers; the
// `LEGACY_INGEST` define selects the pre-columnar API surface so the same
// driver measures a frozen copy of the old parsers.
//
//   gen-xml <path> <channels> <perChannel> <interleaved:0|1>
//   gen-m3u <path> <entries>
//   xml <path> <reps>      parse + organize into [channel: sorted programmes]
//   xml-digest <path>      order-sensitive digest of the organized store
//   m3u <path> <reps>
//   m3u-digest <path>
@main struct GuideIngestBenchmark {
    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }

    static func peakRSS() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return usage.ru_maxrss
    }

    /// Current physical footprint (dirty memory; excludes clean mapped
    /// file pages, unlike ru_maxrss).
    static func heapMB() -> Int {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? Int(info.ri_phys_footprint) / 1_048_576 : -1
    }

    /// Lifetime peak physical footprint.
    static func peakFootprintMB() -> Int {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? Int(info.ri_lifetime_max_phys_footprint) / 1_048_576 : -1
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    // MARK: Fixtures

    static func generateXML(path: String, channels: Int, perChannel: Int, interleaved: Bool) throws {
        try Data().write(to: URL(fileURLWithPath: path))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        var buffer = ""
        buffer.reserveCapacity(1 << 22)
        func flush(force: Bool = false) {
            if force || buffer.utf8.count > (1 << 22) {
                handle.write(Data(buffer.utf8))
                buffer.removeAll(keepingCapacity: true)
            }
        }
        buffer += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE tv SYSTEM \"xmltv.dtd\">\n"
        buffer += "<tv generator-info-name=\"synthetic\" generator-info-url=\"http://127.0.0.1/\">\n"
        for c in 0..<channels {
            buffer += "  <channel id=\"ch\(c).synthetic.tv\">\n    <display-name lang=\"en\">Channel \(c)</display-name>\n    <icon src=\"http://127.0.0.1/logos/\(c).png\" />\n  </channel>\n"
            flush()
        }
        let titles = (0..<20_000).map { i -> String in
            switch i % 5 {
            case 0: return "News \(i)"
            case 1: return "The Evening Show &amp; Friends \(i)"
            case 2: return "Live: Football League Round \(i)"
            case 3: return "Documentary – Wildlife Series \(i)"
            default: return "Film \(i): A Story"
            }
        }
        let descriptions = (0..<150_000).map { i -> String in
            let words = ["Episode", "guide", "listing", "with", "a", "longer", "synopsis", "about", "the", "programme", "&lt;new&gt;", "season", "café", "日本語"]
            var text = "Description \(i):"
            for w in 0..<(8 + i % 24) { text += " " + words[(i &* 31 &+ w &* 7) % words.count] }
            return text
        }
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Int {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Int(seed >> 1)
        }
        let base = 1_790_000_000 // 2026-09-22
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        // Pre-format a small cycle of stamps; a full formatter per programme
        // would dominate generation time.
        let slotSeconds = 1800
        let stamps = (0...(perChannel + 1)).map { formatter.string(from: Date(timeIntervalSince1970: Double(base + $0 * slotSeconds))) }
        func programme(_ c: Int, _ p: Int) {
            let t = titles[next() % titles.count]
            let d = descriptions[next() % descriptions.count]
            let offset = c % 3 == 0 ? " +0000" : (c % 3 == 1 ? " +0100" : " -0500")
            buffer += "  <programme start=\"\(stamps[p])\(offset)\" stop=\"\(stamps[p + 1])\(offset)\" channel=\"ch\(c).synthetic.tv\">\n"
            buffer += "    <title lang=\"en\">\(t)</title>\n"
            if p % 4 == 0 { buffer += "    <sub-title lang=\"en\">Part \(p)</sub-title>\n" }
            buffer += "    <desc lang=\"en\">\(d)</desc>\n"
            buffer += "    <category lang=\"en\">Category \(c % 17)</category>\n"
            if p % 2 == 0 { buffer += "    <episode-num system=\"xmltv_ns\">\(p % 9).\(p % 20).</episode-num>\n" }
            buffer += "  </programme>\n"
            flush()
        }
        if interleaved {
            for p in 0..<perChannel { for c in 0..<channels { programme(c, p) } }
        } else {
            for c in 0..<channels { for p in 0..<perChannel { programme(c, p) } }
        }
        buffer += "</tv>\n"
        flush(force: true)
        try handle.close()
    }

    static func generateM3U(path: String, entries: Int) throws {
        var text = "#EXTM3U url-tvg=\"http://127.0.0.1/xmltv.php\"\n"
        text.reserveCapacity(entries * 260)
        for i in 0..<entries {
            let group = ["News", "Sport", "Movies Live", "Kids", "Música", "Documentary"][i % 6]
            if i % 10 == 9 {
                text += "#EXTINF:-1 tvg-name=\"Anonymous \(i)\" group-title=\"\(group)\",Anonymous \(i)\nhttp://127.0.0.1:8080/live/user/pass/\(i).ts\n"
            } else if i % 25 == 0 {
                text += "#EXTINF:-1 tvg-id=\"vod\(i)\" tvg-name=\"Film \(i)\" tvg-logo=\"http://127.0.0.1/posters/\(i).jpg\" group-title=\"Movies\",Film \(i)\nhttp://127.0.0.1:8080/movie/user/pass/\(i).mkv\n"
            } else {
                let name = i % 7 == 0 ? "Équipe \(i) HD" : "Channel \(i) HD"
                let catchup = i % 4 == 0 ? " catchup=\"xc\" catchup-days=\"7\"" : ""
                text += "#EXTINF:-1 tvg-id=\"ch\(i).synthetic.tv\" tvg-name=\"\(name)\" tvg-logo=\"http://127.0.0.1/logos/\(i).png\" group-title=\"\(group)\"\(catchup),\(name)\nhttp://127.0.0.1:8080/live/user/pass/\(i).ts\n"
            }
        }
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    // MARK: Store construction

    #if LEGACY_INGEST
    /// `EPGViewModel.organize` as of the baseline.
    static func organize(_ allPrograms: [EPGProgram]) -> [String: [EPGProgram]] {
        var organized: [String: [EPGProgram]] = [:]
        organized.reserveCapacity(1024)
        for program in allPrograms {
            organized[program.channelID, default: []].append(program)
        }
        for (key, value) in organized {
            var needsSort = false
            for i in 1..<value.count {
                if value[i].start < value[i - 1].start { needsSort = true; break }
            }
            if needsSort {
                organized[key] = value.sorted { $0.start < $1.start }
            }
        }
        return organized
    }

    static func store(_ data: Data) -> (count: Int, store: [String: [EPGProgram]], parseMs: Double) {
        let started = ContinuousClock.now
        let programs = XMLTVParser.parse(data: data)
        let parseMs = milliseconds(since: started)
        return (programs.count, organize(programs), parseMs)
    }
    #else
    static func store(_ data: Data) -> (count: Int, store: [String: [EPGProgram]], parseMs: Double) {
        let started = ContinuousClock.now
        let guide = XMLTVParser.parseGuide(data: data)
        let parseMs = milliseconds(since: started)
        return (guide.count, guide.programsByChannel(), parseMs)
    }
    #endif

    static func digest(_ store: [String: [EPGProgram]]) -> String {
        var hasher = Hasher()
        var count = 0
        for key in store.keys.sorted() {
            hasher.combine(key)
            for p in store[key]! {
                hasher.combine(p.id); hasher.combine(p.channelID); hasher.combine(p.title); hasher.combine(p.description)
                hasher.combine(p.start); hasher.combine(p.end)
                count += 1
            }
        }
        // Hasher is per-process seeded; also print a stable FNV over the same fields.
        var fnv: UInt64 = 0xcbf29ce484222325
        func mix(_ s: String) { for b in s.utf8 { fnv = (fnv ^ UInt64(b)) &* 0x100000001b3 }; fnv = (fnv ^ 0xff) &* 0x100000001b3 }
        for key in store.keys.sorted() {
            mix(key)
            for p in store[key]! {
                mix(p.id); mix(p.channelID); mix(p.title); mix(p.description)
                mix(String(p.start.timeIntervalSince1970)); mix(String(p.end.timeIntervalSince1970))
            }
        }
        _ = hasher.finalize()
        return "count=\(count) keys=\(store.count) fnv=\(String(fnv, radix: 16))"
    }

    static func m3uDigest(_ content: M3UParser.PlaylistContent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(content.channels) + encoder.encode(content.vodItems)
        var fnv: UInt64 = 0xcbf29ce484222325
        for b in data { fnv = (fnv ^ UInt64(b)) &* 0x100000001b3 }
        return "channels=\(content.channels.count) vod=\(content.vodItems.count) fnv=\(String(fnv, radix: 16))"
    }

    static func main() async throws {
        let args = CommandLine.arguments
        switch args[1] {
        case "gen-xml":
            try generateXML(path: args[2], channels: Int(args[3])!, perChannel: Int(args[4])!, interleaved: args[5] == "1")
        case "gen-m3u":
            try generateM3U(path: args[2], entries: Int(args[3])!)
        case "xml":
            let reps = Int(args[3])!
            var parse: [Double] = [], total: [Double] = [], mbps: [Double] = []
            var count = 0, keys = 0, bytes = 0
            for _ in 0..<reps {
                try autoreleasepool {
                    let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
                    bytes = data.count
                    let started = ContinuousClock.now
                    let result = store(data)
                    let ms = milliseconds(since: started)
                    count = result.count; keys = result.store.count
                    parse.append(result.parseMs); total.append(ms)
                    mbps.append(Double(bytes) / 1_048_576 / (ms / 1000))
                }
            }
            print("{\"bytes\":\(bytes),\"programmes\":\(count),\"channels\":\(keys),\"parseMsMedian\":\(median(parse)),\"readyStoreMsMedian\":\(median(total)),\"MBpsMedian\":\(median(mbps)),\"readyStoreMs\":\(total),\"peakRSSMB\":\(peakRSS() / 1_048_576),\"peakFootprintMB\":\(peakFootprintMB())}")
        case "xml-digest":
            let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
            print(digest(store(data).store))
        case "xml-file":
            // The async local-file import path (64 KiB cancellable chunks).
            let started = ContinuousClock.now
            #if LEGACY_INGEST
            let organized = organize(try await XMLTVParser.parse(from: URL(fileURLWithPath: args[2])))
            #else
            let organized = try await XMLTVParser.parseGuide(from: URL(fileURLWithPath: args[2])).programsByChannel()
            #endif
            let ms = milliseconds(since: started)
            print("{\"readyStoreMs\":\(ms),\"channels\":\(organized.count),\"storeHeapMB\":\(heapMB()),\"peakRSSMB\":\(peakRSS() / 1_048_576),\"peakFootprintMB\":\(peakFootprintMB())}")
        case "xml-stream":
            // The network path: 64 KiB slices through the streaming ingest.
            let reps = Int(args[3])!
            var total: [Double] = []
            var count = 0, heap = 0
            for _ in 0..<reps {
                try autoreleasepool {
                    let data = try Data(contentsOf: URL(fileURLWithPath: args[2]), options: .alwaysMapped)
                    let started = ContinuousClock.now
                    #if LEGACY_INGEST
                    let organized = organize(XMLTVParser.parse(data: data))
                    #else
                    let organized = XMLTVIngest.parseStreaming(data, sliceSizes: [65_536]).programsByChannel()
                    #endif
                    total.append(milliseconds(since: started))
                    count = organized.values.reduce(0) { $0 + $1.count }
                    heap = heapMB()
                }
            }
            print("{\"programmes\":\(count),\"readyStoreMsMedian\":\(median(total)),\"samples\":\(total),\"storeHeapMB\":\(heap),\"peakRSSMB\":\(peakRSS() / 1_048_576),\"peakFootprintMB\":\(peakFootprintMB())}")
        case "m3u", "m3u-digest":
            let text = try String(contentsOfFile: args[2], encoding: .utf8)
            if args[1] == "m3u-digest" {
                print(try m3uDigest(M3UParser.parseContent(text)))
                return
            }
            let reps = Int(args[3])!
            var all: [Double] = [], live: [Double] = []
            var count = 0
            for _ in 0..<reps {
                autoreleasepool {
                    var started = ContinuousClock.now
                    let content = M3UParser.parseContent(text)
                    all.append(milliseconds(since: started))
                    count = content.channels.count + content.vodItems.count
                    started = ContinuousClock.now
                    let channels = M3UParser.parse(text)
                    live.append(milliseconds(since: started))
                    precondition(channels.count <= count)
                }
            }
            print("{\"bytes\":\(text.utf8.count),\"entries\":\(count),\"parseContentMsMedian\":\(median(all)),\"parseLiveMsMedian\":\(median(live)),\"samples\":\(all),\"peakRSSMB\":\(peakRSS() / 1_048_576),\"peakFootprintMB\":\(peakFootprintMB())}")
        default:
            fatalError("unknown mode")
        }
    }
}
