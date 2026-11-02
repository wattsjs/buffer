import SwiftUI

struct SportsView: View {
    @State var viewModel: SportsViewModel
    let channels: [Channel]
    let programs: [String: [EPGProgram]]
    let favoriteChannelIDs: Set<String>
    let hiddenGroups: Set<String>
    let onChannelSelected: (Channel) -> Void
    var onCatchup: ((Channel, EPGProgram) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let warning = viewModel.refreshWarning, viewModel.totalEvents > 0 {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(BufferFont.meta)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, BufferLayout.content)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if viewModel.totalEvents == 0 && !viewModel.hasLoadedOnce {
                loadingState
            } else if viewModel.totalEvents == 0 {
                emptyState
            } else {
                eventList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bufferPageBackground()
        .task {
            // Data sync and auto-refresh are managed by ContentView;
            // just trigger a refresh when the Sports page appears so
            // scores are immediately up-to-date.
            if viewModel.hasLoadedOnce {
                viewModel.refresh()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        BufferFilterBar {
            HStack(spacing: 8) {
                sportFilters

                if viewModel.liveCount > 0 {
                    HStack(spacing: 4) {
                        LiveIndicatorDot(size: 6)
                        Text("\(viewModel.liveCount) Live")
                            .font(BufferFont.badge)
                            .foregroundStyle(.red)
                    }
                }

                Spacer()

                if let last = viewModel.lastRefreshed {
                    Text("Updated \(last, style: .relative) ago")
                        .font(BufferFont.micro)
                        .foregroundStyle(.tertiary)
                }

                Button {
                    viewModel.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(BufferFont.meta)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isLoading)

                Toggle(isOn: Binding(
                    get: { viewModel.hideFinished },
                    set: { viewModel.hideFinished = $0 }
                )) {
                    Text("Hide finished")
                        .font(BufferFont.meta)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var sportFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.availableSports) { sport in
                    BufferFilterChip(
                        title: sport.rawValue,
                        systemImage: sport.icon,
                        isSelected: viewModel.selectedSports.contains(sport)
                    ) {
                        viewModel.toggleSport(sport)
                    }
                }

                if !viewModel.selectedSports.isEmpty {
                    Button("Clear") {
                        viewModel.selectedSports.removeAll()
                    }
                    .font(BufferFont.microMedium)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - Event list

    private let columns = [
        GridItem(.adaptive(minimum: 340, maximum: .infinity), spacing: 10)
    ]

    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                ForEach(viewModel.sections) { section in
                    Section {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(section.events) { event in
                                SportEventCard(
                                    event: event,
                                    viewModel: viewModel,
                                    onChannelSelected: onChannelSelected,
                                    onCatchup: onCatchup
                                )
                            }
                        }
                    } header: {
                        sectionHeader(section.group, count: section.events.count)
                    }
                }
            }
            .padding(.horizontal, BufferLayout.content)
            .padding(.vertical, 12)
        }
    }

    private func sectionHeader(_ group: SportTimeGroup, count: Int) -> some View {
        BufferPinnedSectionHeader(
            icon: group.icon,
            title: group.title,
            count: count,
            accent: colorForGroup(group)
        )
    }

    private func colorForGroup(_ group: SportTimeGroup) -> Color {
        switch group {
        case .live:       .red
        case .upNext:     .orange
        case .laterToday: .yellow
        case .tomorrow:   .blue
        case .thisWeek:   .purple
        case .finished:   .secondary
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text("Fetching live sports…")
                .font(BufferFont.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(viewModel.refreshWarning == nil ? "No Events" : "Sports Unavailable",
                  systemImage: viewModel.refreshWarning == nil ? "sportscourt" : "wifi.exclamationmark")
        } description: {
            Text(viewModel.refreshWarning ?? "No sporting events found right now. Try refreshing or check back later.")
        } actions: {
            Button("Refresh") {
                viewModel.refresh()
            }
            .buttonStyle(.borderedProminent)
        }
    }

}

// MARK: - Event card

private struct SportEventCard: View {
    let event: SportEvent
    let viewModel: SportsViewModel
    let onChannelSelected: (Channel) -> Void
    let onCatchup: ((Channel, EPGProgram) -> Void)?

    @State private var hovered = false
    @State private var showStreams = false
    @State private var matchState = SportEventMatchState()
    @State private var notificationManager = NotificationManager.shared
    @Environment(\.activePlaylistID) private var activePlaylistID: UUID?
    @Environment(\.epgActionModel) private var actionModel

    private var matchContext: SportEventMatchContext {
        SportEventMatchContext(
            event: event,
            indexVersion: viewModel.searchIndexVersion,
            modelIdentity: ObjectIdentifier(viewModel),
            preferencesVersion: viewModel.matchingPreferencesVersion
        )
    }

    /// Subtitle for tournament-style events (no head-to-head teams): round
    /// detail and/or venue, e.g. "Rd 2 · Harbour Town Golf Links".
    private var tournamentSubtitle: String? {
        var parts: [String] = []
        if let detail = event.detail, !detail.isEmpty {
            let lower = detail.lowercased()
            // Skip if the detail only restates what the badge already shows.
            let redundant = lower == "live" || lower == "final" || lower.hasPrefix("final/")
            if !redundant { parts.append(detail) }
        }
        if let leader = event.leader {
            parts.append("\(leader.name) \(leader.score)")
        }
        if let venue = event.venue, !venue.isEmpty {
            parts.append(venue)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var eventActionMode: SportsEventActionPolicy.Mode {
        SportsEventActionPolicy.mode(for: event)
    }

    private var actionHint: String? {
        switch eventActionMode {
        case .live: return nil
        case .upcoming: return "Set a reminder"
        case .replayOnly: return "Replay where available"
        case .unavailable: return "Event unavailable"
        }
    }

    private func replayProgram(for match: StreamMatch) -> EPGProgram? {
        SportsEventActionPolicy.replayProgram(for: event, match: match,
            currentPrograms: actionModel?.programsForChannel(match.channel) ?? [])
    }

    private func actionProgram(for channel: Channel) -> EPGProgram? {
        let matches = matchState.snapshot(for: matchContext,
            unavailableMessage: viewModel.streamIndexUnavailableMessage).matches
        let match = matches.first { $0.channel.preferenceIdentity == channel.preferenceIdentity }
        return SportsProgrammeBinding.program(for: event, channel: channel, match: match,
            currentPrograms: actionModel?.programsForChannel(channel) ?? [])
    }

    private func setReminder(for channel: Channel) {
        guard eventActionMode == .upcoming else { return }
        if channel.sourceOwnership?.logicalChannelID != nil {
            actionModel?.showSmartActionUnavailable("Choose a programme in this channel’s guide to set a reminder with its source binding.")
            return
        }
        guard let playlistID = channel.sourceChannelIdentity?.sourceID ?? activePlaylistID else { return }
        guard let program = actionProgram(for: channel) else {
            actionModel?.showSmartActionUnavailable("The matching programme has changed. Refresh the guide before scheduling this event.")
            return
        }
        Task { @MainActor in
            let scheduled = await notificationManager.scheduleReminder(
                playlistID: playlistID,
                program: program,
                channel: channel,
                leadMinutes: 5
            )
            AppFeedbackCenter.shared.showReminderResult(
                playlistID: playlistID,
                program: program,
                channel: channel,
                leadMinutes: 5,
                scheduled: scheduled
            )
        }
    }

    private func record(channel: Channel) {
        guard eventActionMode == .live || eventActionMode == .upcoming else { return }
        if channel.sourceOwnership?.logicalChannelID != nil {
            actionModel?.showSmartActionUnavailable("Choose a programme in the guide to pin the recording to its actual source and end time.")
            return
        }
        guard let playlistID = channel.sourceChannelIdentity?.sourceID ?? activePlaylistID else { return }
        guard let program = actionProgram(for: channel) else {
            actionModel?.showSmartActionUnavailable("The matching programme has changed. Refresh the guide before scheduling this event.")
            return
        }
        switch event.status {
        case .live, .halftime:
            Task { @MainActor in
                _ = await RecordingManager.shared.startLiveRecording(
                    playlistID: playlistID,
                    channel: channel,
                    program: program
                )
            }
        default:
            _ = RecordingManager.shared.schedule(
                playlistID: playlistID,
                channel: channel,
                program: program
            )
        }
    }

    var body: some View {
        let matchingContext = matchContext
        let matchSnapshot = matchState.snapshot(
            for: matchingContext,
            unavailableMessage: viewModel.streamIndexUnavailableMessage
        )
        VStack(alignment: .leading, spacing: 0) {
            // Top bar: league + time
            HStack(spacing: 6) {
                Image(systemName: event.sport.icon)
                    .font(BufferFont.micro)
                    .foregroundStyle(.secondary)
                Text(event.league.shortName)
                    .font(BufferFont.metaMedium)
                    .foregroundStyle(.secondary)
                if let tournament = event.tournamentName,
                   event.awayTeam != nil, event.homeTeam != nil {
                    Text("·")
                        .font(BufferFont.meta)
                        .foregroundStyle(.tertiary)
                    Text(tournament)
                        .font(BufferFont.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                statusBadge
            }
            .padding(.bottom, 10)

            // Teams
            if let away = event.awayTeam, let home = event.homeTeam {
                teamRow(away, isHome: false)
                    .padding(.bottom, 6)
                teamRow(home, isHome: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(BufferFont.cardTitleMedium)
                        .lineLimit(2)
                    if let subtitle = tournamentSubtitle {
                        Text(subtitle)
                            .font(BufferFont.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 54, alignment: .center)
            }
        }
        .padding(BufferLayout.cardPadding)
        .frame(minHeight: 100)
        .bufferCardSurface(isHovering: hovered, isLive: event.status.isLive)
        .contentShape(Rectangle())
        .scaleEffect(hovered ? 1.01 : 1)
        .bufferHoverTracking($hovered)
        .onTapGesture {
            handleTap()
        }
        // a11y for tap target (was missing label/traits on card; Agent 10 / sports audit item)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.displayTitle), \(event.status.label)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double-tap to view streams or play")
        .onChange(of: matchContext) { updateMatching() }
        .onChange(of: showStreams) { updateMatching() }
        .onDisappear {
            showStreams = false
            matchState.cancel()
        }
        .popover(isPresented: $showStreams, arrowEdge: .trailing) {
            StreamMatchesPopover(
                event: event,
                matches: matchSnapshot.matches,
                favoriteIDs: viewModel.favoriteChannelIDs,
                unavailableMessage: matchSnapshot.unavailableMessage,
                reminderHint: actionHint,
                onPlay: eventActionMode == .live ? { channel in
                    guard matchingContext == matchContext, matchState.hasCurrentMatches(for: matchingContext),
                          eventActionMode == .live else { return }
                    showStreams = false
                    onChannelSelected(channel)
                } : nil,
                onRemind: eventActionMode == .upcoming ? { channel in
                    guard matchingContext == matchContext, matchState.hasCurrentMatches(for: matchingContext),
                          eventActionMode == .upcoming else { return }
                    showStreams = false
                    setReminder(for: channel)
                } : nil,
                onRecord: eventActionMode == .live || eventActionMode == .upcoming ? { channel in
                    guard matchingContext == matchContext, matchState.hasCurrentMatches(for: matchingContext),
                          eventActionMode == .live || eventActionMode == .upcoming else { return }
                    showStreams = false
                    record(channel: channel)
                } : nil,
                replayProgramForMatch: eventActionMode == .replayOnly ? { replayProgram(for: $0) } : nil,
                onCatchup: eventActionMode == .replayOnly && onCatchup != nil ? { channel, program in
                    guard matchingContext == matchContext, matchState.hasCurrentMatches(for: matchingContext),
                          let match = matchSnapshot.matches.first(where: { $0.channel.preferenceIdentity == channel.preferenceIdentity }),
                          let current = replayProgram(for: match), current.id == program.id,
                          current.start == program.start, current.end == program.end else { return }
                    showStreams = false
                    onCatchup?(channel, current)
                } : nil
            )
        }
        .overlay(alignment: .topTrailing) {
            if matchSnapshot.isMatching {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
            }
        }
    }

    // MARK: - Team row

    private func teamRow(_ team: TeamInfo, isHome: Bool) -> some View {
        let hasScore = event.status.isLive || event.status.isFinished
        return HStack(spacing: 8) {
            RemoteArtworkView(
                url: team.logoURL,
                fallbackSystemImage: "sportscourt",
                width: 24,
                height: 24,
                scaledToFill: false
            )

            Text(team.displayName)
                .font(BufferFont.cardTitle)
                .lineLimit(1)

            if hasScore, let score = team.score {
                Spacer()
                Text(score)
                    .font(BufferFont.score)
                    .monospacedDigit()
                    .foregroundStyle(event.status.isLive ? .red : .primary)
            }
        }
    }

    // MARK: - Status badge

    @ViewBuilder
    private var statusBadge: some View {
        switch event.status {
        case .live(let detail):
            HStack(spacing: 4) {
                LiveIndicatorDot(size: 6)
                Text(detail ?? "LIVE")
                    .font(BufferFont.microBadge)
                    .foregroundStyle(.red)
            }
        case .halftime:
            Text("HT")
                .font(BufferFont.microBadge)
                .foregroundStyle(.orange)
        case .final_(let detail):
            Text(detail ?? "Final")
                .font(BufferFont.microSemibold)
                .foregroundStyle(.secondary)
        case .scheduled:
            Text(formatTime(event.startDate))
                .font(BufferFont.metaMedium)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .postponed:
            Text("PPD")
                .font(BufferFont.microBadge)
                .foregroundStyle(.orange)
        case .delayed:
            Text("DLY")
                .font(BufferFont.microBadge)
                .foregroundStyle(.orange)
        case .canceled:
            Text("CXL")
                .font(BufferFont.microBadge)
                .foregroundStyle(.secondary)
                .strikethrough()
        }
    }

    private func formatTime(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.amSymbol = "am"
        f.pmSymbol = "pm"

        if cal.isDateInToday(date) {
            f.dateFormat = "h:mma"
            return f.string(from: date)
        }
        if cal.isDateInTomorrow(date) {
            f.dateFormat = "h:mma"
            return "Tomorrow \(f.string(from: date))"
        }
        f.dateFormat = "EEE h:mma"
        return f.string(from: date)
    }

    // MARK: - Matching

    private func handleTap() {
        showStreams = true
        updateMatching()
    }

    private func updateMatching() {
        matchState.update(
            context: matchContext,
            unavailableMessage: viewModel.streamIndexUnavailableMessage,
            isPresented: showStreams
        ) { [viewModel, event] in
            await viewModel.matchEvent(event)
        }
    }
}

// MARK: - Streams popover
