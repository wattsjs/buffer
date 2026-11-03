import CoreGraphics
import Foundation

// Data-oriented EPG row geometry. Every visible guide row owns one
// `EPGRowLayout` whose flat columns are rebuilt in place (capacity is kept), so
// laying out a row or scrolling the grid performs no per-cell allocation.

// MARK: - Bitset

/// A growable bitset over `UInt64` words. Used instead of `Set<Int>`/`[Bool]`
/// for row occupancy and visibility: membership is a shift and a mask, set
/// algebra is word-wise AND/OR, and clearing keeps the storage.
nonisolated struct EPGBitset: Equatable, Sendable {
    private(set) var words: ContiguousArray<UInt64> = []

    init() {}

    init(bitCount: Int) {
        words = ContiguousArray(repeating: 0, count: (max(0, bitCount) + 63) >> 6)
    }

    var bitCapacity: Int { words.count << 6 }

    mutating func reserve(bitCount: Int) {
        let needed = (max(0, bitCount) + 63) >> 6
        if words.count < needed { words.append(contentsOf: repeatElement(0, count: needed - words.count)) }
    }

    @inline(__always)
    func contains(_ index: Int) -> Bool {
        let word = index >> 6
        guard index >= 0, word < words.count else { return false }
        return words[word] & (1 &<< UInt64(index & 63)) != 0
    }

    @inline(__always)
    mutating func insert(_ index: Int) {
        precondition(index >= 0)
        reserve(bitCount: index + 1)
        words[index >> 6] |= 1 &<< UInt64(index & 63)
    }

    @inline(__always)
    mutating func remove(_ index: Int) {
        let word = index >> 6
        guard index >= 0, word < words.count else { return }
        words[word] &= ~(1 &<< UInt64(index & 63))
    }

    /// Clears every bit without releasing storage.
    mutating func removeAll() {
        words.withUnsafeMutableBufferPointer { buffer in
            for index in buffer.indices { buffer[index] = 0 }
        }
    }

    var isEmpty: Bool { words.allSatisfy { $0 == 0 } }

    var count: Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }

    mutating func formUnion(_ other: EPGBitset) {
        reserve(bitCount: other.bitCapacity)
        for index in other.words.indices { words[index] |= other.words[index] }
    }

    mutating func formIntersection(_ other: EPGBitset) {
        for index in words.indices { words[index] &= index < other.words.count ? other.words[index] : 0 }
    }

    mutating func subtract(_ other: EPGBitset) {
        for index in words.indices where index < other.words.count { words[index] &= ~other.words[index] }
    }

    /// Visits set bits in ascending order (trailing-zero scan, no allocation).
    func forEach(_ body: (Int) -> Void) {
        for (wordIndex, word) in words.enumerated() {
            var remaining = word
            while remaining != 0 {
                let bit = remaining.trailingZeroBitCount
                body(wordIndex << 6 | bit)
                remaining &= remaining &- 1
            }
        }
    }

    static func == (lhs: EPGBitset, rhs: EPGBitset) -> Bool {
        let shared = min(lhs.words.count, rhs.words.count)
        for index in 0..<shared where lhs.words[index] != rhs.words[index] { return false }
        for index in shared..<lhs.words.count where lhs.words[index] != 0 { return false }
        for index in shared..<rhs.words.count where rhs.words[index] != 0 { return false }
        return true
    }
}

// MARK: - Cell flags

/// Per-cell state packed into one byte of the row's flag column.
nonisolated enum EPGCellFlags {
    /// An intentional guide gap (no programme).
    static let gap: UInt8 = 1 << 0
    /// The programme has a reminder for the active source.
    static let reminder: UInt8 = 1 << 1
    /// Airing at the layout's reference time.
    static let live: UInt8 = 1 << 2
    /// Ended, but inside the channel's catch-up window.
    static let catchup: UInt8 = 1 << 3
    /// Ended and outside any catch-up window.
    static let past: UInt8 = 1 << 4
    static let stateMask: UInt8 = live | catchup | past
}

// MARK: - Row layout

/// Structure-of-arrays geometry for one guide row. Columns are parallel:
/// cell `i` spans `x[i] ..< x[i] + width[i]` in timeline points.
nonisolated struct EPGRowLayout {
    /// Timeline-relative left edge of each cell (points).
    private(set) var x = ContiguousArray<Float32>()
    private(set) var width = ContiguousArray<Float32>()
    /// Index of the programme in the source array, or -1 for a gap.
    private(set) var source = ContiguousArray<Int32>()
    /// Programme start/end in seconds since the reference date (the original
    /// programme times, not the clipped geometry). Gaps hold their span.
    private(set) var start = ContiguousArray<Double>()
    private(set) var end = ContiguousArray<Double>()
    private(set) var flags = ContiguousArray<UInt8>()
    /// Vertical card inset shared by every cell of the row.
    private(set) var cellMinY: Float32 = 3
    private(set) var cellHeight: Float32 = 58
    /// Scratch index buffer, used only when the source is not already sorted.
    private var order = ContiguousArray<Int32>()

    init() {}

    var count: Int { x.count }
    var isEmpty: Bool { x.isEmpty }

    mutating func removeAll() {
        x.removeAll(keepingCapacity: true)
        width.removeAll(keepingCapacity: true)
        source.removeAll(keepingCapacity: true)
        start.removeAll(keepingCapacity: true)
        end.removeAll(keepingCapacity: true)
        flags.removeAll(keepingCapacity: true)
    }

    @inline(__always)
    mutating func append(x cellX: Double, width cellWidth: Double, source index: Int32,
                         start cellStart: Double, end cellEnd: Double, flags cellFlags: UInt8) {
        x.append(Float32(cellX))
        width.append(Float32(cellWidth))
        source.append(index)
        start.append(cellStart)
        end.append(cellEnd)
        flags.append(cellFlags)
    }

    mutating func setCellBand(minY: Double, height: Double) {
        cellMinY = Float32(minY)
        cellHeight = Float32(height)
    }

    @inline(__always) func isGap(_ cell: Int) -> Bool { flags[cell] & EPGCellFlags.gap != 0 }
    @inline(__always) func maxX(_ cell: Int) -> Float32 { x[cell] + width[cell] }

    /// Lays out programmes intersecting the timeline into the reused columns.
    /// Identical geometry to the previous `[EPGProgramBlock]` builder: sorted by
    /// (start, end), overlaps clipped to the running cursor, sub-2pt cells
    /// dropped, and optional gaps between programmes when `showGaps` is set.
    mutating func build(
        programs: [EPGProgram],
        timelineStart: Date,
        pixelsPerMinute: Double,
        timelineWidth: Double,
        rowHeight: Double,
        showGaps: Bool,
        reminderIDs: Set<String> = []
    ) {
        removeAll()
        setCellBand(minY: 3, height: rowHeight - 6)
        let origin = timelineStart.timeIntervalSinceReferenceDate
        let windowEnd = origin + timelineWidth / pixelsPerMinute * 60
        let scale = pixelsPerMinute / 60
        let checkReminders = !reminderIDs.isEmpty

        programs.withUnsafeBufferPointer { buffer in
            // One pass: are the in-window programmes already in (start, end)
            // order? Providers normally publish sorted rows; sort indices only
            // when they did not.
            var sorted = true
            var inWindow = 0
            var previousStart = -Double.infinity, previousEnd = -Double.infinity
            for program in buffer {
                let s = program.start.timeIntervalSinceReferenceDate
                let e = program.end.timeIntervalSinceReferenceDate
                guard e > origin, s < windowEnd else { continue }
                inWindow += 1
                if s < previousStart || (s == previousStart && e < previousEnd) { sorted = false }
                previousStart = s
                previousEnd = e
            }
            guard inWindow > 0 else { return }

            var cursor = origin
            @inline(__always)
            func appendGap(until gapEnd: Double) {
                guard gapEnd > cursor else { return }
                let startX = max(0, (cursor - origin) * scale)
                let endX = min(timelineWidth, (gapEnd - origin) * scale)
                let width = endX - startX
                guard width > 2 else { return }
                append(x: startX, width: width, source: -1, start: cursor, end: gapEnd, flags: EPGCellFlags.gap)
            }
            @inline(__always)
            func visit(_ index: Int) {
                let program = buffer[index]
                let s = program.start.timeIntervalSinceReferenceDate
                let e = program.end.timeIntervalSinceReferenceDate
                if showGaps { appendGap(until: s) }
                let effectiveStart = max(s, cursor)
                guard e > effectiveStart else { return }
                let startX = max(0, (effectiveStart - origin) * scale)
                let endX = min(timelineWidth, (e - origin) * scale)
                let width = endX - startX
                guard width > 2 else { return }
                let reminder = checkReminders && reminderIDs.contains(program.id)
                append(x: startX, width: width, source: Int32(truncatingIfNeeded: index), start: s, end: e,
                       flags: reminder ? EPGCellFlags.reminder : 0)
                cursor = e
            }

            if sorted {
                for index in buffer.indices {
                    let program = buffer[index]
                    guard program.end.timeIntervalSinceReferenceDate > origin,
                          program.start.timeIntervalSinceReferenceDate < windowEnd else { continue }
                    visit(index)
                }
            } else {
                order.removeAll(keepingCapacity: true)
                for index in buffer.indices {
                    let program = buffer[index]
                    guard program.end.timeIntervalSinceReferenceDate > origin,
                          program.start.timeIntervalSinceReferenceDate < windowEnd else { continue }
                    order.append(Int32(truncatingIfNeeded: index))
                }
                order.sort { lhs, rhs in
                    let a = buffer[Int(lhs)], b = buffer[Int(rhs)]
                    if a.start != b.start { return a.start < b.start }
                    if a.end != b.end { return a.end < b.end }
                    return lhs < rhs
                }
                for index in order { visit(Int(index)) }
            }
            if showGaps { appendGap(until: windowEnd) }
        }
    }

    /// Recomputes the time-dependent state bits in one pass over the columns.
    mutating func applyState(now: Date, replayStart: Date?) {
        let nowSeconds = now.timeIntervalSinceReferenceDate
        let replaySeconds = replayStart?.timeIntervalSinceReferenceDate
        flags.withUnsafeMutableBufferPointer { flagBuffer in
            start.withUnsafeBufferPointer { starts in
                end.withUnsafeBufferPointer { ends in
                    for cell in flagBuffer.indices {
                        var value = flagBuffer[cell] & ~EPGCellFlags.stateMask
                        if value & EPGCellFlags.gap == 0 {
                            let s = starts[cell], e = ends[cell]
                            if s <= nowSeconds && e > nowSeconds {
                                value |= EPGCellFlags.live
                            } else if e <= nowSeconds {
                                if let replaySeconds, s >= replaySeconds {
                                    value |= EPGCellFlags.catchup
                                } else {
                                    value |= EPGCellFlags.past
                                }
                            }
                        }
                        flagBuffer[cell] = value
                    }
                }
            }
        }
    }

    /// The cell containing a timeline point, by binary search over the
    /// ascending, non-overlapping cell columns.
    func cell(containingX px: Double, y py: Double) -> Int? {
        guard py >= Double(cellMinY), py < Double(cellMinY) + Double(cellHeight) else { return nil }
        let target = Float32(px)
        var low = 0, high = count
        while low < high {
            let mid = (low + high) >> 1
            if x[mid] <= target { low = mid + 1 } else { high = mid }
        }
        let candidate = low - 1
        guard candidate >= 0, px < Double(x[candidate]) + Double(width[candidate]) else { return nil }
        return candidate
    }

    /// The first cell whose right edge lies beyond `minX`.
    func firstCell(endingAfter minX: Double) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) >> 1
            if Double(x[mid]) + Double(width[mid]) <= minX { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func rect(_ cell: Int) -> CGRect {
        CGRect(x: CGFloat(x[cell]), y: CGFloat(cellMinY), width: CGFloat(width[cell]), height: CGFloat(cellHeight))
    }
}

// MARK: - Interned clock text

/// Clock labels are a finite domain (minute of day, optionally weekday), so
/// the guide interns each string once in a flat table instead of running a
/// date formatter per cell per frame. The tables reset if the locale or time
/// zone changes.
@MainActor
final class EPGClockText {
    static let shared = EPGClockText()

    private static let minutesPerDay = 1_440
    private var localeID = ""
    private var timeZone = TimeZone.current
    private var timeZoneID = ""
    /// Guide time-range form: "9:00pm" (`.shortened`, spaces removed, lowercased).
    private var compact = ContiguousArray<String?>(repeating: nil, count: minutesPerDay)
    /// Header form for today: `.shortened` time.
    private var short = ContiguousArray<String?>(repeating: nil, count: minutesPerDay)
    /// Header form for other days: abbreviated weekday + time, keyed by weekday.
    private var weekday = ContiguousArray<String?>(repeating: nil, count: minutesPerDay * 7)
    private(set) var generation = 0
    private var environmentChanged = true

    private init() {
        let center = NotificationCenter.default
        for name in [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { EPGClockText.shared.environmentChanged = true }
            }
        }
    }

    /// Called once per drawing pass; resets the tables only after the system
    /// locale or time zone changed (no per-frame locale queries).
    func beginPass() {
        guard environmentChanged else { return }
        environmentChanged = false
        let locale = Locale.current.identifier
        let zone = TimeZone.current
        guard locale != localeID || zone.identifier != timeZoneID else { return }
        localeID = locale
        timeZone = zone
        timeZoneID = zone.identifier
        for index in compact.indices { compact[index] = nil; short[index] = nil }
        for index in weekday.indices { weekday[index] = nil }
        generation &+= 1
    }

    /// (local minute of day, weekday slot) for an absolute time.
    @inline(__always)
    func key(for seconds: Double) -> (minute: Int, weekday: Int) {
        let date = Date(timeIntervalSinceReferenceDate: seconds)
        let local = seconds + Double(timeZone.secondsFromGMT(for: date))
        let day = (local / 86_400).rounded(.down)
        let minute = Int((local - day * 86_400) / 60)
        let weekday = ((Int(day) % 7) + 7) % 7
        return (min(max(minute, 0), Self.minutesPerDay - 1), weekday)
    }

    func compactTime(_ seconds: Double) -> String {
        let key = key(for: seconds)
        if let text = compact[key.minute] { return text }
        let text = Self.formatCompact(Date(timeIntervalSinceReferenceDate: seconds))
        compact[key.minute] = text
        return text
    }

    func shortTime(_ seconds: Double) -> String {
        let key = key(for: seconds)
        if let text = short[key.minute] { return text }
        let text = Date(timeIntervalSinceReferenceDate: seconds).formatted(date: .omitted, time: .shortened)
        short[key.minute] = text
        return text
    }

    func weekdayTime(_ seconds: Double) -> String {
        let key = key(for: seconds)
        let slot = key.weekday * Self.minutesPerDay + key.minute
        if let text = weekday[slot] { return text }
        let text = Date(timeIntervalSinceReferenceDate: seconds)
            .formatted(.dateTime.weekday(.abbreviated).hour().minute())
        weekday[slot] = text
        return text
    }

    /// "9:00pm - 10:00pm", the sticky metadata text of a programme cell.
    func compactRange(start: Double, end: Double) -> String {
        compactTime(start) + " - " + compactTime(end)
    }

    nonisolated static func formatCompact(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }
}

// MARK: - Time strip

/// The header is fully described by its origin and slot count; titles for the
/// few visible slots are produced while drawing from the interned clock table.
struct EPGTimeStripSpec: Equatable {
    var start: Date
    var slotCount: Int
    var slotWidth: CGFloat
    /// Local start of the reference day: titles on this day omit the weekday.
    var relativeDay: Date
    var relativeDayEnd: Date

    static let slotSeconds: Double = 30 * 60

    init(start: Date, hours: Int, pixelsPerMinute: CGFloat, relativeTo now: Date) {
        self.start = start
        slotCount = max(0, hours) * 2
        slotWidth = 30 * pixelsPerMinute
        let calendar = Calendar.current
        relativeDay = calendar.startOfDay(for: now)
        relativeDayEnd = calendar.date(byAdding: .day, value: 1, to: relativeDay) ?? relativeDay.addingTimeInterval(86_400)
    }

    static let empty = EPGTimeStripSpec(start: Date(timeIntervalSinceReferenceDate: 0), hours: 0, pixelsPerMinute: 4,
                                        relativeTo: Date(timeIntervalSinceReferenceDate: 0))

    func slotX(_ index: Int) -> CGFloat { CGFloat(index) * slotWidth }

    func slotDate(_ index: Int) -> Date { start.addingTimeInterval(Double(index) * Self.slotSeconds) }

    /// Visible slot indices intersecting `[minX, maxX)`.
    func slots(intersecting minX: CGFloat, _ maxX: CGFloat) -> Range<Int> {
        guard slotCount > 0, slotWidth > 0 else { return 0..<0 }
        let first = max(0, Int((minX / slotWidth).rounded(.down)))
        let last = min(slotCount, Int((maxX / slotWidth).rounded(.up)) + 1)
        return first..<max(first, last)
    }

    @MainActor
    func title(_ index: Int) -> String {
        let clock = EPGClockText.shared
        let date = slotDate(index)
        let seconds = date.timeIntervalSinceReferenceDate
        // Same local day as the reference; the day can be 23-25 hours long.
        let sameDay = date >= relativeDay && date < relativeDayEnd
        return sameDay ? clock.shortTime(seconds) : clock.weekdayTime(seconds)
    }
}
