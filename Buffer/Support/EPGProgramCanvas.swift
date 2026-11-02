import AppKit

/// Legacy block description, still accepted by `setBlocks` for fixtures and
/// callers that already hold explicit rectangles. Production rows lay out from
/// programme data directly with `setPrograms`.
struct EPGProgramBlock {
    let program: EPGProgram?
    let rect: CGRect
    let hasReminder: Bool
}

/// One native surface draws every programme card of a guide row from the
/// row's packed `EPGRowLayout` columns: no per-cell views, no per-cell
/// objects, and layout reuses the same column storage for every row it shows.
final class ProgramBlocksView: NSView, EPGTimeSensitiveDrawing, EPGViewportDrawing {
    /// The channel these blocks were built for.
    var ownerID: String?
    /// Block geometry remains in timeline coordinates, while the native backing
    /// surface is only as wide as the visible AppKit table viewport.
    private(set) var timelineOriginX: CGFloat = 0
    /// Source programmes; layout cells refer to them by index.
    private var programs: [EPGProgram] = []
    private(set) var layout = EPGRowLayout()
    /// Shaped titles, parallel to the layout cells; shaped on first draw and
    /// kept until the row is laid out again.
    private var titleLines = ContiguousArray<EPGTextLine?>()
    private var layoutInputs: LayoutInputs?
    private var onProgramTap: ((EPGProgram, CGRect) -> Void)?
    private var onEmptyTap: (() -> Void)?
    private var onProgramRightClick: ((EPGProgram, NSEvent, NSView) -> Void)?
    private var referenceDate = Date()
    private var replayLookbackHours: Int?
    private var stateIsCurrent = false
    private var hoveredProgramID: String?
    private var hoveredCell = -1
    private var hoverTrackingArea: NSTrackingArea?
    private var palette: EPGGridStyle.Palette?
    private var paletteAppearance: NSAppearance.Name?
    /// Opacity of the row separator drawn along the bottom edge; nil draws none.
    var bottomDividerOpacity: CGFloat? {
        didSet { if oldValue != bottomDividerOpacity { needsDisplay = true } }
    }

    private struct LayoutInputs: Equatable {
        let programsBase: UnsafeRawPointer?
        let programCount: Int
        let timelineStart: Date
        let pixelsPerMinute: CGFloat
        let timelineWidth: CGFloat
        let rowHeight: CGFloat
        let showGaps: Bool
        let reminderIDs: Set<String>
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(systemColorsDidChange),
                                               name: NSColor.systemColorsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func systemColorsDidChange() {
        palette = nil
        needsDisplay = true
    }

    func setTimelineOriginX(_ x: CGFloat) {
        guard timelineOriginX != x else { return }
        timelineOriginX = x
        needsDisplay = true
    }

    /// The part of this surface the viewport shows (view coordinates), when
    /// the surface is wider than the viewport. Long titles pin to its leading
    /// edge, so a pan only repaints the card under that edge.
    private var visibleSpan: (minX: CGFloat, maxX: CGFloat)?

    func setVisibleSpan(minX: CGFloat, maxX: CGFloat) {
        let previousMinX = visibleSpan?.minX
        visibleSpan = (minX, maxX)
        guard previousMinX != minX else { return }
        if let previousMinX { invalidateCard(atLocalX: previousMinX) }
        invalidateCard(atLocalX: minX)
    }

    private var pinMinX: CGFloat { visibleSpan?.minX ?? bounds.minX }

    private var visibleBounds: CGRect {
        guard let visibleSpan else { return bounds }
        return CGRect(x: visibleSpan.minX, y: bounds.minY, width: max(0, visibleSpan.maxX - visibleSpan.minX),
                      height: bounds.height)
    }

    private func invalidateCard(atLocalX x: CGFloat) {
        guard let cell = layout.cell(containingX: Double(x + timelineOriginX), y: Double(layout.cellMinY)) else { return }
        let rect = layout.rect(cell).offsetBy(dx: -timelineOriginX, dy: 0).intersection(bounds)
        if !rect.isEmpty { setNeedsDisplay(rect) }
    }

    func setHandlers(
        onProgramTap: @escaping (EPGProgram, CGRect) -> Void,
        onEmptyTap: @escaping () -> Void,
        onProgramRightClick: @escaping (EPGProgram, NSEvent, NSView) -> Void
    ) {
        self.onProgramTap = onProgramTap
        self.onEmptyTap = onEmptyTap
        self.onProgramRightClick = onProgramRightClick
    }

    /// Lays out a row from programme data into the reused columns. Unchanged
    /// inputs (same programme storage and timeline) skip the layout entirely.
    func setPrograms(
        _ programs: [EPGProgram],
        timelineStart: Date,
        pixelsPerMinute: CGFloat,
        timelineWidth: CGFloat,
        rowHeight: CGFloat,
        showGaps: Bool,
        reminderIDs: Set<String>
    ) {
        let base = programs.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        let inputs = LayoutInputs(programsBase: base, programCount: programs.count, timelineStart: timelineStart,
                                  pixelsPerMinute: pixelsPerMinute, timelineWidth: timelineWidth,
                                  rowHeight: rowHeight, showGaps: showGaps, reminderIDs: reminderIDs)
        guard inputs != layoutInputs else { return }
        // Retain the new storage before recording its address.
        self.programs = programs
        layoutInputs = inputs
        layout.build(programs: programs, timelineStart: timelineStart, pixelsPerMinute: Double(pixelsPerMinute),
                     timelineWidth: Double(timelineWidth), rowHeight: Double(rowHeight), showGaps: showGaps,
                     reminderIDs: reminderIDs)
        layoutDidChange()
    }

    func setBlocks(_ blocks: [EPGProgramBlock]) {
        layoutInputs = nil
        programs.removeAll(keepingCapacity: true)
        layout.removeAll()
        if let first = blocks.first { layout.setCellBand(minY: first.rect.minY, height: first.rect.height) }
        for block in blocks {
            let index: Int32
            if let program = block.program {
                index = Int32(programs.count)
                programs.append(program)
            } else {
                index = -1
            }
            var flags: UInt8 = block.program == nil ? EPGCellFlags.gap : 0
            if block.hasReminder { flags |= EPGCellFlags.reminder }
            layout.append(x: block.rect.minX, width: block.rect.width, source: index,
                          start: block.program?.start.timeIntervalSinceReferenceDate ?? 0,
                          end: block.program?.end.timeIntervalSinceReferenceDate ?? 0, flags: flags)
        }
        layoutDidChange()
    }

    private func layoutDidChange() {
        stateIsCurrent = false
        titleLines.removeAll(keepingCapacity: true)
        titleLines.append(contentsOf: repeatElement(nil, count: layout.count))
        hoveredCell = -1
        if let hoveredProgramID {
            for cell in 0..<layout.count where layout.source[cell] >= 0
                && programs[Int(layout.source[cell])].id == hoveredProgramID {
                hoveredCell = cell
                break
            }
            if hoveredCell < 0 { self.hoveredProgramID = nil }
        }
        needsDisplay = true
    }

    func setReferenceDate(_ date: Date) {
        guard referenceDate != date else { return }
        referenceDate = date
        stateIsCurrent = false
        needsDisplay = true
    }

    func setReplayLookbackHours(_ hours: Int?) {
        guard replayLookbackHours != hours else { return }
        replayLookbackHours = hours
        stateIsCurrent = false
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        palette = nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredProgram(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        updateHoveredProgram(at: nil)
    }

    /// The programme cell under a view-local point.
    private func programCell(at point: NSPoint) -> Int? {
        guard let cell = layout.cell(containingX: Double(point.x + timelineOriginX), y: Double(point.y)),
              layout.source[cell] >= 0 else { return nil }
        return cell
    }

    private func updateHoveredProgram(at point: NSPoint?) {
        let next = point.flatMap(programCell(at:)) ?? -1
        guard next != hoveredCell else { return }
        if hoveredCell >= 0 { setNeedsDisplay(layout.rect(hoveredCell).offsetBy(dx: -timelineOriginX, dy: 0)) }
        if next >= 0 { setNeedsDisplay(layout.rect(next).offsetBy(dx: -timelineOriginX, dy: 0)) }
        hoveredCell = next
        hoveredProgramID = next >= 0 ? programs[Int(layout.source[next])].id : nil
    }

    private static let bellImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            .applying(.init(paletteColors: [.systemOrange]))
        return NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }()

    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let titleParagraph: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.minimumLineHeight = EPGStickyLabelMetrics.titleRowHeight
        paragraph.maximumLineHeight = EPGStickyLabelMetrics.titleRowHeight
        return paragraph
    }()

    private func currentPalette() -> EPGGridStyle.Palette {
        let name = effectiveAppearance.name
        if let palette, paletteAppearance == name { return palette }
        let next = EPGGridStyle.palette(for: effectiveAppearance)
        palette = next
        paletteAppearance = name
        return next
    }

    override func draw(_ dirtyRect: NSRect) {
        let drawStarted = ContinuousClock.now
        defer { PerfMetrics.shared.record("epg.programRow.drawMs", since: drawStarted) }
#if DEBUG
        recordDrawConsistency()
#endif
        let palette = currentPalette()
        defer { drawBottomDivider(dirtyRect) }

        if layout.isEmpty {
            // Explain an empty provider/time window without inventing a
            // programme or making genuine gaps look like scheduled content.
            ("No listings for this time" as NSString).draw(
                in: NSRect(x: EPGStickyLabelMetrics.x, y: EPGStickyLabelMetrics.titleRowY,
                           width: max(0, bounds.width - EPGStickyLabelMetrics.x * 2),
                           height: EPGStickyLabelMetrics.titleRowHeight),
                withAttributes: [.font: Self.titleFont, .foregroundColor: palette.metadataText,
                                 .paragraphStyle: Self.titleParagraph]
            )
            return
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let pinMinX = self.pinMinX
        if !stateIsCurrent {
            let replayStart = replayLookbackHours.map { referenceDate.addingTimeInterval(-Double($0) * 3600) }
            layout.applyState(now: referenceDate, replayStart: replayStart)
            stateIsCurrent = true
        }
        let timelineDirtyRect = dirtyRect.offsetBy(dx: timelineOriginX, dy: 0)
        let titleStyle = EPGTextStyle.programmeTitle
        let cellTop = CGFloat(layout.cellMinY)
        let cellHeight = CGFloat(layout.cellHeight)
        guard cellTop < timelineDirtyRect.maxY, cellTop + cellHeight > timelineDirtyRect.minY else { return }

        var cell = layout.firstCell(endingAfter: Double(timelineDirtyRect.minX))
        while cell < layout.count {
            defer { cell += 1 }
            let cellX = CGFloat(layout.x[cell])
            if cellX >= timelineDirtyRect.maxX { break }
            let flags = layout.flags[cell]
            if flags & EPGCellFlags.gap != 0 { continue }
            let rect = CGRect(x: cellX, y: cellTop, width: CGFloat(layout.width[cell]), height: cellHeight)
            let inset = rect.offsetBy(dx: -timelineOriginX, dy: 0).insetBy(dx: 1, dy: 0)
            let state: EPGGridStyle.ProgramState =
                flags & EPGCellFlags.live != 0 ? .live
                : flags & EPGCellFlags.catchup != 0 ? .replay
                : flags & EPGCellFlags.past != 0 ? .past : .upcoming
            let hovered = cell == hoveredCell

            palette.surface(for: state, hovered: hovered).setFill()
            Self.addRoundedRect(inset, radius: 3, to: context)
            context.fillPath()
            (hovered ? palette.hoverBorder : palette.border).setStroke()
            context.setLineWidth(hovered ? 1 : 0.5)
            Self.addRoundedRect(inset, radius: 3, to: context)
            context.strokePath()

            context.saveGState()
            Self.addRoundedRect(inset, radius: 3, to: context)
            context.clip()

            // Restrained state cues preserve the neutral programme surface.
            // The schedule timestamps and now line carry the same meaning.
            if state == .live || state == .replay {
                (state == .live ? palette.liveIndicator : palette.replayIndicator).setFill()
                context.fill(CGRect(x: inset.minX, y: inset.minY + 3, width: 2, height: max(0, inset.height - 6)))
            }

            // Keep the title readable when the viewport begins midway through
            // a long programme. It stays inside its own card, under the native
            // clip path, and is never duplicated in the metadata overlay.
            let titleX = max(inset.minX, pinMinX) + EPGStickyLabelMetrics.x
            let titleY = max(inset.minY + 2, EPGStickyLabelMetrics.titleRowY)
            let reminderReserve: CGFloat
            if flags & EPGCellFlags.reminder != 0, let bell = Self.bellImage {
                let size = bell.size
                reminderReserve = size.width + EPGStickyLabelMetrics.titleTrailingReserve
                bell.draw(
                    in: NSRect(x: inset.maxX - size.width - 6, y: titleY + 1, width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
                )
            } else {
                reminderReserve = EPGStickyLabelMetrics.x
            }

            let titleWidth = min(EPGStickyLabelMetrics.titleMaxWidth, inset.maxX - reminderReserve - titleX)
            if titleWidth > 8 {
                let text: EPGTextLine
                if let shaped = titleLines[cell] {
                    text = shaped
                } else {
                    let program = programs[Int(layout.source[cell])]
                    text = titleStyle.line(program.title.isEmpty ? "No Event Today" : program.title)
                    titleLines[cell] = text
                }
                titleStyle.draw(text, in: NSRect(x: titleX, y: titleY, width: titleWidth, height: EPGStickyLabelMetrics.titleRowHeight),
                                color: palette.primaryText, context: context)
            }
            context.restoreGState()
        }
    }

    private func drawBottomDivider(_ dirtyRect: NSRect) {
        guard let opacity = bottomDividerOpacity else { return }
        let lineWidth = 1 / max(1, window?.backingScaleFactor ?? 2)
        NSColor.separatorColor.withAlphaComponent(NSColor.separatorColor.alphaComponent * opacity).setFill()
        NSRect(x: dirtyRect.minX, y: bounds.maxY - lineWidth, width: dirtyRect.width, height: lineWidth)
            .fill(using: .sourceOver)
    }

    /// Same geometry as `NSBezierPath(roundedRect:xRadius:yRadius:)`, added
    /// straight to the context so drawing a card allocates nothing.
    @inline(__always)
    static func addRoundedRect(_ rect: CGRect, radius: CGFloat, to context: CGContext) {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        guard r > 0 else { context.addRect(rect); return }
        context.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        context.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
        context.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        context.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        context.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: r)
        context.closePath()
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let cell = programCell(at: local) {
            let visibleCard = layout.rect(cell).offsetBy(dx: -timelineOriginX, dy: 0).intersection(visibleBounds)
            onProgramTap?(programs[Int(layout.source[cell])], visibleCard)
        } else {
            onEmptyTap?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let cell = programCell(at: local) else { return }
        onProgramRightClick?(programs[Int(layout.source[cell])], event, self)
    }
}

#if DEBUG
extension ProgramBlocksView {
    /// Counts draws showing content that does not belong to the row currently
    /// displayed: the visible flash when a reused cell paints stale blocks.
    fileprivate func recordDrawConsistency() {
        PerfMetrics.shared.increment("epg.programRow.draws")
        if layout.isEmpty { PerfMetrics.shared.increment("epg.programRow.emptyDraws") }
        var ancestor = superview
        while let view = ancestor, !(view is EPGRowIdentityProviding) { ancestor = view.superview }
        guard let row = ancestor as? EPGRowIdentityProviding, let expected = row.expectedRowID else { return }
        if expected != ownerID.map(AnyHashable.init) {
            PerfMetrics.shared.increment("epg.programRow.staleDraws")
        }
    }
}
#endif
