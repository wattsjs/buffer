// Standalone -O benchmark + equivalence check for ProgramSearchIndex.
// Build: scripts/bench-program-search.sh
// Compares the legacy representation (one 88-byte ProgramSearchEntry with a
// lowercased String per programme, linear `String.contains` scan, sort of
// every hit) against the flat index, on a synthetic library sized like a
// large real account (~2.1M programmes, 15k channels).
import Foundation

struct BenchChannel { let id: String; let name: String; let group: String }

struct LegacyHit { let program: EPGProgram; let channel: BenchChannel; let score: Double; let ordinal: Int }

// MARK: Legacy (verbatim logic from ProgramSearchController / rebuildSearchIndex @ a8a3881)

func legacyBuild(_ guides: [(epgID: String, channelID: String, programs: [EPGProgram])]) -> [ProgramSearchEntry] {
    var entries: [ProgramSearchEntry] = []
    entries.reserveCapacity(guides.reduce(0) { $0 + $1.programs.count })
    for g in guides {
        for (programIndex, program) in g.programs.enumerated() {
            entries.append(ProgramSearchEntry(id: program.id, epgID: g.epgID, programIndex: programIndex,
                channelID: g.channelID, titleLower: program.title.lowercased(), start: program.start, end: program.end))
        }
    }
    return entries
}

func legacySearch(_ query: String, entries: [ProgramSearchEntry], store: [String: [EPGProgram]],
                  channelByID: [String: BenchChannel], now: Date, deterministic: Bool) -> [LegacyHit] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    var programHits: [LegacyHit] = []
    programHits.reserveCapacity(256)
    for (ordinal, entry) in entries.enumerated() {
        let title = entry.titleLower
        var allMatch = true
        for token in tokens where !title.contains(token) { allMatch = false; break }
        if !allMatch { continue }
        var score: Double = 0
        if title.hasPrefix(trimmed) { score += 120 } else if title.contains(trimmed) { score += 70 } else { score += 10 }
        let start = entry.start, end = entry.end
        guard let channel = channelByID[entry.channelID] else { continue }
        if start <= now && end > now { score += 80 }
        else if start > now {
            let minutes = start.timeIntervalSince(now) / 60
            if minutes < 24 * 60 { score += 40 - (minutes / (24 * 60)) * 40 } else if minutes < 7 * 24 * 60 { score += 4 }
        } else { score -= 40 }
        guard let programs = store[entry.epgID] else { continue }
        var p: EPGProgram? = nil
        if programs.indices.contains(entry.programIndex), programs[entry.programIndex].id == entry.id { p = programs[entry.programIndex] }
        else { p = programs.first { $0.id == entry.id } }
        guard let p else { continue }
        programHits.append(LegacyHit(program: p, channel: channel, score: score, ordinal: ordinal))
    }
    programHits.sort { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let lFuture = lhs.program.end > now, rFuture = rhs.program.end > now
        if lFuture != rFuture { return lFuture }
        if deterministic && lhs.program.start == rhs.program.start { return lhs.ordinal < rhs.ordinal }
        return lFuture ? lhs.program.start < rhs.program.start : lhs.program.start > rhs.program.start
    }
    var seen = Set<String>()
    var capped: [LegacyHit] = []
    for hit in programHits {
        if capped.count >= 300 { break }
        if seen.insert(hit.program.id).inserted { capped.append(hit) }
    }
    return capped
}

// MARK: New path (what ProgramSearchController.runSearch does)

func newSearch(_ query: String, index: ProgramSearchIndex, slotChannel: [Int32], now: Date) -> [ProgramSearchIndex.Hit] {
    let trimmed = ProgramSearchIndex.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
    let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { Array($0.utf8) }
    return index.search(phrase: Array(trimmed.utf8), tokens: tokens, now: now, slotChannel: slotChannel)
}

// MARK: Synthetic library

struct RNG { var s: UInt64; mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func zipf(_ n: Int) -> Int { let u = Double(next() % 1_000_000) / 1_000_000; return min(n - 1, Int(pow(Double(n), u)) - 1) } }

func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
func pct(_ xs: [Double], _ p: Double) -> Double { let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p))] }

@main
enum ProgramSearchBench {
    static func main() {
        let args = CommandLine.arguments
        let channels = args.count > 1 ? Int(args[1])! : 15_000
        let perChannel = args.count > 2 ? Int(args[2])! : 140
        let legacyRuns = args.count > 3 ? Int(args[3])! : 5
        var rng = RNG(s: 0x1234_5678_9ABC_DEF1)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var vocab: [String] = (0..<6000).map { _ in
            String((0..<(3 + rng.int(8))).map { _ in letters[rng.zipf(26)] })
        }
        vocab += ["news", "live", "football", "café", "première", "the", "of", "and", "s01", "e02", "hd", "Ñandú"]
        let titlePool: [String] = (0..<250_000).map { _ in
            (0..<(1 + rng.int(5))).map { _ -> String in
                let w = vocab[rng.zipf(vocab.count)]
                return rng.int(3) == 0 ? w.uppercased() : w.prefix(1).uppercased() + w.dropFirst()
            }.joined(separator: rng.int(20) == 0 ? "  " : " ")
        }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000.5)
        var guides: [(epgID: String, channelID: String, programs: [EPGProgram])] = []
        var channelByID: [String: BenchChannel] = [:]
        for c in 0..<channels {
            let epg = "epg.\(c).tv", cid = "ch-\(c)"
            var t = now.addingTimeInterval(-3 * 86_400 + Double(rng.int(3600)))
            var rows: [EPGProgram] = []
            rows.reserveCapacity(perChannel)
            for p in 0..<perChannel {
                let d = Double(30 + rng.int(91)) * 60
                // A few duplicate ids exercise result de-duplication.
                let id = rng.int(500) == 0 ? "dup-\(rng.int(50))" : "\(cid)-\(p)"
                rows.append(EPGProgram(id: id, channelID: epg, title: titlePool[rng.zipf(titlePool.count)],
                                       description: "", start: t, end: t.addingTimeInterval(d)))
                t = t.addingTimeInterval(d)
            }
            guides.append((epg, cid, rows))
            // ~2% of guide channels missing from the controller's list.
            if rng.int(50) != 0 { channelByID[cid] = BenchChannel(id: cid, name: "Channel \(c)", group: "G") }
        }
        let store = Dictionary(uniqueKeysWithValues: guides.map { ($0.epgID, $0.programs) })
        let total = guides.reduce(0) { $0 + $1.programs.count }

        // Queries: 1-3 char prefixes and two-word queries drawn from the vocabulary.
        var queries: [(String, String)] = []
        for _ in 0..<40 { let w = vocab[rng.zipf(vocab.count)]; queries.append(("1-char", String(w.prefix(1)))) }
        for _ in 0..<40 { let w = vocab[rng.zipf(vocab.count)]; queries.append(("2-char", String(w.prefix(2)))) }
        for _ in 0..<40 { let w = vocab[rng.zipf(vocab.count)]; queries.append(("3-char", String(w.prefix(3)))) }
        while queries.filter({ $0.0 == "2-word" }).count < 40 {
            // Two words from a real title (second one partially typed).
            let words = titlePool[rng.zipf(titlePool.count)].split(separator: " ")
            guard words.count >= 2 else { continue }
            let b = words[1]
            queries.append(("2-word", "\(words[0]) \(b.prefix(max(1, b.count - 1)))"))
        }
        queries += [("edge", "  News  "), ("edge", "CAFÉ"), ("edge", "s01 e02"), ("edge", "première hd"), ("edge", "zzzzzzzzzzqq"),
                    ("edge", "abcdefghijk"), ("edge", "ñandú")]

        print("dataset programmes=\(total) channels=\(channels) titlePool=\(titlePool.count)")

        // Build: legacy
        var legacyBuildMs: [Double] = []
        var entries: [ProgramSearchEntry] = []
        var legacyBytes = 0
        for _ in 0..<legacyRuns {
            entries = []
            let before = footprint()
            let clock = ContinuousClock.now
            entries = legacyBuild(guides)
            legacyBuildMs.append(ms(ContinuousClock.now - clock))
            legacyBytes = footprint() - before
            // Analytic: entry stride + out-of-line lowercased titles (>15 UTF-8 bytes).
            legacyBytes = entries.count * MemoryLayout<ProgramSearchEntry>.stride
                + entries.reduce(0) { $0 + ($1.titleLower.utf8.count > 15 ? 32 + $1.titleLower.utf8.count : 0) }
        }
        // Build: new
        var newBuildMs: [Double] = []
        var index = ProgramSearchIndex()
        for _ in 0..<5 {
            index = ProgramSearchIndex()
            let clock = ContinuousClock.now
            index = ProgramSearchIndex.build(guides: guides)!
            newBuildMs.append(ms(ContinuousClock.now - clock))
        }
        let s = index.storage!
        var columnBytes: Int = s.start.count * 8 + s.end.count * 8
        columnBytes += s.slot.count * 4 + s.ordinal.count * 4
        columnBytes += s.titleBytes.count + s.titleOffsets.count * 4 + s.titleRunOffsets.count * 4
        columnBytes += s.tokenBytes.count + s.tokenOffsets.count * 4
        columnBytes += s.tokenTitleOffsets.count * 4 + s.tokenTitles.count * 4
        columnBytes += s.suffixKeys.count * 8 + s.suffixRefs.count * 8 + s.guideStart.count * 4
        print("titles=\(s.titleCount) tokens=\(s.tokenCount) postings=\(s.tokenTitles.count) suffixes=\(s.suffixKeys.count)")

        // Controller-side channel remap (once per updateIndex, not per keystroke).
        let slotChannel: [Int32] = index.channelIDs.map { channelByID[$0] == nil ? -1 : 0 }

        // Equivalence: deterministic legacy order == new order, every query.
        var checked = 0
        for (_, q) in queries { for at in [now, now.addingTimeInterval(150_000.25), now.addingTimeInterval(-500_000)] {
            let legacy = legacySearch(q, entries: entries, store: store, channelByID: channelByID, now: at, deterministic: true)
            let fresh = newSearch(q, index: index, slotChannel: slotChannel, now: at)
            precondition(legacy.count == fresh.count, "count mismatch for \(q): \(legacy.count) vs \(fresh.count)")
            for (a, b) in zip(legacy, fresh) {
                precondition(a.ordinal == Int(b.ordinal) && a.score == b.score, "order mismatch for '\(q)'")
            }
            checked += 1
        } }
        print("equivalence: \(checked) query/time pairs identical (order, ids, scores)")

        // Latency per class.
        print("\nclass   | legacy p50 ms | legacy p99 ms | new p50 ms | new p99 ms | speedup p50")
        for cls in ["1-char", "2-char", "3-char", "2-word"] {
            let qs = queries.filter { $0.0 == cls }.map(\.1)
            var legacyMs: [Double] = []
            for q in qs.prefix(legacyRuns * 2) {
                let clock = ContinuousClock.now
                _ = legacySearch(q, entries: entries, store: store, channelByID: channelByID, now: now, deterministic: false)
                legacyMs.append(ms(ContinuousClock.now - clock))
            }
            let avgHits = qs.reduce(0) { $0 + newSearch($1, index: index, slotChannel: slotChannel, now: now).count } / qs.count
            var newMs: [Double] = []
            for _ in 0..<5 { for q in qs {
                let clock = ContinuousClock.now
                _ = newSearch(q, index: index, slotChannel: slotChannel, now: now)
                newMs.append(ms(ContinuousClock.now - clock))
            } }
            print(String(format: "%@  | %13.2f | %13.2f | %10.3f | %10.3f | %8.0fx  (avg results %d)", cls,
                         pct(legacyMs, 0.5), pct(legacyMs, 0.99), pct(newMs, 0.5), pct(newMs, 0.99),
                         pct(legacyMs, 0.5) / pct(newMs, 0.5), avgHits))
        }
        print(String(format: "\nbuild median ms: legacy %.1f  new %.1f", pct(legacyBuildMs, 0.5), pct(newBuildMs, 0.5)))
        print("memory: legacy entries ~\(legacyBytes / 1_048_576) MiB (stride \(MemoryLayout<ProgramSearchEntry>.stride) B)"
              + "; new index arrays \(columnBytes / 1_048_576) MiB")
    }
}
