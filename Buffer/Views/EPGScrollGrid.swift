import AppKit
import SwiftUI

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
/// `NSHostingView`. Rows are recycled as they move off-screen, so memory
/// stays bounded regardless of channel count.
struct EPGScrollGrid<Item: Identifiable, ChannelContent: View, ProgramContent: View, HeaderContent: View, CornerContent: View>: NSViewRepresentable {
    let items: [Item]
    let rowHeight: CGFloat
    let channelColumnWidth: CGFloat
    let programRowWidth: CGFloat
    let headerHeight: CGFloat
    let nowLineX: CGFloat?
    var channelNameProvider: ((Item) -> String)? = nil
    var rowDataProvider: ((Item) -> ChannelLabelRowData)? = nil
    var revealItemID: AnyHashable?
    let channelContent: (Item) -> ChannelContent
    let programContent: (Item) -> ProgramContent
    let headerContent: () -> HeaderContent
    let cornerContent: () -> CornerContent

    func makeNSView(context: Context) -> EPGContainerView {
        let container = EPGContainerView()
        container.configure(coordinator: context.coordinator, dimensions: dimensions)
        container.setHeaderContent(headerContent())
        container.setCornerContent(cornerContent())
        container.setNowLineX(nowLineX)
        context.coordinator.container = container
        return container
    }

    func updateNSView(_ container: EPGContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        container.applyDimensions(dimensions)
        container.setHeaderContent(headerContent())
        container.setCornerContent(cornerContent())
        container.setNowLineX(nowLineX)

        if let channelNameProvider {
            container.setChannelNames(items.map { channelNameProvider($0) })
        }
        if let rowDataProvider {
            container.setRowData(items.map { rowDataProvider($0) })
        }

        let newIDs = items.map { AnyHashable($0.id) }
        if newIDs != coordinator.itemIDs {
            coordinator.items = items
            coordinator.itemIDs = newIDs
            container.channelTableView.reloadData()
            container.programTableView.reloadData()
        } else {
            coordinator.items = items
            coordinator.refreshVisibleRows()
        }

        if let targetID = revealItemID,
           let idx = items.firstIndex(where: { AnyHashable($0.id) == targetID }) {
            // Defer scroll so the table has laid out after a potential reload
            DispatchQueue.main.async {
                container.scrollToRow(idx)
            }
        }
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

        init(parent: EPGScrollGrid) {
            self.parent = parent
            self.items = parent.items
            self.itemIDs = parent.items.map { AnyHashable($0.id) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            parent.rowHeight
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = items[row]
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
                cell.setContent(parent.programContent(item))
                return cell
            }
        }

        func refreshVisibleRows() {
            guard let container else { return }
            refresh(tableView: container.channelTableView, isChannel: true)
            refresh(tableView: container.programTableView, isChannel: false)
        }

        private func refresh(tableView: NSTableView, isChannel: Bool) {
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location..<(visible.location + visible.length) {
                guard row >= 0, row < items.count else { continue }
                if isChannel {
                    if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? HostingRow<ChannelContent> {
                        cell.setContent(parent.channelContent(items[row]))
                    }
                } else {
                    if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? HostingRow<ProgramContent> {
                        cell.setContent(parent.programContent(items[row]))
                    }
                }
            }
        }
    }
}

// MARK: - Container NSView

final class EPGContainerView: NSView {
    struct Dimensions: Equatable {
        var rowHeight: CGFloat
        var channelColumnWidth: CGFloat
        var programRowWidth: CGFloat
        var headerHeight: CGFloat
    }

    let channelTableView = NSTableView()
    let programTableView = NSTableView()

    private let channelScrollView = NSScrollView()
    private let programScrollView = NSScrollView()
    private let headerScrollView = NSScrollView()
    private let headerHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let cornerHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let nowLineView = NSView()
    private let channelLabelOverlay = ChannelLabelOverlayView()

    private var dimensions = Dimensions(rowHeight: 0, channelColumnWidth: 0, programRowWidth: 0, headerHeight: 0)
    private var nowLineX: CGFloat?
    private var channelNames: [String] = []
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
        needsLayout = true
    }

    func setHeaderContent<Content: View>(_ content: Content) {
        headerHost.rootView = AnyView(content)
    }

    func setCornerContent<Content: View>(_ content: Content) {
        cornerHost.rootView = AnyView(content)
    }

    func setChannelNames(_ names: [String]) {
        channelNames = names
        // Row data will be built when programs are available via setRowData
        channelLabelOverlay.needsDisplay = true
    }

    func setRowData(_ data: [ChannelLabelRowData]) {
        channelLabelOverlay.rowData = data
        channelLabelOverlay.needsDisplay = true
    }

    func setNowLineX(_ x: CGFloat?) {
        guard nowLineX != x else { return }
        nowLineX = x
        updateNowLineFrame()
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

    private func setupSubviews() {
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
        headerScrollView.documentView = headerHost
        headerScrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(headerScrollView)

        // Corner (fixed position, top-left)
        addSubview(cornerHost)

        // Now-time indicator line (sibling overlay; pixel-aligned so it stays straight)
        nowLineView.wantsLayer = true
        nowLineView.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.7).cgColor
        nowLineView.isHidden = true
        addSubview(nowLineView)

        channelLabelOverlay.wantsLayer = false
        addSubview(channelLabelOverlay)

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

        cornerHost.frame = NSRect(x: 0, y: 0, width: ccw, height: hh)
        headerScrollView.frame = NSRect(x: ccw, y: 0, width: bodyWidth, height: hh)
        channelScrollView.frame = NSRect(x: 0, y: hh, width: ccw, height: bodyHeight)
        programScrollView.frame = NSRect(x: ccw, y: hh, width: bodyWidth, height: bodyHeight)

        headerHost.frame = NSRect(x: 0, y: 0, width: dimensions.programRowWidth, height: hh)

        channelLabelOverlay.frame = NSRect(x: ccw, y: hh, width: bodyWidth, height: bodyHeight)
        channelLabelOverlay.rowHeight = dimensions.rowHeight

        updateNowLineFrame()
    }

    private func updateNowLineFrame() {
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

    // MARK: Scroll to row

    func scrollToRow(_ row: Int, animated: Bool = true) {
        guard row >= 0, row < channelTableView.numberOfRows else { return }
        let targetY = CGFloat(row) * dimensions.rowHeight
        let clipHeight = programScrollView.contentView.bounds.height
        // Centre the row vertically when possible
        let centeredY = max(0, targetY - (clipHeight - dimensions.rowHeight) / 2)
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
    }

    // MARK: Scroll sync

    @objc private func programBoundsDidChange(_ note: Notification) {
        guard !isSyncing, let clip = note.object as? NSClipView else { return }
        isSyncing = true
        defer { isSyncing = false }

        let origin = clip.bounds.origin
        mirror(y: origin.y, to: channelScrollView)
        mirror(x: origin.x, to: headerScrollView)
        updateNowLineFrame()
        updateChannelLabelOverlay()
    }

    @objc private func channelBoundsDidChange(_ note: Notification) {
        guard !isSyncing, let clip = note.object as? NSClipView else { return }
        isSyncing = true
        defer { isSyncing = false }

        mirror(y: clip.bounds.origin.y, to: programScrollView)
        updateChannelLabelOverlay()
    }

    @objc private func headerBoundsDidChange(_ note: Notification) {
        guard !isSyncing, let clip = note.object as? NSClipView else { return }
        isSyncing = true
        defer { isSyncing = false }

        mirror(x: clip.bounds.origin.x, to: programScrollView)
        updateNowLineFrame()
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

// MARK: - Channel label overlay

struct ChannelLabelRowData {
    let channelName: String
    /// Block rects + time strings in document coordinates (x relative to row start)
    let blocks: [(rect: CGRect, timeRange: String?)]
}

final class ChannelLabelOverlayView: NSView {
    var rowData: [ChannelLabelRowData] = []
    var rowHeight: CGFloat = 64
    var scrollOffsetX: CGFloat = 0
    var scrollOffsetY: CGFloat = 0

    override var isFlipped: Bool { true }
    override func hitTest(_ aPoint: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !rowData.isEmpty else { return }

        // Clip to our own bounds so text doesn't bleed into the header
        NSBezierPath(rect: bounds).addClip()

        let nameAttrs: [NSAttributedString.Key: Any] = {
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byTruncatingTail
            return [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: p,
            ]
        }()
        let timeAttrs = nameAttrs

        let insetX: CGFloat = 9
        let insetY: CGFloat = 9

        let firstVisibleRow = max(0, Int(scrollOffsetY / rowHeight))
        let visibleRowCount = Int(ceil(bounds.height / rowHeight)) + 1

        for i in firstVisibleRow..<min(firstVisibleRow + visibleRowCount, rowData.count) {
            let data = rowData[i]
            guard !data.blocks.isEmpty else { continue }

            let rowY = CGFloat(i) * rowHeight - scrollOffsetY
            let hasName = !data.channelName.isEmpty
            let nameSize = hasName ? (data.channelName as NSString).size(withAttributes: nameAttrs) : .zero
            let nameWidth = min(nameSize.width + 1, bounds.width * 0.35)

            // The sticky X position for the channel name (screen coords)
            let stickyX = insetX

            for block in data.blocks {
                let blockScreenMinX = block.rect.minX - scrollOffsetX
                let blockScreenMaxX = block.rect.maxX - scrollOffsetX

                guard blockScreenMaxX > 0, blockScreenMinX < bounds.width else { continue }

                let blockTextMinX = max(0, blockScreenMinX) + 9
                guard blockTextMinX < blockScreenMaxX - 10 else { continue }

                // Clip to this block, inset to hide text in the gap
                let clipInset: CGFloat = 2
                let blockClipMinX = max(0, blockScreenMinX + clipInset)
                let blockClipMaxX = blockScreenMaxX - clipInset
                guard blockClipMaxX > blockClipMinX + 10 else { continue }

                let blockClipRect = NSRect(
                    x: blockClipMinX,
                    y: rowY,
                    width: blockClipMaxX - blockClipMinX,
                    height: rowHeight
                )

                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: blockClipRect).addClip()

                // Does the sticky channel name overlap this block?
                let stickyDocX = scrollOffsetX + stickyX
                let stickyDocEndX = stickyDocX + nameWidth
                let blockOverlapsSticky = hasName
                    && block.rect.maxX > stickyDocX
                    && block.rect.minX < stickyDocEndX

                var timeStartX = blockTextMinX

                if blockOverlapsSticky {
                    // Draw channel name at sticky position
                    let nameRect = NSRect(x: stickyX, y: rowY + insetY, width: nameWidth, height: nameSize.height)
                    (data.channelName as NSString).draw(
                        with: nameRect,
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                        attributes: nameAttrs
                    )
                    let nameEndX = stickyX + nameWidth + 8
                    if nameEndX > timeStartX {
                        timeStartX = nameEndX
                    }
                }

                // Draw time
                if let timeRange = block.timeRange {
                    let timeAvail = blockClipMaxX - timeStartX - 9
                    if timeAvail > 20 {
                        let ts = (timeRange as NSString).size(withAttributes: timeAttrs)
                        let timeRect = NSRect(x: timeStartX, y: rowY + insetY, width: min(ts.width, timeAvail), height: ts.height)
                        (timeRange as NSString).draw(
                            with: timeRect,
                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                            attributes: timeAttrs
                        )
                    }
                }

                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}

// MARK: - Hosting row

final class HostingRow<Content: View>: NSTableCellView {
    private var hostingView: NSHostingView<Content>?

    func setContent(_ content: Content) {
        if let hostingView {
            hostingView.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor),
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            hostingView = host
        }
    }
}
