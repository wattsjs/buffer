import Foundation

/// Shared guide lookups used by the UI and the in-process benchmark.
/// Program lists published by `EPGViewModel.organize` are sorted by start.
enum GuideLookup {
    /// One prefix maximum per listing makes arbitrary overlapping end times
    /// searchable. The first maximum past the query belongs to the earliest
    /// matching listing, preserving the provider's ordering for duplicate starts.
    /// The program array shares its immutable storage with the guide snapshot.
    /// Retained for the in-app performance benchmark; the view model uses
    /// `GuideTimeline`, which applies the same search to flat Int32 columns.
    nonisolated struct Prepared: Sendable {
        private let programs: [EPGProgram]
        private let prefixMaximumEnds: [TimeInterval]

        init(programs: [EPGProgram]) {
            self.programs = programs
            var maximum = -Double.infinity
            var ends: [TimeInterval] = []
            ends.reserveCapacity(programs.count)
            for program in programs {
                let end = program.end.timeIntervalSinceReferenceDate
                if end > maximum { maximum = end }
                ends.append(maximum)
            }
            prefixMaximumEnds = ends
        }

        func program(containing date: Date) -> EPGProgram? {
            let timestamp = date.timeIntervalSinceReferenceDate
            var low = 0
            var high = prefixMaximumEnds.count
            while low < high {
                let mid = low + (high - low) / 2
                if prefixMaximumEnds[mid] <= timestamp {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            guard low < programs.count, programs[low].start <= date else { return nil }
            return programs[low]
        }
    }

    static func channelSetFingerprint(_ channels: [Channel]) -> Int {
        var hasher = Hasher()
        hasher.combine(channels.count)
        for channel in channels {
            hasher.combine(channel.id)
        }
        return hasher.finalize()
    }

    /// Joined identity used by the old EPG grid path. Kept so the benchmark
    /// can time the allocation the view used to do on every body pass.
    static func joinedChannelIdentity(_ channels: [Channel]) -> String {
        channels.map(\.id).joined(separator: "\u{1F}")
    }

    nonisolated static func programIndex(in programs: [EPGProgram], containing date: Date) -> Int? {
        guard !programs.isEmpty else { return nil }
        var low = 0
        var high = programs.count
        while low < high {
            let mid = (low + high) / 2
            if programs[mid].start <= date {
                low = mid + 1
            } else {
                high = mid
            }
        }

        // End times need not be sorted: providers emit overlapping and
        // duplicate listings. Preserve the existing first-match semantics.
        return programs[..<low].firstIndex { date < $0.end }
    }

    nonisolated static func program(in programs: [EPGProgram], containing date: Date) -> EPGProgram? {
        programIndex(in: programs, containing: date).map { programs[$0] }
    }

    static func linearProgram(in programs: [EPGProgram], containing date: Date) -> EPGProgram? {
        programs.first { $0.start <= date && date < $0.end }
    }
}

/// Flat, structure-of-arrays index over a published guide.
///
/// Every channel's programmes occupy one contiguous `[lo, hi)` run of three
/// `Int32` columns (start, end, running maximum end) holding whole seconds
/// relative to `baseEpoch`. A channel is addressed by a packed `Handle`: the
/// low 31 bits are its run index and the top bit marks a run that cannot use
/// the integer columns (fractional or out-of-range timestamps, or listings
/// not sorted by start). Those rare runs take the exact `Date` path, so every
/// result is identical to `GuideLookup.program(in:containing:)`.
///
/// The `rows` façade shares its array buffers with the published
/// `[String: [EPGProgram]]` dictionary, so the index adds only the columns.
/// Rebuilding reuses unchanged runs by buffer identity (memcpy, no Date math).
nonisolated struct GuideTimeline: Sendable {
    typealias Handle = UInt32

    static let baseEpoch = EPGProgram.columnEpoch
    static let exactFlag: Handle = 1 << 31
    static let indexMask: Handle = exactFlag - 1

    /// Guide ID → handle, as flat arrays (see `KeyTable`).
    private(set) var keys = KeyTable()
    /// Façade rows by run index (buffers shared with the guide dictionary).
    private(set) var rows: [[EPGProgram]] = []
    /// `runOffsets[i] ..< runOffsets[i + 1]` is run `i` in the time columns.
    private(set) var runOffsets: [UInt32] = [0]
    private(set) var starts: [Int32] = []
    private(set) var ends: [Int32] = []
    private(set) var maximumEnds: [Int32] = []
    /// Runs rebuilt from `Date`s rather than copied from the previous index.
    private(set) var rebuiltRuns = 0

    init() {}

    var isEmpty: Bool { rows.isEmpty }
    var channelCount: Int { rows.count }
    var programCount: Int { starts.count }

    init(_ guide: [String: [EPGProgram]], reusing previous: GuideTimeline? = nil) {
        keys = KeyTable(capacity: guide.count)
        rows.reserveCapacity(guide.count)
        runOffsets.reserveCapacity(guide.count + 1)
        var total = 0
        for list in guide.values { total += list.count }
        starts.reserveCapacity(total)
        ends.reserveCapacity(total)
        maximumEnds.reserveCapacity(total)
        for (key, list) in guide {
            let index = Handle(rows.count)
            var flag: Handle = 0
            if let previous, let old = previous.keys.handle(for: key),
               Self.sharesStorage(previous.rows[Int(old & Self.indexMask)], list) {
                let oldIndex = Int(old & Self.indexMask)
                let lo = Int(previous.runOffsets[oldIndex]), hi = Int(previous.runOffsets[oldIndex + 1])
                starts.append(contentsOf: previous.starts[lo..<hi])
                ends.append(contentsOf: previous.ends[lo..<hi])
                maximumEnds.append(contentsOf: previous.maximumEnds[lo..<hi])
                flag = old & Self.exactFlag
            } else {
                rebuiltRuns += 1
                if !appendColumns(list) { flag = Self.exactFlag }
            }
            keys.insert(key, handle: index | flag)
            rows.append(list)
            runOffsets.append(UInt32(starts.count))
        }
    }

    /// Appends one run; on failure rolls back and reports the run as exact-only.
    private mutating func appendColumns(_ list: [EPGProgram]) -> Bool {
        let mark = starts.count
        var maximum = Int32.min
        var previousStart = -Double.infinity
        for program in list {
            let start = program.start.timeIntervalSince1970
            guard start >= previousStart,
                  let s = Self.column(start), let e = Self.column(program.end.timeIntervalSince1970) else {
                starts.removeSubrange(mark...)
                ends.removeSubrange(mark...)
                maximumEnds.removeSubrange(mark...)
                return false
            }
            previousStart = start
            if e > maximum { maximum = e }
            starts.append(s)
            ends.append(e)
            maximumEnds.append(maximum)
        }
        return true
    }

    @inline(__always)
    private static func column(_ seconds: Double) -> Int32? {
        // The extremes are reserved for clamped query keys.
        guard let value = Int32(exactly: seconds - Double(baseEpoch)),
              value != .min, value != .max else { return nil }
        return value
    }

    private static func sharesStorage(_ lhs: [EPGProgram], _ rhs: [EPGProgram]) -> Bool {
        lhs.count == rhs.count && lhs.withUnsafeBufferPointer { a in
            rhs.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress }
        }
    }

    /// Query instants become integer keys: for whole-second columns,
    /// `start <= t ⇔ start <= ⌊t⌋` and `end > t ⇔ end > ⌊t⌋`.
    @inline(__always)
    static func floorKey(_ date: Date) -> Int32 {
        let t = (date.timeIntervalSince1970 - Double(baseEpoch)).rounded(.down)
        // NaN compares false with everything: `.max` makes `end > key` false.
        if t.isNaN || t >= Double(Int32.max) { return .max }
        if t <= Double(Int32.min) { return .min }
        return Int32(t)
    }

    /// `start < t ⇔ start < ⌈t⌉` for whole-second columns.
    @inline(__always)
    static func ceilingKey(_ date: Date) -> Int32 {
        let t = (date.timeIntervalSince1970 - Double(baseEpoch)).rounded(.up)
        // NaN: `.min` makes `start < key` false.
        if t.isNaN || t <= Double(Int32.min) { return .min }
        if t >= Double(Int32.max) { return .max }
        return Int32(t)
    }

    @inline(__always)
    func handle(for key: String) -> Handle? { keys.handle(for: key) }

    @inline(__always)
    func rows(_ handle: Handle) -> [EPGProgram] { rows[Int(handle & Self.indexMask)] }

    @inline(__always)
    private static func firstAbove(_ key: Int32, in column: UnsafeBufferPointer<Int32>, lo: Int, hi: Int) -> Int {
        var low = lo, high = hi
        while low < high {
            let mid = (low &+ high) &>> 1
            if column[mid] <= key { low = mid &+ 1 } else { high = mid }
        }
        return low
    }

    @inline(__always)
    private static func firstAtOrAbove(_ key: Int32, in column: UnsafeBufferPointer<Int32>, lo: Int, hi: Int) -> Int {
        var low = lo, high = hi
        while low < high {
            let mid = (low &+ high) &>> 1
            if column[mid] < key { low = mid &+ 1 } else { high = mid }
        }
        return low
    }

    /// Row offset of the earliest listing containing `date`, if any.
    @inline(__always)
    func programIndex(_ handle: Handle, at date: Date) -> Int? {
        let index = Int(handle & Self.indexMask)
        if handle & Self.exactFlag != 0 { return GuideLookup.programIndex(in: rows[index], containing: date) }
        let lo = Int(runOffsets[index]), hi = Int(runOffsets[index + 1])
        let key = Self.floorKey(date)
        let found = maximumEnds.withUnsafeBufferPointer { Self.firstAbove(key, in: $0, lo: lo, hi: hi) }
        guard found < hi, starts[found] <= key else { return nil }
        return found - lo
    }

    func program(_ handle: Handle, at date: Date) -> EPGProgram? {
        guard let offset = programIndex(handle, at: date) else { return nil }
        return rows[Int(handle & Self.indexMask)][offset]
    }

    /// Listings intersecting `[start, end)`, ordered by `(start, end)`.
    func programs(_ handle: Handle, between start: Date, and end: Date) -> [EPGProgram] {
        let index = Int(handle & Self.indexMask)
        let list = rows[index]
        if handle & Self.exactFlag != 0 {
            return list.filter { $0.end > start && $0.start < end }
                .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        }
        let lo = Int(runOffsets[index]), hi = Int(runOffsets[index + 1])
        let startKey = Self.floorKey(start)
        let endKey = Self.ceilingKey(end)
        var result: [EPGProgram] = []
        var needsSort = false
        starts.withUnsafeBufferPointer { startColumn in
            ends.withUnsafeBufferPointer { endColumn in
                // Everything before `first` ends at/before `start`; starts are
                // sorted, so everything from `last` begins at/after `end`.
                var first = maximumEnds.withUnsafeBufferPointer { Self.firstAbove(startKey, in: $0, lo: lo, hi: hi) }
                let last = Self.firstAtOrAbove(endKey, in: startColumn, lo: first, hi: hi)
                guard first < last else { return }
                result.reserveCapacity(last - first)
                var previousStart = Int32.min, previousEnd = Int32.min
                while first < last {
                    let e = endColumn[first]
                    if e > startKey {
                        let s = startColumn[first]
                        if s == previousStart && e < previousEnd { needsSort = true }
                        previousStart = s; previousEnd = e
                        result.append(list[first &- lo])
                    }
                    first &+= 1
                }
            }
        }
        // Only equal starts with descending ends can be out of (start, end) order.
        if needsSort { result.sort { ($0.start, $0.end) < ($1.start, $1.end) } }
        return result
    }

    /// "What is on now" for many channels: one tight pass over packed handles,
    /// touching only the offset/start/maximum-end columns. Writes the row
    /// offset of the matching listing (or -1) per handle into `output`.
    func programIndices(_ handles: UnsafeBufferPointer<Handle>, at date: Date,
                        into output: UnsafeMutableBufferPointer<Int32>) {
        precondition(output.count >= handles.count)
        let key = Self.floorKey(date)
        runOffsets.withUnsafeBufferPointer { offsets in
            starts.withUnsafeBufferPointer { startColumn in
                maximumEnds.withUnsafeBufferPointer { maxColumn in
                    for position in 0..<handles.count {
                        let handle = handles[position]
                        let index = Int(handle & Self.indexMask)
                        if handle & Self.exactFlag != 0 {
                            output[position] = GuideLookup.programIndex(in: rows[index], containing: date)
                                .map { Int32($0) } ?? -1
                            continue
                        }
                        let lo = Int(offsets[index]), hi = Int(offsets[index &+ 1])
                        let found = Self.firstAbove(key, in: maxColumn, lo: lo, hi: hi)
                        output[position] = found < hi && startColumn[found] <= key ? Int32(found &- lo) : -1
                    }
                }
            }
        }
    }

    /// Open-addressed string → handle table in three flat arrays: slot
    /// handles, slot hash tags and the key strings by run index. A probe
    /// hashes the UTF-8 bytes with a word-at-a-time multiply-mix (no SipHash,
    /// no normalization) and compares a 32-bit tag before any string bytes.
    struct KeyTable: Sendable {
        /// `handle + 1` per slot; 0 is empty.
        private var slots: [UInt32] = []
        private var tags: [UInt32] = []
        private var strings: [String] = []
        private var mask = 0

        init() {}

        init(capacity: Int) {
            var size = 8
            while size < capacity * 2 { size <<= 1 }
            slots = [UInt32](repeating: 0, count: size)
            tags = [UInt32](repeating: 0, count: size)
            strings.reserveCapacity(capacity)
            mask = size - 1
        }

        var count: Int { strings.count }

        /// Keys are unique by construction (they come from a dictionary).
        mutating func insert(_ key: String, handle: Handle) {
            let hash = Self.hash(key)
            var slot = Int(truncatingIfNeeded: hash) & mask
            while slots[slot] != 0 { slot = (slot &+ 1) & mask }
            slots[slot] = handle &+ 1
            tags[slot] = UInt32(truncatingIfNeeded: hash >> 32)
            strings.append(key)
        }

        @inline(__always)
        func handle(for key: String) -> Handle? {
            guard mask != 0 else { return nil }
            let hash = Self.hash(key)
            let tag = UInt32(truncatingIfNeeded: hash >> 32)
            var slot = Int(truncatingIfNeeded: hash) & mask
            while true {
                let stored = slots[slot]
                if stored == 0 { return nil }
                let handle = stored &- 1
                if tags[slot] == tag, strings[Int(handle & GuideTimeline.indexMask)] == key { return handle }
                slot = (slot &+ 1) & mask
            }
        }

        @inline(__always)
        static func hash(_ key: String) -> UInt64 {
            var key = key
            return key.withUTF8 { bytes -> UInt64 in
                var h: UInt64 = 0x9E37_79B9_7F4A_7C15 ^ UInt64(bytes.count)
                guard let base = bytes.baseAddress else { return mix(h) }
                let raw = UnsafeRawPointer(base)
                var index = 0
                while index &+ 8 <= bytes.count {
                    h = mix(h ^ raw.loadUnaligned(fromByteOffset: index, as: UInt64.self))
                    index &+= 8
                }
                var tail: UInt64 = 0, shift: UInt64 = 0
                while index < bytes.count {
                    tail |= UInt64(bytes[index]) << shift
                    shift &+= 8; index &+= 1
                }
                return mix(h ^ tail)
            }
        }

        @inline(__always)
        private static func mix(_ value: UInt64) -> UInt64 {
            var z = value &* 0xBF58_476D_1CE4_E5B9
            z ^= z >> 31
            z = z &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 29)
        }
    }
}
