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
            timeStripSlots: [], timeStripSlotWidth: 120,
            rowDataProvider: hasProvider ? { [weak self] item in
                guard let self else { return ChannelLabelRowData(channelName: item.name, blocks: []) }
                self.calls += 1
                self.observedNames.append(item.name)
                let blocks: [ChannelLabelBlockData] = self.expensive
                    ? (0..<672).map { index in
                        ChannelLabelBlockData(rect: CGRect(x: index * 120, y: 3, width: 120, height: 58), timeRange: "Slot \(index)")
                    } : []
                return ChannelLabelRowData(channelName: item.name, blocks: blocks)
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
        require(probe.overlay.rowDataByIndex[0]?.channelName == "Channel 0", "first publication installs current overlay names")
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
        require(early.overlay.rowDataByIndex.values.contains(where: { $0.channelName == "Channel 100" }), "layout after first publication populates labels and resumes early reveal")

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
        require(probe.overlay.rowDataByIndex[0]?.channelName == "Renamed", "same-ID rename refreshes overlay")
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
        require(probe.overlay.rowDataByIndex.isEmpty, "removing provider clears stale overlay")
        probe.publish(probe.makeGrid(items: renamed, itemVersion: 2, guideVersion: 3, width: 90_000))
        require(!probe.overlay.rowDataByIndex.isEmpty, "restoring provider rebuilds visible overlay")

        probe.scroll(x: 100, y: 900 * 64)
        probe.publish(probe.makeGrid(items: Array(renamed.prefix(2)), itemVersion: 4, guideVersion: 3))
        probe.container.layoutSubtreeIfNeeded()
        probe.coordinator.updateVisibleRowData()
        require(probe.container.programTableView.numberOfRows == 2, "large list can shrink while scrolled near its end")
        require(probe.overlay.rowDataByIndex.keys.allSatisfy { $0 < 2 }, "shrunk list clears former row metadata")
        probe.publish(probe.makeGrid(items: [], itemVersion: 5, guideVersion: 3))
        require(probe.overlay.rowDataByIndex.isEmpty, "empty publication clears previous labels")

        // Nil revisions must preserve correctness for callers without tokens.
        probe.publish(probe.makeGrid(items: items, itemVersion: nil, guideVersion: nil))
        probe.publish(probe.makeGrid(items: renamed, itemVersion: nil, guideVersion: nil))
        require(probe.overlay.rowDataByIndex[0]?.channelName == "Renamed", "unversioned providers are refreshed")

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
        print("PASS \(checks) production AppKit grid/timeline checks")
    }

    static func timeStripChecks() {
        let cache = EPGTimeStripCache()
        let today = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let start = today.addingTimeInterval(12 * 3_600)
        let initial = cache.slots(start: start, hours: 336, pixelsPerMinute: 4, relativeTo: today)
        require(initial.count == 672 && initial[1].x == 120, "14-day header produces expected half-hour geometry")
        require(initial == cache.slots(start: start, hours: 336, pixelsPerMinute: 4, relativeTo: today.addingTimeInterval(20)), "live tick preserves cached titles within local day")
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let nextDay = cache.slots(start: start, hours: 336, pixelsPerMinute: 4, relativeTo: tomorrow)
        require(nextDay != initial, "day rollover invalidates relative header titles")
        require(nextDay[0].title == start.formatted(.dateTime.weekday(.abbreviated).hour().minute()), "previous-day header includes weekday")
        let resized = cache.slots(start: start, hours: 2, pixelsPerMinute: 2, relativeTo: today)
        require(resized.count == 4 && resized[1].x == 60, "header duration and scale invalidate geometry")
        let shifted = cache.slots(start: start.addingTimeInterval(3_600), hours: 2, pixelsPerMinute: 2, relativeTo: today)
        require(shifted != resized, "timeline anchor change invalidates header titles")
    }

    static func timelineChecks() {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        func channel(_ name: String, days: Int, type: ChannelContentType = .live) -> Channel {
            Channel(id: "same", name: name, logoURL: nil, group: "Group", streamURL: URL(string: "http://127.0.0.1/fixture")!,
                    epgChannelID: "guide", catchup: CatchupInfo(kind: .xc, days: days, source: nil), contentType: type)
        }
        let original = channel("Original", days: 7)
        let cache = EPGTimelineInputCache()
        let initial = cache.inputs(channels: [original], version: 1, lookback: .allAvailable)
        require(initial.archiveStart(anchor: anchor) == anchor.addingTimeInterval(-7 * 86_400), "archive metadata determines exact anchored start")
        let rename = cache.inputs(channels: [channel("Rename", days: 7)], version: 2, lookback: .allAvailable)
        require(initial == rename, "same-ID name/favorite metadata preserves timeline reset inputs")
        let expanded = cache.inputs(channels: [channel("Rename", days: 14)], version: 3, lookback: .allAvailable)
        require(expanded != initial && expanded.archiveHours == 336, "same-ID archive metadata refresh invalidates bounds")
        let limited = cache.inputs(channels: [channel("Rename", days: 14)], version: 3, lookback: .threeDays)
        require(limited.archiveHours == 72, "lookback change invalidates cache without channel revision")
        require(limited.archiveStart(anchor: anchor.addingTimeInterval(37)) == anchor.addingTimeInterval(37 - 72 * 3_600), "archive bounds use exact new anchor")
        require(EPGTimelineInputs(channels: [channel("Huge", days: Int.max)], lookback: .allAvailable).archiveHours == 336, "malformed huge archive days safely cap before arithmetic")
        require(EPGTimelineInputs(channels: [channel("VOD", days: 7, type: .vod)], lookback: .allAvailable).archiveHours == nil, "VOD metadata does not enable catchup timeline")
        require(EPGTimelineInputs(channels: [], lookback: .allAvailable).archiveHours == nil, "empty channel inputs")
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
                                     "overlay_entries": probe.overlay.rowDataByIndex.count]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if CommandLine.arguments.contains("--headers") { benchmarkHeaders() }
    }

    private static func benchmarkHeaders() {
        let today = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let start = today.addingTimeInterval(-14 * 86_400)
        let cache = EPGTimeStripCache()
        _ = cache.slots(start: start, hours: 347, pixelsPerMinute: 4, relativeTo: today)

        // This is the previous production header-building body, reproduced
        // verbatim in structure for a controlled formatter/cache comparison.
        func previousSlots(relativeTo now: Date) -> [TimeStripSlot] {
            let slots = (0..<(347 * 2)).map { index in
                start.addingTimeInterval(Double(index) * 30 * 60)
            }
            return slots.map { date in
                let title = Calendar.current.isDate(date, inSameDayAs: now)
                    ? date.formatted(date: .omitted, time: .shortened)
                    : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
                return TimeStripSlot(x: CGFloat(date.timeIntervalSince(start) / 60) * 4, title: title)
            }
        }
        require(previousSlots(relativeTo: today) == cache.slots(start: start, hours: 347, pixelsPerMinute: 4, relativeTo: today), "header benchmark validates all positions and formatted titles")
        func measure(_ operation: (Date) -> [TimeStripSlot]) -> [Double] {
            var measured: [Double] = []
            for _ in 0..<7 {
                let started = ContinuousClock.now
                var count = 0
                for tick in 0..<100 {
                    count += operation(today.addingTimeInterval(Double(tick * 20))).count
                }
                let duration = started.duration(to: .now).components
                require(count == 69_400, "header benchmark output count")
                measured.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
            }
            return measured
        }
        let report: [String: Any] = ["fixture": "epg-header-100-ticks-694-labels-v1",
                                     "previous_samples_ms": measure(previousSlots),
                                     "cached_samples_ms": measure { cache.slots(start: start, hours: 347, pixelsPerMinute: 4, relativeTo: $0) },
                                     "titles": 694, "ticks": 100]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
