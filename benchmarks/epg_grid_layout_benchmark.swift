import AppKit
import Darwin

// Standalone -O benchmark for the EPG grid rendering hot paths.
//
//   scripts/bench-epg-grid-layout.sh
//
// Every "legacy" function below is the previous production code reproduced
// verbatim in structure (ProgramCanvasLayer.buildBlocks, EPGGridView.buildRowData,
// ProgramRow.reminderProgramIDs, the dictionary-backed visible row window,
// ProgramBlocksView/ChannelLabelOverlayView draw loops and the 14-day time
// strip builder). The "current" side calls the production types directly.

// MARK: - Allocation counter (libmalloc's malloc_logger hook)

private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
nonisolated(unsafe) private var allocationCount = 0
private let countingLogger: MallocLogger = { type, _, _, _, _, _ in
    if type & 2 != 0 { allocationCount &+= 1 } // MALLOC_LOG_TYPE_ALLOCATE (includes realloc)
}

private enum Allocations {
    nonisolated(unsafe) static let hook: UnsafeMutablePointer<MallocLogger?>? = {
        if getenv("EPG_BENCH_NO_MALLOC_LOG") != nil { return nil }
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        return symbol.assumingMemoryBound(to: MallocLogger?.self)
    }()

    /// Mallocs performed by `body` on any thread (the benchmark is single-threaded).
    static func count(_ body: () -> Void) -> Int {
        guard let hook else { return -1 }
        allocationCount = 0
        hook.pointee = countingLogger
        body()
        hook.pointee = nil
        return allocationCount
    }
}

// MARK: - Fixture

private struct Fixture {
    let rows: [[EPGProgram]]
    let timelineStart: Date
    let timelineWidth: CGFloat
    let hours: Int
    let showGaps: Bool
    let label: String
}

private func makeFixture(rows: Int, hours: Int, showGaps: Bool, label: String) -> Fixture {
    // Deterministic LCG so every run lays out identical data.
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next(_ bound: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(bound))
    }
    let start = Date(timeIntervalSinceReferenceDate: 815_000_000) // a fixed Tuesday, 2026
    let end = start.addingTimeInterval(Double(hours) * 3600)
    var all: [[EPGProgram]] = []
    for row in 0..<rows {
        var programs: [EPGProgram] = []
        // Begin before the window, like real guides, and run past it.
        var cursor = start.addingTimeInterval(-Double(next(90)) * 60)
        var index = 0
        while cursor < end.addingTimeInterval(3600) {
            let minutes = [5, 10, 15, 25, 30, 30, 30, 45, 60, 60, 90, 120][next(12)]
            let programEnd = cursor.addingTimeInterval(Double(minutes) * 60)
            // Occasional genuine guide gaps.
            let gap = next(20) == 0 ? Double(next(4) * 15) * 60 : 0
            programs.append(EPGProgram(id: "c\(row)-p\(index)", channelID: "c\(row)",
                                       title: "Programme \(row)-\(index) with a realistic length title",
                                       description: "", start: cursor, end: programEnd))
            cursor = programEnd.addingTimeInterval(gap)
            index += 1
        }
        all.append(programs)
    }
    return Fixture(rows: all, timelineStart: start, timelineWidth: CGFloat(hours * 60) * 4, hours: hours,
                   showGaps: showGaps, label: label)
}

// MARK: - Legacy implementations (previous production code)

private struct LegacyBlock {
    let program: EPGProgram?
    let rect: CGRect
    let hasReminder: Bool
}

private struct LegacyLabelBlock {
    let rect: CGRect
    let timeRange: String?
}

private struct LegacyRowData {
    let channelName: String
    let blocks: [LegacyLabelBlock]
}

private func legacyTimelineTime(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
        .replacingOccurrences(of: " ", with: "")
        .lowercased()
}

private func legacyBuildBlocks(programs: [EPGProgram], timelineStart: Date, timelineWidth: CGFloat,
                               pixelsPerMinute: CGFloat, rowHeight: CGFloat, showGuideGaps: Bool,
                               reminderProgramIDs: Set<String>) -> [LegacyBlock] {
    let end = timelineStart.addingTimeInterval(Double(timelineWidth / pixelsPerMinute) * 60)
    let sorted = programs
        .filter { $0.end > timelineStart && $0.start < end }
        .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    var blocks: [LegacyBlock] = []
    var cursor: Date = timelineStart
    func appendGap(until gapEnd: Date) {
        guard gapEnd > cursor else { return }
        let startX = max(0, cursor.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
        let endX = min(Double(timelineWidth), gapEnd.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
        let width = endX - startX
        guard width > 2 else { return }
        blocks.append(LegacyBlock(program: nil, rect: CGRect(x: startX, y: 3, width: width, height: Double(rowHeight) - 6), hasReminder: false))
    }
    for p in sorted {
        if showGuideGaps { appendGap(until: p.start) }
        let effectiveStart = max(p.start, cursor)
        guard p.end > effectiveStart else { continue }
        let startX = max(0, effectiveStart.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
        let endX = min(Double(timelineWidth), p.end.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
        let width = endX - startX
        guard width > 2 else { continue }
        blocks.append(LegacyBlock(program: p, rect: CGRect(x: startX, y: 3, width: width, height: Double(rowHeight) - 6),
                                  hasReminder: reminderProgramIDs.contains(p.id)))
        cursor = p.end
    }
    if showGuideGaps && !sorted.isEmpty { appendGap(until: end) }
    return blocks
}

private func legacyBuildRowData(name: String, programs: [EPGProgram], timelineStart: Date, pixelsPerMinute: CGFloat,
                                timelineHours: Int, rowHeight: CGFloat, showGuideGaps: Bool) -> LegacyRowData {
    let timelineWidth = CGFloat(timelineHours * 60) * pixelsPerMinute
    let end = timelineStart.addingTimeInterval(Double(timelineWidth / pixelsPerMinute) * 60)
    let sorted = programs
        .filter { $0.end > timelineStart && $0.start < end }
        .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    var blocks: [LegacyLabelBlock] = []
    var cursor = timelineStart
    func appendGap(until gapEnd: Date) {
        guard gapEnd > cursor else { return }
        let startX = max(0, cursor.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
        let endX = min(Double(timelineWidth), gapEnd.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
        let width = endX - startX
        guard width > 2 else { return }
        blocks.append(LegacyLabelBlock(rect: CGRect(x: startX, y: 3, width: width, height: Double(rowHeight) - 6), timeRange: nil))
    }
    for p in sorted {
        if showGuideGaps { appendGap(until: p.start) }
        let effectiveStart = max(p.start, cursor)
        guard p.end > effectiveStart else { continue }
        let startX = max(0, effectiveStart.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
        let endX = min(Double(timelineWidth), p.end.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
        let width = endX - startX
        guard width > 2 else { continue }
        blocks.append(LegacyLabelBlock(rect: CGRect(x: startX, y: 3, width: width, height: Double(rowHeight) - 6),
                                       timeRange: "\(legacyTimelineTime(p.start)) - \(legacyTimelineTime(p.end))"))
        cursor = p.end
    }
    if showGuideGaps && !sorted.isEmpty { appendGap(until: end) }
    return LegacyRowData(channelName: name, blocks: blocks)
}

private struct LegacyReminder { let playlistID: UUID; let programID: String }

private func legacyReminderIDs(programs: [EPGProgram], reminders: [LegacyReminder], playlistID: UUID) -> Set<String> {
    let ids = Set(programs.map(\.id))
    return Set(reminders.lazy.filter { $0.playlistID == playlistID && ids.contains($0.programID) }.map(\.programID))
}

@MainActor
private func legacyDrawBlocks(_ blocks: [LegacyBlock], originX: CGFloat, bounds: CGRect, dirtyRect: NSRect,
                              appearance: NSAppearance, referenceDate: Date, replayLookbackHours: Int?) {
    let palette = EPGGridStyle.palette(for: appearance)
    let replayStart = replayLookbackHours.map { referenceDate.addingTimeInterval(-Double($0) * 3600) }
    let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let timelineDirtyRect = dirtyRect.offsetBy(dx: originX, dy: 0)
    for block in blocks {
        guard block.program != nil else { continue }
        guard block.rect.intersects(timelineDirtyRect) else { continue }
        let inset = block.rect.offsetBy(dx: -originX, dy: 0).insetBy(dx: 1, dy: 0)
        let path = NSBezierPath(roundedRect: inset, xRadius: 3, yRadius: 3)
        guard let program = block.program else { continue }
        let state = EPGGridStyle.state(for: program, now: referenceDate, replayStart: replayStart)
        palette.surface(for: state, hovered: false).setFill()
        path.fill()
        palette.border.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if state == .live || state == .replay {
            (state == .live ? palette.liveIndicator : palette.replayIndicator).setFill()
            NSRect(x: inset.minX, y: inset.minY + 3, width: 2, height: max(0, inset.height - 6)).fill()
        }
        let title = program.title.isEmpty ? "No Event Today" : program.title
        let titleX = max(inset.minX, bounds.minX) + EPGStickyLabelMetrics.x
        let titleY = max(inset.minY + 2, EPGStickyLabelMetrics.titleRowY)
        let titleWidth = min(EPGStickyLabelMetrics.titleMaxWidth, inset.maxX - EPGStickyLabelMetrics.x - titleX)
        if titleWidth > 8 {
            (title as NSString).draw(in: NSRect(x: titleX, y: titleY, width: titleWidth, height: EPGStickyLabelMetrics.titleRowHeight),
                                     withAttributes: [.font: titleFont, .foregroundColor: palette.primaryText, .paragraphStyle: paragraph])
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
private func legacyDrawOverlay(_ rowDataByIndex: [Int: LegacyRowData], bounds: CGRect, rowHeight: CGFloat,
                               scrollOffsetX: CGFloat, scrollOffsetY: CGFloat, appearance: NSAppearance) {
    let palette = EPGGridStyle.palette(for: appearance)
    NSBezierPath(rect: bounds).addClip()
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    paragraph.minimumLineHeight = EPGStickyLabelMetrics.topRowHeight
    paragraph.maximumLineHeight = EPGStickyLabelMetrics.topRowHeight
    let metadataMaxWidth = EPGStickyLabelMetrics.labelWidth(for: bounds.width, maxWidth: EPGStickyLabelMetrics.metadataMaxWidth)
    func measured(_ text: NSAttributedString) -> CGFloat {
        ceil(text.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading]).width) + 1
    }
    let first = max(0, Int(floor(scrollOffsetY / rowHeight)))
    let last = first + Int(ceil(bounds.height / rowHeight)) + 2
    for row in first...last {
        guard let data = rowDataByIndex[row] else { continue }
        let rowY = CGFloat(row) * rowHeight - scrollOffsetY
        guard rowY < bounds.maxY, rowY + rowHeight > bounds.minY else { continue }
        let name = data.channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelText = name.isEmpty ? nil : NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: palette.primaryText, .paragraphStyle: paragraph])
        let channelWidth = channelText.map { min(measured($0), metadataMaxWidth) } ?? 0
        let timeLeadingX = EPGStickyLabelMetrics.x + channelWidth + (channelWidth > 0 ? EPGStickyLabelMetrics.metadataCollisionGap : 0)
        for block in data.blocks {
            guard let timeRange = block.timeRange, !timeRange.isEmpty else { continue }
            let minX = block.rect.minX - scrollOffsetX, maxX = block.rect.maxX - scrollOffsetX
            guard maxX > 0, minX < bounds.width else { continue }
            let textX = max(minX + 1 + EPGStickyLabelMetrics.x, timeLeadingX)
            let textRight = min(bounds.width - EPGStickyLabelMetrics.viewportTrailingPadding, maxX - 1 - EPGStickyLabelMetrics.x)
            let available = textRight - textX
            guard available > 4 else { continue }
            let timeText = NSAttributedString(string: timeRange, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular), .foregroundColor: palette.metadataText, .paragraphStyle: paragraph])
            let labelWidth = min(measured(timeText), metadataMaxWidth, available)
            guard labelWidth > 4 else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: minX, y: rowY, width: maxX - minX, height: rowHeight)).addClip()
            timeText.draw(with: NSRect(x: textX, y: rowY + EPGStickyLabelMetrics.topRowY, width: labelWidth, height: EPGStickyLabelMetrics.topRowHeight),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            NSGraphicsContext.restoreGraphicsState()
        }
        if let channelText {
            let width = min(measured(channelText), min(metadataMaxWidth, bounds.width - 20))
            channelText.draw(with: NSRect(x: EPGStickyLabelMetrics.x, y: rowY + EPGStickyLabelMetrics.topRowY, width: width, height: 14),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

private func legacyTimeStrip(start: Date, hours: Int, pixelsPerMinute: CGFloat, now: Date) -> [(x: CGFloat, title: String)] {
    let calendar = Calendar.current
    return (0..<(max(0, hours) * 2)).map { index in
        let date = start.addingTimeInterval(Double(index) * 30 * 60)
        let title = calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return (CGFloat(index) * 30 * pixelsPerMinute, title)
    }
}

// MARK: - Harness

private func milliseconds(_ body: () -> Void) -> Double {
    let started = ContinuousClock.now
    body()
    let d = started.duration(to: .now).components
    return Double(d.seconds) * 1_000 + Double(d.attoseconds) / 1e15
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

private func sample(runs: Int = 9, _ body: () -> Void) -> Double {
    body() // warm
    return median((0..<runs).map { _ in milliseconds(body) })
}

private func format(_ value: Double) -> String { String(format: value < 0.1 ? "%.4f" : "%.3f", value) }

@MainActor
private func report(_ name: String, legacy: Double, current: Double, legacyAllocs: Int, currentAllocs: Int, unit: String = "ms") {
    let speedup = current > 0 ? legacy / current : .infinity
    print("| \(name) | \(format(legacy)) \(unit) | \(format(current)) \(unit) | \(String(format: "%.1f", speedup))x | \(legacyAllocs) | \(currentAllocs) |")
}

/// Bitmap backing stores must outlive the contexts drawing into them.
@MainActor private var retainedBitmaps: [NSBitmapImageRep] = []

@MainActor
private func bitmapContext(width: Int, height: Int) -> NSGraphicsContext {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    retainedBitmaps.append(rep)
    let base = NSGraphicsContext(bitmapImageRep: rep)!
    base.cgContext.scaleBy(x: 2, y: 2)
    base.cgContext.translateBy(x: 0, y: CGFloat(height))
    base.cgContext.scaleBy(x: 1, y: -1)
    return NSGraphicsContext(cgContext: base.cgContext, flipped: true)
}

@main
@MainActor
struct EPGGridLayoutBenchmark {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        _ = NSApplication.shared
        let probe = Allocations.count { for _ in 0..<1_000 { _ = NSObject() } }
        fputs("malloc_logger probe: \(probe) allocations for 1000 objects\n", stderr)
        precondition(probe < 0 || probe >= 1_000, "malloc_logger hook counts allocations (\(probe))")

        let visibleRows = 60
        let viewportWidth: CGFloat = 1_080
        let appearance = NSAppearance(named: .darkAqua)!
        let playlist = UUID()
        let reminders = (0..<40).map { LegacyReminder(playlistID: playlist, programID: "c\($0 * 7)-p\($0)") }
        let reminderIDs = Set(reminders.map(\.programID))

        print("| Operation | Legacy | Current | Speedup | Legacy mallocs | Current mallocs |")
        print("|---|---|---|---|---|---|")

        for fixture in [makeFixture(rows: 2_000, hours: 6, showGaps: false, label: "6h live window"),
                        makeFixture(rows: 2_000, hours: 347, showGaps: true, label: "14-day catch-up timeline")] {
            let rows = Array(fixture.rows.prefix(visibleRows))
            let cells = rows.reduce(0) { $0 + $1.count }

            // 1. Lay out the visible window: programme canvas + sticky labels per row.
            var legacyOut: [([LegacyBlock], LegacyRowData)] = []
            let legacyLayout = {
                legacyOut.removeAll(keepingCapacity: true)
                for (index, programs) in rows.enumerated() {
                    let ids = legacyReminderIDs(programs: programs, reminders: reminders, playlistID: playlist)
                    let blocks = legacyBuildBlocks(programs: programs, timelineStart: fixture.timelineStart,
                                                   timelineWidth: fixture.timelineWidth, pixelsPerMinute: 4, rowHeight: 64,
                                                   showGuideGaps: fixture.showGaps, reminderProgramIDs: ids)
                    let data = legacyBuildRowData(name: "Channel \(index)", programs: programs, timelineStart: fixture.timelineStart,
                                                  pixelsPerMinute: 4, timelineHours: fixture.hours, rowHeight: 64,
                                                  showGuideGaps: fixture.showGaps)
                    legacyOut.append((blocks, data))
                }
            }
            var canvasLayouts = (0..<visibleRows).map { _ in EPGRowLayout() }
            let store = EPGLabelRowStore()
            var shift = 0
            let currentLayout = {
                for (index, programs) in rows.enumerated() {
                    canvasLayouts[index].build(programs: programs, timelineStart: fixture.timelineStart, pixelsPerMinute: 4,
                                               timelineWidth: Double(fixture.timelineWidth), rowHeight: 64,
                                               showGaps: fixture.showGaps, reminderIDs: reminderIDs)
                }
                // Force a refill of every label slot (alternate disjoint windows).
                shift = shift == 0 ? visibleRows : 0
                store.update(range: shift..<(shift + visibleRows)) { row, slot in
                    slot.channelName = "Channel \(row)"
                    slot.layout.build(programs: rows[row - shift], timelineStart: fixture.timelineStart, pixelsPerMinute: 4,
                                      timelineWidth: Double(fixture.timelineWidth), rowHeight: 64, showGaps: fixture.showGaps)
                }
            }
            // Equivalence: identical geometry and programme order.
            legacyLayout(); currentLayout()
            for (index, (blocks, _)) in legacyOut.enumerated() {
                let layout = canvasLayouts[index]
                precondition(blocks.count == layout.count, "\(fixture.label) row \(index) cell count")
                for (cell, block) in blocks.enumerated() {
                    precondition(abs(block.rect.minX - CGFloat(layout.x[cell])) < 0.05 &&
                                 abs(block.rect.width - CGFloat(layout.width[cell])) < 0.05, "geometry")
                    precondition(block.program?.id == (layout.source[cell] >= 0 ? rows[index][Int(layout.source[cell])].id : nil), "source")
                    precondition(block.hasReminder == (layout.flags[cell] & EPGCellFlags.reminder != 0), "reminder")
                }
            }
            let legacyMs = sample(legacyLayout)
            let currentMs = sample(currentLayout)
            report("Layout \(visibleRows) rows, \(fixture.label) (\(cells) programmes)", legacy: legacyMs, current: currentMs,
                   legacyAllocs: Allocations.count(legacyLayout), currentAllocs: Allocations.count(currentLayout))

            // 2. One vertical scroll step that exposes a new row.
            let overscroll = 12, window = 10 + 2 * overscroll
            var legacyByIndex: [Int: LegacyRowData] = [:]
            for row in 0..<window {
                legacyByIndex[row] = legacyBuildRowData(name: "Channel \(row)", programs: fixture.rows[row], timelineStart: fixture.timelineStart,
                                                        pixelsPerMinute: 4, timelineHours: fixture.hours, rowHeight: 64, showGuideGaps: fixture.showGaps)
            }
            var legacyFirst = 0
            let legacyStep = {
                legacyFirst = (legacyFirst + 1) % (fixture.rows.count - window)
                let range = legacyFirst..<(legacyFirst + window)
                legacyByIndex = legacyByIndex.filter { range.contains($0.key) }
                legacyByIndex.reserveCapacity(range.count)
                for r in range where legacyByIndex[r] == nil {
                    legacyByIndex[r] = legacyBuildRowData(name: "Channel \(r)", programs: fixture.rows[r], timelineStart: fixture.timelineStart,
                                                          pixelsPerMinute: 4, timelineHours: fixture.hours, rowHeight: 64, showGuideGaps: fixture.showGaps)
                }
                // The newly exposed programme row (SwiftUI ProgramRow body).
                let programs = fixture.rows[range.upperBound - 1]
                let ids = legacyReminderIDs(programs: programs, reminders: reminders, playlistID: playlist)
                _ = legacyBuildBlocks(programs: programs, timelineStart: fixture.timelineStart, timelineWidth: fixture.timelineWidth,
                                      pixelsPerMinute: 4, rowHeight: 64, showGuideGaps: fixture.showGaps, reminderProgramIDs: ids)
            }
            let stepStore = EPGLabelRowStore()
            let canvas = ProgramBlocksView(frame: CGRect(x: 0, y: 0, width: viewportWidth, height: 64))
            var currentFirst = 0
            let fill: (Int, inout EPGLabelRow) -> Void = { row, slot in
                slot.channelName = "Channel \(row)"
                slot.layout.build(programs: fixture.rows[row], timelineStart: fixture.timelineStart, pixelsPerMinute: 4,
                                  timelineWidth: Double(fixture.timelineWidth), rowHeight: 64, showGaps: fixture.showGaps)
            }
            stepStore.update(range: 0..<window, fill: fill)
            let currentStep = {
                currentFirst = (currentFirst + 1) % (fixture.rows.count - window)
                let range = currentFirst..<(currentFirst + window)
                stepStore.update(range: range, fill: fill)
                // The newly exposed native programme row.
                canvas.setPrograms(fixture.rows[range.upperBound - 1], timelineStart: fixture.timelineStart, pixelsPerMinute: 4,
                                   timelineWidth: fixture.timelineWidth, rowHeight: 64, showGaps: fixture.showGaps,
                                   reminderIDs: reminderIDs)
            }
            let legacyStepMs = sample(runs: 9) { for _ in 0..<100 { legacyStep() } } / 100
            let currentStepMs = sample(runs: 9) { for _ in 0..<100 { currentStep() } } / 100
            report("Vertical scroll step (1 new row), \(fixture.label)", legacy: legacyStepMs, current: currentStepMs,
                   legacyAllocs: Allocations.count(legacyStep), currentAllocs: Allocations.count(currentStep))

            // 3. One horizontal scroll step: redraw 15 visible programme rows + the sticky label overlay.
            let drawRows = 15
            // Pan back and forth across the populated document.
            let maxOrigin = max(1, Int(fixture.timelineWidth - viewportWidth))
            let firstOrigin = maxOrigin / 2
            var frame = 0
            var originX = CGFloat(firstOrigin)
            let rowContext = bitmapContext(width: Int(viewportWidth), height: 64)
            let overlayContext = bitmapContext(width: Int(viewportWidth), height: drawRows * 64)
            let legacyBlocksByRow = (0..<drawRows).map { row in
                legacyBuildBlocks(programs: fixture.rows[row], timelineStart: fixture.timelineStart, timelineWidth: fixture.timelineWidth,
                                  pixelsPerMinute: 4, rowHeight: 64, showGuideGaps: fixture.showGaps, reminderProgramIDs: [])
            }
            var legacyLabels: [Int: LegacyRowData] = [:]
            for row in 0..<drawRows {
                legacyLabels[row] = legacyBuildRowData(name: "Channel \(row)", programs: fixture.rows[row], timelineStart: fixture.timelineStart,
                                                       pixelsPerMinute: 4, timelineHours: fixture.hours, rowHeight: 64, showGuideGaps: fixture.showGaps)
            }
            let now = fixture.timelineStart.addingTimeInterval(Double(fixture.hours) * 1800)
            let legacyDraw = {
                frame += 1
                originX = CGFloat((firstOrigin + frame * 7) % maxOrigin)
                NSGraphicsContext.current = rowContext
                for blocks in legacyBlocksByRow {
                    legacyDrawBlocks(blocks, originX: originX, bounds: CGRect(x: 0, y: 0, width: viewportWidth, height: 64),
                                     dirtyRect: CGRect(x: 0, y: 0, width: viewportWidth, height: 64), appearance: appearance,
                                     referenceDate: now, replayLookbackHours: 72)
                }
                NSGraphicsContext.current = overlayContext
                legacyDrawOverlay(legacyLabels, bounds: CGRect(x: 0, y: 0, width: viewportWidth, height: CGFloat(drawRows * 64)),
                                  rowHeight: 64, scrollOffsetX: originX, scrollOffsetY: 0, appearance: appearance)
                NSGraphicsContext.current = nil
            }
            let canvases = (0..<drawRows).map { row -> ProgramBlocksView in
                let view = ProgramBlocksView(frame: CGRect(x: 0, y: 0, width: viewportWidth, height: 64))
                view.appearance = appearance
                view.setReferenceDate(now)
                view.setReplayLookbackHours(72)
                view.setPrograms(fixture.rows[row], timelineStart: fixture.timelineStart, pixelsPerMinute: 4,
                                 timelineWidth: fixture.timelineWidth, rowHeight: 64, showGaps: fixture.showGaps, reminderIDs: [])
                return view
            }
            let overlay = ChannelLabelOverlayView(frame: CGRect(x: 0, y: 0, width: viewportWidth, height: CGFloat(drawRows * 64)))
            overlay.appearance = appearance
            overlay.store.update(range: 0..<drawRows, fill: fill)
            func drawOverlay() {
                NSGraphicsContext.current = overlayContext
                overlay.scrollOffsetX = originX
                overlay.draw(overlay.bounds)
                NSGraphicsContext.current = nil
            }
            // (a) Drawing efficiency alone: every row repaints its full viewport, as before.
            let currentFullRepaint = {
                frame += 1
                originX = CGFloat((firstOrigin + frame * 7) % maxOrigin)
                NSGraphicsContext.current = rowContext
                for view in canvases {
                    view.setFrameSize(NSSize(width: viewportWidth, height: 64))
                    view.setTimelineOriginX(originX)
                    view.draw(view.bounds)
                }
                drawOverlay()
            }
            // (b) Production invalidation (EPGNativeProgramCell): surfaces span the viewport
            // plus a staggered margin; a pan inside the margin repaints only the cards under
            // the old and new leading edge, and a surface is re-centred at its edge.
            let wideContext = bitmapContext(width: Int(viewportWidth * 1.8), height: 64)
            var surfaceMinX = [CGFloat](repeating: -1, count: drawRows)
            var surfaceWidth = [CGFloat](repeating: 0, count: drawRows)
            var lastPin = [CGFloat](repeating: 0, count: drawRows)
            let currentPan = {
                frame += 1
                originX = CGFloat((firstOrigin + frame * 7) % maxOrigin)
                NSGraphicsContext.current = wideContext
                for row in 0..<drawRows {
                    let view = canvases[row]
                    let margin = (viewportWidth * (0.2 + 0.05 * CGFloat(row % 4))).rounded()
                    let covers = surfaceWidth[row] > 0 && surfaceMinX[row] <= originX
                        && surfaceMinX[row] + surfaceWidth[row] >= originX + viewportWidth
                    if !covers {
                        let left = max(0, originX - margin)
                        let right = min(fixture.timelineWidth, originX + viewportWidth + margin)
                        surfaceMinX[row] = left
                        surfaceWidth[row] = right - left
                        view.setFrameSize(NSSize(width: right - left, height: 64))
                        view.setTimelineOriginX(left)
                        view.setVisibleSpan(minX: originX - left, maxX: originX + viewportWidth - left)
                        view.draw(view.bounds)
                    } else {
                        let pin = originX - surfaceMinX[row]
                        view.setVisibleSpan(minX: pin, maxX: pin + viewportWidth)
                        // AppKit unions the two invalidated card rects into one display pass.
                        func cardRect(atLocalX x: CGFloat) -> CGRect {
                            guard let cell = view.layout.cell(containingX: Double(x + surfaceMinX[row]), y: 3) else { return .null }
                            return view.layout.rect(cell).offsetBy(dx: -surfaceMinX[row], dy: 0).intersection(view.bounds)
                        }
                        if lastPin[row] != pin {
                            let dirty = cardRect(atLocalX: lastPin[row]).union(cardRect(atLocalX: pin))
                            if !dirty.isNull, !dirty.isEmpty { view.draw(dirty) }
                        }
                    }
                    lastPin[row] = originX - surfaceMinX[row]
                }
                drawOverlay()
            }
            let legacyDrawMs = sample(runs: 9) { for _ in 0..<40 { legacyDraw() } } / 40
            let fullRepaintMs = sample(runs: 9) { for _ in 0..<40 { currentFullRepaint() } } / 40
            let panMs = sample(runs: 9) { for _ in 0..<200 { currentPan() } } / 200
            var legacyAllocs = 0, fullAllocs = 0, panAllocs = 0
            legacyAllocs = Allocations.count { for _ in 0..<40 { legacyDraw() } } / 40
            fullAllocs = Allocations.count { for _ in 0..<40 { currentFullRepaint() } } / 40
            panAllocs = Allocations.count { for _ in 0..<200 { currentPan() } } / 200
            report("Repaint \(drawRows) visible rows + labels (draw cost only), \(fixture.label)", legacy: legacyDrawMs,
                   current: fullRepaintMs, legacyAllocs: legacyAllocs, currentAllocs: fullAllocs)
            report("Horizontal scroll frame, 7pt/frame pan (\(drawRows) rows + labels), \(fixture.label)", legacy: legacyDrawMs,
                   current: panMs, legacyAllocs: legacyAllocs, currentAllocs: panAllocs)
        }

        // 4. Time strip: 14-day header (694 half-hour slots).
        let stripStart = Date(timeIntervalSinceReferenceDate: 815_000_000)
        var tick = 0.0
        let legacyStrip = {
            tick += 20
            _ = legacyTimeStrip(start: stripStart, hours: 347, pixelsPerMinute: 4, now: stripStart.addingTimeInterval(tick))
        }
        let visibleSlots = Int(ceil(1_080 / 120.0)) + 1
        var stripCount = 0
        let currentStrip = {
            tick += 20
            let spec = EPGTimeStripSpec(start: stripStart, hours: 347, pixelsPerMinute: 4, relativeTo: stripStart.addingTimeInterval(tick))
            EPGClockText.shared.beginPass()
            for index in spec.slots(intersecting: 40_000, 40_000 + 1_080) { stripCount += spec.title(index).utf8.count }
        }
        precondition(legacyTimeStrip(start: stripStart, hours: 347, pixelsPerMinute: 4, now: stripStart).enumerated().allSatisfy { index, slot in
            let spec = EPGTimeStripSpec(start: stripStart, hours: 347, pixelsPerMinute: 4, relativeTo: stripStart)
            return slot.title == spec.title(index) && slot.x == spec.slotX(index)
        }, "time strip titles and geometry match the previous builder")
        report("Time strip per update (legacy: build 694 titles; current: spec + \(visibleSlots) visible titles)",
               legacy: sample(legacyStrip), current: sample(currentStrip),
               legacyAllocs: Allocations.count(legacyStrip), currentAllocs: Allocations.count(currentStrip))
        _ = stripCount
    }
}
