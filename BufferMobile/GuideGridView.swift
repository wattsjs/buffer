import SwiftUI
import UIKit

/// Virtualised EPG grid for iOS / iPadOS. Mirrors the Mac's table-backed grid:
/// only rows intersecting the viewport exist, each row owns one reused
/// `EPGRowLayout` (flat SoA columns) and draws just the cells in the visible
/// timeline span, so horizontal scrolling redraws a dozen rows and allocates
/// nothing per cell.
struct GuideGrid: UIViewRepresentable {
    let channels: [Channel]
    let channelSetVersion: Int
    let guideVersion: Int
    let compact: Bool
    let programs: (Channel, Date, Date) -> [EPGProgram]
    let onSelectChannel: (Channel) -> Void
    let onSelectProgram: (Channel, EPGProgram) -> Void
    var onVisibleChannels: ([Channel]) -> Void = { _ in }
    /// Programme IDs with a reminder for the displayed source (bell marker).
    var reminderIDs: Set<String> = []
    /// Long-press menu for a channel, or for one of its programmes.
    var menu: (Channel, EPGProgram?) -> [UIMenuElement] = { _, _ in [] }

    func makeUIView(context: Context) -> GuideGridScrollView {
        let view = GuideGridScrollView()
        view.accessibilityIdentifier = "guide-grid"
        update(view)
        return view
    }

    func updateUIView(_ view: GuideGridScrollView, context: Context) { update(view) }

    private func update(_ view: GuideGridScrollView) {
        view.callbacks = .init(programs: programs, selectChannel: onSelectChannel,
                               selectProgram: onSelectProgram, visibleChannels: onVisibleChannels, menu: menu)
        view.configure(channels: channels, channelSetVersion: channelSetVersion, guideVersion: guideVersion,
                       reminderIDs: reminderIDs, metrics: compact ? .compact : .regular)
    }
}

final class GuideGridScrollView: UIScrollView, UIScrollViewDelegate, UIContextMenuInteractionDelegate {
    struct Metrics: Equatable {
        var rowHeight: CGFloat
        var channelColumnWidth: CGFloat
        var headerHeight: CGFloat
        var pixelsPerMinute: Double

        static let regular = Metrics(rowHeight: 64, channelColumnWidth: 180, headerHeight: 32, pixelsPerMinute: 5)
        static let compact = Metrics(rowHeight: 58, channelColumnWidth: 96, headerHeight: 30, pixelsPerMinute: 3.6)
    }

    struct Callbacks {
        var programs: (Channel, Date, Date) -> [EPGProgram] = { _, _, _ in [] }
        var selectChannel: (Channel) -> Void = { _ in }
        var selectProgram: (Channel, EPGProgram) -> Void = { _, _ in }
        var visibleChannels: ([Channel]) -> Void = { _ in }
        var menu: (Channel, EPGProgram?) -> [UIMenuElement] = { _, _ in [] }
    }

    var callbacks = Callbacks()
    private var channels: [Channel] = []
    private var channelSetVersion = -1
    private var guideVersion = -1
    private var reminderIDs: Set<String> = []
    private var accessibilityCache: [UIAccessibilityElement] = []
    private var menuHighlight: (view: UIView, rect: CGRect)?
    private var metrics = Metrics.regular
    private var window_ = GuideTimelineWindow(pixelsPerMinute: Metrics.regular.pixelsPerMinute)
    private var now = Date()

    private var rows: [Int: GuideRowView] = [:]
    private var channelCells: [Int: GuideChannelCell] = [:]
    private var rowPool: [GuideRowView] = []
    private var cellPool: [GuideChannelCell] = []
    private let header = GuideTimeHeader()
    private let corner = UIView()
    private let nowLine = UIView()
    private var didScrollToNow = false
    private var lastVisibleRange: Range<Int> = 0..<0
    private var clock: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .systemBackground
        alwaysBounceVertical = true
        isDirectionalLockEnabled = true
        contentInsetAdjustmentBehavior = .never
        nowLine.backgroundColor = .systemRed
        corner.backgroundColor = .secondarySystemBackground
        addSubview(nowLine)
        addSubview(header)
        addSubview(corner)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        addInteraction(UIContextMenuInteraction(delegate: self))
        // Cells are drawn, not views: VoiceOver reads the elements built in
        // `layoutSubviews` instead of the scroll view itself.
        isAccessibilityElement = false
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { clock?.invalidate() }

    func configure(channels: [Channel], channelSetVersion: Int, guideVersion: Int, reminderIDs: Set<String>,
                   metrics: Metrics) {
        let channelsChanged = channelSetVersion != self.channelSetVersion || channels.count != self.channels.count
        let metricsChanged = metrics != self.metrics
        guard channelsChanged || metricsChanged || guideVersion != self.guideVersion
                || reminderIDs != self.reminderIDs else { return }
        self.reminderIDs = reminderIDs
        self.channels = channels
        self.channelSetVersion = channelSetVersion
        self.guideVersion = guideVersion
        self.metrics = metrics
        if metricsChanged || channelsChanged { window_ = GuideTimelineWindow(now: now, pixelsPerMinute: metrics.pixelsPerMinute) }
        for row in rows.values { row.isStale = true }
        if channelsChanged { recycleAll() }
        contentSize = CGSize(width: metrics.channelColumnWidth + window_.width,
                             height: metrics.headerHeight + CGFloat(channels.count) * metrics.rowHeight)
        setNeedsLayout()
    }

    private func tick() {
        now = Date()
        for row in rows.values { row.applyState(now: now); row.setNeedsDisplay() }
        header.setNeedsDisplay()
        setNeedsLayout()
    }

    private func recycleAll() {
        for (_, row) in rows { row.removeFromSuperview(); rowPool.append(row) }
        for (_, cell) in channelCells { cell.removeFromSuperview(); cellPool.append(cell) }
        rows.removeAll()
        channelCells.removeAll()
        lastVisibleRange = 0..<0
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        if !didScrollToNow, !channels.isEmpty {
            didScrollToNow = true
            let target = max(0, window_.x(for: now.addingTimeInterval(-30 * 60)))
            contentOffset.x = min(CGFloat(target), max(0, contentSize.width - bounds.width))
        }
        let offset = contentOffset
        let m = metrics
        let timelineWidth = max(0, bounds.width - m.channelColumnWidth)
        let firstRow = max(0, Int((offset.y - m.headerHeight) / m.rowHeight))
        let lastRow = min(channels.count, Int((offset.y + bounds.height - m.headerHeight) / m.rowHeight) + 1)
        let visible = firstRow..<max(firstRow, lastRow)

        for (index, row) in rows where !visible.contains(index) {
            row.removeFromSuperview(); rowPool.append(row); rows[index] = nil
        }
        for (index, cell) in channelCells where !visible.contains(index) {
            cell.removeFromSuperview(); cellPool.append(cell); channelCells[index] = nil
        }
        for index in visible {
            let y = m.headerHeight + CGFloat(index) * m.rowHeight
            let channel = channels[index]
            let row = rows[index] ?? {
                let row = rowPool.popLast() ?? GuideRowView()
                rows[index] = row
                insertSubview(row, belowSubview: nowLine)
                row.isStale = true
                return row
            }()
            if row.isStale || row.channelID != channel.id {
                row.load(channel: channel, programs: callbacks.programs(channel, window_.start, window_.end),
                         window: window_, rowHeight: m.rowHeight, now: now, reminderIDs: reminderIDs)
            }
            row.frame = CGRect(x: offset.x + m.channelColumnWidth, y: y, width: timelineWidth, height: m.rowHeight)
            row.setTimelineOffset(offset.x)

            let cell = channelCells[index] ?? {
                let cell = cellPool.popLast() ?? GuideChannelCell()
                channelCells[index] = cell
                insertSubview(cell, belowSubview: header)
                return cell
            }()
            cell.show(channel, compact: m.channelColumnWidth < 120)
            cell.frame = CGRect(x: offset.x, y: y, width: m.channelColumnWidth, height: m.rowHeight)
        }

        header.frame = CGRect(x: offset.x + m.channelColumnWidth, y: offset.y, width: timelineWidth, height: m.headerHeight)
        header.configure(spec: window_.timeStrip(now: now), offset: offset.x)
        corner.frame = CGRect(x: offset.x, y: offset.y, width: m.channelColumnWidth, height: m.headerHeight)
        let nowX = m.channelColumnWidth + CGFloat(window_.x(for: now))
        nowLine.frame = CGRect(x: nowX - 1, y: offset.y, width: 2, height: bounds.height)
        nowLine.isHidden = nowX < offset.x + m.channelColumnWidth
        bringSubviewToFront(header)
        bringSubviewToFront(corner)

        if visible != lastVisibleRange {
            lastVisibleRange = visible
            callbacks.visibleChannels(Array(channels[visible]))
        }
        rebuildAccessibilityElements(visible: visible, timelineWidth: timelineWidth)
    }

    // MARK: - Hit testing, menus and accessibility

    /// The channel (and programme, if any) under a point in content space.
    private func target(at point: CGPoint) -> (channel: Channel, program: EPGProgram?)? {
        let m = metrics
        let rowIndex = Int((point.y - m.headerHeight) / m.rowHeight)
        guard point.y >= contentOffset.y + m.headerHeight, channels.indices.contains(rowIndex) else { return nil }
        let channel = channels[rowIndex]
        guard point.x - contentOffset.x >= m.channelColumnWidth, let row = rows[rowIndex] else { return (channel, nil) }
        let localY = point.y - (m.headerHeight + CGFloat(rowIndex) * m.rowHeight)
        return (channel, row.program(atTimelineX: Double(point.x - m.channelColumnWidth), y: Double(localY)))
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let target = target(at: location) else { return nil }
        let elements = callbacks.menu(target.channel, target.program)
        guard !elements.isEmpty else { return nil }
        menuHighlight = highlightRect(at: location)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(title: target.program?.title ?? target.channel.name, children: elements)
        }
    }

    /// Lift only the pressed cell (or channel name), not the whole grid.
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        guard let (view, rect) = menuHighlight else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: rect, cornerRadius: 6)
        let center = view.convert(CGPoint(x: rect.midX, y: rect.midY), to: self)
        return UITargetedPreview(view: view, parameters: parameters,
                                 target: UIPreviewTarget(container: self, center: center))
    }

    /// The drawn view and rect (in its coordinates) under a long-press.
    private func highlightRect(at point: CGPoint) -> (view: UIView, rect: CGRect)? {
        let m = metrics
        let rowIndex = Int((point.y - m.headerHeight) / m.rowHeight)
        guard channels.indices.contains(rowIndex) else { return nil }
        if point.x - contentOffset.x < m.channelColumnWidth {
            guard let cell = channelCells[rowIndex] else { return nil }
            return (cell, cell.bounds)
        }
        guard let row = rows[rowIndex],
              let rect = row.cellRect(atTimelineX: point.x - m.channelColumnWidth) else { return nil }
        // Row views are viewport-wide and draw from the timeline offset.
        return (row, rect.offsetBy(dx: -contentOffset.x, dy: 0).intersection(row.bounds))
    }

    private func rebuildAccessibilityElements(visible: Range<Int>, timelineWidth: CGFloat) {
        let m = metrics
        var elements: [UIAccessibilityElement] = []
        let clock = EPGClockText.shared
        for index in visible {
            let channel = channels[index]
            let y = m.headerHeight + CGFloat(index) * m.rowHeight
            let channelElement = GuideAccessibilityElement(accessibilityContainer: self) { [weak self] in
                self?.callbacks.selectChannel(channel)
            }
            channelElement.accessibilityLabel = channel.name
            channelElement.accessibilityHint = "Plays the channel"
            channelElement.accessibilityTraits = .button
            channelElement.accessibilityFrameInContainerSpace = CGRect(x: contentOffset.x, y: y,
                                                                      width: m.channelColumnWidth, height: m.rowHeight)
            elements.append(channelElement)
            guard let row = rows[index] else { continue }
            for cell in row.visibleCells(minX: contentOffset.x, width: timelineWidth) {
                let program = cell.program
                let element = GuideAccessibilityElement(accessibilityContainer: self) { [weak self] in
                    self?.callbacks.selectProgram(channel, program)
                }
                let times = clock.compactRange(start: program.start.timeIntervalSinceReferenceDate,
                                               end: program.end.timeIntervalSinceReferenceDate)
                element.accessibilityLabel = "\(program.title), \(channel.name)"
                element.accessibilityValue = cell.isLive ? "On now, \(times)" : times
                element.accessibilityTraits = .button
                element.accessibilityFrameInContainerSpace = cell.rect.offsetBy(dx: m.channelColumnWidth, dy: y)
                elements.append(element)
            }
        }
        accessibilityCache = elements
    }

    override var accessibilityElements: [Any]? {
        get { accessibilityCache }
        set {}
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let target = target(at: recognizer.location(in: self)) else { return }
        if let program = target.program {
            callbacks.selectProgram(target.channel, program)
        } else {
            callbacks.selectChannel(target.channel)
        }
    }
}

/// An accessibility element for one drawn guide cell; activating it plays.
final class GuideAccessibilityElement: UIAccessibilityElement {
    private let activate: () -> Void

    init(accessibilityContainer: Any, activate: @escaping () -> Void) {
        self.activate = activate
        super.init(accessibilityContainer: accessibilityContainer)
    }

    override func accessibilityActivate() -> Bool {
        activate()
        return true
    }
}

/// One visible guide row. Holds the row's programmes and its `EPGRowLayout`;
/// draws only the cells intersecting the viewport.
final class GuideRowView: UIView {
    var isStale = true
    private(set) var channelID: String?
    private var layout = EPGRowLayout()
    private var programs: [EPGProgram] = []
    private var replayStart: Date?
    private var timelineOffset: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .systemBackground
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func load(channel: Channel, programs: [EPGProgram], window: GuideTimelineWindow, rowHeight: CGFloat, now: Date,
              reminderIDs: Set<String>) {
        channelID = channel.id
        self.programs = programs
        replayStart = channel.archiveWindow(now: now)?.start
        layout.build(programs: programs, timelineStart: window.start, pixelsPerMinute: window.pixelsPerMinute,
                     timelineWidth: window.width, rowHeight: Double(rowHeight), showGaps: channel.supportsRewind,
                     reminderIDs: reminderIDs)
        layout.applyState(now: now, replayStart: replayStart)
        isStale = false
        setNeedsDisplay()
    }

    func applyState(now: Date) { layout.applyState(now: now, replayStart: replayStart) }

    func setTimelineOffset(_ offset: CGFloat) {
        guard offset != timelineOffset else { return }
        timelineOffset = offset
        setNeedsDisplay()
    }

    func program(atTimelineX x: Double, y: Double) -> EPGProgram? {
        guard let cell = layout.cell(containingX: x, y: y) else { return nil }
        let index = Int(layout.source[cell])
        return programs.indices.contains(index) ? programs[index] : nil
    }

    /// The programme cell spanning a timeline x, in row coordinates.
    func cellRect(atTimelineX x: CGFloat) -> CGRect? {
        let cell = layout.firstCell(endingAfter: Double(x))
        guard cell < layout.count, CGFloat(layout.x[cell]) <= x, !layout.isGap(cell) else { return nil }
        return layout.rect(cell)
    }

    /// Programme cells intersecting the visible span, in row coordinates.
    func visibleCells(minX: CGFloat, width: CGFloat) -> [(rect: CGRect, program: EPGProgram, isLive: Bool)] {
        var result: [(CGRect, EPGProgram, Bool)] = []
        var cell = layout.firstCell(endingAfter: Double(minX))
        while cell < layout.count, CGFloat(layout.x[cell]) < minX + width {
            defer { cell += 1 }
            let index = Int(layout.source[cell])
            guard !layout.isGap(cell), programs.indices.contains(index) else { continue }
            var rect = layout.rect(cell)
            let left = max(rect.minX, minX)
            rect = CGRect(x: left, y: rect.minY, width: min(rect.maxX, minX + width) - left, height: rect.height)
            result.append((rect, programs[index], layout.flags[cell] & EPGCellFlags.live != 0))
        }
        return result
    }

    private static let bell = UIImage(systemName: "bell.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))?
        .withTintColor(.systemOrange, renderingMode: .alwaysOriginal)

    private static let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: UIColor.label,
    ]
    private static let timeAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: UIColor.secondaryLabel,
    ]
    private static let pastTitleAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: UIColor.tertiaryLabel,
    ]

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.systemBackground.cgColor)
        context.fill(rect)
        let minX = Double(timelineOffset), maxX = minX + Double(bounds.width)
        let clock = EPGClockText.shared
        clock.beginPass()
        var cell = layout.firstCell(endingAfter: minX)
        while cell < layout.count, Double(layout.x[cell]) < maxX {
            defer { cell += 1 }
            let flags = layout.flags[cell]
            var frame = layout.rect(cell).offsetBy(dx: -timelineOffset, dy: 0).insetBy(dx: 1, dy: 0)
            frame.size.width = max(0, frame.width - 1)
            if flags & EPGCellFlags.gap != 0 {
                UIColor.secondarySystemBackground.withAlphaComponent(0.4).setFill()
                UIBezierPath(roundedRect: frame, cornerRadius: 6).fill()
                continue
            }
            let fill: UIColor = if flags & EPGCellFlags.live != 0 {
                UIColor.tintColor.withAlphaComponent(0.22)
            } else if flags & EPGCellFlags.past != 0 {
                UIColor.secondarySystemBackground.withAlphaComponent(0.55)
            } else {
                UIColor.secondarySystemBackground
            }
            fill.setFill()
            UIBezierPath(roundedRect: frame, cornerRadius: 6).fill()
            let index = Int(layout.source[cell])
            guard programs.indices.contains(index), frame.width > 24 else { continue }
            // Sticky text: keep the title readable when the cell starts off-screen.
            let textX = max(frame.minX, 0) + 8
            let textWidth = frame.maxX - textX - 6
            guard textWidth > 12 else { continue }
            let past = flags & EPGCellFlags.past != 0
            if flags & EPGCellFlags.reminder != 0, let bell = Self.bell, frame.width > 40 {
                bell.draw(at: CGPoint(x: frame.maxX - bell.size.width - 6, y: frame.minY + 6))
            }
            (programs[index].title as NSString).draw(
                with: CGRect(x: textX, y: frame.minY + 7, width: textWidth, height: 18),
                options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                attributes: past ? Self.pastTitleAttributes : Self.titleAttributes, context: nil)
            let range = clock.compactRange(start: layout.start[cell], end: layout.end[cell])
            (range as NSString).draw(
                with: CGRect(x: textX, y: frame.minY + 27, width: textWidth, height: 14),
                options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                attributes: Self.timeAttributes, context: nil)
        }
    }
}

final class GuideChannelCell: UIView {
    private let label = UILabel()
    private let separator = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        label.numberOfLines = 2
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        separator.backgroundColor = .separator
        addSubview(label)
        addSubview(separator)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ channel: Channel, compact: Bool) {
        label.text = channel.name
        label.font = .systemFont(ofSize: compact ? 11 : 13, weight: .semibold)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 10, dy: 4)
        separator.frame = CGRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5)
    }
}

final class GuideTimeHeader: UIView {
    private var spec = EPGTimeStripSpec.empty
    private var offset: CGFloat = 0
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: UIColor.secondaryLabel,
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(spec: EPGTimeStripSpec, offset: CGFloat) {
        guard spec != self.spec || offset != self.offset else { return }
        self.spec = spec
        self.offset = offset
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        UIColor.secondarySystemBackground.setFill()
        UIRectFill(rect)
        EPGClockText.shared.beginPass()
        for slot in spec.slots(intersecting: offset, offset + bounds.width) {
            let x = spec.slotX(slot) - offset
            UIColor.separator.setFill()
            UIRectFill(CGRect(x: x, y: bounds.height - 8, width: 1, height: 8))
            (spec.title(slot) as NSString).draw(at: CGPoint(x: x + 6, y: (bounds.height - 15) / 2),
                                                withAttributes: Self.attributes)
        }
    }
}
