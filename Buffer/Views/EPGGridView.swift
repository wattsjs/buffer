import SwiftUI
import AppKit

struct EPGGridView: View {
    let channels: [Channel]
    let channelSetVersion: Int
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
    var onPlayFromStart: ((Channel, EPGProgram) -> Void)? = nil

    @Environment(\.activePlaylistID) private var activePlaylistID: UUID?

    @State private var timelineAnchor = Date()
    @State private var timelineResetID = 0
    @State private var scrollToCurrentID = 0

    // Lightweight "now" ticker (Agent 02 + 09). Updates every 20 s so the red
    // live line and "LIVE" badges stay accurate without relying
    // on incidental re-renders from syncs or user actions.
    @State private var now = Date()
    @State private var nowTicker: Task<Void, Never>? = nil
    @State private var timelineInputCache = EPGTimelineInputCache()
    @State private var timeStripCache = EPGTimeStripCache()
    @State private var displayedTimelineInputs: EPGTimelineInputs?
    @State private var visibleChannelContext = EPGVisibleChannelContext()

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

    private func timelineIdentity(resetID: Int) -> AnyHashable {
        AnyHashable(resetID)
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
        timelineInputs.archiveStart(anchor: currentNow)
    }

    private var timelineInputs: EPGTimelineInputs {
        timelineInputCache.inputs(channels: channels, version: channelSetVersion, lookback: catchupLookback)
    }

    private func requestCatchupGuideIfNeeded(for channels: [Channel]) {
        let candidates = visibleChannelContext.candidates(from: channels)
        guard !candidates.isEmpty else { return }
        onCatchupGuideNeeded?(candidates)
    }

    private func makeNowX(now: Date, timelineStart: Date, timelineWidth: CGFloat) -> CGFloat? {
        let offset = now.timeIntervalSince(timelineStart) / 60.0 * Double(pixelsPerMinute)
        guard offset > 0, offset < Double(timelineWidth) else { return nil }
        return CGFloat(offset)
    }

    private static func timelineTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
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
                timelineIdentity: timelineIdentity(resetID: timelineResetID),
                itemSetVersion: channelSetVersion,
                dataVersion: AnyHashable(guideVersion),
                referenceDate: now,
                timeStripSlots: timeStripCache.slots(start: timelineStart, hours: timelineHours, pixelsPerMinute: pixelsPerMinute, relativeTo: now),
                timeStripSlotWidth: 30 * pixelsPerMinute,
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
                visibleItemsDidChange: { visible in
                    visibleChannelContext.update(visible)
                    onCatchupGuideNeeded?(visible)
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
                    .fadeIfStreamDead(channel: channel)
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
                        replayLookbackHours: channel.supportsRewind
                            ? min(min(channel.catchup?.days ?? 0, 14) * 24, catchupLookback.limitHours ?? 336)
                            : nil,
                        onPlay: { onChannelSelected(channel) },
                        playlistID: activePlaylistID,
                        onPlayFromStart: onPlayFromStart.map { callback in { callback(channel, $0) } }
                    )
                    .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
                    .overlay(alignment: .bottom) {
                        Divider().opacity(0.5)
                    }
                    // A failed live-stream probe says nothing about the
                    // readability/availability of this schedule or its replay.
                    // Keep status dimming on the channel/logo tile only; an
                    // 80k-point row must not become an offscreen effect group.
                },
                cornerContent: { cornerLabel }
            )
            .bufferPageBackground()
            .onChange(of: channelSetVersion) { _, _ in
                let inputs = timelineInputs
                if displayedTimelineInputs != inputs {
                    displayedTimelineInputs = inputs
                    resetTimelineWindow(for: channels, now: Date())
                }
                requestCatchupGuideIfNeeded(for: channels)
            }
            .onChange(of: catchupLookback) { _, _ in
                displayedTimelineInputs = timelineInputs
                resetTimelineWindow(for: channels, now: Date())
                requestCatchupGuideIfNeeded(for: channels)
            }
            .onAppear {
                displayedTimelineInputs = timelineInputs
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
                StreamProbeBadge(channel: channel, style: .compact)
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
            SmartSportsSourceMenuItem(channel: channel)
        }
    }
}

// MARK: - Program row

private struct ProgramRow: View {
    @Environment(\.epgActionModel) private var actionModel
    let channel: Channel
    let programs: [EPGProgram]
    let fallbackTitle: String
    let timelineStart: Date
    let timelineWidth: CGFloat
    let pixelsPerMinute: CGFloat
    let rowHeight: CGFloat
    let showGuideGaps: Bool
    let replayLookbackHours: Int?
    let onPlay: () -> Void

    @State private var selectedProgram: EPGProgram?
    @State private var selectedRect: CGRect = .zero

    let playlistID: UUID?
    var onPlayFromStart: ((EPGProgram) -> Void)? = nil

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
            ownerID: channel.id,
            programs: programs,
            fallbackTitle: fallbackTitle,
            timelineStart: timelineStart,
            timelineWidth: timelineWidth,
            pixelsPerMinute: pixelsPerMinute,
            rowHeight: rowHeight,
            showGuideGaps: showGuideGaps,
            replayLookbackHours: replayLookbackHours,
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
                        onPlay: onPlay,
                        onPlayFromStart: channel.canReplay(program) ? onPlayFromStart.map { callback in { callback(program) } } : nil,
                        actionModel: actionModel
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
                    },
                    onPlayFromStart: onPlayFromStart.map { callback in { selectedProgram = nil; callback(program) } }
                )
            }
        }
    }
}

// MARK: - AppKit programme canvas (viewport-sized backing for full archive widths)

private struct ProgramCanvasLayer: View, Equatable {
    let ownerID: String
    let programs: [EPGProgram]
    let fallbackTitle: String
    let timelineStart: Date
    let timelineWidth: CGFloat
    let pixelsPerMinute: CGFloat
    let rowHeight: CGFloat
    let showGuideGaps: Bool
    let replayLookbackHours: Int?
    let reminderProgramIDs: Set<String>
    let onProgramTap: (EPGProgram, CGRect) -> Void
    let onEmptyTap: () -> Void
    let onProgramRightClick: (EPGProgram, NSEvent, NSView) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.ownerID == rhs.ownerID,
              lhs.timelineStart == rhs.timelineStart,
              lhs.timelineWidth == rhs.timelineWidth,
              lhs.pixelsPerMinute == rhs.pixelsPerMinute,
              lhs.rowHeight == rhs.rowHeight,
              lhs.showGuideGaps == rhs.showGuideGaps,
              lhs.replayLookbackHours == rhs.replayLookbackHours,
              lhs.fallbackTitle == rhs.fallbackTitle,
              lhs.reminderProgramIDs == rhs.reminderProgramIDs,
              lhs.programs.count == rhs.programs.count else { return false }
        for (a, b) in zip(lhs.programs, rhs.programs) {
            if a.id != b.id || a.start != b.start || a.end != b.end || a.title != b.title { return false }
        }
        return true
    }

    fileprivate typealias Block = EPGProgramBlock

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
            ownerID: ownerID,
            blocks: buildBlocks(),
            replayLookbackHours: replayLookbackHours,
            onProgramTap: onProgramTap,
            onEmptyTap: onEmptyTap,
            onProgramRightClick: onProgramRightClick
        )
    }
}

private struct ProgramBlocksRepresentable: NSViewRepresentable {
    let ownerID: String
    let blocks: [ProgramCanvasLayer.Block]
    let replayLookbackHours: Int?
    let onProgramTap: (EPGProgram, CGRect) -> Void
    let onEmptyTap: () -> Void
    let onProgramRightClick: (EPGProgram, NSEvent, NSView) -> Void

    func makeNSView(context: Context) -> ProgramBlocksView {
        let view = ProgramBlocksView()
        EPGGridStyle.applyAppearance(to: view, scheme: context.environment.colorScheme,
                                    contrast: context.environment.colorSchemeContrast)
        view.setHandlers(
            onProgramTap: onProgramTap,
            onEmptyTap: onEmptyTap,
            onProgramRightClick: onProgramRightClick
        )
        view.ownerID = ownerID
        view.setBlocks(blocks)
        view.setReplayLookbackHours(replayLookbackHours)
        return view
    }

    func updateNSView(_ view: ProgramBlocksView, context: Context) {
        EPGGridStyle.applyAppearance(to: view, scheme: context.environment.colorScheme,
                                    contrast: context.environment.colorSchemeContrast)
        view.setHandlers(
            onProgramTap: onProgramTap,
            onEmptyTap: onEmptyTap,
            onProgramRightClick: onProgramRightClick
        )
        view.ownerID = ownerID
        view.setBlocks(blocks)
        view.setReplayLookbackHours(replayLookbackHours)
    }
}

// MARK: - Program detail popover

struct ProgramDetailPopover: View {
    let program: EPGProgram
    let channel: Channel
    let onPlay: () -> Void
    var onPlayFromStart: (() -> Void)? = nil

    @State private var notificationManager = NotificationManager.shared
    @State private var recordingManager = RecordingManager.shared
    @Environment(\.activePlaylistID) private var activePlaylistID: UUID?
    @Environment(\.epgActionModel) private var actionModel

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
        guard channel.sourceOwnership?.logicalChannelID == nil else { return false }
        guard onPlayFromStart != nil else { return false }
        guard let days = channel.catchup?.days, days > 0 else { return false }
        let windowStart = Date().addingTimeInterval(-Double(days) * 86400)
        return program.start >= windowStart && program.start < Date()
    }

    private var existingReminder: ProgramReminder? {
        guard let playlistID = activePlaylistID else { return nil }
        return notificationManager.reminder(playlistID: playlistID, for: program)
    }

    private var existingRecording: Recording? {
        let action = actionModel?.sourceProgramAction(channel: channel, program: program)
        return recordingManager.recordings.first { rec in
            rec.programID == (action?.program.id ?? program.id)
                && (((action?.channel.sourceChannelIdentity ?? channel.sourceChannelIdentity) != nil &&
                     rec.sourceOwnership?.channelIdentity == (action?.channel.sourceChannelIdentity ?? channel.sourceChannelIdentity)) ||
                    (rec.sourceOwnership == nil && rec.channelID == channel.id))
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
                        onPlayFromStart?()
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
            if channel.sourceOwnership?.logicalChannelID != nil, let actionModel {
                Text("Catchup needs validated source timing.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Original Source Guide") { actionModel.showOriginalSourceGuide(for: channel) }
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
        guard let action = actionModel?.sourceProgramAction(channel: channel, program: program) ??
                (channel.sourceOwnership?.logicalChannelID == nil ? (channel, program) : nil) else {
            actionModel?.showSmartActionUnavailable("The guide source has changed. Refresh Smart Sports and select the programme again.")
            return
        }
        _ = recordingManager.schedule(
            playlistID: action.channel.sourceChannelIdentity?.sourceID ?? playlistID,
            channel: action.channel,
            program: action.program
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
        guard let action = actionModel?.sourceProgramAction(channel: channel, program: program) ??
                (channel.sourceOwnership?.logicalChannelID == nil ? (channel, program) : nil) else {
            actionModel?.showSmartActionUnavailable("The guide source has changed. Refresh Smart Sports and select the programme again.")
            return
        }
        Task { @MainActor in
            let scheduled = await notificationManager.scheduleReminder(
                playlistID: playlistID,
                program: program,
                channel: channel,
                leadMinutes: lead, sourceChannel: action.channel, sourceProgramID: action.program.id
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
