import Darwin
import Foundation

/// Guide data-core benchmark: persisted-guide cold load, visible-window
/// lookups, ranged lookups, incremental republication and memory footprint.
///
/// Built twice by `scripts/bench-guide-store.sh`:
///   -D BASELINE  against the pre-redesign DataCache/GuideLookup/GuideHistory
///                (JSON cache, per-key Prepared lookups, hour buckets);
///   (default)    against the flat columnar store and `GuideTimeline`.
/// Each subcommand runs in a fresh process so "load" is a process-cold load
/// of a page-cached file, exactly what launch hydration sees.
///
///   guide-store-bench write <channels> <programmesPerChannel>
///   guide-store-bench load
///   guide-store-bench query
@main
enum GuideStoreBenchmark {
    static let key = "guide-store-bench"
    static let now = Date(timeIntervalSince1970: 1_780_000_000)

    static func main() throws {
        let args = CommandLine.arguments
        switch args.count > 1 ? args[1] : "" {
        case "write":
            let channels = args.count > 2 ? Int(args[2])! : 30_000
            let perChannel = args.count > 3 ? Int(args[3])! : 100
            write(channels: channels, perChannel: perChannel)
        case "load": load(queries: false)
        case "query": load(queries: true)
        default:
            print("usage: guide-store-bench write|load|query"); exit(2)
        }
    }

    // MARK: - Fixture

    static func makeGuide(channels: Int, perChannel: Int) -> [String: [EPGProgram]] {
        var rng = SplitMix(seed: 0x5EED)
        // Index 0 is a blank provider title, which retention must drop.
        let titles = (0..<20_000).map { $0 == 0 ? " " : "Programme title number \($0) — \(["News", "Live", "Film", "Match"][$0 % 4])" }
        let descriptions = (0..<60_000).map { i in
            "Episode synopsis \(i): a longer provider description that repeats across airings and channels in real guides."
        }
        var guide: [String: [EPGProgram]] = [:]
        guide.reserveCapacity(channels)
        let first = Int(now.timeIntervalSince1970) - 3 * 86_400
        for c in 0..<channels {
            let id = "channel.\(c).uk"
            var t = first + Int(rng.next() % 3600)
            var list: [EPGProgram] = []
            list.reserveCapacity(perChannel)
            for _ in 0..<perChannel {
                let length = [1800, 3600, 5400, 7200][Int(rng.next() % 4)]
                let unique = rng.next() % 5 == 0
                let description = unique ? "Unique note \(c)-\(t)" : descriptions[Int(rng.next() % UInt64(descriptions.count))]
                list.append(EPGProgram(id: "\(id)_\(t)", channelID: id,
                    title: titles[Int(rng.next() % UInt64(titles.count))], description: description,
                    start: Date(timeIntervalSince1970: TimeInterval(t)),
                    end: Date(timeIntervalSince1970: TimeInterval(t + length))))
                t += length
            }
            guide[id] = list
        }
        return guide
    }

    static func makeChannels(_ keys: [String]) -> [Channel] {
        // A third of channels keep two days of history, so retention drops
        // their oldest day of listings.
        keys.enumerated().map { index, id in
            Channel(id: id, name: id, logoURL: URL(string: "http://127.0.0.1/logo/\(index).png"), group: "Group \(index % 40)",
                    streamURL: URL(string: "http://127.0.0.1/\(id).ts")!, epgChannelID: id,
                    catchup: CatchupInfo(kind: .xc, days: index % 3 == 0 ? 2 : 7, source: nil))
        }
    }

    static func write(channels: Int, perChannel: Int) {
        let guide = makeGuide(channels: channels, perChannel: perChannel)
        let count = guide.values.reduce(0) { $0 + $1.count }
        var samples: [Double] = []
        for _ in 0..<3 {
            let started = ContinuousClock.now
            DataCache.savePrograms(guide, key: key)
            samples.append(ms(since: started))
        }
        DataCache.saveChannels(makeChannels(guide.keys.sorted()), key: key)
        report("save", ["programmes": Double(count), "channels": Double(channels), "saveMs": median(samples)])
    }

    // MARK: - Load and query

    static func load(queries: Bool) {
        let footprintBefore = footprint()
        let loadStarted = ContinuousClock.now
        let channels = DataCache.loadChannels(key: key)?.channels ?? []
        let channelsMs = ms(since: loadStarted)
        let starts = GuideHistory.retentionStarts(channels: channels, now: now)
        let programsStarted = ContinuousClock.now
        #if BASELINE
        // Old hydration: decode the whole JSON guide, then prune.
        guard let cache = DataCache.loadPrograms(key: key) else { fatalError("no cache; run write first") }
        let loadMs = ms(since: programsStarted)
        let pruneStarted = ContinuousClock.now
        let pruned = GuideHistory.prune(cache.programs, starts: starts, now: now)
        let pruneMs = ms(since: pruneStarted)
        #else
        // New hydration: retention applied on the columns during decode.
        guard let cache = DataCache.loadPrograms(key: key, retaining: GuideHistory.retentionPolicy(starts: starts, now: now)) else {
            fatalError("no cache; run write first")
        }
        let loadMs = ms(since: programsStarted)
        let pruned = cache.programs
        let pruneMs = 0.0
        #if VERIFY_PRUNE
        let reference = GuideHistory.prune(DataCache.loadPrograms(key: key)!.programs, starts: starts, now: now)
        precondition(Set(reference.keys) == Set(pruned.keys) && reference.allSatisfy { key, list in
            let other = pruned[key]!
            return other.count == list.count && zip(list, other).allSatisfy { $0.id == $1.id && $0.start == $1.start && $0.end == $1.end && $0.title == $1.title }
        }, "decode-time retention differs from GuideHistory.prune")
        print("verified decode-time retention == GuideHistory.prune")
        #endif
        #endif
        let indexStarted = ContinuousClock.now
        let index = Index(pruned)
        let indexMs = ms(since: indexStarted)
        let total = ms(since: loadStarted)
        let footprintAfter = footprint()
        let count = pruned.values.reduce(0) { $0 + $1.count }
        var values: [String: Double] = [
            "programmes": Double(count), "channels": Double(channels.count),
            "loadProgramsMs": loadMs, "loadChannelsMs": channelsMs, "pruneMs": pruneMs, "indexMs": indexMs,
            "launchTotalMs": total, "footprintMB": Double(footprintAfter - footprintBefore) / 1_048_576,
        ]
        if queries {
            let keys = pruned.keys.sorted()
            let first = max(0, min(1000, keys.count - 60))
            let visible = Array(keys[first..<min(keys.count, first + 60)])
            values.merge(queryBenchmarks(index: index, guide: pruned, visible: visible)) { $1 }
        }
        withExtendedLifetime((cache, pruned, index)) {}
        report(queries ? "query" : "load", values)
    }

    static func queryBenchmarks(index: Index, guide: [String: [EPGProgram]], visible: [String]) -> [String: Double] {
        var result: [String: Double] = [:]
        // 60-row visible window: what is on at one instant, as the grid asks.
        let instants = (0..<64).map { now.addingTimeInterval(Double($0 * 397)) }
        var checksum = 0, packedChecksum = 0
        var samples: [Double] = []
        for _ in 0..<7 {
            let started = ContinuousClock.now
            for _ in 0..<200 {
                for date in instants {
                    for id in visible { if let p = index.program(id, at: date) { checksum &+= p.title.utf8.count } }
                }
            }
            samples.append(ms(since: started) * 1_000_000 / Double(200 * instants.count * visible.count))
        }
        result["lookupNsPerRow"] = median(samples)
        result["lookupWindow60Us"] = median(samples) * 60 / 1000

        // 6h ranged query per visible row.
        samples = []
        for _ in 0..<7 {
            let started = ContinuousClock.now
            for _ in 0..<20 {
                for date in instants {
                    let end = date.addingTimeInterval(6 * 3600)
                    for id in visible { checksum &+= index.programs(id, between: date, and: end).count }
                }
            }
            samples.append(ms(since: started) * 1000 / Double(20 * instants.count))
        }
        result["ranged6hWindow60Us"] = median(samples)

        // Republish after ~1% of channels changed (progressive guide stage).
        let changed = Array(guide.keys.sorted().prefix(guide.count / 100))
        var updated = guide
        for id in changed { updated[id] = guide[id].map { Array($0.dropLast()) } }
        var workerSamples: [Double] = [], mainSamples: [Double] = []
        for _ in 0..<5 {
            let (next, workerMs, mainMs) = index.republish(updated, changed: changed)
            workerSamples.append(workerMs); mainSamples.append(mainMs)
            withExtendedLifetime(next) {}
        }
        result["republish1pctWorkerMs"] = median(workerSamples)
        result["republish1pctMainMs"] = median(mainSamples)
        #if !BASELINE
        // Packed-handle tight scan for 60 rows (no string hashing per query).
        let handles = visible.compactMap { index.timeline.handle(for: $0) }
        var output = [Int32](repeating: -1, count: handles.count)
        samples = []
        for _ in 0..<7 {
            let started = ContinuousClock.now
            for _ in 0..<200 {
                for date in instants {
                    handles.withUnsafeBufferPointer { h in
                        output.withUnsafeMutableBufferPointer { index.timeline.programIndices(h, at: date, into: $0) }
                    }
                    packedChecksum &+= Int(output[7])
                }
            }
            samples.append(ms(since: started) * 1_000_000 / Double(200 * instants.count * handles.count))
        }
        result["packedScanNsPerRow"] = median(samples)
        #endif
        result["checksum"] = Double(checksum & 0xFFFF); _ = packedChecksum
        return result
    }

    // MARK: - Old vs new index (the view model's private storage, verbatim)

    #if BASELINE
    /// Pre-redesign `EPGViewModel` storage: per-key `Prepared` lookups plus
    /// `programHourBuckets` (copied from the old view model).
    struct Index {
        var programs: [String: [EPGProgram]]
        var lookups: [String: GuideLookup.Prepared]
        var hourBuckets: [String: [Int: [Int]]]

        init(_ programs: [String: [EPGProgram]]) {
            self.programs = programs
            hourBuckets = Self.makeProgramHourBuckets(programs)
            lookups = programs.mapValues { GuideLookup.Prepared(programs: $0) }
        }

        static func makeProgramHourBuckets(_ programs: [String: [EPGProgram]]) -> [String: [Int: [Int]]] {
            var hourBuckets: [String: [Int: [Int]]] = [:]
            hourBuckets.reserveCapacity(programs.count)
            for (epgID, progs) in programs {
                var buckets: [Int: [Int]] = [:]
                buckets.reserveCapacity(max(1, progs.count / 8))
                for (programIndex, p) in progs.enumerated() {
                    let startH = Int(floor(p.start.timeIntervalSince1970 / 3600))
                    let endH = Int(floor((p.end.timeIntervalSince1970 - 0.001) / 3600))
                    for h in startH...max(startH, endH) { buckets[h, default: []].append(programIndex) }
                }
                hourBuckets[epgID] = buckets
            }
            return hourBuckets
        }

        func program(_ epgID: String, at date: Date) -> EPGProgram? {
            if let lookup = lookups[epgID] { return lookup.program(containing: date) }
            return GuideLookup.program(in: programs[epgID] ?? [], containing: date)
        }

        func programs(_ epgID: String, between start: Date, and end: Date) -> [EPGProgram] {
            guard let buckets = hourBuckets[epgID], !buckets.isEmpty else { return [] }
            let allPrograms = programs[epgID] ?? []
            let startH = Int(floor(start.timeIntervalSince1970 / 3600)) - 1
            let endH = Int(ceil(end.timeIntervalSince1970 / 3600)) + 1
            var candidates: [EPGProgram] = []
            var seenIndices = Set<Int>()
            for h in startH...endH {
                if let list = buckets[h] {
                    for programIndex in list where seenIndices.insert(programIndex).inserted {
                        guard allPrograms.indices.contains(programIndex) else { continue }
                        let p = allPrograms[programIndex]
                        if p.end > start && p.start < end { candidates.append(p) }
                    }
                }
            }
            return candidates.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        }

        /// Old `publishGuidePrograms`: worker prepares changed keys, the main
        /// thread copies and patches the three dictionaries.
        func republish(_ full: [String: [EPGProgram]], changed: [String]) -> (Index, Double, Double) {
            let workerStarted = ContinuousClock.now
            var delta: [String: [EPGProgram]] = [:]
            for id in changed { delta[id] = full[id] }
            let buckets = Self.makeProgramHourBuckets(delta)
            let prepared = delta.mapValues { GuideLookup.Prepared(programs: $0) }
            let workerMs = ms(since: workerStarted)
            let mainStarted = ContinuousClock.now
            var programs = self.programs, hourBuckets = self.hourBuckets, lookups = self.lookups
            for (id, list) in delta {
                programs[id] = list; hourBuckets[id] = buckets[id]; lookups[id] = prepared[id]
            }
            var next = self
            next.programs = programs; next.hourBuckets = hourBuckets; next.lookups = lookups
            return (next, workerMs, ms(since: mainStarted))
        }
    }
    #else
    struct Index {
        var programs: [String: [EPGProgram]]
        var timeline: GuideTimeline

        init(_ programs: [String: [EPGProgram]]) {
            self.programs = programs
            timeline = GuideTimeline(programs)
        }

        func program(_ epgID: String, at date: Date) -> EPGProgram? {
            guard let handle = timeline.handle(for: epgID) else { return nil }
            return timeline.program(handle, at: date)
        }

        func programs(_ epgID: String, between start: Date, and end: Date) -> [EPGProgram] {
            guard let handle = timeline.handle(for: epgID) else { return [] }
            return timeline.programs(handle, between: start, and: end)
        }

        /// New `publishGuidePrograms`: the worker builds the complete guide
        /// and its timeline (unchanged runs copied); main only assigns.
        func republish(_ full: [String: [EPGProgram]], changed: [String]) -> (Index, Double, Double) {
            let workerStarted = ContinuousClock.now
            var merged = programs
            for id in changed { merged[id] = full[id] }
            let timeline = GuideTimeline(merged, reusing: self.timeline)
            let workerMs = ms(since: workerStarted)
            let mainStarted = ContinuousClock.now
            var next = self
            next.programs = merged
            next.timeline = timeline
            return (next, workerMs, ms(since: mainStarted))
        }
    }
    #endif

    // MARK: - Utilities

    static func ms(since start: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: .now).components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    static func report(_ name: String, _ values: [String: Double]) {
        #if BASELINE
        let variant = "baseline"
        #else
        let variant = "columnar"
        #endif
        let fields = values.keys.sorted().map { "\($0)=\(String(format: "%.3f", values[$0]!))" }
        print("\(variant) \(name) " + fields.joined(separator: " "))
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
