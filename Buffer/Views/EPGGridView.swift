import SwiftUI

struct EPGGridView: View {
    let channels: [Channel]
    let hasLoadedOnce: Bool
    var revealChannelID: String? = nil
    let programsProvider: (Channel) -> [EPGProgram]
    let isFavorite: (Channel) -> Bool
    let onToggleFavorite: (Channel) -> Void
    let onChannelSelected: (Channel) -> Void

    private let channelColumnWidth: CGFloat = 120
    private let rowHeight: CGFloat = 64
    private let pixelsPerMinute: CGFloat = 4
    private let headerHeight: CGFloat = 32
    private let timelineHours = 12

    private var timelineWidth: CGFloat {
        CGFloat(timelineHours * 60) * pixelsPerMinute
    }

    private func makeTimelineStart(from now: Date) -> Date {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now) - 1
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
    }

    private func makeNowX(now: Date, timelineStart: Date) -> CGFloat? {
        let offset = now.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute)
        guard offset > 0, offset < Double(timelineWidth) else { return nil }
        return CGFloat(offset)
    }

    private func timeSlots(from timelineStart: Date) -> [Date] {
        (0..<(timelineHours * 2)).map { i in
            timelineStart.addingTimeInterval(Double(i) * 30 * 60)
        }
    }

    var body: some View {
        if channels.isEmpty && hasLoadedOnce {
            ContentUnavailableView(
                "No Channels",
                systemImage: "tv",
                description: Text("Add a server in Settings to load channels.")
            )
        } else if !channels.isEmpty {
            // Snapshot once so the red line and every row's aired shading
            // resolve against the exact same `now` — otherwise the Canvas's
            // nowX and the NSView line can be computed from separate Date()
            // reads and drift apart visually.
            let now = Date()
            let timelineStart = makeTimelineStart(from: now)
            let nowX = makeNowX(now: now, timelineStart: timelineStart)
            let width = timelineWidth

            EPGScrollGrid(
                items: channels,
                rowHeight: rowHeight,
                channelColumnWidth: channelColumnWidth,
                programRowWidth: width,
                headerHeight: headerHeight,
                nowLineX: nowX,
                channelNameProvider: { $0.name },
                rowDataProvider: { [programsProvider, timelineStart, pixelsPerMinute, timelineHours] channel in
                    Self.buildRowData(
                        channel: channel,
                        programs: programsProvider(channel),
                        timelineStart: timelineStart,
                        pixelsPerMinute: pixelsPerMinute,
                        timelineHours: timelineHours,
                        rowHeight: rowHeight
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
                },
                programContent: { channel in
                    ProgramRow(
                        channel: channel,
                        programs: programsProvider(channel),
                        fallbackTitle: channel.name,
                        timelineStart: timelineStart,
                        timelineWidth: width,
                        pixelsPerMinute: pixelsPerMinute,
                        rowHeight: rowHeight,
                        nowX: nowX,
                        onPlay: { onChannelSelected(channel) }
                    )
                    .frame(width: width, height: rowHeight)
                    .overlay(alignment: .bottom) {
                        Divider().opacity(0.5)
                    }
                },
                headerContent: { timeStrip(timelineStart: timelineStart) },
                cornerContent: { cornerLabel }
            )
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private static func buildRowData(
        channel: Channel,
        programs: [EPGProgram],
        timelineStart: Date,
        pixelsPerMinute: CGFloat,
        timelineHours: Int,
        rowHeight: CGFloat
    ) -> ChannelLabelRowData {
        let timelineWidth = CGFloat(timelineHours * 60) * pixelsPerMinute
        let end = timelineStart.addingTimeInterval(Double(timelineWidth / pixelsPerMinute) * 60)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"

        let sorted = programs
            .filter { $0.end > timelineStart && $0.start < end }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        var blocks: [(rect: CGRect, timeRange: String?)] = []
        var cursor = timelineStart

        for p in sorted {
            let effectiveStart = max(p.start, cursor)
            guard p.end > effectiveStart else { continue }
            let startX = max(0, effectiveStart.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
            let endX = min(Double(timelineWidth), p.end.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute))
            let width = endX - startX
            guard width > 2 else { continue }
            blocks.append((
                rect: CGRect(x: startX, y: 3, width: width, height: Double(rowHeight) - 6),
                timeRange: "\(formatter.string(from: p.start)) - \(formatter.string(from: p.end))"
            ))
            cursor = p.end
        }

        if blocks.isEmpty {
            blocks.append((
                rect: CGRect(x: 0, y: 3, width: timelineWidth, height: rowHeight - 6),
                timeRange: nil
            ))
        }

        return ChannelLabelRowData(channelName: channel.name, blocks: blocks)
    }

    private func timeStrip(timelineStart: Date) -> some View {
        HStack(spacing: 0) {
            ForEach(timeSlots(from: timelineStart), id: \.self) { time in
                Text(time, format: .dateTime.hour().minute())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30 * pixelsPerMinute, alignment: .leading)
                    .padding(.leading, 6)
            }
        }
        .frame(width: timelineWidth, height: headerHeight, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var cornerLabel: some View {
        HStack {
            Text("TV Guide")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(channel.name)
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
    let nowX: CGFloat?
    let onPlay: () -> Void

    @State private var selectedProgram: EPGProgram?
    @State private var selectedRect: CGRect = .zero

    private var reminderProgramIDs: Set<String> {
        let ids = programs.map(\.id)
        return Set(
            NotificationManager.shared.reminders
                .filter { ids.contains($0.programID) }
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
            nowX: nowX,
            reminderProgramIDs: reminderProgramIDs,
            onProgramTap: { program, rect in
                selectedRect = rect
                selectedProgram = program
            },
            onEmptyTap: onPlay,
            onProgramRightClick: { program, event, view in
                ReminderMenuBuilder.present(
                    program: program,
                    channel: channel,
                    event: event,
                    in: view,
                    onPlay: onPlay
                )
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
    let nowX: CGFloat?
    let reminderProgramIDs: Set<String>
    let onProgramTap: (EPGProgram, CGRect) -> Void
    let onEmptyTap: () -> Void
    let onProgramRightClick: (EPGProgram, NSEvent, NSView) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.timelineStart == rhs.timelineStart,
              lhs.timelineWidth == rhs.timelineWidth,
              lhs.pixelsPerMinute == rhs.pixelsPerMinute,
              lhs.rowHeight == rhs.rowHeight,
              lhs.nowX == rhs.nowX,
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

    private func buildBlocks() -> [Block] {
        let end = timelineStart.addingTimeInterval(Double(timelineWidth / pixelsPerMinute) * 60)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"

        let sorted = programs
            .filter { $0.end > timelineStart && $0.start < end }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        var blocks: [Block] = []
        var cursor: Date = timelineStart

        for p in sorted {
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
                    timeRange: "\(formatter.string(from: p.start)) - \(formatter.string(from: p.end))",
                    hasReminder: reminderProgramIDs.contains(p.id),
                    isFallback: false
                )
            )
            cursor = p.end
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
        let nowFill = Color(nsColor: .tertiaryLabelColor).opacity(0.55)
        let border = Color(nsColor: .separatorColor)
        let textPrimary = Color.primary
        let textSecondary = Color.secondary

        Canvas { context, _ in
            for block in blocks {
                let inset = block.rect.insetBy(dx: 1, dy: 0)
                let path = Path(roundedRect: inset, cornerRadius: 3)
                context.fill(path, with: .color(fill))
                if !block.isFallback,
                   let nowX,
                   nowX > inset.minX,
                   nowX < inset.maxX {
                    let airedWidth = nowX - inset.minX
                    let airedRect = CGRect(x: inset.minX, y: inset.minY, width: airedWidth, height: inset.height)
                    context.drawLayer { layer in
                        layer.clip(to: path)
                        layer.fill(Path(airedRect), with: .color(nowFill))
                    }
                }
                context.stroke(path, with: .color(border), lineWidth: 0.5)

                let textRect = inset.insetBy(dx: 8, dy: 6)
                guard textRect.width > 10 else { continue }

                let titleText = Text(block.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(textPrimary)

                let resolvedTitle = context.resolve(titleText)
                let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                let titleSize = resolvedTitle.measure(in: unbounded)
                let resolvedTime = block.timeRange.map {
                    context.resolve(
                        Text($0)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(textSecondary)
                    )
                }
                let timeSize = resolvedTime?.measure(in: unbounded) ?? .zero

                let timeLineHeight = timeSize.height

                context.drawLayer { layer in
                    layer.clip(to: Path(inset))

                    let titleOriginY = block.timeRange == nil
                        ? inset.midY - titleSize.height / 2
                        : textRect.minY + timeLineHeight + 1
                    let titleOrigin = CGPoint(x: textRect.minX, y: titleOriginY)
                    layer.draw(
                        resolvedTitle,
                        in: CGRect(origin: titleOrigin, size: CGSize(width: max(titleSize.width, textRect.width), height: titleSize.height))
                    )

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
        notificationManager.reminder(for: program)
    }

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
                        PendingCatchup.set(channelID: channel.id, start: program.start)
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
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    @ViewBuilder
    private var reminderButton: some View {
        if let existing = existingReminder {
            Button {
                notificationManager.cancelReminder(for: program)
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
        Task { @MainActor in
            let scheduled = await notificationManager.scheduleReminder(
                program: program,
                channel: channel,
                leadMinutes: lead
            )
            AppFeedbackCenter.shared.showReminderResult(
                program: program,
                channel: channel,
                leadMinutes: lead,
                scheduled: scheduled
            )
        }
    }
}
