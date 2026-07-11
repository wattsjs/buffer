import SwiftUI
import AppKit

struct EPGGridView: View {
    let channels: [Channel]
    let hasLoadedOnce: Bool
    var revealChannelID: String? = nil
    var catchupLookback: CatchupLookbackSetting = .default
    let guideVersion: Int
    let programsProvider: (Channel) -> [EPGProgram]
    /// Optional ranged provider backed by pre-buckets in VM. When present, rowData + ProgramRow receive
    /// only programs intersecting the current timeline window (makes buildRowData/buildBlocks allocation-free for the window).
    var rangedProgramsProvider: ((Channel, Date, Date) -> [EPGProgram])? = nil
    var onCatchupGuideNeeded: (([Channel]) -> Void)? = nil
    let isFavorite: (Channel) -> Bool
    let onToggleFavorite: (Channel) -> Void
    let onChannelSelected: (Channel) -> Void

    @Environment(\.activePlaylistID) private var activePlaylistID: UUID?

    @State private var timelineAnchor = Date()
    @State private var timelineResetID = 0
    @State private var scrollToCurrentID = 0

    // Lightweight "now" ticker (Agent 02 + 09). Updates every 20 s so the red
    // live line and "LIVE" badges stay accurate without relying
    // on incidental re-renders from syncs or user actions.
    @State private var now = Date()
    @State private var nowTicker: Task<Void, Never>? = nil

    private let channelColumnWidth: CGFloat = 120
    private let rowHeight: CGFloat = 64
    private let pixelsPerMinute: CGFloat = 4
    private let headerHeight: CGFloat = 32
    private let minimumPastTimelineHours = 1
    private let liveFutureTimelineHours = 11
    private let maximumCatchupTimelineHours = 14 * 24

    private func timelineHours(timelineStart: Date, timelineEnd: Date) -> Int {
        max(1, Int(ceil(timelineEnd.timeIntervalSince(timelineStart) / 3600)))
    }

    private func timelineWidth(hours: Int) -> CGFloat {
        CGFloat(hours * 60) * pixelsPerMinute
    }

    private func timelineBounds(for channels: [Channel], anchor: Date) -> (start: Date, end: Date) {
        let anchorHour = Calendar.current.dateInterval(of: .hour, for: anchor)?.start ?? anchor
        let end = anchorHour.addingTimeInterval(Double(liveFutureTimelineHours) * 3600)

        guard let archiveStart = archiveStart(for: channels, now: anchor) else {
            return (anchorHour.addingTimeInterval(-Double(minimumPastTimelineHours) * 3600), end)
        }

        let archiveHour = Calendar.current.dateInterval(of: .hour, for: archiveStart)?.start ?? archiveStart
        let cappedStart = anchorHour.addingTimeInterval(-Double(maximumCatchupTimelineHours) * 3600)
        return (max(archiveHour, cappedStart), end)
    }

    // MARK: - Live "now" ticker (Agent 02/09)

    private func startNowTicker() {
        guard nowTicker == nil else { return }
        now = Date()
        nowTicker = Task { @MainActor in
            while !Task.isCancelled {
                if AppLifecycleCoordinator.shared.shouldPauseBackgroundWork {
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
                try? await Task.sleep(for: .seconds(20))
                now = Date()
            }
        }
    }

    private func stopNowTicker() {
        nowTicker?.cancel()
        nowTicker = nil
    }

    private func initialTimelineOffset(timelineStart: Date, now: Date) -> CGFloat {
        let target = now.addingTimeInterval(-Double(minimumPastTimelineHours) * 3600)
        return CGFloat(max(0, target.timeIntervalSince(timelineStart) / 60)) * pixelsPerMinute
    }

    private func timelineIdentity(for channels: [Channel], resetID: Int) -> AnyHashable {
        AnyHashable("\(channels.map(\.id).joined(separator: "\u{1F}"))|\(resetID)")
    }

    private func resetTimelineWindow(for channels: [Channel], now currentNow: Date) {
        now = currentNow
        timelineAnchor = currentNow
        scrollToCurrentID = 0
        timelineResetID += 1
    }

    private func resetToCurrentTimeline() {
        let currentNow = Date()
        now = currentNow
        timelineAnchor = currentNow
        timelineResetID += 1
        scrollToCurrentID += 1
    }

    /// Earliest wall-clock moment the timeline can reach for these channels.
    /// Derived ONLY from channel catchup metadata and the lookback setting so
    /// it is deterministic for a fixed anchor: loaded guide data must never
    /// move the document origin between hard resets, or content would shift
    /// under the user's scroll position.
    private func archiveStart(for channels: [Channel], now currentNow: Date) -> Date? {
        guard let channelArchiveStart = channels
            .compactMap({ $0.archiveWindow(now: currentNow)?.start })
            .min() else { return nil }

        guard let limitHours = catchupLookback.limitHours else { return channelArchiveStart }
        return max(channelArchiveStart, currentNow.addingTimeInterval(-Double(limitHours) * 3600))
    }



    private func requestCatchupGuideIfNeeded(for channels: [Channel]) {
        guard channels.contains(where: \.supportsRewind) else { return }
        onCatchupGuideNeeded?(channels)
    }

    private func makeNowX(now: Date, timelineStart: Date, timelineWidth: CGFloat) -> CGFloat? {
        let offset = now.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute)
        guard offset > 0, offset < Double(timelineWidth) else { return nil }
        return CGFloat(offset)
    }

    private func timeSlots(from timelineStart: Date, timelineHours: Int) -> [Date] {
        (0..<(timelineHours * 2)).map { i in
            timelineStart.addingTimeInterval(Double(i) * 30 * 60)
        }
    }

    private static func timelineTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    private static func headerTime(_ date: Date, relativeTo now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    var body: some View {
        if channels.isEmpty && hasLoadedOnce {
            ContentUnavailableView(
                "No Channels",
                systemImage: "tv",
                description: Text("Add a server in Settings to load channels.")
            )
        } else if !channels.isEmpty {
            // Use the ticker-driven `now` (updated every ~20 s) instead of a fresh
            // Date() on every body evaluation. This makes the live line and badges
            // accurate and smooth while avoiding full grid rebuilds on every tick.
            let now = self.now
            let timelineAnchor = self.timelineAnchor
            let bounds = timelineBounds(for: channels, anchor: timelineAnchor)
            let timelineStart = bounds.start
            let timelineEnd = bounds.end
            let timelineHours = timelineHours(timelineStart: timelineStart, timelineEnd: timelineEnd)
            let width = timelineWidth(hours: timelineHours)
            let nowX = makeNowX(now: now, timelineStart: timelineStart, timelineWidth: width)

            EPGScrollGrid(
                items: channels,
                rowHeight: rowHeight,
                channelColumnWidth: channelColumnWidth,
                programRowWidth: width,
                headerHeight: headerHeight,
                nowLineX: nowX,
                initialHorizontalOffset: initialTimelineOffset(timelineStart: timelineStart, now: now),
                horizontalScrollRequest: scrollToCurrentID > 0
                    ? HorizontalScrollRequest(
                        id: scrollToCurrentID,
                        targetX: initialTimelineOffset(timelineStart: timelineStart, now: now)
                    )
                    : nil,
                timelineIdentity: timelineIdentity(for: channels, resetID: timelineResetID),
                dataVersion: AnyHashable(guideVersion),
                timeStripSlots: timeSlots(from: timelineStart, timelineHours: timelineHours).map {
                    TimeStripSlot(x: CGFloat($0.timeIntervalSince(timelineStart) / 60) * pixelsPerMinute, title: Self.headerTime($0, relativeTo: now))
                },
                timeStripSlotWidth: 30 * pixelsPerMinute,
                channelNameProvider: { $0.name },
                rowDataProvider: { [programsProvider, rangedProgramsProvider, timelineStart, timelineEnd = timelineEnd, pixelsPerMinute, timelineHours] channel in
                    let progs = rangedProgramsProvider?(channel, timelineStart, timelineEnd) ?? programsProvider(channel)
                    return Self.buildRowData(
                        channel: channel,
                        programs: progs,
                        timelineStart: timelineStart,
                        pixelsPerMinute: pixelsPerMinute,
                        timelineHours: timelineHours,
                        rowHeight: rowHeight,
                        showGuideGaps: channel.supportsRewind
                    )
                },
                revealItemID: revealChannelID.map { AnyHashable($0) },
                channelContent: { channel in
                    ChannelCell(
                        channel: channel,
                        width: channelColumnWidth,
                        height: rowHeight,
                        isFavorite: isFavorite(channel),
                        onTap: { onChannelSelected(channel) },
                        onToggleFavorite: { onToggleFavorite(channel) }
                    )
                    .id(channel.id)
                    .fadeIfStreamDead(channelID: channel.id)
                },
                programContent: { [programsProvider, rangedProgramsProvider, timelineStart, timelineEnd = timelineEnd] channel in
                    let progs = rangedProgramsProvider?(channel, timelineStart, timelineEnd) ?? programsProvider(channel)
                    return ProgramRow(
                        channel: channel,
                        programs: progs,
                        fallbackTitle: channel.name,
                        timelineStart: timelineStart,
                        timelineWidth: width,
                        pixelsPerMinute: pixelsPerMinute,
                        rowHeight: rowHeight,
                        showGuideGaps: channel.supportsRewind,
                        onPlay: { onChannelSelected(channel) },
                        playlistID: activePlaylistID
                    )
                    .frame(width: width, height: rowHeight)
                    .overlay(alignment: .bottom) {
                        Divider().opacity(0.5)
                    }
                    .fadeIfStreamDead(channelID: channel.id)
                },
                cornerContent: { cornerLabel }
            )
            .bufferPageBackground()
            .onChange(of: channels.map(\.id)) { _, _ in
                resetTimelineWindow(for: channels, now: Date())
                requestCatchupGuideIfNeeded(for: channels)
            }
            .onChange(of: catchupLookback) { _, _ in
                resetTimelineWindow(for: channels, now: Date())
                requestCatchupGuideIfNeeded(for: channels)
            }
            .onAppear {
                startNowTicker()
                requestCatchupGuideIfNeeded(for: channels)
            }
            .onDisappear { stopNowTicker() }
        }
    }

    private static func buildRowData(
        channel: Channel,
        programs: [EPGProgram],
        timelineStart: Date,
        pixelsPerMinute: CGFloat,
        timelineHours: Int,
        rowHeight: CGFloat,
        showGuideGaps: Bool
    ) -> ChannelLabelRowData {
        let timelineWidth = CGFloat(timelineHours * 60) * pixelsPerMinute
        let end = timelineStart.addingTimeInterval(Double(timelineWidth / pixelsPerMinute) * 60)

        let sorted = programs
            .filter { $0.end > timelineStart && $0.start < end }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        var blocks: [ChannelLabelBlockData] = []
        var cursor = timelineStart

        func appendGap(until gapEnd: Date) {
            guard gapEnd > cursor else { return }
            let startX = max(0, cursor.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
            let endX = min(Double(timelineWidth), gapEnd.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
            let width = endX - startX
            guard width > 2 else { return }
            blocks.append(ChannelLabelBlockData(
                rect: CGRect(x: startX, y: 3, width: width, height: Double(rowHeight) - 6),
                timeRange: nil
            ))
        }

        for p in sorted {
            if showGuideGaps {
                appendGap(until: p.start)
            }
            let effectiveStart = max(p.start, cursor)
            guard p.end > effectiveStart else { continue }
            let startX = max(0, effectiveStart.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
            let endX = min(Double(timelineWidth), p.end.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
            let width = endX - startX
            guard width > 2 else { continue }
            blocks.append(ChannelLabelBlockData(
                rect: CGRect(x: startX, y: 3, width: width, height: Double(rowHeight) - 6),
                timeRange: "\(Self.timelineTime(p.start)) - \(Self.timelineTime(p.end))"
            ))
            cursor = p.end
        }

        if showGuideGaps && !sorted.isEmpty {
            appendGap(until: end)
        }

        return ChannelLabelRowData(channelName: channel.name, blocks: blocks)
    }


    private var cornerLabel: some View {
        HStack(spacing: 6) {
            Text("TV Guide")
                .font(BufferFont.cardTitle)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Button {
                resetToCurrentTimeline()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(BufferFont.captionSemibold)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Scroll to current time")
        }
        .padding(.horizontal, 12)
        .frame(width: channelColumnWidth, height: headerHeight, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Channel cell

private struct ChannelCell: View {
    let channel: Channel
    let width: CGFloat
    let height: CGFloat
    let isFavorite: Bool
    let onTap: () -> Void
    let onToggleFavorite: () -> Void

    @State private var bgColor: Color

    init(
        channel: Channel,
        width: CGFloat,
        height: CGFloat,
        isFavorite: Bool,
        onTap: @escaping () -> Void,
        onToggleFavorite: @escaping () -> Void
    ) {
        self.channel = channel
        self.width = width
        self.height = height
        self.isFavorite = isFavorite
        self.onTap = onTap
        self.onToggleFavorite = onToggleFavorite
        if let url = channel.logoURL, let cached = LogoColorAnalyzer.cachedColor(for: url) {
            _bgColor = State(initialValue: Color(nsColor: cached))
        } else {
            _bgColor = State(initialValue: Color(nsColor: .textBackgroundColor))
        }
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(bgColor)
                ChannelLogoView(url: channel.logoURL, contentInset: 5) { color in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        bgColor = Color(nsColor: color)
                    }
                }
                .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(BufferFont.tinyBold)
                        .foregroundStyle(.yellow)
                        .padding(3)
                        .background(Circle().fill(.black.opacity(0.35)))
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if channel.supportsRewind {
                    Image(systemName: "gobackward")
                        .font(BufferFont.tinyBold)
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(.black.opacity(0.4)))
                        .padding(6)
                        .help("Rewind available")
                }
            }
            .overlay(alignment: .bottomLeading) {
                StreamProbeBadge(channelID: channel.id, style: .compact)
                    .padding(6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(channel.name)
        .requestStreamProbe(for: channel)
        .contextMenu {
            Button(action: onToggleFavorite) {
                Label(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "star.slash" : "star"
                )
            }
            Button(action: onTap) {
                Label("Play Channel", systemImage: "play.fill")
            }
            AddToMultiViewMenuItem(channel: channel)
        }
    }
}

// MARK: - Program row

private struct ProgramRow: View {
    let channel: Channel
    let programs: [EPGProgram]
    let fallbackTitle: String
    let timelineStart: Date
    let timelineWidth: CGFloat
    let pixelsPerMinute: CGFloat
    let rowHeight: CGFloat
    let showGuideGaps: Bool
    let onPlay: () -> Void

    @State private var selectedProgram: EPGProgram?
    @State private var selectedRect: CGRect = .zero

    let playlistID: UUID?

    private var reminderProgramIDs: Set<String> {
        guard let playlistID else { return [] }
        let ids = Set(programs.map(\.id))
        return Set(
            NotificationManager.shared.reminders
                .lazy
                .filter { $0.playlistID == playlistID && ids.contains($0.programID) }
                .map(\.programID)
        )
    }

    var body: some View {
        ProgramCanvasLayer(
            programs: programs,
            fallbackTitle: fallbackTitle,
            timelineStart: timelineStart,
            timelineWidth: timelineWidth,
            pixelsPerMinute: pixelsPerMinute,
            rowHeight: rowHeight,
            showGuideGaps: showGuideGaps,
            reminderProgramIDs: reminderProgramIDs,
            onProgramTap: { program, rect in
                selectedRect = rect
                selectedProgram = program
            },
            onEmptyTap: onPlay,
            onProgramRightClick: { program, event, view in
                if let playlistID {
                    ReminderMenuBuilder.present(
                        playlistID: playlistID,
                        program: program,
                        channel: channel,
                        event: event,
                        in: view,
                        onPlay: onPlay
                    )
                }
            }
        )
        .equatable()
        .popover(
            isPresented: Binding(
                get: { selectedProgram != nil },
                set: { if !$0 { selectedProgram = nil } }
            ),
            attachmentAnchor: .rect(.rect(selectedRect)),
            arrowEdge: .top
        ) {
            if let program = selectedProgram {
                ProgramDetailPopover(
                    program: program,
                    channel: channel,
                    onPlay: {
                        selectedProgram = nil
                        onPlay()
                    }
                )
            }
        }
    }
}

// MARK: - AppKit program block layer (tiled drawing for full-archive widths)

private struct ProgramCanvasLayer: View, Equatable {
    let programs: [EPGProgram]
    let fallbackTitle: String
    let timelineStart: Date
    let timelineWidth: CGFloat
    let pixelsPerMinute: CGFloat
    let rowHeight: CGFloat
    let showGuideGaps: Bool
    let reminderProgramIDs: Set<String>
    let onProgramTap: (EPGProgram, CGRect) -> Void
    let onEmptyTap: () -> Void
    let onProgramRightClick: (EPGProgram, NSEvent, NSView) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.timelineStart == rhs.timelineStart,
              lhs.timelineWidth == rhs.timelineWidth,
              lhs.pixelsPerMinute == rhs.pixelsPerMinute,
              lhs.rowHeight == rhs.rowHeight,
              lhs.showGuideGaps == rhs.showGuideGaps,
              lhs.fallbackTitle == rhs.fallbackTitle,
              lhs.reminderProgramIDs == rhs.reminderProgramIDs,
              lhs.programs.count == rhs.programs.count else { return false }
        for (a, b) in zip(lhs.programs, rhs.programs) {
            if a.id != b.id || a.start != b.start || a.end != b.end || a.title != b.title { return false }
        }
        return true
    }

    fileprivate struct Block {
        let program: EPGProgram?
        let rect: CGRect
        let hasReminder: Bool
    }

    private func buildBlocks() -> [Block] {
        let end = timelineStart.addingTimeInterval(Double(timelineWidth / pixelsPerMinute) * 60)

        let sorted = programs
            .filter { $0.end > timelineStart && $0.start < end }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        var blocks: [Block] = []
        var cursor: Date = timelineStart

        func appendGap(until gapEnd: Date) {
            guard gapEnd > cursor else { return }
            let startX = max(0, cursor.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
            let endX = min(Double(timelineWidth), gapEnd.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
            let width = endX - startX
            guard width > 2 else { return }
            blocks.append(
                Block(
                    program: nil,
                    rect: CGRect(x: startX, y: 3, width: width, height: Double(rowHeight) - 6),
                    hasReminder: false
                )
            )
        }

        for p in sorted {
            if showGuideGaps {
                appendGap(until: p.start)
            }
            let effectiveStart = max(p.start, cursor)
            guard p.end > effectiveStart else { continue }

            let startX = max(0, effectiveStart.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
            let endX = min(Double(timelineWidth), p.end.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
            let width = endX - startX
            guard width > 2 else { continue }

            blocks.append(
                Block(
                    program: p,
                    rect: CGRect(x: startX, y: 3, width: width, height: Double(rowHeight) - 6),
                    hasReminder: reminderProgramIDs.contains(p.id)
                )
            )
            cursor = p.end
        }

        if showGuideGaps && !sorted.isEmpty {
            appendGap(until: end)
        }

        return blocks
    }

    var body: some View {
        ProgramBlocksRepresentable(
            blocks: buildBlocks(),
            onProgramTap: onProgramTap,
            onEmptyTap: onEmptyTap,
            onProgramRightClick: onProgramRightClick
        )
    }
}

private struct ProgramBlocksRepresentable: NSViewRepresentable {
    let blocks: [ProgramCanvasLayer.Block]
    let onProgramTap: (EPGProgram, CGRect) -> Void
    let onEmptyTap: () -> Void
    let onProgramRightClick: (EPGProgram, NSEvent, NSView) -> Void

    func makeNSView(context: Context) -> ProgramBlocksView {
        let view = ProgramBlocksView()
        view.setHandlers(
            onProgramTap: onProgramTap,
            onEmptyTap: onEmptyTap,
            onProgramRightClick: onProgramRightClick
        )
        view.setBlocks(blocks)
        return view
    }

    func updateNSView(_ view: ProgramBlocksView, context: Context) {
        view.setHandlers(
            onProgramTap: onProgramTap,
            onEmptyTap: onEmptyTap,
            onProgramRightClick: onProgramRightClick
        )
        view.setBlocks(blocks)
    }
}

private final class ProgramBlocksView: NSView {
    private var blocks: [ProgramCanvasLayer.Block] = []
    private var onProgramTap: ((EPGProgram, CGRect) -> Void)?
    private var onEmptyTap: (() -> Void)?
    private var onProgramRightClick: ((EPGProgram, NSEvent, NSView) -> Void)?

    override var isFlipped: Bool { true }

    func setHandlers(
        onProgramTap: @escaping (EPGProgram, CGRect) -> Void,
        onEmptyTap: @escaping () -> Void,
        onProgramRightClick: @escaping (EPGProgram, NSEvent, NSView) -> Void
    ) {
        self.onProgramTap = onProgramTap
        self.onEmptyTap = onEmptyTap
        self.onProgramRightClick = onProgramRightClick
    }

    func setBlocks(_ blocks: [ProgramCanvasLayer.Block]) {
        self.blocks = blocks
        needsDisplay = true
    }

    private static let bellImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            .applying(.init(paletteColors: [.systemOrange]))
        return NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }()

    private static func blockFillColor(for block: ProgramCanvasLayer.Block) -> NSColor {
        block.program == nil
            ? NSColor(calibratedWhite: 0.46, alpha: 0.90)
            : NSColor(calibratedWhite: 0.86, alpha: 1)
    }

    private static let blockStrokeColor = NSColor(calibratedWhite: 0.72, alpha: 0.55)
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
        let strokeColor = Self.blockStrokeColor

        for block in blocks {
            guard block.program != nil else { continue }
            guard block.rect.intersects(dirtyRect) else { continue }
            let inset = block.rect.insetBy(dx: 1, dy: 0)
            let path = NSBezierPath(roundedRect: inset, xRadius: 3, yRadius: 3)
            Self.blockFillColor(for: block).setFill()
            path.fill()
            strokeColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()

            guard let program = block.program else { continue }
            NSGraphicsContext.saveGraphicsState()
            path.addClip()

            // Title lives only here (canvas), never in the sticky overlay.
            // Coordinates are block-local so the title scrolls with its card
            // and hard-clips at both block edges via path.addClip() above.
            let title = program.title.isEmpty ? "No Event Today" : program.title
            let titleX = inset.minX + EPGStickyLabelMetrics.x
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
                        .foregroundColor: NSColor(calibratedWhite: 0.04, alpha: 1),
                        .paragraphStyle: Self.titleParagraph,
                    ]
                )
            }

            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let block = blocks.first(where: { $0.rect.contains(location) }), let program = block.program {
            onProgramTap?(program, block.rect)
        } else {
            onEmptyTap?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let block = blocks.first(where: { $0.rect.contains(location) }), let program = block.program else { return }
        onProgramRightClick?(program, event, self)
    }
}

// MARK: - Program detail popover

struct ProgramDetailPopover: View {
    let program: EPGProgram
    let channel: Channel
    let onPlay: () -> Void

    @State private var notificationManager = NotificationManager.shared
    @State private var recordingManager = RecordingManager.shared
    @Environment(\.activePlaylistID) private var activePlaylistID: UUID?

    private var timeRange: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return "\(formatter.string(from: program.start)) – \(formatter.string(from: program.end))"
    }

    private var durationText: String {
        let minutes = Int(program.duration / 60)
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(minutes)m"
    }

    private var canRemind: Bool {
        program.end > Date()
    }

    /// True when the program has ended or is in progress AND the channel
    /// exposes a catchup window that still covers its start time.
    private var canPlayFromCatchup: Bool {
        guard let days = channel.catchup?.days, days > 0 else { return false }
        let windowStart = Date().addingTimeInterval(-Double(days) * 86400)
        return program.start >= windowStart && program.start < Date()
    }

    private var existingReminder: ProgramReminder? {
        guard let playlistID = activePlaylistID else { return nil }
        return notificationManager.reminder(playlistID: playlistID, for: program)
    }

    private var existingRecording: Recording? {
        recordingManager.recordings.first { rec in
            rec.programID == program.id
                && rec.channelID == channel.id
                && (rec.status == .scheduled || rec.status == .recording || rec.status == .startingUp)
        }
    }

    private var canRecord: Bool { program.end > Date() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(program.title.isEmpty ? "No Event" : program.title)
                        .font(BufferFont.title)
                        .lineLimit(2)
                    if program.isNowPlaying {
                        HStack(spacing: 4) {
                            LiveIndicatorDot(size: 5)
                            Text("LIVE")
                                .font(BufferFont.tinyBold)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red, in: Capsule())
                    }
                    if existingReminder != nil {
                        Image(systemName: "bell.fill")
                            .font(BufferFont.microBadge)
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(timeRange) · \(durationText)")
                    .font(BufferFont.caption)
                    .foregroundStyle(.secondary)
            }

            if !program.description.isEmpty {
                Text(program.description)
                    .font(BufferFont.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if canPlayFromCatchup {
                    Button {
                        PendingCatchup.set(
                            channelID: channel.id,
                            start: program.start,
                            duration: program.duration
                        )
                        onPlay()
                    } label: {
                        Label("Play from start", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .help("Play this program from its start via catchup")
                } else {
                    Button(action: onPlay) {
                        Label("Play Channel", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }

                if canRemind {
                    reminderButton
                }

                if canRecord {
                    recordButton
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    @ViewBuilder
    private var recordButton: some View {
        if let existing = existingRecording {
            let isRec = existing.status == .recording || existing.status == .startingUp
            Button {
                recordingManager.cancel(id: existing.id)
            } label: {
                Image(systemName: isRec ? "stop.circle.fill" : "record.circle.fill")
                    .font(BufferFont.iconLarge)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .tint(.red)
            .help(isRec ? "Stop recording" : "Cancel scheduled recording")
        } else {
            Button {
                scheduleRecording()
            } label: {
                Image(systemName: "record.circle")
                    .font(BufferFont.iconLarge)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .help("Record this program")
        }
    }

    private func scheduleRecording() {
        guard let playlistID = activePlaylistID else { return }
        _ = recordingManager.schedule(
            playlistID: playlistID,
            channel: channel,
            program: program
        )
    }

    @ViewBuilder
    private var reminderButton: some View {
        if let existing = existingReminder {
            Button {
                if let playlistID = activePlaylistID {
                    notificationManager.cancelReminder(playlistID: playlistID, for: program)
                }
            } label: {
                Label("Cancel", systemImage: "bell.slash")
            }
            .controlSize(.large)
            .help("Cancel reminder set for \(existing.notifyAt, format: .dateTime.hour().minute())")
        } else {
            Menu {
                Button("At start") { scheduleReminder(lead: 0) }
                Button("5 min before") { scheduleReminder(lead: 5) }
                Button("15 min before") { scheduleReminder(lead: 15) }
                Button("1 hour before") { scheduleReminder(lead: 60) }
            } label: {
                Label("Remind Me", systemImage: "bell")
            } primaryAction: {
                scheduleReminder(lead: 5)
            }
            .menuStyle(.borderedButton)
            .controlSize(.large)
            .help("Get a notification before this program starts")
        }
    }

    private func scheduleReminder(lead: Int) {
        guard let playlistID = activePlaylistID else { return }
        Task { @MainActor in
            let scheduled = await notificationManager.scheduleReminder(
                playlistID: playlistID,
                program: program,
                channel: channel,
                leadMinutes: lead
            )
            AppFeedbackCenter.shared.showReminderResult(
                playlistID: playlistID,
                program: program,
                channel: channel,
                leadMinutes: lead,
                scheduled: scheduled
            )
        }
    }
}
