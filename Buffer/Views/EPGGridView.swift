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
    /// Optional ranged provider backed by pre-buckets in VM. When present, the label and programme
    /// row layouts receive only programs intersecting the current timeline window.
    var rangedProgramsProvider: ((Channel, Date, Date) -> [EPGProgram])? = nil
    var onCatchupGuideNeeded: (([Channel]) -> Void)? = nil
    let isFavorite: (Channel) -> Bool
    let onToggleFavorite: (Channel) -> Void
    let onChannelSelected: (Channel) -> Void
    var onPlayFromStart: ((Channel, EPGProgram) -> Void)? = nil

    @Environment(\.activePlaylistID) private var activePlaylistID: UUID?
    @Environment(\.epgActionModel) private var actionModel

    @State private var timelineAnchor = Date()
    @State private var timelineResetID = 0
    @State private var scrollToCurrentID = 0

    // Lightweight "now" ticker (Agent 02 + 09). Updates every 20 s so the red
    // live line and "LIVE" badges stay accurate without relying
    // on incidental re-renders from syncs or user actions.
    @State private var now = Date()
    @State private var nowTicker: Task<Void, Never>? = nil
    /// The inputs behind the current document origin. Updated exactly when
    /// the channel set or lookback changes, so the body never rescans channels.
    @State private var displayedTimelineInputs: EPGTimelineInputs?
    @State private var visibleChannelContext = EPGVisibleChannelContext()
    @State private var popoverPresenter = EPGProgramPopoverPresenter()

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

    /// The displayed inputs, or (before the first appearance) a direct
    /// single-pass computation from the channels.
    private var timelineInputs: EPGTimelineInputs {
        displayedTimelineInputs ?? currentTimelineInputs
    }

    private var currentTimelineInputs: EPGTimelineInputs {
        EPGTimelineInputs(channels: channels, lookback: catchupLookback)
    }

    /// Reminder programme IDs for the active source. Read here, once per
    /// grid update, so reminder changes refresh the visible native rows.
    private var reminderProgramIDs: Set<String> {
        guard let playlistID = activePlaylistID else { return [] }
        let reminders = NotificationManager.shared.reminders
        guard !reminders.isEmpty else { return [] }
        return Set(reminders.lazy.filter { $0.playlistID == playlistID }.map(\.programID))
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

            let reminderIDs = reminderProgramIDs
            let rowHeight = self.rowHeight
            let pixelsPerMinute = self.pixelsPerMinute

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
                timeStrip: EPGTimeStripSpec(start: timelineStart, hours: timelineHours,
                                            pixelsPerMinute: pixelsPerMinute, relativeTo: now),
                rowDataProvider: { [programsProvider, rangedProgramsProvider, timelineStart, timelineEnd] channel, slot in
                    let programs = rangedProgramsProvider?(channel, timelineStart, timelineEnd) ?? programsProvider(channel)
                    slot.channelName = channel.name
                    slot.layout.build(
                        programs: programs,
                        timelineStart: timelineStart,
                        pixelsPerMinute: Double(pixelsPerMinute),
                        timelineWidth: Double(width),
                        rowHeight: Double(rowHeight),
                        showGaps: channel.supportsRewind
                    )
                },
                visibleItemsDidChange: { visible in
                    visibleChannelContext.update(visible)
                    onCatchupGuideNeeded?(visible)
                },
                revealItemID: revealChannelID.map { AnyHashable($0) },
                nativeProgramRow: { [programsProvider, rangedProgramsProvider, timelineStart, timelineEnd,
                                     catchupLookback, activePlaylistID, actionModel, popoverPresenter,
                                     onChannelSelected, onPlayFromStart] channel, canvas in
                    let programs = rangedProgramsProvider?(channel, timelineStart, timelineEnd) ?? programsProvider(channel)
                    let onPlay = { onChannelSelected(channel) }
                    let playFromStart = onPlayFromStart.map { callback in { (program: EPGProgram) in callback(channel, program) } }
                    canvas.ownerID = channel.id
                    canvas.setPrograms(
                        programs,
                        timelineStart: timelineStart,
                        pixelsPerMinute: pixelsPerMinute,
                        timelineWidth: width,
                        rowHeight: rowHeight,
                        showGaps: channel.supportsRewind,
                        reminderIDs: reminderIDs
                    )
                    canvas.setReplayLookbackHours(channel.supportsRewind
                        ? min(min(channel.catchup?.days ?? 0, 14) * 24, catchupLookback.limitHours ?? 336)
                        : nil)
                    canvas.setHandlers(
                        onProgramTap: { [weak canvas] program, rect in
                            guard let canvas else { return }
                            popoverPresenter.present(
                                program: program, channel: channel, anchor: rect, in: canvas,
                                playlistID: activePlaylistID, actionModel: actionModel,
                                onPlay: onPlay, onPlayFromStart: playFromStart
                            )
                        },
                        onEmptyTap: onPlay,
                        onProgramRightClick: { program, event, view in
                            guard let activePlaylistID else { return }
                            ReminderMenuBuilder.present(
                                playlistID: activePlaylistID,
                                program: program,
                                channel: channel,
                                event: event,
                                in: view,
                                onPlay: onPlay,
                                onPlayFromStart: channel.canReplay(program) ? playFromStart.map { callback in { callback(program) } } : nil,
                                actionModel: actionModel
                            )
                        }
                    )
                },
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
                // Programme rows are native (`nativeProgramRow`). A failed
                // live-stream probe says nothing about the schedule or its
                // replay, so status dimming stays on the channel tile only.
                programContent: { _ in EmptyView() },
                cornerContent: { cornerLabel }
            )
            .bufferPageBackground()
            .onChange(of: channelSetVersion) { _, _ in
                let inputs = currentTimelineInputs
                if displayedTimelineInputs != inputs {
                    displayedTimelineInputs = inputs
                    resetTimelineWindow(for: channels, now: Date())
                }
                requestCatchupGuideIfNeeded(for: channels)
            }
            .onChange(of: catchupLookback) { _, _ in
                displayedTimelineInputs = currentTimelineInputs
                resetTimelineWindow(for: channels, now: Date())
                requestCatchupGuideIfNeeded(for: channels)
            }
            .onAppear {
                displayedTimelineInputs = currentTimelineInputs
                startNowTicker()
                requestCatchupGuideIfNeeded(for: channels)
            }
            .onDisappear { stopNowTicker() }
        }
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

// MARK: - Programme popover

/// Presents the programme detail for a native programme row. One presenter
/// serves the whole grid; at most one detail popover is open at a time.
@MainActor
final class EPGProgramPopoverPresenter: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?

    func present(
        program: EPGProgram,
        channel: Channel,
        anchor: CGRect,
        in view: NSView,
        playlistID: UUID?,
        actionModel: EPGViewModel?,
        onPlay: @escaping () -> Void,
        onPlayFromStart: ((EPGProgram) -> Void)?
    ) {
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let close: () -> Void = { [weak popover] in popover?.close() }
        let content = ProgramDetailPopover(
            program: program,
            channel: channel,
            onPlay: {
                close()
                onPlay()
            },
            onPlayFromStart: onPlayFromStart.map { callback in { close(); callback(program) } }
        )
        .environment(\.activePlaylistID, playlistID)
        .environment(\.epgActionModel, actionModel)
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.delegate = self
        self.popover = popover
        // `arrowEdge: .top`: the card hangs below the programme.
        popover.show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === popover { popover = nil }
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
            actionModel?.showSmartActionUnavailable("The guide source has changed. Refresh Smart Channels and select the programme again.")
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
            actionModel?.showSmartActionUnavailable("The guide source has changed. Refresh Smart Channels and select the programme again.")
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
