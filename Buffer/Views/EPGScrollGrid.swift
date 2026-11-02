import AppKit
import OSLog
import SwiftUI

struct HorizontalScrollRequest: Equatable {
    let id: Int
    let targetX: CGFloat
}

enum EPGStickyLabelMetrics {
    static let x: CGFloat = 10
    static let topRowY: CGFloat = 8
    static let topRowHeight: CGFloat = 14
    static let titleRowY: CGFloat = 29
    static let titleRowHeight: CGFloat = 18
    static let metadataMaxWidth: CGFloat = 320
    static let titleMaxWidth: CGFloat = 360
    static let titleTrailingReserve: CGFloat = 24
    static let viewportTrailingPadding: CGFloat = 10
    /// Clear separation between the pinned channel name and program time.
    static let metadataCollisionGap: CGFloat = 10

    static func labelWidth(for viewportWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
        max(0, min(viewportWidth - x - viewportTrailingPadding, maxWidth))
    }

    static func labelWidth(for viewportWidth: CGFloat) -> CGFloat {
        labelWidth(for: viewportWidth, maxWidth: metadataMaxWidth)
    }
}

struct TimeStripSlot: Equatable {
    let x: CGFloat
    let title: String
}

/// Virtualized EPG grid built from three synchronized AppKit scroll views:
/// a channel column (fixed width, scrolls vertically), a time header (fixed
/// height, scrolls horizontally), and a program grid (scrolls both axes).
///
/// Scroll sync follows Apple's canonical NSScrollView pattern: each clip view
/// posts `boundsDidChangeNotification`; the container observes the program
/// view's bounds and mirrors X into the header and Y into the channel column
/// (and vice versa so trackpad scrolling over any pane drives the whole grid).
/// Origin comparison prevents feedback loops.
///
/// Each row is an `NSTableView` cell hosting SwiftUI content via
/// `NSHostingView`. Programme hosts also track only the horizontal viewport:
/// a multi-day archive must never allocate an 80k-point backing surface.
struct EPGScrollGrid<Item: Identifiable, ChannelContent: View, ProgramContent: View, CornerContent: View>: NSViewRepresentable {
    let items: [Item]
    let rowHeight: CGFloat
    let channelColumnWidth: CGFloat
    let programRowWidth: CGFloat
    let headerHeight: CGFloat
    let nowLineX: CGFloat?
    let initialHorizontalOffset: CGFloat?
    let horizontalScrollRequest: HorizontalScrollRequest?
    let timelineIdentity: AnyHashable?
    var itemSetVersion: AnyHashable? = nil
    let dataVersion: AnyHashable?
    var referenceDate: Date? = nil
    let timeStripSlots: [TimeStripSlot]
    let timeStripSlotWidth: CGFloat
    var rowDataProvider: ((Item) -> ChannelLabelRowData)? = nil
    var visibleItemsDidChange: (([Item]) -> Void)? = nil
    var revealItemID: AnyHashable?
    let channelContent: (Item) -> ChannelContent
    let programContent: (Item) -> ProgramContent
    let cornerContent: () -> CornerContent

    func makeNSView(context: Context) -> EPGContainerView {
        let container = makeContainer(coordinator: context.coordinator)
        EPGGridStyle.applyAppearance(to: container, scheme: context.environment.colorScheme,
                                    contrast: context.environment.colorSchemeContrast)
        return container
    }

    func makeContainer(coordinator: Coordinator) -> EPGContainerView {
        let container = EPGContainerView()
        container.configure(coordinator: coordinator, dimensions: dimensions)
        container.setTimeStrip(slots: timeStripSlots, slotWidth: timeStripSlotWidth)
        container.setCornerContent(cornerContent())
        container.setNowLineX(nowLineX)
        coordinator.container = container
        // Wire scroll-driven visible rowData updates (enables computing rowData only during/after vertical scrolls)
        let coordinatorRef = coordinator
        container.updateVisibleRowData = { [weak coordinatorRef] in
            coordinatorRef?.updateVisibleRowData()
            if let coordinatorRef {
                coordinatorRef.requestReveal(coordinatorRef.parent.revealItemID)
            }
        }
        container.refreshVisibleRows = { [weak coordinatorRef] in
            coordinatorRef?.refreshVisibleRows()
        }
        container.reloadVisibleProgramRows = { [weak coordinatorRef] in
            coordinatorRef?.reloadVisibleProgramRows()
        }
        return container
    }

    func updateNSView(_ container: EPGContainerView, context: Context) {
        EPGGridStyle.applyAppearance(to: container, scheme: context.environment.colorScheme,
                                    contrast: context.environment.colorSchemeContrast)
        updateContainer(container, coordinator: context.coordinator)
    }

    func updateContainer(_ container: EPGContainerView, coordinator: Coordinator) {
        // Geometry and scroll setters can synchronously invoke the callbacks.
        // Publish all inputs first so a new provider never receives old items.
        let itemIDsChanged = coordinator.install(self)
        if itemIDsChanged {
            container.channelTableView.reloadData()
            container.programTableView.reloadData()
            container.needsLayout = true
        }
        container.setTimelineIdentity(timelineIdentity)
        container.applyDimensions(dimensions)
        container.setTimeStrip(slots: timeStripSlots, slotWidth: timeStripSlotWidth)
        container.setCornerContent(cornerContent())
        container.setNowLineX(nowLineX)
        container.setInitialHorizontalOffset(initialHorizontalOffset)
        container.setHorizontalScrollRequest(horizontalScrollRequest)

        // A guide and channel-metadata update can arrive together. Refresh
        // both hosted columns, including favorite state and renamed channels.
        coordinator.refreshVisibleRows()
        container.setReferenceDate(referenceDate)
        coordinator.requestReveal(revealItemID)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private var dimensions: EPGContainerView.Dimensions {
        .init(
            rowHeight: rowHeight,
            channelColumnWidth: channelColumnWidth,
            programRowWidth: programRowWidth,
            headerHeight: headerHeight
        )
    }

    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: EPGScrollGrid
        weak var container: EPGContainerView?
        var items: [Item]
        var itemIDs: [AnyHashable]
        var itemSetVersion: AnyHashable?
        /// Captured so AppKit scroll handlers can compute rowData for only the visible window without full scan.
        var rowDataProvider: ((Item) -> ChannelLabelRowData)?
        private var rowDataInputs: RowDataInputs?
        private var rowDataByIndex: [Int: ChannelLabelRowData] = [:]
        private var rowDataRange: Range<Int>?
        private var hasPublishedItems = false
        private var revealTargetID: AnyHashable?
        private var revealGeneration = 0
        private var completedRevealID: AnyHashable?
        private var pendingRevealGeneration: Int?
        private var visibleItemsInputs: VisibleItemsInputs?
        private var visibleItemsGeneration = 0

        private struct VisibleItemsInputs: Equatable {
            let range: Range<Int>
            let itemSetVersion: AnyHashable?
            let itemIDs: [AnyHashable]
        }

        private struct RowDataInputs: Equatable {
            let itemSetVersion: AnyHashable?
            let dataVersion: AnyHashable?
            let timelineIdentity: AnyHashable?
            let dimensions: EPGContainerView.Dimensions
        }

        init(parent: EPGScrollGrid) {
            self.parent = parent
            self.items = parent.items
            self.itemIDs = []
            self.itemSetVersion = nil
            self.rowDataProvider = parent.rowDataProvider
        }

        /// Returns whether AppKit's row identities/count need republishing.
        fileprivate func install(_ next: EPGScrollGrid) -> Bool {
            let nextInputs = RowDataInputs(
                itemSetVersion: next.itemSetVersion,
                dataVersion: next.dataVersion,
                timelineIdentity: next.timelineIdentity,
                dimensions: next.dimensions
            )
            // Optional versions are a compatibility path for callers whose
            // providers can change without a source-driven revision token.
            if next.itemSetVersion == nil || next.dataVersion == nil || rowDataInputs != nextInputs {
                rowDataByIndex.removeAll(keepingCapacity: true)
                rowDataRange = nil
            }
            rowDataInputs = nextInputs

            let sameItemSet = hasPublishedItems && next.itemSetVersion != nil && next.itemSetVersion == itemSetVersion
            let nextIDs = sameItemSet ? itemIDs : next.items.map { AnyHashable($0.id) }
            let identitiesChanged = !hasPublishedItems || nextIDs != itemIDs
            parent = next
            items = next.items
            itemIDs = nextIDs
            itemSetVersion = next.itemSetVersion
            rowDataProvider = next.rowDataProvider
            hasPublishedItems = true
            return identitiesChanged
        }

        fileprivate func requestReveal(_ targetID: AnyHashable?) {
            if targetID != revealTargetID {
                revealTargetID = targetID
                completedRevealID = nil
                revealGeneration &+= 1
                pendingRevealGeneration = nil
            }
            guard let targetID, completedRevealID != targetID,
                  pendingRevealGeneration != revealGeneration,
                  items.contains(where: { AnyHashable($0.id) == targetID }) else { return }
            let generation = revealGeneration
            pendingRevealGeneration = generation
            // Resolve the ID after layout, because an intervening refresh may
            // reorder rows. A newer/nil request cancels this deferred callback.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revealGeneration == generation else { return }
                defer { self.pendingRevealGeneration = nil }
                guard self.revealTargetID == targetID, self.completedRevealID != targetID,
                      let index = self.items.firstIndex(where: { AnyHashable($0.id) == targetID }),
                      let container = self.container else { return }
                container.layoutSubtreeIfNeeded()
                guard container.scrollToRow(index) else { return }
                self.completedRevealID = targetID
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            parent.rowHeight
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard items.indices.contains(row) else { return nil }
            let item = items[row]
            let cellStarted = ContinuousClock.now
            defer { PerfMetrics.shared.record("epg.cell.makeMs", since: cellStarted) }
            if tableView === container?.channelTableView {
                let identifier = NSUserInterfaceItemIdentifier("channelCell")
                let cell: HostingRow<ChannelContent>
                if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? HostingRow<ChannelContent> {
                    cell = reused
                } else {
                    cell = HostingRow<ChannelContent>()
                    cell.identifier = identifier
                }
                cell.setContent(parent.channelContent(item))
                return cell
            } else {
                let identifier = NSUserInterfaceItemIdentifier("programCell")
                let cell: HostingRow<ProgramContent>
                if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? HostingRow<ProgramContent> {
                    cell = reused
                } else {
                    cell = HostingRow<ProgramContent>()
                    cell.identifier = identifier
                }
                cell.usesHorizontalViewport = true
                cell.expectedRowID = AnyHashable(item.id)
                cell.setContent(parent.programContent(item))
                return cell
            }
        }

        func refreshVisibleRows() {
            guard let container else { return }
            refresh(tableView: container.channelTableView, isChannel: true)
            refresh(tableView: container.programTableView, isChannel: false)
            // Keep rowData (for the channel label overlay) in sync for the current visible vertical window.
            updateVisibleRowData()
        }

        func reloadVisibleProgramRows() {
            guard let container else { return }
            let tableView = container.programTableView
            refresh(tableView: tableView, isChannel: false)
            tableView.needsLayout = true
            tableView.layoutSubtreeIfNeeded()
            updateVisibleRowData()
        }

        /// Computes and pushes rowData ONLY for visible rows + a small overscroll window.
        /// This is the core of the Agent 02 / Master Issues visible-range rowData optimization.
        /// Called on state updates (via updateNSView) and vertical scroll (via container callback).
        func updateVisibleRowData() {
            guard let container else { return }
            publishVisibleItemsIfNeeded(in: container.programTableView)
            guard let provider = rowDataProvider else {
                rowDataByIndex.removeAll(keepingCapacity: true)
                rowDataRange = nil
                container.setRowDataForVisible([:])
                return
            }

            let tableView = container.programTableView
            let vis = tableView.rows(in: tableView.visibleRect)
            guard vis.length > 0, vis.location != NSNotFound else {
                rowDataByIndex.removeAll(keepingCapacity: true)
                rowDataRange = nil
                container.setRowDataForVisible([:])
                return
            }

            // Small overscroll window: enough for smooth scrolling / trackpad inertia without popping in labels.
            // For 64px rows, 12 rows ~= 1 screen height on typical windows; keeps memory + CPU minimal even for 1000+ channels.
            let overscroll = 12
            let first = min(items.count, max(0, vis.location - overscroll))
            let last = min(items.count, vis.location + Int(vis.length) + overscroll)
            let range = first..<max(first, last)
            guard rowDataRange != range else { return }

            // Horizontal movement does not change document-space metadata.
            // Vertical movement builds only newly exposed rows and discards
            // those outside this bounded window.
            let buildStarted = ContinuousClock.now
            rowDataByIndex = rowDataByIndex.filter { range.contains($0.key) }
            rowDataByIndex.reserveCapacity(range.count)
            var built = 0
            for r in range where rowDataByIndex[r] == nil {
                rowDataByIndex[r] = provider(items[r])
                built += 1
            }
            rowDataRange = range
            PerfMetrics.shared.record("epg.visibleRowData.buildMs", since: buildStarted)
            PerfMetrics.shared.increment("epg.visibleRowData.rowsBuilt", by: built)
            container.setRowDataForVisible(rowDataByIndex)
        }

        private func publishVisibleItemsIfNeeded(in tableView: NSTableView) {
            guard hasPublishedItems else { return }
            guard parent.visibleItemsDidChange != nil else {
                visibleItemsInputs = nil
                visibleItemsGeneration &+= 1
                return
            }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.location != NSNotFound, visible.length > 0 else { return }
            let first = min(items.count, max(0, visible.location))
            let last = min(items.count, visible.location + visible.length)
            guard first < last else { return }
            let range = first..<last
            if let previous = visibleItemsInputs,
               itemSetVersion != nil, previous.range == range,
               previous.itemSetVersion == itemSetVersion { return }
            let inputs = VisibleItemsInputs(range: range, itemSetVersion: itemSetVersion,
                                           itemIDs: Array(itemIDs[range]))
            guard inputs != visibleItemsInputs else { return }
            visibleItemsInputs = inputs
            visibleItemsGeneration &+= 1
            let generation = visibleItemsGeneration
            // SwiftUI owns the loading state. Never call back into it from an
            // AppKit layout/update pass, and drop superseded deferred ranges.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visibleItemsGeneration == generation,
                      self.items.count >= range.upperBound else { return }
                self.parent.visibleItemsDidChange?(Array(self.items[range]))
            }
        }

        private func refresh(tableView: NSTableView, isChannel: Bool) {
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            let refreshStarted = ContinuousClock.now
            defer { PerfMetrics.shared.record(isChannel ? "epg.refresh.channelRowsMs" : "epg.refresh.programRowsMs", since: refreshStarted) }
            for row in visible.location..<(visible.location + visible.length) {
                guard row >= 0, row < items.count else { continue }
                if isChannel {
                    if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? HostingRow<ChannelContent> {
                        cell.setContent(parent.channelContent(items[row]))
                    }
                } else {
                    if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? HostingRow<ProgramContent> {
                        cell.expectedRowID = AnyHashable(items[row].id)
                        cell.setContent(parent.programContent(items[row]))
                    }
                }
            }
        }
    }
}

// MARK: - Container NSView

/// The guide is three scroll views kept in step on the main thread, plus a
/// label overlay positioned from the same scroll offset. Responsive scrolling
/// would move one table's content off the main thread ahead of the others,
/// so rows, logos and pinned labels drift apart for a frame (visible flicker).
final class EPGTableView: NSTableView {
    override class var isCompatibleWithResponsiveScrolling: Bool { false }
}

final class EPGContainerView: NSView {
    struct Dimensions: Equatable {
        var rowHeight: CGFloat
        var channelColumnWidth: CGFloat
        var programRowWidth: CGFloat
        var headerHeight: CGFloat
    }

    let channelTableView = EPGTableView()
    let programTableView = EPGTableView()
    private let channelScrollView = NSScrollView()
    private let programScrollView = NSScrollView()
    private let headerScrollView = NSScrollView()
    private let timeStripView = TimeStripView()
    private let cornerHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let nowLineView = NSView()
    private let channelLabelOverlay = ChannelLabelOverlayView()

    private var dimensions = Dimensions(rowHeight: 0, channelColumnWidth: 0, programRowWidth: 0, headerHeight: 0)
    private var nowLineX: CGFloat?
    private var referenceDate: Date?
    private var initialHorizontalOffset: CGFloat?
    private var didApplyInitialHorizontalOffset = false
    private var timelineIdentity: AnyHashable?
    private var lastHorizontalScrollRequestID: Int?
    private var lastProgramScrollAt: ContinuousClock.Instant?
    private var pendingHorizontalScrollRequest: HorizontalScrollRequest?
    /// Called by vertical scroll handlers so Coordinator can lazily compute rowData only for the new visible window.
    var updateVisibleRowData: (() -> Void)?
    /// Rebinds currently visible hosted table rows after document-width or horizontal-position changes.
    var refreshVisibleRows: (() -> Void)?
    /// Recreates visible hosted program rows when the horizontal document width changes.
    var reloadVisibleProgramRows: (() -> Void)?
    private var isSyncing = false

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupSubviews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshDrawingColors()
    }

    private func refreshDrawingColors() {
        nowLineView.layer?.backgroundColor = EPGGridStyle.palette(for: effectiveAppearance).liveIndicator.cgColor
        timeStripView.needsDisplay = true
        channelLabelOverlay.needsDisplay = true
    }

    func setReferenceDate(_ date: Date?) {
        guard let date, date != referenceDate else { return }
        referenceDate = date
        func update(_ view: NSView) {
            if let drawing = view as? EPGTimeSensitiveDrawing {
                drawing.setReferenceDate(date)
            } else {
                for child in view.subviews { update(child) }
            }
        }
        // NSTableView only creates/recycles the small visible window. This
        // refresh changes drawing colors, never row identities or cached data.
        update(programTableView)
    }

    // MARK: Setup

    func configure(coordinator: NSObject, dimensions: Dimensions) {
        self.dimensions = dimensions

        configureTable(channelTableView, columnWidth: dimensions.channelColumnWidth)
        configureTable(programTableView, columnWidth: dimensions.programRowWidth)
        channelTableView.rowHeight = dimensions.rowHeight
        programTableView.rowHeight = dimensions.rowHeight

        if let delegate = coordinator as? NSTableViewDelegate {
            channelTableView.delegate = delegate
            programTableView.delegate = delegate
        }
        if let source = coordinator as? NSTableViewDataSource {
            channelTableView.dataSource = source
            programTableView.dataSource = source
        }

        needsLayout = true
    }

    func applyDimensions(_ new: Dimensions) {
        guard new != dimensions else { return }
        let oldProgramWidth = dimensions.programRowWidth
        dimensions = new

        if let col = channelTableView.tableColumns.first, col.width != new.channelColumnWidth {
            col.minWidth = new.channelColumnWidth
            col.maxWidth = new.channelColumnWidth
            col.width = new.channelColumnWidth
        }
        if let col = programTableView.tableColumns.first, col.width != new.programRowWidth {
            col.minWidth = new.programRowWidth
            col.maxWidth = new.programRowWidth
            col.width = new.programRowWidth
        }
        channelTableView.rowHeight = new.rowHeight
        programTableView.rowHeight = new.rowHeight
        syncDocumentFrames()
        if oldProgramWidth != new.programRowWidth {
            reloadVisibleProgramRows?()
        }
        needsLayout = true
    }

    func setTimeStrip(slots: [TimeStripSlot], slotWidth: CGFloat) {
        timeStripView.setSlots(slots, slotWidth: slotWidth)
    }

    func setCornerContent<Content: View>(_ content: Content) {
        cornerHost.rootView = AnyView(content)
    }

    func setRowData(_ data: [ChannelLabelRowData]) {
        // Legacy full-array path (populates 0... for compatibility; prefer sparse for perf)
        var dict: [Int: ChannelLabelRowData] = [:]
        for (idx, d) in data.enumerated() { dict[idx] = d }
        channelLabelOverlay.rowDataByIndex = dict
        channelLabelOverlay.needsDisplay = true
    }

    /// Sets rowData only for the visible vertical range + overscroll (the key optimization).
    /// This avoids O(N channels) work in rowDataProvider + buildRowData on every update/scroll tick.
    func setRowDataForVisible(_ data: [Int: ChannelLabelRowData]) {
        channelLabelOverlay.rowDataByIndex = data
        channelLabelOverlay.needsDisplay = true
    }

    func setNowLineX(_ x: CGFloat?) {
        guard nowLineX != x else { return }
        nowLineX = x
        channelLabelOverlay.nowLineX = x
        channelLabelOverlay.needsDisplay = true
        updateNowLineFrame()
    }

    func setTimelineIdentity(_ identity: AnyHashable?) {
        guard timelineIdentity != identity else { return }
        timelineIdentity = identity
        didApplyInitialHorizontalOffset = false
        initialHorizontalOffset = nil
        lastHorizontalScrollRequestID = nil
        pendingHorizontalScrollRequest = nil
    }

    func setInitialHorizontalOffset(_ x: CGFloat?) {
        guard !didApplyInitialHorizontalOffset, let x else { return }
        let rounded = x.rounded(.toNearestOrEven)
        if initialHorizontalOffset != rounded {
            initialHorizontalOffset = rounded
        }
        applyInitialHorizontalOffsetIfNeeded()
    }

    func setHorizontalScrollRequest(_ request: HorizontalScrollRequest?) {
        guard let request else { return }
        guard lastHorizontalScrollRequestID != request.id else { return }
        pendingHorizontalScrollRequest = request
        applyHorizontalScrollRequestIfNeeded()
    }

    private func configureTable(_ tableView: NSTableView, columnWidth: CGFloat) {
        if tableView.tableColumns.isEmpty {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
            column.width = columnWidth
            column.minWidth = columnWidth
            column.maxWidth = columnWidth
            column.resizingMask = []
            tableView.addTableColumn(column)
        }
        tableView.headerView = nil
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = []
        tableView.focusRingType = .none
        tableView.allowsColumnResizing = false
        tableView.allowsColumnReordering = false
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
    }

#if DEBUG
    static let diagnosticAutoscrollNotification = Notification.Name("BufferDiagnosticEPGAutoscroll")
    private var diagnosticScrollTimer: Timer?

    /// Scrolls the programme grid by itself (no synthetic input events) so
    /// scroll rendering can be profiled without taking over the pointer.
    @objc private func runDiagnosticAutoscroll(_ note: Notification) {
        guard window != nil else { return }
        let seconds = note.userInfo?["seconds"] as? Double ?? 6
        let clip = programScrollView.contentView
        let started = Date()
        var direction: CGFloat = 1
        var flipAt = started.addingTimeInterval(seconds / 4)
        diagnosticScrollTimer?.invalidate()
        diagnosticScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(started) < seconds else {
                    timer.invalidate()
                    AppLog.performance.info("diagnostic autoscroll finished")
                    return
                }
                if Date() >= flipAt { direction = -direction; flipAt = Date().addingTimeInterval(seconds / 4) }
                let maxY = max(0, (self.programScrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
                var origin = clip.bounds.origin
                origin.y = min(maxY, max(0, origin.y + direction * 35))
                clip.scroll(to: origin)
                self.programScrollView.reflectScrolledClipView(clip)
            }
        }
        AppLog.performance.info("diagnostic autoscroll started seconds=\(seconds, privacy: .public)")
    }
#endif

    private func setupSubviews() {
#if DEBUG
        NotificationCenter.default.addObserver(self, selector: #selector(runDiagnosticAutoscroll(_:)),
                                               name: Self.diagnosticAutoscrollNotification, object: nil)
#endif
        // Program grid (scrolls both axes)
        programScrollView.hasVerticalScroller = true
        programScrollView.hasHorizontalScroller = true
        programScrollView.autohidesScrollers = true
        programScrollView.scrollerStyle = .overlay
        programScrollView.drawsBackground = false
        programScrollView.horizontalScrollElasticity = .allowed
        programScrollView.verticalScrollElasticity = .allowed
        programScrollView.documentView = programTableView
        programScrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(programScrollView)

        // Channel column (vertical only)
        channelScrollView.hasVerticalScroller = false
        channelScrollView.hasHorizontalScroller = false
        channelScrollView.drawsBackground = false
        channelScrollView.horizontalScrollElasticity = .none
        channelScrollView.verticalScrollElasticity = .allowed
        channelScrollView.documentView = channelTableView
        channelScrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(channelScrollView)

        // Time header (horizontal only)
        headerScrollView.hasVerticalScroller = false
        headerScrollView.hasHorizontalScroller = false
        headerScrollView.drawsBackground = false
        headerScrollView.horizontalScrollElasticity = .allowed
        headerScrollView.verticalScrollElasticity = .none
        headerScrollView.documentView = timeStripView
        headerScrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(headerScrollView)

        // Corner (fixed position, top-left)
        addSubview(cornerHost)

        channelLabelOverlay.wantsLayer = false
        addSubview(channelLabelOverlay)

        // Now-time indicator line (sibling overlay; pixel-aligned so it stays straight).
        // Keep it above the sticky text overlay so it remains visible while horizontally scrolling.
        nowLineView.wantsLayer = true
        refreshDrawingColors()
        nowLineView.isHidden = true
        addSubview(nowLineView, positioned: .above, relativeTo: nil)

        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(programBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: programScrollView.contentView
        )
        nc.addObserver(
            self,
            selector: #selector(channelBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: channelScrollView.contentView
        )
        nc.addObserver(
            self,
            selector: #selector(headerBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: headerScrollView.contentView
        )
    }

    // MARK: Layout

    override func layout() {
        super.layout()

        let w = bounds.width
        let h = bounds.height
        let ccw = dimensions.channelColumnWidth
        let hh = dimensions.headerHeight
        let bodyWidth = max(0, w - ccw)
        let bodyHeight = max(0, h - hh)

        // Virtualized EPG grid with two main NSTableViews (channels and programs) that vertical scroll together.
        // The standard AppKit table handles frame syncing, row recycling, and heights automatically.
        // Drawing manual table frames on top of the layout system broke vertical scrolling in AppKit table.
        cornerHost.frame = NSRect(x: 0, y: 0, width: ccw, height: hh)
        headerScrollView.frame = NSRect(x: ccw, y: 0, width: bodyWidth, height: hh)
        channelScrollView.frame = NSRect(x: 0, y: hh, width: ccw, height: bodyHeight)
        programScrollView.frame = NSRect(x: ccw, y: hh, width: bodyWidth, height: bodyHeight)

        syncDocumentFrames()
        channelLabelOverlay.frame = NSRect(x: ccw, y: hh, width: bodyWidth, height: bodyHeight)
        channelLabelOverlay.rowHeight = dimensions.rowHeight

        applyInitialHorizontalOffsetIfNeeded()
        applyHorizontalScrollRequestIfNeeded()
        updateNowLineFrame()
        updateChannelLabelOverlay()
        updateProgramDrawingViewports()
        updateVisibleRowData?()
    }

    private func syncDocumentFrames() {
        let rowCount = max(channelTableView.numberOfRows, programTableView.numberOfRows)
        let documentHeight = max(
            CGFloat(rowCount) * dimensions.rowHeight,
            programScrollView.contentView.bounds.height,
            channelScrollView.contentView.bounds.height
        )
        channelTableView.setFrameSize(NSSize(width: dimensions.channelColumnWidth, height: documentHeight))
        programTableView.setFrameSize(NSSize(width: dimensions.programRowWidth, height: documentHeight))
        timeStripView.frame = NSRect(
            x: 0,
            y: 0,
            width: dimensions.programRowWidth,
            height: dimensions.headerHeight
        )
    }

    private func updateNowLineFrame() {
        guard bounds.width > dimensions.channelColumnWidth, dimensions.programRowWidth > 0 else {
            nowLineView.isHidden = true
            return
        }

        guard let x = nowLineX, x > 0, x < dimensions.programRowWidth else {
            nowLineView.isHidden = true
            return
        }
        let scrollOffset = programScrollView.contentView.bounds.origin.x
        let programMinX = dimensions.channelColumnWidth
        let programMinY = dimensions.headerHeight
        let programMaxX = bounds.width
        let screenX = programMinX + x - scrollOffset

        // Hide when outside the visible program area; otherwise pixel-snap to a stable column.
        if screenX < programMinX - 1 || screenX > programMaxX + 1 {
            nowLineView.isHidden = true
            return
        }

        let scale = window?.backingScaleFactor ?? 2
        let snapped = (screenX * scale).rounded() / scale
        let lineWidth: CGFloat = 1.5
        nowLineView.frame = NSRect(
            x: snapped - lineWidth / 2,
            y: programMinY,
            width: lineWidth,
            height: max(0, bounds.height - programMinY)
        )
        nowLineView.isHidden = false
    }

    private func applyInitialHorizontalOffsetIfNeeded() {
        guard !didApplyInitialHorizontalOffset,
              let initialHorizontalOffset,
              dimensions.programRowWidth > 0,
              programScrollView.contentView.bounds.width > 0 else { return }

        syncDocumentFrames()
        programTableView.layoutSubtreeIfNeeded()
        timeStripView.layoutSubtreeIfNeeded()

        let maxX = max(0, dimensions.programRowWidth - programScrollView.contentView.bounds.width)
        let targetX = min(max(initialHorizontalOffset, 0), maxX)
        guard maxX > 0 || targetX == 0 else { return }
        let currentY = programScrollView.contentView.bounds.origin.y
        let target = NSPoint(x: targetX, y: currentY)

        programScrollView.contentView.scroll(to: target)
        programScrollView.reflectScrolledClipView(programScrollView.contentView)
        let appliedX = programScrollView.contentView.bounds.origin.x
        guard abs(appliedX - targetX) < 1 else { return }
        mirror(x: appliedX, to: headerScrollView)
        channelLabelOverlay.scrollOffsetX = appliedX
        updateNowLineFrame()
        updateChannelLabelOverlay()
        reloadVisibleProgramRows?()
        didApplyInitialHorizontalOffset = true
    }

    private func applyHorizontalScrollRequestIfNeeded() {
        guard let request = pendingHorizontalScrollRequest,
              lastHorizontalScrollRequestID != request.id,
              dimensions.programRowWidth > 0,
              programScrollView.contentView.bounds.width > 0 else { return }

        syncDocumentFrames()
        programTableView.layoutSubtreeIfNeeded()
        timeStripView.layoutSubtreeIfNeeded()

        let clip = programScrollView.contentView
        let maxX = max(0, dimensions.programRowWidth - clip.bounds.width)
        let targetX = min(max(request.targetX, 0), maxX)
        guard maxX > 0 || targetX == 0 else { return }
        let target = NSPoint(x: targetX, y: clip.bounds.origin.y)

        clip.scroll(to: target)
        programScrollView.reflectScrolledClipView(clip)
        let appliedX = clip.bounds.origin.x
        guard abs(appliedX - targetX) < 1 else { return }
        mirror(x: appliedX, to: headerScrollView)
        updateNowLineFrame()
        updateChannelLabelOverlay()
        reloadVisibleProgramRows?()

        lastHorizontalScrollRequestID = request.id
        pendingHorizontalScrollRequest = nil
    }

    // MARK: Scroll to row

    @discardableResult
    func scrollToRow(_ row: Int, animated: Bool = true) -> Bool {
        guard row >= 0, row < channelTableView.numberOfRows,
              programScrollView.contentView.bounds.height > 0 else { return false }
        let targetY = CGFloat(row) * dimensions.rowHeight
        let clipHeight = programScrollView.contentView.bounds.height
        // Centre the row vertically when possible
        let maxY = max(0, CGFloat(channelTableView.numberOfRows) * dimensions.rowHeight - clipHeight)
        let centeredY = min(maxY, max(0, targetY - (clipHeight - dimensions.rowHeight) / 2))
        let point = NSPoint(x: programScrollView.contentView.bounds.origin.x, y: centeredY)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                programScrollView.contentView.animator().setBoundsOrigin(point)
                channelScrollView.contentView.animator().setBoundsOrigin(
                    NSPoint(x: 0, y: centeredY)
                )
            }
            programScrollView.reflectScrolledClipView(programScrollView.contentView)
            channelScrollView.reflectScrolledClipView(channelScrollView.contentView)
        } else {
            programScrollView.contentView.scroll(to: point)
            programScrollView.reflectScrolledClipView(programScrollView.contentView)
            channelScrollView.contentView.scroll(to: NSPoint(x: 0, y: centeredY))
            channelScrollView.reflectScrolledClipView(channelScrollView.contentView)
        }
        updateVisibleRowData?()
        return true
    }

    // MARK: Scroll sync

    @objc private func programBoundsDidChange(_ note: Notification) {
        guard !isSyncing, let clip = note.object as? NSClipView else { return }
        isSyncing = true
        defer { isSyncing = false }

        let scrollStarted = ContinuousClock.now
        if let lastProgramScrollAt {
            // Gaps above one display frame while scrolling point to main-thread stalls.
            let interval = PerfMetrics.milliseconds(since: lastProgramScrollAt, now: scrollStarted)
            if interval < 250 { PerfMetrics.shared.record("epg.scroll.callbackIntervalMs", interval) }
        }
        lastProgramScrollAt = scrollStarted
        defer { PerfMetrics.shared.record("epg.scroll.handlerMs", since: scrollStarted) }
        let origin = clip.bounds.origin
        mirror(y: origin.y, to: channelScrollView)
        mirror(x: origin.x, to: headerScrollView)
        updateNowLineFrame()
        updateChannelLabelOverlay()
        updateProgramDrawingViewports()
        updateVisibleRowData?()   // visible rowData may have shifted; compute only for new window (not full list)
    }

    @objc private func channelBoundsDidChange(_ note: Notification) {
        guard !isSyncing, let clip = note.object as? NSClipView else { return }
        isSyncing = true
        defer { isSyncing = false }

        mirror(y: clip.bounds.origin.y, to: programScrollView)
        updateChannelLabelOverlay()
        updateProgramDrawingViewports()
        updateVisibleRowData?()   // vertical scroll in channel column also updates visible program rows
    }

    @objc private func headerBoundsDidChange(_ note: Notification) {
        guard !isSyncing, let clip = note.object as? NSClipView else { return }
        isSyncing = true
        defer { isSyncing = false }

        mirror(x: clip.bounds.origin.x, to: programScrollView)
        updateNowLineFrame()
        updateChannelLabelOverlay()
        updateProgramDrawingViewports()
    }

    private func updateProgramDrawingViewports() {
        let visible = programTableView.rows(in: programTableView.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            (programTableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? EPGViewportHosting)?.updateDrawingViewport()
        }
    }

    private func updateChannelLabelOverlay() {
        let clip = programScrollView.contentView.bounds
        channelLabelOverlay.scrollOffsetX = clip.origin.x
        channelLabelOverlay.scrollOffsetY = clip.origin.y
        channelLabelOverlay.needsDisplay = true
    }

    private func mirror(x: CGFloat, to scrollView: NSScrollView) {
        let clip = scrollView.contentView
        guard clip.bounds.origin.x != x else { return }
        let target = NSPoint(x: x, y: clip.bounds.origin.y)
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
    }

    private func mirror(y: CGFloat, to scrollView: NSScrollView) {
        let clip = scrollView.contentView
        guard clip.bounds.origin.y != y else { return }
        let target = NSPoint(x: clip.bounds.origin.x, y: y)
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
    }

}

// MARK: - Time strip

final class TimeStripView: NSView {
    private var slots: [TimeStripSlot] = []
    private var slotWidth: CGFloat = 120

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func setSlots(_ slots: [TimeStripSlot], slotWidth: CGFloat) {
        guard self.slots != slots || self.slotWidth != slotWidth else { return }
        self.slots = slots
        self.slotWidth = slotWidth
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let drawStarted = ContinuousClock.now
        defer { PerfMetrics.shared.record("epg.timeStrip.drawMs", since: drawStarted) }
        let palette = EPGGridStyle.palette(for: effectiveAppearance)
        palette.header.setFill()
        dirtyRect.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: palette.metadataText
        ]

        for slot in slots {
            let rect = NSRect(x: slot.x, y: 0, width: slotWidth, height: bounds.height)
            guard rect.intersects(dirtyRect) else { continue }
            let textRect = NSRect(x: rect.minX + 6, y: 8, width: max(0, rect.width - 6), height: 16)
            (slot.title as NSString).draw(in: textRect, withAttributes: attributes)
        }

        palette.border.setStroke()
        let divider = NSBezierPath()
        divider.lineWidth = 1 / (window?.backingScaleFactor ?? 2)
        let y = bounds.maxY - divider.lineWidth / 2
        divider.move(to: NSPoint(x: dirtyRect.minX, y: y))
        divider.line(to: NSPoint(x: dirtyRect.maxX, y: y))
        divider.stroke()
    }
}

// MARK: - Channel label overlay

struct ChannelLabelBlockData {
    let rect: CGRect
    /// Nil time denotes an intentional guide gap; the sticky metadata clips out there.
    let timeRange: String?
}

struct ChannelLabelRowData {
    let channelName: String
    /// Program block metadata in document coordinates (x relative to row start).
    let blocks: [ChannelLabelBlockData]
}

final class ChannelLabelOverlayView: NSView {
    /// Sparse storage: only visible rows + small overscroll window have entries.
    /// Keys are absolute row indices in the items array.
    var rowDataByIndex: [Int: ChannelLabelRowData] = [:]
    var rowHeight: CGFloat = 64
    var scrollOffsetX: CGFloat = 0
    var scrollOffsetY: CGFloat = 0
    var nowLineX: CGFloat?

    override var isFlipped: Bool { true }
    override func hitTest(_ aPoint: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard rowHeight > 0, !rowDataByIndex.isEmpty else { return }
        let drawStarted = ContinuousClock.now
        defer { PerfMetrics.shared.record("epg.labelOverlay.drawMs", since: drawStarted) }
        let palette = EPGGridStyle.palette(for: effectiveAppearance)

        NSBezierPath(rect: bounds).addClip()

        let metadataParagraph = Self.truncatingParagraph(lineHeight: EPGStickyLabelMetrics.topRowHeight)
        let metadataMaxWidth = EPGStickyLabelMetrics.labelWidth(
            for: bounds.width,
            maxWidth: EPGStickyLabelMetrics.metadataMaxWidth
        )
        guard metadataMaxWidth > 24 else { return }

        let firstVisibleRow = max(0, Int(floor(scrollOffsetY / rowHeight)))
        let visibleRowCount = Int(ceil(bounds.height / rowHeight)) + 2
        let lastVisibleRow = firstVisibleRow + visibleRowCount

        for row in firstVisibleRow...lastVisibleRow {
            guard let data = rowDataByIndex[row] else { continue }
            let rowY = CGFloat(row) * rowHeight - scrollOffsetY
            guard rowY < bounds.maxY, rowY + rowHeight > bounds.minY else { continue }

            let channelName = data.channelName.trimmingCharacters(in: .whitespacesAndNewlines)
            let channelText = channelName.isEmpty
                ? nil
                : channelNameString(channelName, paragraph: metadataParagraph, color: palette.primaryText)
            let channelWidth = channelText.map { min(measuredWidth(of: $0), metadataMaxWidth) } ?? 0
            let timeLeadingX = EPGStickyLabelMetrics.x
                + channelWidth
                + (channelWidth > 0 ? EPGStickyLabelMetrics.metadataCollisionGap : 0)

            // Times are constrained to begin after the pinned channel name.
            // As an outgoing block narrows, its time truncates and disappears;
            // it never slides left underneath the channel label.
            for block in data.blocks {
                guard let timeRange = block.timeRange, !timeRange.isEmpty else { continue }

                let blockScreenMinX = block.rect.minX - scrollOffsetX
                let blockScreenMaxX = block.rect.maxX - scrollOffsetX
                guard blockScreenMaxX > 0, blockScreenMinX < bounds.width else { continue }

                // Match the canvas title's ten-point interior inset, including
                // the one-point card gutter. New cards should never put their
                // timestamp against a border while the title is indented.
                let textX = max(blockScreenMinX + 1 + EPGStickyLabelMetrics.x, timeLeadingX)
                let textRight = min(bounds.width - EPGStickyLabelMetrics.viewportTrailingPadding,
                                    blockScreenMaxX - 1 - EPGStickyLabelMetrics.x)
                let availableWidth = textRight - textX
                guard availableWidth > 4 else { continue }

                let timeText = timeRangeString(timeRange, paragraph: metadataParagraph, color: palette.metadataText)
                let labelWidth = min(measuredWidth(of: timeText), metadataMaxWidth, availableWidth)
                guard labelWidth > 4 else { continue }

                let blockClipRect = NSRect(
                    x: blockScreenMinX,
                    y: rowY,
                    width: blockScreenMaxX - blockScreenMinX,
                    height: rowHeight
                )

                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: blockClipRect).addClip()
                timeText.draw(
                    with: NSRect(
                        x: textX,
                        y: rowY + EPGStickyLabelMetrics.topRowY,
                        width: labelWidth,
                        height: EPGStickyLabelMetrics.topRowHeight
                    ),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
                NSGraphicsContext.restoreGraphicsState()
            }

            if let channelText {
                drawPinnedChannelName(
                    channelText,
                    rowY: rowY,
                    height: EPGStickyLabelMetrics.topRowHeight,
                    maxWidth: metadataMaxWidth
                )
            }
        }
    }

    private static let channelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let timeRangeFont = NSFont.systemFont(ofSize: 10, weight: .regular)

    private static func truncatingParagraph(lineHeight: CGFloat) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return paragraph
    }

    private func channelNameString(_ channelName: String, paragraph: NSParagraphStyle, color: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: channelName,
            attributes: [
                .font: Self.channelFont,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func timeRangeString(_ timeRange: String, paragraph: NSParagraphStyle, color: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: timeRange,
            attributes: [
                .font: Self.timeRangeFont,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    @discardableResult
    private func drawPinnedChannelName(
        _ text: NSAttributedString,
        rowY: CGFloat,
        height: CGFloat,
        maxWidth: CGFloat
    ) -> CGFloat? {
        let labelX = EPGStickyLabelMetrics.x
        let availableWidth = min(maxWidth, bounds.width - labelX - EPGStickyLabelMetrics.viewportTrailingPadding)
        guard availableWidth > 8 else { return nil }

        let textWidth = min(measuredWidth(of: text), availableWidth)
        guard textWidth > 4 else { return nil }

        let textY = rowY + EPGStickyLabelMetrics.topRowY
        text.draw(
            with: NSRect(
                x: labelX,
                y: textY,
                width: textWidth,
                height: height
            ),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )

        return labelX + textWidth
    }

    private func measuredWidth(of text: NSAttributedString) -> CGFloat {
        ceil(text.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).width) + 1
    }
}

// MARK: - Hosting row

/// A reusable table row that knows which item it currently represents, so
/// diagnostics can detect a frame drawn with another row's content.
protocol EPGRowIdentityProviding: AnyObject {
    var expectedRowID: AnyHashable? { get }
}

private protocol EPGViewportHosting: AnyObject {
    func updateDrawingViewport()
}

final class HostingRow<Content: View>: NSTableCellView, EPGViewportHosting, EPGRowIdentityProviding {
    private var hostingView: NSHostingView<Content>?
    var usesHorizontalViewport = false
    var expectedRowID: AnyHashable?

    override func layout() {
        super.layout()
        updateDrawingViewport()
    }

    func updateDrawingViewport() {
        guard let hostingView else { return }
        var hostFrame = bounds
        if usesHorizontalViewport, let clip = enclosingScrollView?.contentView {
            let viewport = convert(clip.bounds, from: clip)
            let left = max(bounds.minX, viewport.minX)
            let right = min(bounds.maxX, viewport.maxX)
            hostFrame.origin.x = left
            hostFrame.size.width = max(0, right - left)
        }
        if hostingView.frame != hostFrame {
            hostingView.frame = hostFrame
            hostingView.layoutSubtreeIfNeeded()
        }
        guard usesHorizontalViewport else { return }
        func update(_ view: NSView) {
            if let canvas = view as? EPGViewportDrawing {
                // Convert the actual representable origin rather than assuming
                // SwiftUI has placed it at the host's leading edge.
                let origin = view.convert(.zero, to: self).x
                canvas.setTimelineOriginX(origin)
            } else {
                for child in view.subviews { update(child) }
            }
        }
        update(hostingView)
    }

    func setContent(_ content: Content) {
        if let hostingView {
            hostingView.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            host.translatesAutoresizingMaskIntoConstraints = true
            addSubview(host)
            hostingView = host
        }
        needsLayout = true
        updateDrawingViewport()
    }
}
