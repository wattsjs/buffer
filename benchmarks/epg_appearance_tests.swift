import AppKit
import SwiftUI

private struct FixtureChannel: Identifiable { let id: Int }

private struct FixtureProgramRow: View {
    let blocks: [EPGProgramBlock]
    let now: Date
    let width: CGFloat
    let opacity: Double
    @State private var showDetail = false
    var body: some View {
        FixtureCanvas(blocks: blocks, now: now)
            .equatable()
            .popover(isPresented: $showDetail, attachmentAnchor: .rect(.rect(.zero)), arrowEdge: .top) { Text("Programme detail") }
            .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }
            .opacity(opacity)
            .saturation(opacity == 1 ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.25), value: opacity)
    }
}

@MainActor private final class FixtureOpacity {
    var value = 1.0
}

private final class FixturePageView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        EPGGridStyle.palette(for: effectiveAppearance).page.setFill()
        dirtyRect.fill()
    }
}

private struct FixtureCanvas: NSViewRepresentable, Equatable {
    let blocks: [EPGProgramBlock]
    let now: Date
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.now == rhs.now && lhs.blocks.map { $0.program?.id } == rhs.blocks.map { $0.program?.id }
    }
    func makeNSView(context: Context) -> ProgramBlocksView {
        let view = ProgramBlocksView()
        view.setBlocks(blocks)
        view.setReferenceDate(now)
        view.setReplayLookbackHours(72)
        return view
    }
    func updateNSView(_ view: ProgramBlocksView, context: Context) {
        view.setBlocks(blocks)
        view.setReferenceDate(now)
    }
}

@main
@MainActor
struct EPGAppearanceTests {
    static var checks = 0
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let output = URL(fileURLWithPath: ".local/bench/epg-appearance", isDirectory: true)

    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fputs("FAIL \(message)\n", stderr); exit(1) }
        checks += 1
    }

    static func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    static func program(_ id: String, start: Double, end: Double) -> EPGProgram {
        EPGProgram(id: id, channelID: "fixture", title: "Programme \(id)", description: "",
                   start: now.addingTimeInterval(start), end: now.addingTimeInterval(end))
    }

    static func luminance(_ color: NSColor) -> Double {
        let rgb = color.usingColorSpace(.sRGB)!
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    static func contrast(_ foreground: NSColor, _ background: NSColor) -> Double {
        let foreground = EPGGridStyle.composite(foreground, over: background)
        let first = luminance(foreground), second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    static func colorString(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB)!
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }

    static func snapshot(_ view: NSView, path: String, rect: CGRect? = nil, scale: Int = 2) -> NSBitmapImageRep {
        let rect = rect ?? view.bounds
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width) * scale,
                                     pixelsHigh: Int(rect.height) * scale, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = rect.size
        view.cacheDisplay(in: rect, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(path))
        return bitmap
    }

    static func pixel(_ bitmap: NSBitmapImageRep, x: Double, y: Double, scale: Int = 2) -> NSColor {
        bitmap.colorAt(x: Int(x * Double(scale)), y: Int(y * Double(scale)))!.usingColorSpace(.sRGB)!
    }

    static func close(_ first: NSColor, _ second: NSColor, tolerance: Double = 0.025) -> Bool {
        let a = first.usingColorSpace(.sRGB)!, b = second.usingColorSpace(.sRGB)!
        return abs(a.redComponent - b.redComponent) < tolerance && abs(a.greenComponent - b.greenComponent) < tolerance && abs(a.blueComponent - b.blueComponent) < tolerance
    }

    static func main() {
        _ = NSApplication.shared
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var measurements: [[String: Any]] = []
        for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark"),
                               (.accessibilityHighContrastAqua, "light-contrast"), (.accessibilityHighContrastDarkAqua, "dark-contrast")] {
            let appearance = NSAppearance(named: name)!
            let palette = EPGGridStyle.palette(for: appearance)
            var minimumTitle = Double.infinity, minimumMetadata = Double.infinity
            for state in [EPGGridStyle.ProgramState.upcoming, .past, .replay, .live] {
                for hovered in [false, true] {
                    let surface = palette.surface(for: state, hovered: hovered)
                    let title = contrast(palette.primaryText, surface)
                    let metadata = contrast(palette.metadataText, surface)
                    minimumTitle = min(minimumTitle, title)
                    minimumMetadata = min(minimumMetadata, metadata)
                    require(title >= 7, "\(suffix) programme/channel primary contrast \(title)")
                    require(metadata >= 4.5, "\(suffix) programme time contrast \(metadata)")
                }
            }
            require(contrast(palette.metadataText, palette.header) >= 4.5, "\(suffix) timeline labels")
            require(contrast(palette.liveIndicator, palette.liveSurface) >= 3, "\(suffix) live indicator contrast")
            require(contrast(palette.replayIndicator, palette.pastSurface) >= 3, "\(suffix) replay indicator contrast")
            renderCanvas(appearance: appearance, suffix: suffix)
            renderPinnedTitle(appearance: appearance, suffix: suffix)
            let rendered = [renderPannedGrid(appearance: appearance, suffix: suffix, opacity: 1),
                            renderPannedGrid(appearance: appearance, suffix: suffix, opacity: 0.45),
                            renderPannedGrid(appearance: appearance, suffix: suffix, opacity: 0.35),
                            renderPannedGrid(appearance: appearance, suffix: suffix, opacity: 1, native: true)]
            measurements.append(["appearance": suffix, "programmeSurface": colorString(palette.upcomingSurface),
                                 "minimumPrimaryContrast": minimumTitle, "minimumMetadataContrast": minimumMetadata,
                                 "renderedProgrammeContrast": rendered])
        }
        testViewportInteraction()
        testSourcePriorityContext()
        testTextEquivalence()
        let report: [String: Any] = ["fixture": "production-epg-appearance-and-pan-v1", "appearances": measurements, "checks": checks]
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        print("PASS \(checks) production EPG appearance, contrast, panned canvas and viewport priority checks")
    }

    static func renderCanvas(appearance: NSAppearance, suffix: String) {
        let view = ProgramBlocksView(frame: CGRect(x: 0, y: 0, width: 900, height: 64))
        view.appearance = appearance
        view.setReferenceDate(now)
        view.setReplayLookbackHours(72)
        view.setBlocks([
            EPGProgramBlock(program: program("Replay", start: -7200, end: -3600), rect: CGRect(x: 0, y: 3, width: 300, height: 58), hasReminder: false),
            EPGProgramBlock(program: program("Live", start: -1800, end: 1800), rect: CGRect(x: 300, y: 3, width: 300, height: 58), hasReminder: true),
            EPGProgramBlock(program: program("Next", start: 1800, end: 5400), rect: CGRect(x: 600, y: 3, width: 300, height: 58), hasReminder: false)
        ])
        let bitmap = snapshot(view, path: "\(suffix)-programme-states.png")
        let palette = EPGGridStyle.palette(for: appearance)
        require(close(pixel(bitmap, x: 150, y: 52), palette.pastSurface), "\(suffix) actual replay card pixels")
        require(close(pixel(bitmap, x: 450, y: 52), palette.liveSurface), "\(suffix) actual live card pixels")
        require(close(pixel(bitmap, x: 750, y: 52), palette.upcomingSurface), "\(suffix) actual upcoming card pixels")

        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        let point = view.convert(NSPoint(x: 150, y: 20), to: nil)
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 0, pressure: 0)!
        view.mouseMoved(with: event)
        let hovered = snapshot(view, path: "\(suffix)-hover.png")
        require(close(pixel(hovered, x: 150, y: 52), palette.surface(for: .replay, hovered: true)),
                "\(suffix) pointer hover paints the interaction surface")
        view.mouseExited(with: event)
        view.setReferenceDate(now.addingTimeInterval(7200))
        let expired = snapshot(view, path: "\(suffix)-live-transition.png")
        require(close(pixel(expired, x: 450, y: 52), palette.pastSurface),
                "\(suffix) live colour expires using drawing time without rebuilding blocks")
        view.setReferenceDate(now)

        // Preserve real programme geometry when only appearance changes.
        view.appearance = NSAppearance(named: suffix.hasPrefix("dark") ? .aqua : .darkAqua)
        let transitioned = snapshot(view, path: "\(suffix)-appearance-transition.png")
        require(close(pixel(transitioned, x: 750, y: 52), EPGGridStyle.palette(for: view.effectiveAppearance).upcomingSurface),
                "appearance transition repaints unchanged programme geometry")
        window.contentView = nil
    }

    static func renderPannedGrid(appearance: NSAppearance, suffix: String, opacity: Double, native: Bool = false) -> [String: Any] {
        let suffix = suffix + (native ? "-native" : "") + (opacity == 1 ? "" : "-dimmed-\(opacity)")
        let width: CGFloat = 80_640
        let blocks = (0..<672).map { index in
            EPGProgramBlock(program: program("Slot \(index)", start: Double(index * 1800), end: Double((index + 1) * 1800)),
                            rect: CGRect(x: index * 120, y: 3, width: 120, height: 58), hasReminder: false)
        }
        let programs = blocks.compactMap(\.program)
        let items = (0..<3).map { FixtureChannel(id: $0) }
        let opacityState = FixtureOpacity()
        let grid = EPGScrollGrid(items: items, rowHeight: 64, channelColumnWidth: 120, programRowWidth: width,
                                 headerHeight: 32, nowLineX: 400, initialHorizontalOffset: 60_060,
                                 horizontalScrollRequest: nil, timelineIdentity: 1,
                                 itemSetVersion: 1, dataVersion: 1, referenceDate: now,
                                 timeStrip: EPGTimeStripSpec(start: now, hours: 336, pixelsPerMinute: 4, relativeTo: now),
                                 rowDataProvider: { item, slot in
                                     slot.channelName = "Channel \(item.id)"
                                     slot.layout.build(programs: programs, timelineStart: now, pixelsPerMinute: 4,
                                                       timelineWidth: Double(width), rowHeight: 64, showGaps: false)
                                 },
                                 nativeProgramRow: native ? { item, canvas in
                                     canvas.ownerID = "\(item.id)"
                                     canvas.setPrograms(programs, timelineStart: now, pixelsPerMinute: 4, timelineWidth: width,
                                                        rowHeight: 64, showGaps: false, reminderIDs: [])
                                     canvas.setReplayLookbackHours(72)
                                 } : nil,
                                 channelContent: { item in Text("Channel \(item.id)") },
                                 programContent: { _ in FixtureProgramRow(blocks: blocks, now: now, width: width, opacity: opacityState.value) },
                                 cornerContent: { Text("TV Guide") })
        let coordinator = grid.makeCoordinator()
        let container = grid.makeContainer(coordinator: coordinator)
        container.appearance = appearance
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 224),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        let page = FixturePageView(frame: CGRect(x: 0, y: 0, width: 900, height: 224))
        page.appearance = appearance
        container.frame = page.bounds
        page.addSubview(container)
        window.contentView = page
        grid.updateContainer(container, coordinator: coordinator)
        container.layoutSubtreeIfNeeded()
        pump()
        if opacity != 1 {
            opacityState.value = opacity
            grid.updateContainer(container, coordinator: coordinator)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }
        let scroll = container.programTableView.enclosingScrollView!
        func canvases(in view: NSView) -> [ProgramBlocksView] {
            if let canvas = view as? ProgramBlocksView { return [canvas] }
            return view.subviews.flatMap { canvases(in: $0) }
        }
        var renderedTitleContrast = 0.0
        let palette = EPGGridStyle.palette(for: appearance)
        let expectedSurface = EPGGridStyle.composite(palette.upcomingSurface.withAlphaComponent(opacity), over: palette.page)
        let initial = snapshot(page, path: "\(suffix)-initial-archive-offset.png")
        require(close(pixel(initial, x: 430, y: 86), expectedSurface),
                "\(suffix) initial full-archive offset paints populated programme cards")
        let initialCanvases = canvases(in: container.programTableView)
        // Native rows keep a bounded panning margin either side of the viewport.
        let surfaceLimit = scroll.contentView.bounds.width * (native ? 1.7 : 1) + 1
        require(!initialCanvases.isEmpty, "\(suffix) native programme canvases attached")
        require(initialCanvases.allSatisfy { $0.bounds.width <= surfaceLimit },
                "\(suffix) backing surfaces remain bounded to viewport at 80k archive width")
        for offset in [CGFloat(0), 1200, 20_040, 60_060] {
            scroll.contentView.scroll(to: NSPoint(x: offset, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            container.layoutSubtreeIfNeeded()
            pump()
            let visibleCanvases = canvases(in: container.programTableView)
            require(visibleCanvases.allSatisfy { $0.bounds.width <= surfaceLimit },
                    "\(suffix) horizontal pan does not grow backing surfaces")
            require(visibleCanvases.allSatisfy { canvas in
                native
                    ? abs(canvas.timelineOriginX - canvas.frame.minX) < 1 && canvas.timelineOriginX <= offset + 1
                        && canvas.timelineOriginX + canvas.bounds.width >= offset + scroll.contentView.bounds.width - 1
                    : abs(canvas.timelineOriginX - offset) < 1
            }, "\(suffix) horizontal pan maps native drawing to its document coordinates")
            let bitmap = snapshot(page, path: "\(suffix)-pan-\(Int(offset)).png")
            // Middle of a programme, below titles/metadata and away from the
            // now line. Sampling actual hosted production canvas, not tokens.
            require(close(pixel(bitmap, x: 430, y: 86), expectedSurface), "\(suffix) hosted canvas painted at document x \(offset)")
            if offset == 0 {
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                var extreme = pixel(bitmap, x: 380, y: 68)
                for x in 372..<468 {
                    for y in 61..<79 {
                        let candidate = pixel(bitmap, x: Double(x), y: Double(y))
                        if dark ? luminance(candidate) > luminance(extreme) : luminance(candidate) < luminance(extreme) {
                            extreme = candidate
                        }
                    }
                }
                renderedTitleContrast = contrast(extreme, pixel(bitmap, x: 430, y: 86))
                if opacity == 1 { require(renderedTitleContrast >= 7, "\(suffix) actual programme glyph contrast \(renderedTitleContrast)") }
            }
        }
        if opacity == 1 {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            container.setReferenceDate(now.addingTimeInterval(20_000))
            pump()
            let updatedTime = snapshot(page, path: "\(suffix)-reference-time.png")
            require(close(pixel(updatedTime, x: 430, y: 86), palette.pastSurface),
                    "\(suffix) container time updates reach hosted native canvas without rebuilding rows")
        }
        // Direct non-zero dirty rectangles and explicit Retina-scale bitmap
        // contexts exercise the canvas without repainting its document origin.
        let direct = ProgramBlocksView(frame: CGRect(x: 0, y: 0, width: width, height: 64))
        direct.appearance = appearance
        direct.setReferenceDate(now)
        direct.setBlocks(blocks)
        let portion = snapshot(direct, path: "\(suffix)-partial-rect.png", rect: CGRect(x: 60_030, y: 0, width: 600, height: 64))
        require(close(pixel(portion, x: 100, y: 52), EPGGridStyle.palette(for: appearance).upcomingSurface),
                "\(suffix) partial dirty rect paints only its nonzero document region at 2x")
        window.contentView = nil
        return ["rowOpacity": opacity, "saturation": opacity == 1 ? 1 : 0.4,
                "renderedTitleContrast": renderedTitleContrast]
    }

    static func renderPinnedTitle(appearance: NSAppearance, suffix: String) {
        let view = ProgramBlocksView(frame: CGRect(x: 0, y: 0, width: 780, height: 64))
        view.appearance = appearance
        view.setReferenceDate(now)
        let long = program("Long current programme remains readable", start: -1800, end: 1800)
        view.setBlocks([EPGProgramBlock(program: long, rect: CGRect(x: 0, y: 3, width: 120_000, height: 58), hasReminder: false)])
        for origin in [CGFloat(50_000), 60_000, 90_000] {
            view.setTimelineOriginX(origin)
            let bitmap = snapshot(view, path: "\(suffix)-pinned-title-\(Int(origin)).png")
            let surface = pixel(bitmap, x: 450, y: 52)
            var glyphPixels = 0
            for x in 10..<280 {
                for y in 29..<47 where contrast(pixel(bitmap, x: Double(x), y: Double(y)), surface) >= 4.5 {
                    glyphPixels += 1
                }
            }
            require(glyphPixels > 100, "\(suffix) long programme title remains pinned inside card at archive origin \(origin)")
        }
        // A following intentional gap must remain untouched even when the
        // title of the preceding, partly visible card is much longer.
        view.setBlocks([EPGProgramBlock(program: long, rect: CGRect(x: 0, y: 3, width: 60_060, height: 58), hasReminder: false)])
        view.setTimelineOriginX(60_000)
        let clipped = snapshot(view, path: "\(suffix)-pinned-title-card-edge.png")
        require(pixel(clipped, x: 70, y: 36).alphaComponent < 0.01,
                "\(suffix) pinned title hard-clips at the programme edge before a genuine gap")
    }

    /// CoreText guide labels must render exactly like the NSString drawing
    /// they replaced (fixed line height, truncating tail).
    static func testTextEquivalence() {
        func render(_ draw: (CGContext) -> Void) -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 80, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 3200, bitsPerPixel: 32)!
            let base = NSGraphicsContext(bitmapImageRep: rep)!
            base.cgContext.scaleBy(x: 2, y: 2)
            base.cgContext.translateBy(x: 0, y: 40)
            base.cgContext.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: base.cgContext, flipped: true)
            draw(base.cgContext)
            NSGraphicsContext.current = nil
            return Data(bytes: rep.bitmapData!, count: 3200 * 80)
        }
        func paragraph(_ height: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.alignment = .left
            style.lineBreakMode = .byTruncatingTail
            style.minimumLineHeight = height
            style.maximumLineHeight = height
            return style
        }
        let color = NSColor.labelColor
        let cases: [(EPGTextStyle, String, Bool)] = [
            (.programmeTitle, "Programme with a realistic title", false),
            (.programmeTitle, "No Event Today", false),
            (.timeRange, "9:00pm - 10:30pm", true),
            (.channelName, "BBC One HD", true),
        ]
        for (style, text, usesOptions) in cases {
            let rect = CGRect(x: 10.5, y: 7, width: 300, height: style.lineHeight)
            let attributes: [NSAttributedString.Key: Any] = [.font: style.font, .foregroundColor: color,
                                                             .paragraphStyle: paragraph(style.lineHeight)]
            let reference = render { _ in
                if usesOptions {
                    (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                            attributes: attributes, context: nil)
                } else {
                    (text as NSString).draw(in: rect, withAttributes: attributes)
                }
            }
            let shaped = style.line(text)
            let current = render { context in style.draw(shaped, in: rect, color: color, context: context) }
            require(reference == current, "CoreText label '\(text)' renders identically to NSString drawing")
        }
        // Truncated labels stay inside their rectangle and end with an ellipsis.
        let narrow = render { context in
            EPGTextStyle.programmeTitle.draw(EPGTextStyle.programmeTitle.line("A very long programme title that cannot fit"),
                                             in: CGRect(x: 10, y: 7, width: 80, height: 18), color: .black, context: context)
        }
        var inkBeyond = false
        narrow.withUnsafeBytes { bytes in
            for y in 0..<80 { for x in 182..<800 where bytes[y * 3200 + x * 4 + 3] != 0 { inkBeyond = true } }
        }
        require(!inkBeyond, "truncated CoreText title is clipped to its rectangle")
    }

    static func testSourcePriorityContext() {
        func channel(_ id: Int, name: String? = nil) -> Channel {
            Channel(id: "\(id)", name: name ?? "Channel \(id)", logoURL: nil, group: "Fixture",
                    streamURL: URL(string: "http://127.0.0.1/\(id)")!, epgChannelID: "\(id)")
        }
        let context = EPGVisibleChannelContext()
        let channels = (0..<100).map { channel($0) }
        require(context.candidates(from: channels).count == 24, "unlaid-out viewport has a bounded fallback")
        context.update(Array(channels[40..<48]))
        require(context.candidates(from: channels).map(\.id) == Array(channels[40..<48]).map(\.id), "viewport priority uses current row IDs")
        var updated = channels
        updated[40] = channel(40, name: "Renamed")
        require(context.candidates(from: updated).first?.name == "Renamed", "remembered viewport IDs resolve current metadata")
        require(context.candidates(from: Array(channels.prefix(20))).count == 20, "source/filter replacement falls back to its own bounded channels")
    }

    static func testViewportInteraction() {
        let view = ProgramBlocksView(frame: CGRect(x: 0, y: 0, width: 780, height: 64))
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.setTimelineOriginX(60_000)
        let chosen = program("Visible", start: 0, end: 1800)
        view.setBlocks([
            EPGProgramBlock(program: chosen, rect: CGRect(x: 60_000, y: 3, width: 120, height: 58), hasReminder: false),
            EPGProgramBlock(program: nil, rect: CGRect(x: 60_120, y: 3, width: 120, height: 58), hasReminder: false)
        ])
        var tappedID: String?, tappedRect: CGRect?, emptyTaps = 0, rightClickID: String?
        view.setHandlers(onProgramTap: { tappedID = $0.id; tappedRect = $1 },
                         onEmptyTap: { emptyTaps += 1 },
                         onProgramRightClick: { rightClickID = $0.id; _ = $1; _ = $2 })
        func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: x, y: 20), to: nil),
                               modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        view.mouseDown(with: event(.leftMouseDown, x: 60))
        require(tappedID == chosen.id, "viewport hit-testing resolves the actual document programme")
        require(tappedRect == CGRect(x: 0, y: 3, width: 120, height: 58), "programme popover anchor remains local to viewport")
        view.rightMouseDown(with: event(.rightMouseDown, x: 60))
        require(rightClickID == chosen.id, "context menu resolves document programme after horizontal pan")
        view.mouseDown(with: event(.leftMouseDown, x: 180))
        require(emptyTaps == 1 && tappedID == chosen.id, "gaps retain live-play handling and never manufacture a programme")
        view.setBlocks([EPGProgramBlock(program: chosen, rect: CGRect(x: 0, y: 3, width: 120_000, height: 58), hasReminder: false)])
        view.mouseDown(with: event(.leftMouseDown, x: 60))
        require(tappedID == chosen.id && tappedRect == CGRect(x: 0, y: 3, width: 780, height: 58),
                "long panned programme clicks anchor the popover inside its visible card")
        window.contentView = nil
    }
}
