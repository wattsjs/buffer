import AppKit

struct EPGProgramBlock {
    let program: EPGProgram?
    let rect: CGRect
    let hasReminder: Bool
}

final class ProgramBlocksView: NSView, EPGTimeSensitiveDrawing, EPGViewportDrawing {
    /// The channel these blocks were built for.
    var ownerID: String?
    /// Block geometry remains in timeline coordinates, while the native backing
    /// surface is only as wide as the visible AppKit table viewport.
    private(set) var timelineOriginX: CGFloat = 0
    private var blocks: [EPGProgramBlock] = []
    private var onProgramTap: ((EPGProgram, CGRect) -> Void)?
    private var onEmptyTap: (() -> Void)?
    private var onProgramRightClick: ((EPGProgram, NSEvent, NSView) -> Void)?
    private var referenceDate = Date()
    private var replayLookbackHours: Int?
    private var hoveredProgramID: String?
    private var hoverTrackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    func setTimelineOriginX(_ x: CGFloat) {
        guard timelineOriginX != x else { return }
        timelineOriginX = x
        needsDisplay = true
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

    func setBlocks(_ blocks: [EPGProgramBlock]) {
        self.blocks = blocks
        if let hoveredProgramID, !blocks.contains(where: { $0.program?.id == hoveredProgramID }) {
            self.hoveredProgramID = nil
        }
        needsDisplay = true
    }

    func setReferenceDate(_ date: Date) {
        guard referenceDate != date else { return }
        referenceDate = date
        needsDisplay = true
    }

    func setReplayLookbackHours(_ hours: Int?) {
        guard replayLookbackHours != hours else { return }
        replayLookbackHours = hours
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
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

    private func updateHoveredProgram(at point: NSPoint?) {
        let next = point.flatMap { point in
            let timelinePoint = NSPoint(x: point.x + timelineOriginX, y: point.y)
            return blocks.first { $0.rect.contains(timelinePoint) }?.program?.id
        }
        guard hoveredProgramID != next else { return }
        for block in blocks where block.program?.id == hoveredProgramID || block.program?.id == next {
            setNeedsDisplay(block.rect.offsetBy(dx: -timelineOriginX, dy: 0))
        }
        hoveredProgramID = next
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

    override func draw(_ dirtyRect: NSRect) {
        let drawStarted = ContinuousClock.now
        defer { PerfMetrics.shared.record("epg.programRow.drawMs", since: drawStarted) }
#if DEBUG
        recordDrawConsistency()
#endif
        let palette = EPGGridStyle.palette(for: effectiveAppearance)
        let replayStart = replayLookbackHours.map { referenceDate.addingTimeInterval(-Double($0) * 3600) }

        if blocks.isEmpty {
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
        let timelineDirtyRect = dirtyRect.offsetBy(dx: timelineOriginX, dy: 0)

        for block in blocks {
            guard block.program != nil else { continue }
            guard block.rect.intersects(timelineDirtyRect) else { continue }
            let inset = block.rect.offsetBy(dx: -timelineOriginX, dy: 0).insetBy(dx: 1, dy: 0)
            let path = NSBezierPath(roundedRect: inset, xRadius: 3, yRadius: 3)
            guard let program = block.program else { continue }
            let state = EPGGridStyle.state(for: program, now: referenceDate, replayStart: replayStart)
            let hovered = program.id == hoveredProgramID
            palette.surface(for: state, hovered: hovered).setFill()
            path.fill()
            (hovered ? palette.hoverBorder : palette.border).setStroke()
            path.lineWidth = hovered ? 1 : 0.5
            path.stroke()

            NSGraphicsContext.saveGraphicsState()
            path.addClip()

            // Restrained state cues preserve the neutral programme surface.
            // The schedule timestamps and now line carry the same meaning.
            if state == .live || state == .replay {
                (state == .live ? palette.liveIndicator : palette.replayIndicator).setFill()
                NSRect(x: inset.minX, y: inset.minY + 3, width: 2, height: max(0, inset.height - 6)).fill()
            }

            // Keep the title readable when the viewport begins midway through
            // a long programme. It stays inside its own card, under the native
            // clip path, and is never duplicated in the metadata overlay.
            let title = program.title.isEmpty ? "No Event Today" : program.title
            let titleX = max(inset.minX, bounds.minX) + EPGStickyLabelMetrics.x
            let titleY = max(inset.minY + 2, EPGStickyLabelMetrics.titleRowY)
            let reminderReserve: CGFloat
            if block.hasReminder, let bell = Self.bellImage {
                let size = bell.size
                reminderReserve = size.width + EPGStickyLabelMetrics.titleTrailingReserve
                bell.draw(
                    in: NSRect(
                        x: inset.maxX - size.width - 6,
                        y: titleY + 1,
                        width: size.width,
                        height: size.height
                    ),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: nil
                )
            } else {
                reminderReserve = EPGStickyLabelMetrics.x
            }

            let titleWidth = min(
                EPGStickyLabelMetrics.titleMaxWidth,
                inset.maxX - reminderReserve - titleX
            )
            if titleWidth > 8 {
                (title as NSString).draw(
                    in: NSRect(
                        x: titleX,
                        y: titleY,
                        width: titleWidth,
                        height: EPGStickyLabelMetrics.titleRowHeight
                    ),
                    withAttributes: [
                        .font: Self.titleFont,
                        .foregroundColor: palette.primaryText,
                        .paragraphStyle: Self.titleParagraph,
                    ]
                )
            }

            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let location = NSPoint(x: local.x + timelineOriginX, y: local.y)
        if let block = blocks.first(where: { $0.rect.contains(location) }), let program = block.program {
            let visibleCard = block.rect.offsetBy(dx: -timelineOriginX, dy: 0).intersection(bounds)
            onProgramTap?(program, visibleCard)
        } else {
            onEmptyTap?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let location = NSPoint(x: local.x + timelineOriginX, y: local.y)
        guard let block = blocks.first(where: { $0.rect.contains(location) }), let program = block.program else { return }
        onProgramRightClick?(program, event, self)
    }
}

#if DEBUG
extension ProgramBlocksView {
    /// Counts draws showing content that does not belong to the row currently
    /// displayed: the visible flash when a reused cell paints stale blocks.
    fileprivate func recordDrawConsistency() {
        PerfMetrics.shared.increment("epg.programRow.draws")
        if blocks.isEmpty { PerfMetrics.shared.increment("epg.programRow.emptyDraws") }
        var ancestor = superview
        while let view = ancestor, !(view is EPGRowIdentityProviding) { ancestor = view.superview }
        guard let row = ancestor as? EPGRowIdentityProviding, let expected = row.expectedRowID else { return }
        if expected != ownerID.map(AnyHashable.init) {
            PerfMetrics.shared.increment("epg.programRow.staleDraws")
        }
    }
}
#endif
