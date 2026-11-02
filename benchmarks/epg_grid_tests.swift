import AppKit
import SwiftUI

private struct GridItem: Identifiable {
    let id: Int
    let name: String
    var favorite = false
}

private struct ProbeRow: View {
    let label: String
    var body: some View { Text(label) }
}

/// 672 half-hour programmes: a 14-day archive row.
private let archivePrograms: [EPGProgram] = (0..<672).map { index in
    EPGProgram(id: "slot-\(index)", channelID: "fixture", title: "Slot \(index)", description: "",
               start: Date(timeIntervalSinceReferenceDate: Double(index) * 1_800),
               end: Date(timeIntervalSinceReferenceDate: Double(index + 1) * 1_800))
}

@MainActor
private final class GridProbe {
    typealias Grid = EPGScrollGrid<GridItem, ProbeRow, ProbeRow, EmptyView>

    var calls = 0
    var observedNames: [String] = []
    var visiblePublications: [[Int]] = []
    var visibleNames: [[String]] = []
    var expensive = false
    var grid: Grid!
    var coordinator: Grid.Coordinator!
    var container: EPGContainerView!
    let window: NSWindow

    init(items: [GridItem], reveal: Int? = nil, publishBeforeLayout: Bool = false) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 608), styleMask: [.borderless], backing: .buffered, defer: false)
        grid = makeGrid(items: items, reveal: reveal)
        coordinator = grid.makeCoordinator()
        container = grid.makeContainer(coordinator: coordinator)
        if publishBeforeLayout {
            publish(grid)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        window.contentView = container
        if !publishBeforeLayout { publish(grid) }
        container.layoutSubtreeIfNeeded()
    }

    func makeGrid(items: [GridItem], itemVersion: Int? = 1, guideVersion: Int? = 1, timeline: Int = 1,
                  width: CGFloat = 80_640, reveal: Int? = nil, hasProvider: Bool = true) -> Grid {
        var grid = Grid(
            items: items, rowHeight: 64, channelColumnWidth: 120, programRowWidth: width,
            headerHeight: 32, nowLineX: nil, initialHorizontalOffset: nil,
            horizontalScrollRequest: nil, timelineIdentity: timeline,
            itemSetVersion: itemVersion.map(AnyHashable.init), dataVersion: guideVersion.map(AnyHashable.init),
            timeStrip: .empty,
            rowDataProvider: hasProvider ? { [weak self] item, slot in
                slot.channelName = item.name
                guard let self else { slot.layout.removeAll(); return }
                self.calls += 1
                self.observedNames.append(item.name)
                slot.layout.build(programs: self.expensive ? archivePrograms : [],
                                  timelineStart: Date(timeIntervalSinceReferenceDate: 0), pixelsPerMinute: 4,
                                  timelineWidth: Double(width), rowHeight: 64, showGaps: false)
            } : nil,
            revealItemID: reveal.map(AnyHashable.init),
            channelContent: { ProbeRow(label: "\($0.name):\($0.favorite)") },
            programContent: { ProbeRow(label: "\($0.name):guide\(guideVersion ?? -1)") },
            cornerContent: { EmptyView() }
        )
        #if GRID_BASELINE
        grid.channelNameProvider = { $0.name }
        #else
        grid.visibleItemsDidChange = { [weak self] items in
            self?.visiblePublications.append(items.map(\.id))
            self?.visibleNames.append(items.map(\.name))
        }
        #endif
        return grid
    }

    func publish(_ next: Grid) {
        grid = next
        grid.updateContainer(container, coordinator: coordinator)
    }

    func contentLabel(_ table: NSTableView, row: Int) -> String? {
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true),
              let host = cell.subviews.first as? NSHostingView<ProbeRow> else { return nil }
        return host.rootView.label
    }

    var overlay: ChannelLabelOverlayView {
        container.subviews.first(where: { $0 is ChannelLabelOverlayView }) as! ChannelLabelOverlayView
    }

    var labels: EPGLabelRowStore { container.labelStore }

    func labelName(_ row: Int) -> String? { labels.row(row)?.channelName }

    var clip: NSClipView { container.programTableView.enclosingScrollView!.contentView }

    func scroll(x: CGFloat, y: CGFloat) {
        clip.scroll(to: NSPoint(x: x, y: y))
        container.programTableView.enclosingScrollView!.reflectScrolledClipView(clip)
    }
}

@main
@MainActor
struct EPGGridTests {
    static var checks = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL \(message)\n", stderr)
            exit(1)
        }
        checks += 1
    }

    static func pump(_ seconds: Double = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func main() {
        _ = NSApplication.shared
        let items = (0..<1_000).map { GridItem(id: $0, name: "Channel \($0)") }
        if CommandLine.arguments.contains("--benchmark") {
            benchmark(items)
            return
        }

        let probe = GridProbe(items: items)
        require(probe.container.channelTableView.numberOfRows == 1_000, "first publication installs all table identities")
        require(probe.labelName(0) == "Channel 0", "first publication installs current overlay names")
        require(probe.contentLabel(probe.container.channelTableView, row: 0) == "Channel 0:false", "initial channel host")
        let initialCalls = probe.calls
        require(initialCalls > 0 && initialCalls < 40, "rowData work is bounded to visible+overscroll window")
        require(probe.visiblePublications.isEmpty, "viewport callback is deferred beyond AppKit layout/publication")
        pump()
        require(probe.visiblePublications.count == 1, "first laid-out viewport publishes once")
        require(probe.visiblePublications[0].count <= 10 && probe.visiblePublications[0].first == 0,
                "viewport priorities include actual visible rows without metadata overscroll")
        let initialViewportPublications = probe.visiblePublications.count
        let early = GridProbe(items: items, reveal: 100, publishBeforeLayout: true)
        pump(0.5)
        require(early.labels.populatedRows.contains(where: { early.labelName($0) == "Channel 100" }), "layout after first publication populates labels and resumes early reveal")

        for x in stride(from: CGFloat(20), through: 2_000, by: 20) { probe.scroll(x: x, y: 0) }
        require(probe.calls == initialCalls, "100 horizontal scrolls reuse document-space row data")
        probe.publish(probe.makeGrid(items: items))
        require(probe.calls == initialCalls, "same source versions reuse row data on view update")
        pump()
        require(probe.visiblePublications.count == initialViewportPublications,
                "horizontal scrolling and identical updates do not repeat viewport requests")

        var renamed = items
        renamed[0] = GridItem(id: 0, name: "Renamed", favorite: true)
        probe.observedNames.removeAll()
        probe.publish(probe.makeGrid(items: renamed, itemVersion: 2, guideVersion: 2, width: 90_000))
        require(!probe.observedNames.contains("Channel 0"), "geometry callbacks receive new items before new providers")
        require(probe.labelName(0) == "Renamed", "same-ID rename refreshes overlay")
        require(probe.contentLabel(probe.container.channelTableView, row: 0) == "Renamed:true", "guide+metadata publication refreshes channel host and favorite")
        require(probe.contentLabel(probe.container.programTableView, row: 0) == "Renamed:guide2", "guide+metadata publication refreshes program host")
        pump()
        require(probe.visibleNames.last?.first == "Renamed", "same-ID metadata revision refreshes viewport priority channels")
        let afterRename = probe.calls
        probe.publish(probe.makeGrid(items: renamed, itemVersion: 2, guideVersion: 3, width: 90_000))
        require(probe.calls > afterRename, "guide revision invalidates row data")

        let beforeVertical = probe.calls
        probe.scroll(x: 200, y: 64)
        require(probe.calls > beforeVertical && probe.calls - beforeVertical <= 2, "one-row vertical scroll builds only newly exposed metadata")
        pump()
        require(probe.visiblePublications.last?.first == 1, "vertical scrolling updates actual viewport priority channels")

        // Only the newest vertical range survives deferred publication.
        let beforeCoalescedViewport = probe.visiblePublications.count
        probe.scroll(x: 200, y: 64 * 3)
        probe.scroll(x: 200, y: 64 * 5)
        pump()
        require(probe.visiblePublications.count == beforeCoalescedViewport + 1 && probe.visiblePublications.last?.first == 5,
                "deferred viewport publication drops superseded scroll ranges")

        probe.publish(probe.makeGrid(items: renamed, itemVersion: 2, guideVersion: 3, width: 90_000, hasProvider: false))
        require(probe.labels.isEmpty, "removing provider clears stale overlay")
        probe.publish(probe.makeGrid(items: renamed, itemVersion: 2, guideVersion: 3, width: 90_000))
        require(!probe.labels.isEmpty, "restoring provider rebuilds visible overlay")

        probe.scroll(x: 100, y: 900 * 64)
        probe.publish(probe.makeGrid(items: Array(renamed.prefix(2)), itemVersion: 4, guideVersion: 3))
        probe.container.layoutSubtreeIfNeeded()
        probe.coordinator.updateVisibleRowData()
        require(probe.container.programTableView.numberOfRows == 2, "large list can shrink while scrolled near its end")
        require(probe.labels.populatedRows.allSatisfy { $0 < 2 }, "shrunk list clears former row metadata")
        probe.publish(probe.makeGrid(items: [], itemVersion: 5, guideVersion: 3))
        require(probe.labels.isEmpty, "empty publication clears previous labels")

        // Nil revisions must preserve correctness for callers without tokens.
        probe.publish(probe.makeGrid(items: items, itemVersion: nil, guideVersion: nil))
        probe.publish(probe.makeGrid(items: renamed, itemVersion: nil, guideVersion: nil))
        require(probe.labelName(0) == "Renamed", "unversioned providers are refreshed")

        // Queue a reveal, reorder before its deferred execution, then inspect
        // the real AppKit origin after the animation ends.
        probe.publish(probe.makeGrid(items: items, itemVersion: 6, guideVersion: 4, reveal: 100))
        var reordered = items
        reordered.swapAt(100, 200)
        probe.publish(probe.makeGrid(items: reordered, itemVersion: 7, guideVersion: 4, reveal: 100))
        pump(0.5)
        let expectedY = CGFloat(200 * 64) - (probe.clip.bounds.height - 64) / 2
        // AppKit may change the clip height as the overlay scrollers appear;
        // keep the requested row within half a row of the viewport centre.
        require(abs(probe.clip.bounds.origin.y - expectedY) < 32, "deferred reveal resolves current ID rather than captured stale index (actual=\(probe.clip.bounds.origin.y), expected=\(expectedY))")
        probe.scroll(x: 100, y: 0)
        probe.publish(probe.makeGrid(items: reordered, itemVersion: 7, guideVersion: 4, reveal: 100))
        pump(0.5)
        require(abs(probe.clip.bounds.origin.y) < 1, "completed reveal does not pin user scroll on later updates")

        probe.publish(probe.makeGrid(items: reordered, itemVersion: 7, guideVersion: 4, reveal: 800))
        probe.publish(probe.makeGrid(items: reordered, itemVersion: 7, guideVersion: 4, reveal: nil))
        pump(0.5)
        require(abs(probe.clip.bounds.origin.y) < 1, "nil reveal cancels queued scroll")

        probe.publish(probe.makeGrid(items: reordered, itemVersion: 7, guideVersion: 4, reveal: 800))
        probe.publish(probe.makeGrid(items: Array(reordered.prefix(2)), itemVersion: 8, guideVersion: 4, reveal: 800))
        pump()
        probe.publish(probe.makeGrid(items: reordered, itemVersion: 9, guideVersion: 4, reveal: 800))
        pump(0.5)
        let restoredY = CGFloat(800 * 64) - (probe.clip.bounds.height - 64) / 2
        require(abs(probe.clip.bounds.origin.y - restoredY) < 32, "target removed before deferred scroll can be revealed after republication")
        probe.container.scrollToRow(999, animated: false)
        let maxY = CGFloat(items.count * 64) - probe.clip.bounds.height
        require(abs(probe.clip.bounds.origin.y - maxY) < 1, "last row reveal clamps to document end")

        timelineChecks()
        timeStripChecks()
        bitsetChecks()
        rowLayoutChecks()
        labelStoreChecks()
        clockTextChecks()
        print("PASS \(checks) production AppKit grid/timeline checks")
    }

    /// The previous production header builder, kept as the reference.
    static func previousSlots(start: Date, hours: Int, pixelsPerMinute: CGFloat, relativeTo now: Date) -> [(x: CGFloat, title: String)] {
        (0..<(max(0, hours) * 2)).map { index in
            let date = start.addingTimeInterval(Double(index) * 30 * 60)
            let title = Calendar.current.isDate(date, inSameDayAs: now)
                ? date.formatted(date: .omitted, time: .shortened)
                : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            return (CGFloat(index) * 30 * pixelsPerMinute, title)
        }
    }

    static func timeStripChecks() {
        let today = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let start = today.addingTimeInterval(12 * 3_600)
        func matchesPrevious(_ spec: EPGTimeStripSpec, hours: Int, ppm: CGFloat, now: Date) -> Bool {
            let previous = previousSlots(start: spec.start, hours: hours, pixelsPerMinute: ppm, relativeTo: now)
            guard previous.count == spec.slotCount else { return false }
            return previous.enumerated().allSatisfy { index, slot in slot.x == spec.slotX(index) && slot.title == spec.title(index) }
        }
        EPGClockText.shared.beginPass()
        let initial = EPGTimeStripSpec(start: start, hours: 336, pixelsPerMinute: 4, relativeTo: today)
        require(initial.slotCount == 672 && initial.slotX(1) == 120, "14-day header produces expected half-hour geometry")
        require(matchesPrevious(initial, hours: 336, ppm: 4, now: today), "every header title and position matches the previous builder")
        require(initial == EPGTimeStripSpec(start: start, hours: 336, pixelsPerMinute: 4, relativeTo: today.addingTimeInterval(20)),
                "live tick within the local day leaves the header unchanged")
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let nextDay = EPGTimeStripSpec(start: start, hours: 336, pixelsPerMinute: 4, relativeTo: tomorrow)
        require(nextDay != initial && matchesPrevious(nextDay, hours: 336, ppm: 4, now: tomorrow), "day rollover changes relative header titles")
        require(nextDay.title(0) == start.formatted(.dateTime.weekday(.abbreviated).hour().minute()), "previous-day header includes weekday")
        let resized = EPGTimeStripSpec(start: start, hours: 2, pixelsPerMinute: 2, relativeTo: today)
        require(resized.slotCount == 4 && resized.slotX(1) == 60, "header duration and scale change geometry")
        let visible = initial.slots(intersecting: 130, 250)
        require(visible.contains(1) && visible.contains(2) && !visible.contains(0) && visible.count <= 4,
                "only slots intersecting the dirty rectangle are titled")
        let shifted = EPGTimeStripSpec(start: start.addingTimeInterval(3_600), hours: 2, pixelsPerMinute: 2, relativeTo: today)
        require(shifted != resized, "timeline anchor change invalidates header titles")
    }

    static func timelineChecks() {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        func channel(_ name: String, days: Int, type: ChannelContentType = .live, id: String = "same") -> Channel {
            Channel(id: id, name: name, logoURL: nil, group: "Group", streamURL: URL(string: "http://127.0.0.1/fixture")!,
                    epgChannelID: "guide", catchup: CatchupInfo(kind: .xc, days: days, source: nil), contentType: type)
        }
        let initial = EPGTimelineInputs(channels: [channel("Original", days: 7)], lookback: .allAvailable)
        require(initial.archiveStart(anchor: anchor) == anchor.addingTimeInterval(-7 * 86_400), "archive metadata determines exact anchored start")
        let rename = EPGTimelineInputs(channels: [channel("Rename", days: 7)], lookback: .allAvailable)
        require(initial == rename, "same-ID name/favorite metadata preserves timeline reset inputs")
        let expanded = EPGTimelineInputs(channels: [channel("Rename", days: 14)], lookback: .allAvailable)
        require(expanded != initial && expanded.archiveHours == 336, "same-ID archive metadata refresh invalidates bounds")
        let limited = EPGTimelineInputs(channels: [channel("Rename", days: 14)], lookback: .threeDays)
        require(limited.archiveHours == 72, "lookback change limits archive hours")
        require(limited.archiveStart(anchor: anchor.addingTimeInterval(37)) == anchor.addingTimeInterval(37 - 72 * 3_600), "archive bounds use exact new anchor")
        require(EPGTimelineInputs(channels: [channel("Huge", days: Int.max)], lookback: .allAvailable).archiveHours == 336, "malformed huge archive days safely cap before arithmetic")
        require(EPGTimelineInputs(channels: [channel("VOD", days: 7, type: .vod)], lookback: .allAvailable).archiveHours == nil, "VOD metadata does not enable catchup timeline")
        require(EPGTimelineInputs(channels: [], lookback: .allAvailable).archiveHours == nil, "empty channel inputs")
        let a = channel("A", days: 0, id: "a"), b = channel("B", days: 0, id: "b"), ab = channel("AB", days: 0, id: "ab")
        let order1 = EPGTimelineInputs(channels: [a, b], lookback: .allAvailable)
        require(order1 == EPGTimelineInputs(channels: [a, b], lookback: .allAvailable), "same ordered IDs compare equal")
        require(order1 != EPGTimelineInputs(channels: [b, a], lookback: .allAvailable), "reordered channel IDs reset the timeline")
        require(order1 != EPGTimelineInputs(channels: [ab], lookback: .allAvailable), "ID boundaries are part of the identity")
        require(order1 != EPGTimelineInputs(channels: [a], lookback: .allAvailable), "membership change resets the timeline")
    }

    static func bitsetChecks() {
        var bits = EPGBitset(bitCount: 130)
        require(bits.isEmpty && bits.bitCapacity == 192, "bitset rounds storage to 64-bit words")
        for index in [0, 63, 64, 129] { bits.insert(index) }
        require(bits.contains(63) && bits.contains(64) && !bits.contains(65) && bits.count == 4, "bitset membership across word boundaries")
        bits.insert(400)
        require(bits.contains(400) && bits.bitCapacity >= 401, "insert grows storage")
        var visited: [Int] = []
        bits.forEach { visited.append($0) }
        require(visited == [0, 63, 64, 129, 400], "set bits visit in ascending order")
        var other = EPGBitset()
        other.insert(64)
        other.insert(7)
        var intersection = bits
        intersection.formIntersection(other)
        require(intersection.count == 1 && intersection.contains(64), "word-wise intersection")
        var union = other
        union.formUnion(bits)
        require(union.count == 6, "word-wise union")
        bits.subtract(other)
        require(!bits.contains(64) && bits.count == 4, "word-wise subtraction")
        let capacity = bits.bitCapacity
        bits.removeAll()
        require(bits.isEmpty && bits.bitCapacity == capacity, "clearing keeps storage")
        require(EPGBitset(bitCount: 10) == EPGBitset(bitCount: 500), "equality ignores trailing zero words")
        bits.remove(10_000)
        require(!bits.contains(-1), "out-of-range queries are false")
    }

    static func rowLayoutChecks() {
        let origin = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func program(_ id: String, _ startMinutes: Double, _ endMinutes: Double) -> EPGProgram {
            EPGProgram(id: id, channelID: "c", title: id, description: "",
                       start: origin.addingTimeInterval(startMinutes * 60), end: origin.addingTimeInterval(endMinutes * 60))
        }
        // Overlap, a sub-2pt sliver, a gap, a programme before and after the window.
        let sorted = [program("before", -60, 30), program("overlap", 20, 60), program("sliver", 60, 60.25),
                      program("next", 90, 120), program("after", 600, 660)]
        var layout = EPGRowLayout()
        layout.build(programs: sorted, timelineStart: origin, pixelsPerMinute: 4, timelineWidth: 720, rowHeight: 64,
                     showGaps: true, reminderIDs: ["next"])
        let sources = (0..<layout.count).map { layout.source[$0] }
        require(sources == [0, 1, -1, 3, -1], "cursor clipping, sliver drop and gaps (\(sources))")
        require(layout.x[0] == 0 && layout.width[0] == 120, "pre-window programme clips at the timeline origin")
        require(layout.x[1] == 120 && layout.width[1] == 120, "overlap begins at the running cursor")
        require(layout.isGap(2) && layout.x[2] == 240 && layout.width[2] == 120, "guide gap between programmes")
        require(layout.flags[3] & EPGCellFlags.reminder != 0 && layout.flags[1] & EPGCellFlags.reminder == 0, "reminder bit")
        require(layout.isGap(4) && layout.x[4] == 480 && layout.maxX(4) == 720, "trailing gap runs to the window end")
        let shuffled = [sorted[3], sorted[4], sorted[1], sorted[0], sorted[2]]
        var unsorted = EPGRowLayout()
        unsorted.build(programs: shuffled, timelineStart: origin, pixelsPerMinute: 4,
                       timelineWidth: 720, rowHeight: 64, showGaps: true, reminderIDs: ["next"])
        require(unsorted.count == layout.count && (0..<layout.count).allSatisfy { cell in
            unsorted.x[cell] == layout.x[cell] && unsorted.width[cell] == layout.width[cell]
                && (unsorted.source[cell] < 0 ? nil : shuffled[Int(unsorted.source[cell])].id)
                    == (layout.source[cell] < 0 ? nil : sorted[Int(layout.source[cell])].id)
        }, "unsorted providers lay out identically")
        require(layout.cell(containingX: 130, y: 10) == 1 && layout.cell(containingX: 130, y: 1) == nil
                && layout.cell(containingX: 800, y: 10) == nil && layout.cell(containingX: 0, y: 10) == 0, "binary-search hit testing")
        require(layout.firstCell(endingAfter: 239) == 1 && layout.firstCell(endingAfter: 240) == 2, "viewport culling start")
        layout.applyState(now: origin.addingTimeInterval(100 * 60), replayStart: origin.addingTimeInterval(-30 * 60))
        require(layout.flags[3] & EPGCellFlags.live != 0, "live state bit")
        require(layout.flags[1] & EPGCellFlags.catchup != 0 && layout.flags[0] & EPGCellFlags.past != 0, "catch-up vs past bits")
        require(layout.flags[2] & EPGCellFlags.stateMask == 0, "gaps carry no state")
        let capacity = layout.x.capacity
        layout.build(programs: Array(sorted.prefix(2)), timelineStart: origin, pixelsPerMinute: 4, timelineWidth: 480, rowHeight: 64, showGaps: false)
        require(layout.count == 2 && layout.x.capacity == capacity, "rebuilding reuses column storage")
        layout.build(programs: [], timelineStart: origin, pixelsPerMinute: 4, timelineWidth: 480, rowHeight: 64, showGaps: true)
        require(layout.isEmpty, "empty rows lay out no gaps")
    }

    static func labelStoreChecks() {
        let store = EPGLabelRowStore()
        func fill(_ row: Int, _ slot: inout EPGLabelRow) { slot.channelName = "row \(row)" }
        require(store.update(range: 0..<34, fill: fill) == 34 && store.capacity == 64, "first window fills every row")
        require(store.update(range: 1..<35, fill: fill) == 1, "one-row scroll refills one slot")
        require(store.row(0) == nil && store.row(34)?.channelName == "row 34", "rows leaving the window are evicted")
        require(store.populatedRows == Array(1..<35), "occupancy bitset tracks the window")
        require(store.update(range: 100..<200, fill: fill) == 100 && store.capacity == 128, "taller windows grow the ring")
        require(store.row(150)?.channelName == "row 150", "lookup after growth")
        store.invalidate()
        require(store.isEmpty && store.range == nil && store.update(range: 100..<200, fill: fill) == 100, "invalidation refills")
    }

    static func clockTextChecks() {
        let clock = EPGClockText.shared
        clock.beginPass()
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<200 {
            let seconds = date.timeIntervalSinceReferenceDate
            let expected = date.formatted(date: .omitted, time: .shortened).replacingOccurrences(of: " ", with: "").lowercased()
            require(clock.compactTime(seconds) == expected, "interned compact time \(date)")
            require(clock.weekdayTime(seconds) == date.formatted(.dateTime.weekday(.abbreviated).hour().minute()),
                    "interned weekday time \(date)")
            require(clock.shortTime(seconds) == date.formatted(date: .omitted, time: .shortened), "interned short time \(date)")
            date = date.addingTimeInterval(37 * 60 + 13)
        }
        require(clock.compactRange(start: 0, end: 3_600) == clock.compactTime(0) + " - " + clock.compactTime(3_600), "range text")
    }

    private static func benchmark(_ items: [GridItem]) {
        let probe = GridProbe(items: items)
        probe.expensive = true
        // Invalidate once to warm up the same production row builder fixture.
        probe.publish(probe.makeGrid(items: items, itemVersion: 2))
        var samples: [Double] = []
        var providerCounts: [Int] = []
        for _ in 0..<7 {
            let calls = probe.calls
            let started = ContinuousClock.now
            for tick in 0..<100 { probe.scroll(x: CGFloat(tick * 20), y: 0) }
            let duration = started.duration(to: .now).components
            samples.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
            providerCounts.append(probe.calls - calls)
        }
        let report: [String: Any] = ["fixture": "epg-appkit-horizontal-100x-672-blocks-v1", "samples_ms": samples,
                                     "provider_calls": providerCounts, "rows": items.count,
                                     "visible_rows": probe.container.programTableView.rows(in: probe.container.programTableView.visibleRect).length,
                                     "overlay_entries": probe.labels.populatedRows.count]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
