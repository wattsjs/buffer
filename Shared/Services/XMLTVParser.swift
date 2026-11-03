import Foundation
import OSLog
import Synchronization
import SwiftLibxml2

/// XMLTV ingest straight into guide columns.
///
/// Bytes are tokenized by a hand-written scanner that emits the same
/// element/character events libxml2's SAX2 interface produces for the
/// documents it accepts, and feeds them to one programme state machine.
/// Programmes never become per-element `String`s or structs while parsing:
/// channel IDs, titles and descriptions are interned into byte string
/// tables (per scanned part, merged into one global table afterwards), times
/// become `Int32` seconds from `EPGProgram.columnEpoch` (parsed from the
/// timestamp bytes), and each part keeps flat row columns (see `XMLTVGuide`).
///
/// Anything outside the scanner's verified subset of XML (other encodings,
/// DTD internal subsets, undefined entities, malformed markup, invalid
/// UTF-8, ...) hands the document to libxml2's push parser from the last
/// point where no programme was open, replaying the prolog and the open
/// ancestors' start tags, so results stay identical to the libxml2 parser
/// this replaces. Large in-memory documents are split at `<programme`
/// boundaries and scanned in parallel; each part's starting state is
/// verified against its predecessor's end state before it is accepted.
nonisolated struct XMLTVParser {
    static func parse(from url: URL) async throws -> [EPGProgram] {
        try await parseGuide(from: url).programs()
    }

    static func parse(data: Data) -> [EPGProgram] {
        parseGuide(data: data).programs()
    }

    static func parseGuide(data: Data) -> XMLTVGuide {
        parseData(data, cancellation: nil)
    }

    static func parseGuide(from url: URL) async throws -> XMLTVGuide {
        // Perform local file reads inside the detached task (Agent 03) so
        // large XMLTV guides never block the main thread on import/switch.
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { () throws -> XMLTVGuide in
            try Task.checkCancellation()
            let fetchStarted = ContinuousClock.now
            guard url.isFileURL else {
                // Remote guides parse while they download; parse time is
                // hidden behind the transfer instead of following it.
                let result = try await StreamingGuideParse.run(url: url, configuration: guideSessionConfiguration)
                try Task.checkCancellation()
                let totalMs = AppLog.elapsedMilliseconds(since: fetchStarted)
                PerfMetrics.shared.record("guide.xmltv.fetchAndParseMs", Double(totalMs))
                PerfMetrics.shared.record("guide.xmltv.firstByteMs", Double(result.firstByteMs))
                PerfMetrics.shared.record("guide.xmltv.parseCpuMs", Double(result.parseMs))
                AppLog.sync.info("XMLTV loaded bytes=\(result.bytes, privacy: .public) fetchMs=\(totalMs, privacy: .public) parseMs=\(result.parseMs, privacy: .public) firstByteMs=\(result.firstByteMs, privacy: .public) tailParseMs=\(result.tailParseMs, privacy: .public) streamed=true programs=\(result.guide.count, privacy: .public)")
                return result.guide
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            try Task.checkCancellation()
            let fetchMs = AppLog.elapsedMilliseconds(since: fetchStarted)
            let parseStarted = ContinuousClock.now
            let cancellation = XMLTVCancellation()
            let guide = await withTaskCancellationHandler {
                parseData(data, cancellation: cancellation)
            } onCancel: {
                cancellation.cancel()
            }
            try Task.checkCancellation()
            AppLog.sync.info("XMLTV loaded bytes=\(data.count, privacy: .public) fetchMs=\(fetchMs, privacy: .public) parseMs=\(AppLog.elapsedMilliseconds(since: parseStarted), privacy: .public) programs=\(guide.count, privacy: .public)")
            return guide
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    private static func parseData(_ data: Data, cancellation: XMLTVCancellation?) -> XMLTVGuide {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> XMLTVGuide in
            guard raw.count > 0, let base = raw.baseAddress else { return .empty }
            return XMLTVIngest.parse(base.assumingMemoryBound(to: UInt8.self), count: raw.count, cancellation: cancellation)
        }
    }
}

private extension XMLTVParser {
    static var guideSessionConfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 180
        return config
    }
}

// MARK: - Guide columns

/// A parsed XMLTV guide in column form. Rows live in parts (one per scanned
/// region, in document order) as flat columns; titles and descriptions are
/// interned once into a global byte string table (hash-partitioned into
/// buckets when parts were scanned in parallel). `EPGProgram` façades are
/// built only on request, with one `String` per distinct channel ID, title
/// and description.
nonisolated struct XMLTVGuide: Sendable {
    fileprivate let parts: [XMLTVRows]
    /// Global channel ID strings, in first-appearance order.
    fileprivate let channelIDs: [String]
    /// Per part: local channel ID → index into `channelIDs`.
    fileprivate let channelMaps: [[UInt32]]
    /// Global title/description tables, one per hash bucket.
    fileprivate let textTables: [XMLTVByteTable]
    /// Per part: local text ID → `bucket << textBucketShift | index`.
    /// Empty for a single part, whose own table is the global one.
    fileprivate let textMaps: [[UInt32]]
    fileprivate static let textBucketShift: UInt32 = 26

    /// Number of programmes.
    let count: Int

    static let empty = XMLTVGuide(parts: [])

    fileprivate init(parts: [XMLTVRows]) {
        precondition(Int64(xmltvColumnEpoch) == EPGProgram.columnEpoch)
        var parts = parts.filter { $0.count > 0 }
        var ids: [String] = []
        var index: [String: UInt32] = [:]
        var maps: [[UInt32]] = []
        maps.reserveCapacity(parts.count)
        for part in parts {
            var map = [UInt32](repeating: 0, count: part.channels.count)
            for local in 0..<part.channels.count {
                let id = part.channels.string(UInt32(local))
                if let existing = index[id] {
                    map[local] = existing
                } else {
                    let global = UInt32(ids.count)
                    ids.append(id)
                    index[id] = global
                    map[local] = global
                }
            }
            maps.append(map)
        }
        channelIDs = ids
        channelMaps = maps
        count = parts.reduce(0) { $0 + $1.count }

        if parts.count <= 1 {
            textTables = parts.map(\.text)
            textMaps = []
        } else {
            (textTables, textMaps) = Self.mergeText(parts)
            // The per-part tables are now redundant.
            for index in parts.indices { parts[index].text = XMLTVByteTable() }
        }
        self.parts = parts
    }

    /// Merges per-part text tables into hash-partitioned global tables, in
    /// parallel by bucket; parts are visited in order, so IDs are a
    /// deterministic function of the document.
    private static func mergeText(_ parts: [XMLTVRows]) -> ([XMLTVByteTable], [[UInt32]]) {
        let bucketCount = 64
        let shift = UInt32(32 - 6)
        // Per part: local IDs grouped by bucket.
        var grouped: [(ids: [UInt32], starts: [Int])] = []
        grouped.reserveCapacity(parts.count)
        for part in parts {
            let table = part.text
            var starts = [Int](repeating: 0, count: bucketCount + 1)
            for id in 0..<table.count { starts[Int(table.hash32(id) >> shift) + 1] += 1 }
            for bucket in 0..<bucketCount { starts[bucket + 1] += starts[bucket] }
            var cursor = starts
            var ids = [UInt32](repeating: 0, count: table.count)
            for id in 0..<table.count {
                let bucket = Int(table.hash32(id) >> shift)
                ids[cursor[bucket]] = UInt32(id)
                cursor[bucket] += 1
            }
            grouped.append((ids, starts))
        }
        let maps = parts.map { UnsafeMutableBufferPointer<UInt32>.allocate(capacity: max(1, $0.text.count)) }
        defer { maps.forEach { $0.deallocate() } }
        let tables = UnsafeMutableBufferPointer<XMLTVByteTable>.allocate(capacity: bucketCount)
        tables.initialize(repeating: XMLTVByteTable())
        defer { tables.deinitialize(); tables.deallocate() }
        let output = XMLTVUnchecked((maps, tables)), groups = grouped
        DispatchQueue.concurrentPerform(iterations: bucketCount) { bucket in
            var table = XMLTVByteTable()
            let high = UInt32(bucket) << XMLTVGuide.textBucketShift
            for (index, part) in parts.enumerated() {
                let group = groups[index]
                let map = output.value.0[index]
                for slot in group.starts[bucket]..<group.starts[bucket + 1] {
                    let id = Int(group.ids[slot])
                    map[id] = high | part.text.withBytes(id) { table.intern($0, $1, hash32: part.text.hash32(id)) }
                }
            }
            output.value.1[bucket] = table
        }
        return (Array(tables), zip(maps, parts).map { Array(UnsafeBufferPointer(rebasing: $0[0..<$1.text.count])) })
    }

    var isEmpty: Bool { count == 0 }

    /// Earliest programme start, equal to `programs().map(\.start).min()`.
    var earliestStart: Date? {
        var best: Int?
        for part in parts {
            for row in 0..<part.count {
                let value = part.startSeconds(row)
                if best == nil || value < best! { best = value }
            }
        }
        return best.map(xmltvDate)
    }

    /// Latest programme end, equal to `programs().map(\.end).max()`.
    var latestEnd: Date? {
        var best: Int?
        for part in parts {
            for row in 0..<part.count {
                let value = part.endSeconds(row)
                if best == nil || value > best! { best = value }
            }
        }
        return best.map(xmltvDate)
    }

    /// All programmes in document order (the libxml2 parser's output).
    func programs() -> [EPGProgram] {
        let strings = materializeText()
        var result: [EPGProgram] = []
        result.reserveCapacity(count)
        for (index, part) in parts.enumerated() {
            let map = channelMaps[index], textMap = textMaps.isEmpty ? [] : textMaps[index]
            for row in 0..<part.count {
                result.append(part.program(row, channelID: channelIDs[Int(map[Int(part.channel[row])])], text: strings, textMap: textMap))
            }
        }
        return result
    }

    /// Programmes grouped per channel ID, each list in document order and
    /// sorted by start where it was not already: exactly
    /// `EPGViewModel.organize(programs())`, built by a counting sort over
    /// the channel column instead of per-programme dictionary appends.
    func programsByChannel() -> [String: [EPGProgram]] {
        guard count > 0 else { return [:] }
        let channelCount = channelIDs.count
        var counts = [Int](repeating: 0, count: channelCount + 1)
        for (index, part) in parts.enumerated() {
            let map = channelMaps[index]
            for row in 0..<part.count { counts[Int(map[Int(part.channel[row])]) + 1] += 1 }
        }
        for channel in 0..<channelCount { counts[channel + 1] += counts[channel] }
        let offsets = counts
        // Rows grouped per channel, stable in document order: part << 32 | row.
        var grouped = [UInt64](repeating: 0, count: count)
        var cursor = offsets
        for (index, part) in parts.enumerated() {
            let map = channelMaps[index]
            let high = UInt64(index) << 32
            for row in 0..<part.count {
                let channel = Int(map[Int(part.channel[row])])
                grouped[cursor[channel]] = high | UInt64(row)
                cursor[channel] += 1
            }
        }
        let order = grouped
        let strings = materializeText()
        let lists = UnsafeMutableBufferPointer<[EPGProgram]>.allocate(capacity: channelCount)
        lists.initialize(repeating: [])
        defer { lists.deinitialize(); lists.deallocate() }
        let output = XMLTVUnchecked(lists)
        let build: (Int, Int) -> Void = { firstChannel, lastChannel in
            order.withUnsafeBufferPointer { order in
                for channel in firstChannel..<lastChannel {
                    let lo = offsets[channel], hi = offsets[channel + 1]
                    let channelID = channelIDs[channel]
                    var list: [EPGProgram] = []
                    list.reserveCapacity(hi - lo)
                    var sorted = true
                    var previous = Int.min
                    for slot in lo..<hi {
                        let packed = order[slot]
                        let index = Int(packed >> 32), row = Int(packed & 0xFFFF_FFFF)
                        let part = parts[index]
                        let start = part.startSeconds(row)
                        if start < previous { sorted = false }
                        previous = start
                        list.append(part.program(row, channelID: channelID, text: strings,
                                                 textMap: textMaps.isEmpty ? [] : textMaps[index]))
                    }
                    // Most XMLTV generators emit programmes in chronological
                    // order; sort only channels that are not (same sort as
                    // `EPGViewModel.organize`, applied to the same order).
                    if !sorted { list = list.sorted { $0.start < $1.start } }
                    output.value[channel] = list
                }
            }
        }
        let chunks = count < 65_536 ? 1 : min(channelCount, ProcessInfo.processInfo.activeProcessorCount * 2)
        if chunks <= 1 {
            build(0, channelCount)
        } else {
            // Contiguous channel ranges balanced by row count.
            var bounds = [0]
            for chunk in 1..<chunks {
                let target = count / chunks * chunk
                var low = bounds.last!, high = channelCount
                while low < high {
                    let mid = (low + high) >> 1
                    if offsets[mid] < target { low = mid + 1 } else { high = mid }
                }
                bounds.append(low)
            }
            bounds.append(channelCount)
            let work = XMLTVUnchecked(build)
            DispatchQueue.concurrentPerform(iterations: bounds.count - 1) { chunk in
                if bounds[chunk] < bounds[chunk + 1] { work.value(bounds[chunk], bounds[chunk + 1]) }
            }
        }
        var organized: [String: [EPGProgram]] = [:]
        organized.reserveCapacity(channelCount)
        // Rows truncated by a libxml2 replay can leave channel IDs without rows.
        for channel in 0..<channelCount where offsets[channel + 1] > offsets[channel] {
            organized[channelIDs[channel]] = lists[channel]
        }
        return organized
    }

    /// One `String` per distinct title/description, per bucket (in parallel).
    private func materializeText() -> [[String]] {
        if textTables.count <= 1 { return textTables.map { $0.strings() } }
        let output = UnsafeMutableBufferPointer<[String]>.allocate(capacity: textTables.count)
        output.initialize(repeating: [])
        defer { output.deinitialize(); output.deallocate() }
        let slots = XMLTVUnchecked(output), tables = textTables
        DispatchQueue.concurrentPerform(iterations: tables.count) { index in
            slots.value[index] = tables[index].strings()
        }
        return Array(output)
    }
}

nonisolated private struct XMLTVUnchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

nonisolated final class XMLTVCancellation: Sendable {
    private let flag = Atomic<Bool>(false)
    func cancel() { flag.store(true, ordering: .relaxed) }
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

/// Interned UTF-8 byte strings: one blob, end offsets, open addressing.
nonisolated private struct XMLTVByteTable {
    private(set) var blob: [UInt8] = []
    private var ends: [Int] = [0]
    private var hashes: [UInt32] = []
    private var slots: [UInt32] = Array(repeating: 0, count: 256)

    var count: Int { hashes.count }

    @inline(__always) static func hash(_ p: UnsafePointer<UInt8>, _ n: Int) -> UInt64 {
        var h: UInt64 = 0x9E37_79B9_7F4A_7C15 ^ UInt64(truncatingIfNeeded: n)
        let raw = UnsafeRawPointer(p)
        var i = 0
        while i + 8 <= n {
            h = (h ^ raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)) &* 0xFF51_AFD7_ED55_8CCD
            h ^= h >> 32
            i += 8
        }
        if i < n {
            var tail: UInt64 = 0
            var shift: UInt64 = 0
            while i < n { tail |= UInt64(p[i]) << shift; shift += 8; i += 1 }
            h = (h ^ tail) &* 0xC4CE_B9FE_1A85_EC53
        }
        h ^= h >> 29
        h = h &* 0xBF58_476D_1CE4_E5B9
        return h ^ (h >> 32)
    }

    @inline(__always) mutating func intern(_ p: UnsafePointer<UInt8>, _ n: Int) -> UInt32 {
        intern(p, n, hash32: UInt32(truncatingIfNeeded: Self.hash(p, n)))
    }

    func hash32(_ id: Int) -> UInt32 { hashes[id] }

    func withBytes<R>(_ id: Int, _ body: (UnsafePointer<UInt8>, Int) -> R) -> R {
        blob.withUnsafeBufferPointer { body($0.baseAddress.map { $0 + ends[id] } ?? UnsafePointer(bitPattern: 1)!, ends[id + 1] - ends[id]) }
    }

    /// Interns with a precomputed `hash32` (the low 32 bits of `hash`).
    mutating func intern(_ p: UnsafePointer<UInt8>, _ n: Int, hash32 h32: UInt32) -> UInt32 {
        var mask = slots.count - 1
        var slot = Int(h32) & mask
        while true {
            let entry = slots[slot]
            if entry == 0 { break }
            let id = Int(entry - 1)
            if hashes[id] == h32 {
                let lo = ends[id], len = ends[id + 1] - lo
                if len == n {
                    let equal = blob.withUnsafeBufferPointer { memcmp($0.baseAddress! + lo, p, n) == 0 }
                    if equal || n == 0 { return UInt32(id) }
                }
            }
            slot = (slot + 1) & mask
        }
        let id = hashes.count
        blob.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
        ends.append(blob.count)
        hashes.append(h32)
        slots[slot] = UInt32(id + 1)
        if hashes.count * 2 > slots.count {
            var grown = [UInt32](repeating: 0, count: slots.count * 2)
            mask = grown.count - 1
            for (index, value) in hashes.enumerated() {
                var s = Int(value) & mask
                while grown[s] != 0 { s = (s + 1) & mask }
                grown[s] = UInt32(index + 1)
            }
            slots = grown
        }
        return UInt32(id)
    }

    func string(_ id: UInt32) -> String {
        let lo = ends[Int(id)], hi = ends[Int(id) + 1]
        return blob.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[lo..<hi]), as: UTF8.self) }
    }

    func strings() -> [String] {
        var result: [String] = []
        result.reserveCapacity(count)
        blob.withUnsafeBufferPointer { blob in
            for id in 0..<count {
                result.append(String(decoding: UnsafeBufferPointer(rebasing: blob[ends[id]..<ends[id + 1]]), as: UTF8.self))
            }
        }
        return result
    }

    func equals(_ id: UInt32, _ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        let lo = ends[Int(id)]
        guard ends[Int(id) + 1] - lo == n else { return false }
        return n == 0 || blob.withUnsafeBufferPointer { memcmp($0.baseAddress! + lo, p, n) == 0 }
    }
}

/// Row columns for one scanned region of the document.
nonisolated private struct XMLTVRows: Sendable {
    var text = XMLTVByteTable()
    var channels = XMLTVByteTable()
    var channel: [UInt32] = []
    var title: [UInt32] = []
    var desc: [UInt32] = []
    /// Seconds from `EPGProgram.columnEpoch`; `Int32.min` marks a row whose
    /// times are kept exactly in `exceptions`.
    var start: [Int32] = []
    var end: [Int32] = []
    var exceptions: [(row: Int, start: Int, end: Int)] = []
    private var lastChannel: UInt32 = .max

    var count: Int { channel.count }

    @inline(__always) private static func trim(_ p: UnsafePointer<UInt8>, _ n: Int) -> (UnsafePointer<UInt8>, Int) {
        var lo = 0, hi = n
        while lo < hi && xmltvIsSpace(p[lo]) { lo += 1 }
        while hi > lo && xmltvIsSpace(p[hi - 1]) { hi -= 1 }
        return (p + lo, hi - lo)
    }

    mutating func append(channel c: UnsafePointer<UInt8>, _ cn: Int, start s: Int, end e: Int,
                title t: UnsafePointer<UInt8>, _ tn: Int, desc d: UnsafePointer<UInt8>, _ dn: Int) {
        let channelID: UInt32
        if lastChannel != .max, channels.equals(lastChannel, c, cn) {
            channelID = lastChannel
        } else {
            channelID = channels.intern(c, cn)
            lastChannel = channelID
        }
        let (tp, tl) = Self.trim(t, tn), (dp, dl) = Self.trim(d, dn)
        channel.append(channelID)
        title.append(text.intern(tp, tl))
        desc.append(text.intern(dp, dl))
        let rs = s &- xmltvColumnEpoch, re = e &- xmltvColumnEpoch
        if rs > Int(Int32.min), rs <= Int(Int32.max), re > Int(Int32.min), re <= Int(Int32.max) {
            start.append(Int32(rs))
            end.append(Int32(re))
        } else {
            exceptions.append((channel.count - 1, s, e))
            start.append(.min)
            end.append(.min)
        }
    }

    mutating func truncate(to rows: Int) {
        guard rows < count else { return }
        channel.removeSubrange(rows...)
        title.removeSubrange(rows...)
        desc.removeSubrange(rows...)
        start.removeSubrange(rows...)
        end.removeSubrange(rows...)
        exceptions.removeAll { $0.row >= rows }
        lastChannel = .max
    }

    private func exception(_ row: Int) -> (start: Int, end: Int) {
        var low = 0, high = exceptions.count
        while low < high {
            let mid = (low + high) >> 1
            if exceptions[mid].row < row { low = mid + 1 } else { high = mid }
        }
        return (exceptions[low].start, exceptions[low].end)
    }

    @inline(__always) func startSeconds(_ row: Int) -> Int {
        let value = start[row]
        return value == .min ? exception(row).start : xmltvColumnEpoch + Int(value)
    }

    @inline(__always) func endSeconds(_ row: Int) -> Int {
        let value = end[row]
        return value == .min ? exception(row).end : xmltvColumnEpoch + Int(value)
    }

    @inline(__always) func program(_ row: Int, channelID: String, text: [[String]], textMap: [UInt32]) -> EPGProgram {
        @inline(__always) func string(_ local: UInt32) -> String {
            if textMap.isEmpty { return text[0][Int(local)] }
            let global = textMap[Int(local)]
            return text[Int(global >> XMLTVGuide.textBucketShift)][Int(global & (1 << XMLTVGuide.textBucketShift - 1))]
        }
        return EPGProgram(channelStartIDWithChannelID: channelID,
                   title: string(title[row]), description: string(desc[row]),
                   start: xmltvDate(startSeconds(row)), end: xmltvDate(endSeconds(row)))
    }
}

/// `EPGProgram.columnEpoch` as a file-local constant the optimizer folds
/// (checked against the model in `XMLTVGuide.init`).
nonisolated private let xmltvColumnEpoch = 1_700_000_000

/// `Date(timeIntervalSince1970:)`, which is defined as this subtraction.
@inline(__always)
nonisolated private func xmltvDate(_ seconds: Int) -> Date {
    Date(timeIntervalSinceReferenceDate: TimeInterval(seconds) - Date.timeIntervalBetween1970AndReferenceDate)
}

// MARK: - Programme state machine

/// The programme rules of the original SAX context, driven by either the
/// byte scanner or libxml2. Text is accumulated as raw (decoded) bytes.
nonisolated private struct XMLTVProgrammeState {
    var inProgramme = false
    var channel: [UInt8] = []
    var hasStart = false, hasEnd = false
    var start = 0, end = 0
    /// 0: none, 1: title, 2: desc.
    var field: UInt8 = 0
    var title: [UInt8] = []
    var desc: [UInt8] = []

    init() {
        channel.reserveCapacity(64)
        title.reserveCapacity(128)
        desc.reserveCapacity(1024)
    }

    @inline(__always) var wantsText: Bool { field != 0 }

    @inline(__always) mutating func startProgramme() {
        inProgramme = true
        channel.removeAll(keepingCapacity: true)
        hasStart = false
        hasEnd = false
        field = 0
        title.removeAll(keepingCapacity: true)
        desc.removeAll(keepingCapacity: true)
    }

    @inline(__always) mutating func setStart(_ p: UnsafePointer<UInt8>, _ n: Int) {
        if let value = parseXMLTVDate(p, length: n) { start = value; hasStart = true } else { hasStart = false }
    }

    @inline(__always) mutating func setEnd(_ p: UnsafePointer<UInt8>, _ n: Int) {
        if let value = parseXMLTVDate(p, length: n) { end = value; hasEnd = true } else { hasEnd = false }
    }

    @inline(__always) mutating func setChannel(_ p: UnsafePointer<UInt8>, _ n: Int) {
        channel.removeAll(keepingCapacity: true)
        channel.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
    }

    @inline(__always) mutating func startOther(isTitle: Bool, isDesc: Bool) {
        guard inProgramme else { return }
        field = isTitle ? 1 : (isDesc ? 2 : 0)
    }

    @inline(__always) mutating func appendText(_ p: UnsafePointer<UInt8>, _ n: Int) {
        if field == 1 { title.append(contentsOf: UnsafeBufferPointer(start: p, count: n)) }
        else if field == 2 { desc.append(contentsOf: UnsafeBufferPointer(start: p, count: n)) }
    }

    @inline(__always) mutating func appendByte(_ b: UInt8) {
        if field == 1 { title.append(b) } else if field == 2 { desc.append(b) }
    }

    mutating func endElement(isProgramme: Bool, rows: inout XMLTVRows) {
        if isProgramme {
            if hasStart, hasEnd, !channel.isEmpty {
                channel.withUnsafeBufferPointer { c in
                    title.withUnsafeBufferPointer { t in
                        desc.withUnsafeBufferPointer { d in
                            let empty = UnsafePointer<UInt8>(bitPattern: 1)!
                            rows.append(channel: c.baseAddress!, c.count, start: start, end: end,
                                        title: t.baseAddress ?? empty, t.count, desc: d.baseAddress ?? empty, d.count)
                        }
                    }
                }
            }
            inProgramme = false
            field = 0
            return
        }
        if inProgramme { field = 0 }
    }
}

/// High bit set in each zero byte of `y`.
@inline(__always)
nonisolated private func xmltvZeroBytes(_ y: UInt64) -> UInt64 {
    ~(((y & 0x7F7F_7F7F_7F7F_7F7F) &+ 0x7F7F_7F7F_7F7F_7F7F) | y) & 0x8080_8080_8080_8080
}

@inline(__always)
nonisolated private func xmltvIsSpace(_ b: UInt8) -> Bool {
    b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
}

/// Parse an XMLTV timestamp like `20240114193000 +0000` (or the same without
/// an offset — treated as UTC) straight out of its raw byte slice into Unix
/// seconds. Allocation-free; identical rules to the libxml2-era parser.
@inline(__always)
nonisolated private func parseXMLTVDate(_ ptr: UnsafePointer<UInt8>, length: Int) -> Int? {
    guard length >= 14 else { return nil }
    for i in 0..<14 {
        let c = ptr[i]
        if c < 0x30 || c > 0x39 { return nil }
    }
    @inline(__always) func d(_ i: Int) -> Int { Int(ptr[i]) - 0x30 }
    @inline(__always) func d2(_ i: Int) -> Int { d(i) * 10 + d(i + 1) }
    let year   = d(0) * 1000 + d(1) * 100 + d(2) * 10 + d(3)
    let month  = d2(4)
    let day    = d2(6)
    let hour   = d2(8)
    let minute = d2(10)
    let second = d2(12)
    guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
    // Optional " ±HHMM" offset (skip at most one leading space).
    var tzSeconds = 0
    var p = 14
    if p < length, ptr[p] == 0x20 { p += 1 }
    if p + 5 <= length {
        let signByte = ptr[p]
        if signByte == 0x2B || signByte == 0x2D {
            for i in (p + 1)..<(p + 5) {
                let c = ptr[i]
                if c < 0x30 || c > 0x39 { return nil }
            }
            let sign = signByte == 0x2D ? -1 : 1
            let tzH = Int(ptr[p + 1] - 0x30) * 10 + Int(ptr[p + 2] - 0x30)
            let tzM = Int(ptr[p + 3] - 0x30) * 10 + Int(ptr[p + 4] - 0x30)
            tzSeconds = sign * (tzH * 3600 + tzM * 60)
        }
    }
    // Howard Hinnant days-from-civil.
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let m = month + (month > 2 ? -3 : 9)
    let doy = (153 * m + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let daysSinceEpoch = era * 146097 + doe - 719468
    return daysSinceEpoch * 86400 + hour * 3600 + minute * 60 + second - tzSeconds
}

// MARK: - Byte validation

/// Scans `[from, to)` for bytes libxml2 would reject as UTF-8 XML characters
/// (C0 controls other than tab/LF/CR, U+FFFE/U+FFFF, invalid or overlong
/// sequences). Returns the first bad offset, or nil and the end of the
/// validated bytes: without `final`, a sequence cut by `to` is left for the
/// next call.
nonisolated private func xmltvValidate(_ p: UnsafePointer<UInt8>, from: Int, to: Int, final: Bool) -> (bad: Int?, validEnd: Int) {
    let high: UInt64 = 0x8080_8080_8080_8080
    let low7: UInt64 = 0x7F7F_7F7F_7F7F_7F7F
    @inline(__always) func zeroBytes(_ y: UInt64) -> UInt64 { ~(((y & low7) &+ low7) | y) & high }
    let raw = UnsafeRawPointer(p)
    var i = from
    while i < to {
        if i + 8 <= to {
            let w = raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)
            if w & high == 0 {
                // Bytes below 0x20 lack the high bit after adding 0x60.
                let controls = ~((w &+ 0x6060_6060_6060_6060) & high) & high
                if controls == 0 { i += 8; continue }
                let allowed = zeroBytes(w ^ 0x0909_0909_0909_0909) | zeroBytes(w ^ 0x0A0A_0A0A_0A0A_0A0A)
                    | zeroBytes(w ^ 0x0D0D_0D0D_0D0D_0D0D)
                if controls & ~allowed == 0 { i += 8; continue }
            }
        }
        let b = p[i]
        if b < 0x80 {
            if b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D { return (i, i) }
            i += 1
            continue
        }
        let need: Int
        var lower: UInt8 = 0x80, upper: UInt8 = 0xBF
        switch b {
        case 0xC2...0xDF: need = 1
        case 0xE0: need = 2; lower = 0xA0
        case 0xE1...0xEC, 0xEE...0xEF: need = 2
        case 0xED: need = 2; upper = 0x9F
        case 0xF0: need = 3; lower = 0x90
        case 0xF1...0xF3: need = 3
        case 0xF4: need = 3; upper = 0x8F
        default: return (i, i)
        }
        let available = min(need, to - i - 1)
        for k in stride(from: 1, through: available, by: 1) {
            let c = p[i + k]
            if k == 1 ? (c < lower || c > upper) : (c < 0x80 || c > 0xBF) { return (i, i) }
        }
        if available < need { return final ? (i, i) : (nil, i) }
        // U+FFFE and U+FFFF are not XML characters.
        if b == 0xEF, p[i + 1] == 0xBF, p[i + 2] >= 0xBE { return (i, i) }
        i += need + 1
    }
    return (nil, to)
}

// MARK: - Byte scanner

nonisolated private enum XMLTVScanStatus {
    /// Stopped at a token boundary at or after the limit.
    case reachedLimit
    /// The next token is incomplete within the available bytes.
    case needMore
    /// Outside the verified subset: replay through libxml2.
    case fallback
    /// No further programme can be emitted: the root element closed (or
    /// libxml2 would halt at extra content after it).
    case done
    case cancelled
}

/// Tokenizes the libxml2-compatible subset of XML and drives the programme
/// state machine. Positions are byte offsets into the caller's buffer.
nonisolated private struct XMLTVScanner {
    enum Phase: UInt8 { case prolog, content, done }

    struct Entry {
        /// Into `stackBytes`, or into the scanned buffer when `inBuffer`
        /// (elements inside a programme: they always lie after the commit
        /// point, so the streaming buffer still holds them).
        var nameStart: Int, nameLength: Int
        /// Raw start-tag bytes in `stackBytes` for elements outside any
        /// programme (replayed to libxml2), else -1.
        var rawStart: Int, rawLength: Int
        var isProgramme: Bool
        var inBuffer: Bool
    }

    struct Underflow {
        var name: [UInt8]
        /// Position after the end tag and the row count at that point.
        var position: Int
        var rows: Int
    }

    static let maximumDepth = 200
    static let maximumToken = 1 << 20

    var pos: Int
    var phase: Phase
    let speculative: Bool
    var rows = XMLTVRows()
    var state = XMLTVProgrammeState()

    var stack: [Entry] = []
    var stackBytes: [UInt8] = []
    var programmeOpen = 0
    var maximumLocalDepth = 0
    var underflows: [Underflow] = []

    /// Last token boundary after the root start tag with no programme open:
    /// libxml2 replays from here.
    var commitPos: Int
    var commitRows = 0
    var commitDepth = 0
    var prolog: [UInt8] = []
    private var sawDoctype = false
    private var attributeNames: [Int] = []
    private var scratch: [UInt8] = []
    private var nextCancellationCheck = 0

    /// A scanner for a document from its first byte.
    init() {
        pos = 0
        phase = .prolog
        speculative = false
        commitPos = 0
    }

    /// A scanner starting at a `<programme` tag inside the root element,
    /// with unknown ancestors (verified when its result is adopted).
    init(speculativeAt position: Int) {
        pos = position
        phase = .content
        speculative = true
        commitPos = position
    }

    // MARK: Byte helpers

    @inline(__always) private static func isNameChar(_ b: UInt8) -> Bool {
        // '-' '.' '0'-'9', 'A'-'Z' '_' 'a'-'z' (':' is handled by callers).
        if b < 64 { return (0x03FF_6000_0000_0000 as UInt64) >> UInt64(b) & 1 != 0 }
        if b < 128 { return (0x07FF_FFFE_87FF_FFFE as UInt64) >> UInt64(b - 64) & 1 != 0 }
        return false
    }

    @inline(__always) private static func isNameStart(_ b: UInt8) -> Bool {
        let l = b | 0x20
        return (l >= 0x61 && l <= 0x7A) || b == 0x5F
    }

    @inline(__always) private static func equals(_ p: UnsafePointer<UInt8>, _ n: Int, _ literal: StaticString) -> Bool {
        n == literal.utf8CodeUnitCount && memcmp(p, literal.utf8Start, n) == 0
    }

    @inline(__always) private static func find(_ base: UnsafePointer<UInt8>, _ byte: UInt8, from: Int, to: Int) -> Int? {
        guard from < to, let hit = memchr(base + from, Int32(byte), to - from) else { return nil }
        return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
    }

    @inline(__always) private static func incomplete(_ final: Bool) -> XMLTVScanStatus { final ? .fallback : .needMore }

    /// `&...;` at `i`: the predefined entities and valid character
    /// references only. Returns the index after `;` and the scalar.
    private static func entity(_ base: UnsafePointer<UInt8>, at i: Int, end: Int) -> (next: Int, value: UInt32)? {
        var j = i + 1
        let limit = min(end, i + 12)
        while j < limit && base[j] != 0x3B { j += 1 }
        guard j < limit else { return nil }
        let name = base + i + 1, n = j - i - 1
        if n >= 2, name[0] == 0x23 {
            var value: UInt32 = 0
            if name[1] == 0x78 {
                guard n >= 3 else { return nil }
                for k in 2..<n {
                    let c = name[k]
                    let digit: UInt32
                    switch c {
                    case 0x30...0x39: digit = UInt32(c - 0x30)
                    case 0x41...0x46: digit = UInt32(c - 0x41 + 10)
                    case 0x61...0x66: digit = UInt32(c - 0x61 + 10)
                    default: return nil
                    }
                    value = value * 16 + digit
                }
            } else {
                for k in 1..<n {
                    let c = name[k]
                    guard c >= 0x30, c <= 0x39 else { return nil }
                    value = value * 10 + UInt32(c - 0x30)
                }
            }
            // The XML Char production.
            guard value == 0x9 || value == 0xA || value == 0xD || (value >= 0x20 && value <= 0xD7FF)
                    || (value >= 0xE000 && value <= 0xFFFD) || (value >= 0x10000 && value <= 0x10FFFF) else { return nil }
            return (j + 1, value)
        }
        if equals(name, n, "lt") { return (j + 1, 0x3C) }
        if equals(name, n, "gt") { return (j + 1, 0x3E) }
        if equals(name, n, "amp") { return (j + 1, 0x26) }
        if equals(name, n, "quot") { return (j + 1, 0x22) }
        if equals(name, n, "apos") { return (j + 1, 0x27) }
        return nil
    }

    @inline(__always) private static func withUTF8(_ value: UInt32, _ body: (UnsafePointer<UInt8>, Int) -> Void) {
        var bytes: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
        let count: Int
        if value < 0x80 {
            bytes.0 = UInt8(value); count = 1
        } else if value < 0x800 {
            bytes = (UInt8(0xC0 | (value >> 6)), UInt8(0x80 | (value & 0x3F)), 0, 0); count = 2
        } else if value < 0x10000 {
            bytes = (UInt8(0xE0 | (value >> 12)), UInt8(0x80 | ((value >> 6) & 0x3F)), UInt8(0x80 | (value & 0x3F)), 0); count = 3
        } else {
            bytes = (UInt8(0xF0 | (value >> 18)), UInt8(0x80 | ((value >> 12) & 0x3F)),
                     UInt8(0x80 | ((value >> 6) & 0x3F)), UInt8(0x80 | (value & 0x3F))); count = 4
        }
        withUnsafeBytes(of: bytes) { body($0.baseAddress!.assumingMemoryBound(to: UInt8.self), count) }
    }

    /// True when every `&` in `[s, e)` starts a valid reference.
    private static func referencesAreValid(_ base: UnsafePointer<UInt8>, _ s: Int, _ e: Int) -> Bool {
        var i = s
        while let amp = find(base, 0x26, from: i, to: e) {
            guard let (next, _) = entity(base, at: amp, end: e) else { return false }
            i = next
        }
        return true
    }

    /// Character data `[s, e)` inside an element.
    private mutating func content(_ base: UnsafePointer<UInt8>, _ s: Int, _ e: Int) -> Bool {
        guard state.wantsText else {
            // Not collected: only verify it is well-formed character data.
            if e - s <= 32 {
                // Mostly indentation between tags.
                var i = s
                while i < e {
                    let b = base[i]
                    if b == 0x26 || b == 0x5D { break }
                    i += 1
                }
                if i == e { return true }
            }
            guard Self.referencesAreValid(base, s, e) else { return false }
            var i = s
            while let bracket = Self.find(base, 0x5D, from: i, to: e) {
                if bracket + 2 < e, base[bracket + 1] == 0x5D, base[bracket + 2] == 0x3E { return false }
                i = bracket + 1
            }
            return true
        }
        var run = s, i = s
        let raw = UnsafeRawPointer(base)
        while i < e {
            // Skip words without '&', CR or ']'.
            if i + 8 <= e {
                let w = raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)
                if xmltvZeroBytes(w ^ 0x2626_2626_2626_2626) | xmltvZeroBytes(w ^ 0x0D0D_0D0D_0D0D_0D0D)
                    | xmltvZeroBytes(w ^ 0x5D5D_5D5D_5D5D_5D5D) == 0 { i += 8; continue }
            }
            let b = base[i]
            guard b == 0x26 || b == 0x0D || b == 0x5D else { i += 1; continue }
            if i > run { state.appendText(base + run, i - run) }
            if b == 0x26 {
                guard let (next, value) = Self.entity(base, at: i, end: e) else { return false }
                Self.withUTF8(value) { state.appendText($0, $1) }
                i = next
            } else if b == 0x0D {
                // Line-end normalization: CR LF and lone CR become LF.
                state.appendByte(0x0A)
                i += (i + 1 < e && base[i + 1] == 0x0A) ? 2 : 1
            } else {
                if i + 2 < e, base[i + 1] == 0x5D, base[i + 2] == 0x3E { return false }
                state.appendByte(0x5D)
                i += 1
            }
            run = i
        }
        if e > run { state.appendText(base + run, e - run) }
        return true
    }

    @inline(__always) private mutating func markCommit() {
        if programmeOpen == 0 && !speculative && phase == .content {
            commitPos = pos
            commitRows = rows.count
            commitDepth = stack.count
        }
    }

    // MARK: Main loop

    /// Scans tokens that start before `limit`, reading at most up to `end`.
    /// `final` means no bytes follow `end`.
    mutating func run(_ base: UnsafePointer<UInt8>, limit: Int, end: Int, final: Bool,
                      cancellation: XMLTVCancellation?) -> XMLTVScanStatus {
        while pos < limit {
            if phase == .done { return .done }
            if let cancellation, pos >= nextCancellationCheck {
                if cancellation.isCancelled { return .cancelled }
                nextCancellationCheck = pos + 256 * 1024
            }
            guard let lt = Self.find(base, 0x3C, from: pos, to: end) else {
                // Character data runs to the end of the available bytes.
                if !final { return end - pos > Self.maximumToken ? .fallback : .needMore }
                return .fallback
            }
            if lt > pos {
                if phase == .content {
                    if lt - pos > Self.maximumToken || !content(base, pos, lt) { return .fallback }
                } else {
                    for i in pos..<lt where !xmltvIsSpace(base[i]) { return .fallback }
                }
                pos = lt
                markCommit()
                if pos >= limit { break }
            }
            let status = tag(base, end: end, final: final)
            if status != .reachedLimit { return status }
            markCommit()
        }
        if phase == .done { return .done }
        if final && pos >= end { return .fallback }
        return .reachedLimit
    }

    /// One markup token at `pos` (which holds `<`).
    private mutating func tag(_ base: UnsafePointer<UInt8>, end: Int, final: Bool) -> XMLTVScanStatus {
        guard pos + 1 < end else { return Self.incomplete(final) }
        let c = base[pos + 1]
        if c == 0x2F { return endTag(base, end: end, final: final) }
        if c == 0x21 { return bang(base, end: end, final: final) }
        if c == 0x3F { return processingInstruction(base, end: end, final: final) }
        guard Self.isNameStart(c) else { return .fallback }
        return startTag(base, end: end, final: final)
    }

    private mutating func endTag(_ base: UnsafePointer<UInt8>, end: Int, final: Bool) -> XMLTVScanStatus {
        let nameStart = pos + 2
        var i = nameStart
        guard i < end else { return Self.incomplete(final) }
        guard Self.isNameStart(base[i]) else { return .fallback }
        while i < end && Self.isNameChar(base[i]) { i += 1 }
        let nameEnd = i
        while i < end && xmltvIsSpace(base[i]) { i += 1 }
        guard i < end else { return i - pos > Self.maximumToken ? .fallback : Self.incomplete(final) }
        // Also rejects prefixed names (':').
        guard base[i] == 0x3E, phase == .content else { return .fallback }
        let n = nameEnd - nameStart
        let isProgramme = Self.equals(base + nameStart, n, "programme")
        if let top = stack.last {
            guard top.nameLength == n else { return .fallback }
            if top.inBuffer {
                guard memcmp(base + top.nameStart, base + nameStart, n) == 0 else { return .fallback }
            } else {
                guard stackBytes.withUnsafeBufferPointer({ memcmp($0.baseAddress! + top.nameStart, base + nameStart, n) == 0 }) else { return .fallback }
                stackBytes.removeSubrange(top.nameStart...)
            }
            stack.removeLast()
            if top.isProgramme { programmeOpen -= 1 }
            pos = i + 1
            state.endElement(isProgramme: isProgramme, rows: &rows)
            // libxml2 emits nothing for content after the root element.
            if stack.isEmpty && !speculative { phase = .done }
            return .reachedLimit
        }
        guard speculative else { return .fallback }
        pos = i + 1
        state.endElement(isProgramme: isProgramme, rows: &rows)
        underflows.append(Underflow(name: Array(UnsafeBufferPointer(start: base + nameStart, count: n)),
                                    position: pos, rows: rows.count))
        return .reachedLimit
    }

    private mutating func bang(_ base: UnsafePointer<UInt8>, end: Int, final: Bool) -> XMLTVScanStatus {
        let s = pos
        let available = end - s
        if available < 9 && !final {
            for form in ["<!--", "<![CDATA[", "<!DOCTYPE"] as [StaticString]
            where available < form.utf8CodeUnitCount && memcmp(base + s, form.utf8Start, available) == 0 {
                return .needMore
            }
        }
        if available >= 4, base[s + 2] == 0x2D, base[s + 3] == 0x2D {
            // Comment: "--" may only appear as the start of "-->".
            var i = s + 4
            while true {
                guard let dash = Self.find(base, 0x2D, from: i, to: end) else {
                    return available > Self.maximumToken ? .fallback : Self.incomplete(final)
                }
                guard dash + 2 < end else { return Self.incomplete(final) }
                if base[dash + 1] == 0x2D {
                    guard base[dash + 2] == 0x3E else { return .fallback }
                    pos = dash + 3
                    return .reachedLimit
                }
                i = dash + 1
            }
        }
        if available >= 9, memcmp(base + s, ("<![CDATA[" as StaticString).utf8Start, 9) == 0 {
            guard phase == .content else { return .fallback }
            var i = s + 9
            while true {
                guard let bracket = Self.find(base, 0x5D, from: i, to: end) else {
                    return available > Self.maximumToken ? .fallback : Self.incomplete(final)
                }
                guard bracket + 2 < end else { return Self.incomplete(final) }
                guard base[bracket + 1] == 0x5D && base[bracket + 2] == 0x3E else { i = bracket + 1; continue }
                // libxml2's push parser hands CDATA bytes over unnormalized.
                if state.wantsText { state.appendText(base + s + 9, bracket - s - 9) }
                pos = bracket + 3
                return .reachedLimit
            }
        }
        if available >= 9, memcmp(base + s, ("<!DOCTYPE" as StaticString).utf8Start, 9) == 0 {
            guard phase == .prolog, !sawDoctype, available > 9, xmltvIsSpace(base[s + 9]) else { return .fallback }
            var i = s + 9
            var quote: UInt8 = 0
            while i < end {
                let b = base[i]
                if quote != 0 {
                    if b == quote { quote = 0 }
                } else if b == 0x22 || b == 0x27 {
                    quote = b
                } else if b == 0x5B {
                    return .fallback  // internal subset
                } else if b == 0x3E {
                    sawDoctype = true
                    pos = i + 1
                    return .reachedLimit
                }
                i += 1
            }
            return available > Self.maximumToken ? .fallback : Self.incomplete(final)
        }
        return available < 9 ? Self.incomplete(final) : .fallback
    }

    private mutating func processingInstruction(_ base: UnsafePointer<UInt8>, end: Int, final: Bool) -> XMLTVScanStatus {
        let s = pos
        var i = s + 2
        guard i < end else { return Self.incomplete(final) }
        guard Self.isNameStart(base[i]) else { return .fallback }
        while i < end && Self.isNameChar(base[i]) { i += 1 }
        guard i < end else { return Self.incomplete(final) }
        let targetEnd = i
        let target = base + s + 2, targetLength = targetEnd - s - 2
        var close = i
        while true {
            guard let q = Self.find(base, 0x3F, from: close, to: end) else {
                return end - s > Self.maximumToken ? .fallback : Self.incomplete(final)
            }
            guard q + 1 < end else { return Self.incomplete(final) }
            if base[q + 1] == 0x3E { close = q; break }
            close = q + 1
        }
        guard close == targetEnd || xmltvIsSpace(base[targetEnd]) else { return .fallback }
        if targetLength == 3, (target[0] | 0x20) == 0x78, (target[1] | 0x20) == 0x6D, (target[2] | 0x20) == 0x6C {
            // The XML declaration: only at the very start, UTF-8, version 1.0.
            let afterBOM = s == 3 && base[0] == 0xEF && base[1] == 0xBB && base[2] == 0xBF
            guard phase == .prolog, s == 0 || afterBOM, Self.equals(target, 3, "xml"),
                  declarationIsSupported(base, from: targetEnd, to: close) else { return .fallback }
        }
        pos = close + 2
        return .reachedLimit
    }

    private func declarationIsSupported(_ base: UnsafePointer<UInt8>, from: Int, to: Int) -> Bool {
        var i = from
        var sawVersion = false
        while i < to {
            while i < to && xmltvIsSpace(base[i]) { i += 1 }
            if i >= to { break }
            let nameStart = i
            while i < to && Self.isNameChar(base[i]) { i += 1 }
            let name = base + nameStart, n = i - nameStart
            while i < to && xmltvIsSpace(base[i]) { i += 1 }
            guard i < to, base[i] == 0x3D else { return false }
            i += 1
            while i < to && xmltvIsSpace(base[i]) { i += 1 }
            guard i < to, base[i] == 0x22 || base[i] == 0x27 else { return false }
            let quote = base[i]
            let valueStart = i + 1
            guard let valueEnd = Self.find(base, quote, from: valueStart, to: to) else { return false }
            let value = base + valueStart, vn = valueEnd - valueStart
            if Self.equals(name, n, "version") {
                guard !sawVersion, Self.equals(value, vn, "1.0") else { return false }
                sawVersion = true
            } else if Self.equals(name, n, "encoding") {
                let lower = UnsafeBufferPointer(start: value, count: vn).map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }
                guard sawVersion, lower.elementsEqual("utf-8".utf8) || lower.elementsEqual("utf8".utf8) else { return false }
            } else if Self.equals(name, n, "standalone") {
                guard sawVersion, Self.equals(value, vn, "yes") || Self.equals(value, vn, "no") else { return false }
            } else {
                return false
            }
            i = valueEnd + 1
            guard i >= to || xmltvIsSpace(base[i]) else { return false }
        }
        return sawVersion
    }

    private mutating func startTag(_ base: UnsafePointer<UInt8>, end: Int, final: Bool) -> XMLTVScanStatus {
        let s = pos
        let nameStart = s + 1
        var i = nameStart
        while i < end && Self.isNameChar(base[i]) { i += 1 }
        guard i < end else { return Self.incomplete(final) }
        let nameEnd = i
        let n = nameEnd - nameStart
        let name = base + nameStart
        let isProgramme = Self.equals(name, n, "programme")
        var startValue = -1, startLength = 0, startDecode = false
        var stopValue = -1, stopLength = 0, stopDecode = false
        var channelValue = -1, channelLength = 0, channelDecode = false
        attributeNames.removeAll(keepingCapacity: true)
        var selfClosing = false
        while true {
            let beforeSpace = i
            while i < end && xmltvIsSpace(base[i]) { i += 1 }
            guard i < end else { return i - s > Self.maximumToken ? .fallback : Self.incomplete(final) }
            let b = base[i]
            if b == 0x3E { i += 1; break }
            if b == 0x2F {
                guard i + 1 < end else { return Self.incomplete(final) }
                guard base[i + 1] == 0x3E else { return .fallback }
                selfClosing = true
                i += 2
                break
            }
            // Attributes must follow white space; a ':' in the element
            // name (a prefix) also lands here.
            guard i > beforeSpace, Self.isNameStart(b) else { return .fallback }
            let attributeStart = i
            var colon = -1
            while i < end {
                let a = base[i]
                if Self.isNameChar(a) { i += 1 } else if a == 0x3A { if colon < 0 { colon = i }; i += 1 } else { break }
            }
            let attributeEnd = i
            while i < end && xmltvIsSpace(base[i]) { i += 1 }
            guard i < end else { return Self.incomplete(final) }
            guard base[i] == 0x3D else { return .fallback }
            i += 1
            while i < end && xmltvIsSpace(base[i]) { i += 1 }
            guard i < end else { return Self.incomplete(final) }
            let quote = base[i]
            guard quote == 0x22 || quote == 0x27 else { return .fallback }
            let valueStart = i + 1
            guard let valueEnd = Self.find(base, quote, from: valueStart, to: end) else {
                return end - s > Self.maximumToken ? .fallback : Self.incomplete(final)
            }
            i = valueEnd + 1
            let an = attributeEnd - attributeStart
            let attribute = base + attributeStart
            // Duplicate attribute names are a well-formedness error.
            for k in stride(from: 0, to: attributeNames.count, by: 2) {
                if attributeNames[k + 1] == an && memcmp(base + attributeNames[k], attribute, an) == 0 { return .fallback }
            }
            attributeNames.append(attributeStart)
            attributeNames.append(an)
            let vn = valueEnd - valueStart
            if Self.find(base, 0x3C, from: valueStart, to: valueEnd) != nil { return .fallback }
            let hasReference = Self.find(base, 0x26, from: valueStart, to: valueEnd) != nil
            if hasReference && !Self.referencesAreValid(base, valueStart, valueEnd) { return .fallback }
            if colon >= 0 {
                // Namespace declarations and xml:* attributes carry no
                // programme data; other prefixes need namespace processing.
                let prefixLength = colon - attributeStart
                guard Self.equals(attribute, prefixLength, "xmlns") || Self.equals(attribute, prefixLength, "xml"),
                      colon + 1 < attributeEnd, Self.isNameStart(base[colon + 1]) else { return .fallback }
                for k in (colon + 1)..<attributeEnd where base[k] == 0x3A { return .fallback }
                continue
            }
            guard isProgramme, vn > 0 else { continue }
            let kind: Int
            if Self.equals(attribute, an, "start") { kind = 0 }
            else if Self.equals(attribute, an, "stop") { kind = 1 }
            else if Self.equals(attribute, an, "channel") { kind = 2 }
            else { continue }
            // Attribute-value normalization of literal white space is left
            // to libxml2.
            for k in valueStart..<valueEnd where base[k] == 0x09 || base[k] == 0x0A || base[k] == 0x0D { return .fallback }
            switch kind {
            case 0: startValue = valueStart; startLength = vn; startDecode = hasReference
            case 1: stopValue = valueStart; stopLength = vn; stopDecode = hasReference
            default: channelValue = valueStart; channelLength = vn; channelDecode = hasReference
            }
        }
        guard i - s <= Self.maximumToken, n <= 1000 else { return .fallback }
        if phase == .prolog {
            prolog = Array(UnsafeBufferPointer(start: base, count: s))
            phase = .content
        }
        let depth = stack.count + 1
        guard depth <= Self.maximumDepth else { return .fallback }
        maximumLocalDepth = max(maximumLocalDepth, depth)
        pos = i
        if isProgramme {
            state.startProgramme()
            if startValue >= 0 { applyAttribute(base, startValue, startLength, startDecode, kind: 0) }
            if stopValue >= 0 { applyAttribute(base, stopValue, stopLength, stopDecode, kind: 1) }
            if channelValue >= 0 { applyAttribute(base, channelValue, channelLength, channelDecode, kind: 2) }
        } else {
            state.startOther(isTitle: Self.equals(name, n, "title"), isDesc: Self.equals(name, n, "desc"))
        }
        if selfClosing {
            state.endElement(isProgramme: isProgramme, rows: &rows)
            if stack.isEmpty && !speculative { phase = .done }
            return .reachedLimit
        }
        if programmeOpen > 0 {
            stack.append(Entry(nameStart: nameStart, nameLength: n, rawStart: -1, rawLength: 0, isProgramme: isProgramme, inBuffer: true))
        } else {
            let entryNameStart = stackBytes.count
            stackBytes.append(contentsOf: UnsafeBufferPointer(start: name, count: n))
            var rawStart = -1, rawLength = 0
            if !isProgramme {
                rawStart = stackBytes.count
                rawLength = i - s
                stackBytes.append(contentsOf: UnsafeBufferPointer(start: base + s, count: rawLength))
            }
            stack.append(Entry(nameStart: entryNameStart, nameLength: n, rawStart: rawStart, rawLength: rawLength,
                               isProgramme: isProgramme, inBuffer: false))
        }
        if isProgramme { programmeOpen += 1 }
        return .reachedLimit
    }

    private mutating func applyAttribute(_ base: UnsafePointer<UInt8>, _ s: Int, _ n: Int, _ decode: Bool, kind: Int) {
        guard decode else { applyDecoded(base + s, n, kind: kind); return }
        scratch.removeAll(keepingCapacity: true)
        var i = s, run = s
        while let amp = Self.find(base, 0x26, from: i, to: s + n), let (next, value) = Self.entity(base, at: amp, end: s + n) {
            scratch.append(contentsOf: UnsafeBufferPointer(start: base + run, count: amp - run))
            if value == 0x26 {
                // libxml2 (without entity substitution) hands SAX2 an
                // ampersand in an attribute value as "&#38;".
                scratch.append(contentsOf: [0x26, 0x23, 0x33, 0x38, 0x3B])
            } else {
                Self.withUTF8(value) { scratch.append(contentsOf: UnsafeBufferPointer(start: $0, count: $1)) }
            }
            i = next
            run = next
        }
        scratch.append(contentsOf: UnsafeBufferPointer(start: base + run, count: s + n - run))
        let decoded = scratch
        decoded.withUnsafeBufferPointer { applyDecoded($0.baseAddress!, $0.count, kind: kind) }
    }

    @inline(__always) private mutating func applyDecoded(_ p: UnsafePointer<UInt8>, _ n: Int, kind: Int) {
        switch kind {
        case 0: state.setStart(p, n)
        case 1: state.setEnd(p, n)
        default: state.setChannel(p, n)
        }
    }

    // MARK: Replay and merging

    /// The prolog and the open ancestors' start tags at the commit point,
    /// which put libxml2 into the context the commit point was in.
    func replayPrefix() -> [UInt8] {
        var prefix = prolog
        for entry in stack.prefix(commitDepth) {
            precondition(entry.rawStart >= 0, "commit point inside a programme")
            prefix.append(contentsOf: stackBytes[entry.rawStart..<(entry.rawStart + entry.rawLength)])
        }
        return prefix
    }

    /// Shifts positions after the caller dropped `count` leading bytes.
    mutating func rebase(dropping count: Int) {
        pos -= count
        commitPos -= count
        for index in stack.indices where stack[index].inBuffer { stack[index].nameStart -= count }
        nextCancellationCheck = 0
    }

    /// Adopts a speculative scanner that started exactly where this one
    /// stopped, if its assumptions hold against this (true) state. The
    /// result continues from where `next` stopped; `closedRoot` means the
    /// root element ended inside `next` and its rows were cut there.
    func adopt(_ next: XMLTVScanner) -> (scanner: XMLTVScanner, closedRoot: Bool)? {
        guard !speculative, next.speculative, phase == .content, programmeOpen == 0,
              stack.count + next.maximumLocalDepth <= Self.maximumDepth else { return nil }
        let depth = stack.count
        guard next.underflows.count <= depth else { return nil }
        for (index, underflow) in next.underflows.enumerated() {
            let entry = stack[depth - 1 - index]
            guard stackBytes[entry.nameStart..<(entry.nameStart + entry.nameLength)].elementsEqual(underflow.name) else { return nil }
        }
        var resumed = XMLTVScanner()
        resumed.rows = next.rows
        resumed.prolog = prolog
        resumed.sawDoctype = true
        if next.underflows.count == depth {
            // The root element closed inside the part; nothing after its end
            // tag can produce programmes.
            let close = next.underflows[depth - 1]
            resumed.rows.truncate(to: close.rows)
            resumed.phase = .done
            resumed.pos = close.position
            return (resumed, true)
        }
        guard next.programmeOpen == 0 else { return nil }
        // True stack: ours minus the part's underflows, plus its residue.
        var entries = Array(stack.prefix(depth - next.underflows.count))
        var bytes = stackBytes
        if let last = entries.last {
            bytes.removeSubrange(max(last.nameStart + last.nameLength, last.rawStart + last.rawLength)...)
        } else {
            bytes.removeAll()
        }
        for entry in next.stack {
            var moved = entry
            moved.nameStart = bytes.count
            bytes.append(contentsOf: next.stackBytes[entry.nameStart..<(entry.nameStart + entry.nameLength)])
            if entry.rawStart >= 0 {
                moved.rawStart = bytes.count
                bytes.append(contentsOf: next.stackBytes[entry.rawStart..<(entry.rawStart + entry.rawLength)])
            }
            entries.append(moved)
        }
        resumed.phase = .content
        resumed.pos = next.pos
        resumed.stack = entries
        resumed.stackBytes = bytes
        resumed.state = next.state
        resumed.commitPos = next.pos
        resumed.commitRows = next.rows.count
        resumed.commitDepth = entries.count
        return (resumed, false)
    }
}

// MARK: - libxml2 replay

// Hardcoded rather than imported from the xmlParserOption enum so this file
// stays decoupled from however the ClangImporter decides to surface that
// particular C enum. These bit values are stable across libxml2 versions.
nonisolated private let kXMLParseRecover: Int32   = 1 << 0
nonisolated private let kXMLParseNoError: Int32   = 1 << 5
nonisolated private let kXMLParseNoWarning: Int32 = 1 << 6
nonisolated private let kXMLParseNoNet: Int32     = 1 << 11

nonisolated(unsafe) private let saxHandler: xmlSAXHandler = {
    var sax = xmlSAXHandler()
    sax.initialized = XML_SAX2_MAGIC
    sax.startElementNs = { ctx, localname, _, _, _, _, nbAttributes, _, attributes in
        guard let ctx, let localname else { return }
        Unmanaged<XMLTVSAXContext>.fromOpaque(ctx).takeUnretainedValue()
            .startElement(localname: localname, nbAttributes: Int(nbAttributes), attributes: attributes)
    }
    sax.endElementNs = { ctx, localname, _, _ in
        guard let ctx, let localname else { return }
        Unmanaged<XMLTVSAXContext>.fromOpaque(ctx).takeUnretainedValue().endElement(localname: localname)
    }
    sax.characters = { ctx, ch, len in
        guard let ctx, let ch, len > 0 else { return }
        Unmanaged<XMLTVSAXContext>.fromOpaque(ctx).takeUnretainedValue().state.appendText(ch, Int(len))
    }
    return sax
}()

/// libxml2 SAX2 events into the shared programme state machine.
nonisolated private final class XMLTVSAXContext: @unchecked Sendable {
    var state = XMLTVProgrammeState()
    var rows: XMLTVRows

    init(rows: XMLTVRows) { self.rows = rows }

    func startElement(localname: UnsafePointer<xmlChar>, nbAttributes: Int, attributes: UnsafePointer<UnsafePointer<xmlChar>?>?) {
        if cstrEquals(localname, "programme") {
            state.startProgramme()
            guard let attributes, nbAttributes >= 3 else { return }
            // SAX2 attribute layout: (localname, prefix, URI, value_start, value_end).
            for index in 0..<nbAttributes {
                let base = index * 5
                guard let name = attributes[base], attributes[base + 1] == nil,
                      let s = attributes[base + 3], let e = attributes[base + 4], e > s else { continue }
                if cstrEquals(name, "start") {
                    state.setStart(s, e - s)
                } else if cstrEquals(name, "stop") {
                    state.setEnd(s, e - s)
                } else if cstrEquals(name, "channel") {
                    state.setChannel(s, e - s)
                }
            }
            return
        }
        state.startOther(isTitle: cstrEquals(localname, "title"), isDesc: cstrEquals(localname, "desc"))
    }

    func endElement(localname: UnsafePointer<xmlChar>) {
        state.endElement(isProgramme: cstrEquals(localname, "programme"), rows: &rows)
    }
}

/// A libxml2 push parse into `rows`, fed in bounded slices.
nonisolated private final class XMLTVLibxmlPush {
    private let context: XMLTVSAXContext
    private var parser: xmlParserCtxtPtr?

    init(rows: XMLTVRows) { context = XMLTVSAXContext(rows: rows) }

    deinit { if let parser { xmlFreeParserCtxt(parser) } }

    func feed(_ p: UnsafePointer<UInt8>, _ n: Int, cancellation: XMLTVCancellation? = nil) {
        var offset = 0
        while offset < n {
            if let cancellation, cancellation.isCancelled { return }
            let length = min(n - offset, 64 * 1024)
            let chars = UnsafeRawPointer(p + offset).assumingMemoryBound(to: CChar.self)
            if let parser {
                _ = xmlParseChunk(parser, chars, Int32(length), 0)
            } else {
                var sax = saxHandler
                let ctxPtr = Unmanaged.passUnretained(context).toOpaque()
                // libxml2 copies the handler table into the new context.
                parser = withUnsafeMutablePointer(to: &sax) { xmlCreatePushParserCtxt($0, ctxPtr, chars, Int32(length), nil) }
                if let parser { _ = xmlCtxtUseOptions(parser, kXMLParseRecover | kXMLParseNoError | kXMLParseNoWarning | kXMLParseNoNet) }
            }
            offset += length
        }
    }

    /// Ends the document and returns the rows (the initial ones plus
    /// everything libxml2 emitted).
    func finish() -> XMLTVRows {
        if let parser { _ = xmlParseChunk(parser, nil, 0, 1) }
        return context.rows
    }

    var rows: XMLTVRows { context.rows }
}

@inline(__always)
nonisolated private func cstrEquals(_ a: UnsafePointer<xmlChar>, _ b: StaticString) -> Bool {
    let bLen = b.utf8CodeUnitCount
    guard a[0] == b.utf8Start[0] else { return false }
    return xmlStrlen(a) == bLen && memcmp(a, b.utf8Start, bLen) == 0
}

// MARK: - Drivers

nonisolated enum XMLTVIngest {
    /// Test hook: the reference behaviour, libxml2 for the whole document.
    static func parseWithLibxml2(_ data: Data, sliceSizes: [Int] = [64 * 1024]) -> XMLTVGuide {
        data.withUnsafeBytes { raw in
            guard raw.count > 0, let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return .empty }
            let push = XMLTVLibxmlPush(rows: XMLTVRows())
            var offset = 0, index = 0
            while offset < raw.count {
                let size = max(1, min(sliceSizes[index % sliceSizes.count], raw.count - offset))
                push.feed(base + offset, size)
                offset += size
                index += 1
            }
            return XMLTVGuide(parts: [push.finish()])
        }
    }

    /// Test hook: parse with these split points (snapped to the following
    /// `<programme` tags) instead of the size-based ones.
    static func parse(_ data: Data, splitPoints: [Int]) -> XMLTVGuide {
        data.withUnsafeBytes { raw in
            guard raw.count > 0, let base = raw.baseAddress else { return .empty }
            return parse(base.assumingMemoryBound(to: UInt8.self), count: raw.count, cancellation: nil, splitPoints: splitPoints)
        }
    }

    /// Test hook: the network path, fed in the given slice sizes.
    static func parseStreaming(_ data: Data, sliceSizes: [Int]) -> XMLTVGuide {
        let ingest = XMLTVStreamIngest()
        data.withUnsafeBytes { raw in
            guard raw.count > 0, let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0, index = 0
            while offset < raw.count {
                let size = max(1, min(sliceSizes[index % sliceSizes.count], raw.count - offset))
                ingest.feed(base + offset, size)
                offset += size
                index += 1
            }
        }
        return data.isEmpty ? .empty : ingest.finish()
    }

    fileprivate static func parse(_ base: UnsafePointer<UInt8>, count: Int, cancellation: XMLTVCancellation?,
                                  splitPoints: [Int]? = nil) -> XMLTVGuide {
        var boundaries = [0]
        let targets: [Int]
        if let splitPoints {
            targets = splitPoints
        } else {
            let cores = ProcessInfo.processInfo.activeProcessorCount
            let parts = count >= 8 << 20 && cores > 1 ? min(63, max(2, min(cores * 3, count / (4 << 20)))) : 1
            targets = parts > 1 ? (1..<parts).map { count / parts * $0 } : []
        }
        for target in targets where target > boundaries.last! && target < count {
            if let found = nextProgramme(base, from: target, count: count), found > boundaries.last! { boundaries.append(found) }
        }
        boundaries.append(count)
        let partCount = boundaries.count - 1

        struct PartResult {
            var scanner: XMLTVScanner
            var status: XMLTVScanStatus
            var firstBad: Int?
        }
        let results = UnsafeMutableBufferPointer<PartResult?>.allocate(capacity: partCount)
        results.initialize(repeating: nil)
        defer { results.deinitialize(); results.deallocate() }
        let slots = XMLTVUnchecked(results), input = XMLTVUnchecked(base), bounds = boundaries
        let scan: (Int) -> Void = { index in
            let lo = bounds[index], hi = bounds[index + 1]
            let bad = xmltvValidate(input.value, from: lo, to: hi, final: true).bad
            var scanner = index == 0 ? XMLTVScanner() : XMLTVScanner(speculativeAt: lo)
            let status = scanner.run(input.value, limit: hi, end: bad ?? count, final: bad == nil, cancellation: cancellation)
            slots.value[index] = PartResult(scanner: scanner, status: status, firstBad: bad)
        }
        if partCount == 1 {
            scan(0)
        } else {
            let work = XMLTVUnchecked(scan)
            DispatchQueue.concurrentPerform(iterations: partCount) { work.value($0) }
        }
        if cancellation?.isCancelled == true { return .empty }
        // Bytes past the first invalid one are libxml2's alone.
        let globalBad = (0..<partCount).compactMap { results[$0]!.firstBad }.min()
        let end = globalBad ?? count
        let final = globalBad == nil

        var parts: [XMLTVRows] = []
        var current = results[0]!.scanner
        var status = results[0]!.status
        if current.pos > end {
            // The first part read past an invalid byte found by a later part.
            current = XMLTVScanner()
            status = current.run(base, limit: end, end: end, final: false, cancellation: cancellation)
        }
        var next = 1
        while true {
            switch status {
            case .cancelled:
                return .empty
            case .done:
                return XMLTVGuide(parts: parts + [current.rows])
            case .fallback, .needMore:
                return XMLTVGuide(parts: parts + [replay(current, base: base, count: count, cancellation: cancellation)])
            case .reachedLimit:
                break
            }
            while next < partCount && boundaries[next] < current.pos { next += 1 }
            if next < partCount && boundaries[next] == current.pos {
                let candidate = results[next]!
                if candidate.firstBad == nil, candidate.scanner.pos <= end, candidate.status != .cancelled,
                   let (adopted, closedRoot) = current.adopt(candidate.scanner),
                   closedRoot || candidate.status == .reachedLimit {
                    parts.append(current.rows)
                    current = adopted
                    status = closedRoot ? .done : .reachedLimit
                    next += 1
                    continue
                }
                next += 1
            }
            // Continue sequentially to the next part boundary.
            let limit = next < partCount ? boundaries[next] : end
            status = current.run(base, limit: max(limit, current.pos + 1), end: end, final: final, cancellation: cancellation)
            if status == .reachedLimit && current.pos >= end { status = .needMore }
        }
    }

    /// Hands the rest of the document to libxml2 from the scanner's commit
    /// point; rows after the commit point are replaced by libxml2's.
    private static func replay(_ scanner: XMLTVScanner, base: UnsafePointer<UInt8>, count: Int, cancellation: XMLTVCancellation?) -> XMLTVRows {
        var rows = scanner.rows
        rows.truncate(to: scanner.commitRows)
        let push = XMLTVLibxmlPush(rows: rows)
        let prefix = scanner.replayPrefix()
        prefix.withUnsafeBufferPointer { if $0.count > 0 { push.feed($0.baseAddress!, $0.count) } }
        if scanner.commitPos < count {
            push.feed(base + scanner.commitPos, count - scanner.commitPos, cancellation: cancellation)
        }
        if cancellation?.isCancelled == true { return push.rows }
        return push.finish()
    }

    /// The next `<programme` start tag at or after `from`.
    private static func nextProgramme(_ base: UnsafePointer<UInt8>, from: Int, count: Int) -> Int? {
        var i = from
        let tag: StaticString = "<programme"
        while i + 11 <= count, let hit = memchr(base + i, 0x3C, count - i) {
            let at = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            guard at + 11 <= count else { return nil }
            if memcmp(base + at, tag.utf8Start, 10) == 0 {
                let after = base[at + 10]
                if xmltvIsSpace(after) || after == 0x3E || after == 0x2F { return at }
            }
            i = at + 1
        }
        return nil
    }
}

/// Streaming ingest of network chunks: the scanner runs over a buffer that
/// keeps bytes from the last commit point; on fallback libxml2 takes over
/// from there and receives every later chunk directly.
nonisolated private final class XMLTVStreamIngest {
    private var buffer: [UInt8] = []
    private var validEnd = 0
    private var badOffset: Int?
    private var scanner = XMLTVScanner()
    private var libxml: XMLTVLibxmlPush?
    private var finished = false

    func feed(_ p: UnsafePointer<UInt8>, _ n: Int) {
        if finished { return }
        if let libxml { libxml.feed(p, n); return }
        buffer.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
        scan(final: false)
    }

    func finish() -> XMLTVGuide {
        if !finished && libxml == nil { scan(final: true) }
        if let libxml { scanner.rows = libxml.finish() }
        libxml = nil
        finished = true
        return XMLTVGuide(parts: [scanner.rows])
    }

    private func scan(final: Bool) {
        if badOffset == nil {
            let (bad, end) = buffer.withUnsafeBufferPointer { xmltvValidate($0.baseAddress!, from: validEnd, to: $0.count, final: final) }
            badOffset = bad
            validEnd = bad ?? end
        }
        let end = badOffset ?? validEnd
        let isFinal = final && badOffset == nil
        let status = buffer.withUnsafeBufferPointer { buffer in
            scanner.run(buffer.baseAddress!, limit: end, end: end, final: isFinal, cancellation: nil)
        }
        switch status {
        case .done:
            finished = true
            buffer = []
        case .reachedLimit, .needMore:
            if badOffset != nil || final { startFallback() } else { compact() }
        case .fallback:
            startFallback()
        case .cancelled:
            break
        }
    }

    private func startFallback() {
        scanner.rows.truncate(to: scanner.commitRows)
        let push = XMLTVLibxmlPush(rows: scanner.rows)
        scanner.rows = XMLTVRows()
        let prefix = scanner.replayPrefix()
        prefix.withUnsafeBufferPointer { if $0.count > 0 { push.feed($0.baseAddress!, $0.count) } }
        buffer.withUnsafeBufferPointer { b in
            if scanner.commitPos < b.count { push.feed(b.baseAddress! + scanner.commitPos, b.count - scanner.commitPos) }
        }
        buffer = []
        libxml = push
    }

    /// Drops bytes before the commit point once enough have accumulated.
    private func compact() {
        let drop = min(scanner.commitPos, scanner.pos)
        guard drop >= 1 << 20 || (drop > 0 && drop * 2 >= buffer.count) else { return }
        buffer.removeSubrange(0..<drop)
        scanner.rebase(dropping: drop)
        validEnd -= drop
    }
}

/// Feeds each received network chunk straight into the guide scanner on the
/// session's serial delegate queue. Produces the same programmes as
/// buffering the whole document and parsing it afterwards.
nonisolated private final class StreamingGuideParse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result: Sendable {
        let guide: XMLTVGuide
        let bytes: Int
        let firstByteMs: Int
        let parseMs: Int
        let tailParseMs: Int
    }

    private let started = ContinuousClock.now
    private let ingest = XMLTVStreamIngest()
    private var bytes = 0
    private var firstByteMs = -1
    private var parseDuration: Duration = .zero
    private var failure: Error?
    private var continuation: CheckedContinuation<Result, Error>?

    static func run(url: URL, configuration: URLSessionConfiguration) async throws -> Result {
        let delegate = StreamingGuideParse()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 90)
        request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    delegate.continuation = continuation
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            failure = URLError(.badServerResponse)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, !data.isEmpty else { return }
        if firstByteMs < 0 { firstByteMs = AppLog.elapsedMilliseconds(since: started) }
        bytes += data.count
        let parseStarted = ContinuousClock.now
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            ingest.feed(base.assumingMemoryBound(to: UInt8.self), raw.count)
        }
        parseDuration += parseStarted.duration(to: .now)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error = failure ?? error {
            continuation.resume(throwing: error)
            return
        }
        let tailStarted = ContinuousClock.now
        // An empty body never created a parser before; keep that result.
        let guide = bytes == 0 ? XMLTVGuide.empty : ingest.finish()
        let tail = tailStarted.duration(to: .now)
        parseDuration += tail
        continuation.resume(returning: Result(
            guide: guide,
            bytes: bytes,
            firstByteMs: max(0, firstByteMs),
            parseMs: Self.milliseconds(parseDuration),
            tailParseMs: Self.milliseconds(tail)
        ))
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}
