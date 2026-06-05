import SwiftUI

struct EPGGridView: View {
    let channels: [Channel]
    let hasLoadedOnce: Bool
    var revealChannelID: String? = nil
    var catchupLookback: CatchupLookbackSetting = .default
    let programsProvider: (Channel) -> [EPGProgram]
    /// Optional ranged provider backed by pre-buckets in VM. When present, rowData + ProgramRow receive
    /// only programs intersecting the current timeline window (makes buildRowData/buildBlocks allocation-free for the window).
    var rangedProgramsProvider: ((Channel, Date, Date) -> [EPGProgram])? = nil
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
    private let futureTimelineHours = 11

    private func timelineHours(timelineStart: Date, timelineEnd: Date) -> Int {
        max(1, Int(ceil(timelineEnd.timeIntervalSince(timelineStart) / 3600)))
    }

    private func timelineWidth(hours: Int) -> CGFloat {
        CGFloat(hours * 60) * pixelsPerMinute
    }

    private func pastTimelineHours(for channels: [Channel]) -> Int {
        guard channels.contains(where: \.supportsRewind) else { return minimumPastTimelineHours }
        return maxPastTimelineHours(for: channels, now: timelineAnchor)
    }

    private func maxPastTimelineHours(for channels: [Channel], now: Date) -> Int {
        let availableHours = availablePastTimelineHours(for: channels, now: now)
        guard let limitHours = catchupLookback.limitHours else { return availableHours }
        return min(availableHours, limitHours)
    }

    private func availablePastTimelineHours(for channels: [Channel], now: Date) -> Int {
        let earliest = earliestCatchupTimelineStart(for: channels, now: now)
        guard let earliest else { return minimumPastTimelineHours }
        let hours = Int(ceil(now.timeIntervalSince(earliest) / 3600))
        return max(minimumPastTimelineHours, hours)
    }

    private func earliestCatchupTimelineStart(for channels: [Channel], now: Date) -> Date? {
        channels
            .compactMap { channel -> Date? in
                guard let days = channel.catchup?.days, days > 0 else { return nil }
                let catchupStart = now.addingTimeInterval(-Double(days) * 86400)
                return programsProvider(channel)
                    .lazy
                    .filter { $0.start < now && $0.end > catchupStart }
                    .map { max($0.start, catchupStart) }
                    .min()
            }
            .min()
            .map { floorToHalfHour($0) }
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

    private func makeTimelineStart(from now: Date, pastHours: Int, channels: [Channel]) -> Date {
        let cal = Calendar.current
        let currentHour = cal.dateInterval(of: .hour, for: now)?.start ?? now
        let requested = currentHour.addingTimeInterval(-Double(pastHours) * 60 * 60)
        guard let earliest = earliestCatchupTimelineStart(for: channels, now: now) else { return requested }
        return max(requested, earliest)
    }

    private func makeTimelineEnd(from now: Date) -> Date {
        let cal = Calendar.current
        let currentHour = cal.dateInterval(of: .hour, for: now)?.start ?? now
        return currentHour.addingTimeInterval(Double(futureTimelineHours) * 3600)
    }

    private func floorToHalfHour(_ date: Date) -> Date {
        let cal = Calendar.current
        let hourStart = cal.dateInterval(of: .hour, for: date)?.start ?? date
        let minute = cal.component(.minute, from: date)
        return hourStart.addingTimeInterval(minute >= 30 ? 30 * 60 : 0)
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
            let pastHours = pastTimelineHours(for: channels)
            let timelineStart = makeTimelineStart(from: timelineAnchor, pastHours: pastHours, channels: channels)
            let timelineEnd = makeTimelineEnd(from: timelineAnchor)
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
                headerContent: { timeStrip(timelineStart: timelineStart, timelineHours: timelineHours, now: now) },
                cornerContent: { cornerLabel }
            )
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: channels.map(\.id)) { _, _ in
                resetTimelineWindow(for: channels, now: Date())
            }
            .onChange(of: catchupLookback) { _, _ in
                resetTimelineWindow(for: channels, now: Date())
            }
            .onAppear {
                startNowTicker()
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

        var blocks: [(rect: CGRect, timeRange: String?)] = []
        var cursor = timelineStart

        func appendGap(until gapEnd: Date) {
            guard gapEnd > cursor else { return }
            let startX = max(0, cursor.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
            let endX = min(Double(timelineWidth), gapEnd.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
            let width = endX - startX
            guard width > 2 else { return }
            blocks.append((
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
            blocks.append((
                rect: CGRect(x: startX, y: 3, width: width, height: Double(rowHeight) - 6),
                timeRange: "\(Self.timelineTime(p.start)) - \(Self.timelineTime(p.end))"
            ))
            cursor = p.end
        }

        if showGuideGaps {
            appendGap(until: end)
        }

        if blocks.isEmpty {
            blocks.append((
                rect: CGRect(x: 0, y: 3, width: timelineWidth, height: rowHeight - 6),
                timeRange: nil
            ))
        }

        return ChannelLabelRowData(channelName: channel.name, blocks: blocks)
    }

    private func timeStrip(timelineStart: Date, timelineHours: Int, now: Date) -> some View {
        HStack(spacing: 0) {
            ForEach(timeSlots(from: timelineStart, timelineHours: timelineHours), id: \.self) { time in
                Text(Self.headerTime(time, relativeTo: now))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 30 * pixelsPerMinute, alignment: .leading)
                    .padding(.leading, 6)
            }
        }
        .frame(width: timelineWidth(hours: timelineHours), height: headerHeight, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var cornerLabel: some View {
        HStack(spacing: 6) {
            Text("TV Guide")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Button {
                scrollToCurrentID += 1
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
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
                ChannelLogoView(url: channel.logoURL) { color in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        bgColor = Color(nsColor: color)
                    }
                }
                .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.yellow)
                        .padding(3)
                        .background(Circle().fill(.black.opacity(0.35)))
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if channel.supportsRewind {
                    Image(systemName: "gobackward")
                        .font(.system(size: 9, weight: .bold))
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

// MARK: - Program row (Canvas-rendered)

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

// MARK: - Canvas layer (isolated from selection state for snappy popover response)

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
            if a.id != b.id || a.start != b.start || a.end != b.end { return false }
        }
        return true
    }

    fileprivate struct Block {
        let program: EPGProgram?
        let rect: CGRect
        let title: String
        let timeRange: String?
        let hasReminder: Bool
        let isFallback: Bool
    }

    private static func timelineTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
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
                    title: "No guide data",
                    timeRange: nil,
                    hasReminder: false,
                    isFallback: true
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
                    title: p.title.isEmpty ? "No Event Today" : p.title,
                    timeRange: "\(Self.timelineTime(p.start)) - \(Self.timelineTime(p.end))",
                    hasReminder: reminderProgramIDs.contains(p.id),
                    isFallback: false
                )
            )
            cursor = p.end
        }

        if showGuideGaps {
            appendGap(until: end)
        }

        if blocks.isEmpty {
            let title = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                blocks.append(
                    Block(
                        program: nil,
                        rect: CGRect(x: 0, y: 3, width: timelineWidth, height: rowHeight - 6),
                        title: title,
                        timeRange: nil,
                        hasReminder: false,
                        isFallback: true
                    )
                )
            }
        }

        return blocks
    }

    var body: some View {
        let blocks = buildBlocks()
        let fill = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
        let border = Color(nsColor: .separatorColor)
        let textPrimary = Color.primary
        let textSecondary = Color.secondary

        Canvas { context, _ in
            for block in blocks {
                let inset = block.rect.insetBy(dx: 1, dy: 0)
                let path = Path(roundedRect: inset, cornerRadius: 3)
                context.fill(path, with: .color(fill))
                context.stroke(path, with: .color(border), lineWidth: 0.5)

                let textRect = inset.insetBy(dx: 9, dy: 5)
                guard textRect.width > 10 else { continue }

                let titleText = Text(block.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(textPrimary)

                let resolvedTitle = context.resolve(titleText)
                let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                let titleSize = resolvedTitle.measure(in: unbounded)
                let resolvedTime = block.timeRange.map {
                    context.resolve(
                        Text($0)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(textSecondary)
                    )
                }
                let timeSize = resolvedTime?.measure(in: unbounded) ?? .zero

                context.drawLayer { layer in
                    layer.clip(to: Path(inset))

                    if let resolvedTime {
                        let lineGap: CGFloat = 2
                        let groupHeight = timeSize.height + lineGap + titleSize.height
                        let groupY = max(textRect.minY, inset.midY - groupHeight / 2)
                        layer.draw(
                            resolvedTime,
                            in: CGRect(
                                x: textRect.minX,
                                y: groupY,
                                width: textRect.width,
                                height: timeSize.height
                            )
                        )
                        layer.draw(
                            resolvedTitle,
                            in: CGRect(
                                x: textRect.minX,
                                y: groupY + timeSize.height + lineGap,
                                width: textRect.width,
                                height: titleSize.height
                            )
                        )
                    } else {
                        let titleOriginY = inset.midY - titleSize.height / 2
                        layer.draw(
                            resolvedTitle,
                            in: CGRect(
                                x: textRect.minX,
                                y: titleOriginY,
                                width: textRect.width,
                                height: titleSize.height
                            )
                        )
                    }

                    if block.hasReminder {
                        let bellText = Text(Image(systemName: "bell.fill"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.orange)
                        let resolvedBell = context.resolve(bellText)
                        let bellSize = resolvedBell.measure(in: unbounded)
                        let bellOrigin = CGPoint(
                            x: inset.maxX - bellSize.width - 5,
                            y: inset.minY + 5
                        )
                        layer.draw(resolvedBell, at: bellOrigin, anchor: .topLeading)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            if let block = blocks.first(where: { $0.rect.contains(location) }) {
                if let program = block.program {
                    onProgramTap(program, block.rect)
                } else {
                    onEmptyTap()
                }
            } else {
                onEmptyTap()
            }
        }
        .overlay(
            RightClickCatcher { location, event, view in
                if let block = blocks.first(where: { $0.rect.contains(location) }),
                   let program = block.program {
                    onProgramRightClick(program, event, view)
                }
            }
        )
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
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    if program.isNowPlaying {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red, in: Capsule())
                    }
                    if existingReminder != nil {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(timeRange) · \(durationText)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if !program.description.isEmpty {
                Text(program.description)
                    .font(.system(size: 12))
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
                    .font(.system(size: 18))
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
                    .font(.system(size: 18))
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
