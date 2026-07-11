import SwiftUI

struct SportsView: View {
    @State var viewModel: SportsViewModel
    let channels: [Channel]
    let programs: [String: [EPGProgram]]
    let favoriteChannelIDs: Set<String>
    let hiddenGroups: Set<String>
    let onChannelSelected: (Channel) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

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
                                    onChannelSelected: onChannelSelected
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
            Label("No Events", systemImage: "sportscourt")
        } description: {
            Text("No sporting events found right now. Try refreshing or check back later.")
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

    @State private var hovered = false
    @State private var showStreams = false
    @State private var matches: [StreamMatch]?
    @State private var matchUnavailableMessage: String?
    @State private var isMatching = false
    @State private var lastIndexVersion: Int = 0
    @State private var notificationManager = NotificationManager.shared
    @Environment(\.activePlaylistID) private var activePlaylistID: UUID?

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

    /// Event is playable if live, halftime, or starting within 15 minutes.
    private var eventIsPlayable: Bool {
        switch event.status {
        case .live, .halftime: return true
        default:
            return event.startDate.timeIntervalSinceNow <= 15 * 60
        }
    }

    /// Synthetic EPGProgram used for reminder + recording integrations.
    /// ESPN scoreboards only give a start time, so we assume a 3-hour window.
    private func syntheticProgram(for channel: Channel) -> EPGProgram {
        EPGProgram(
            id: "sport_\(event.id)",
            channelID: channel.epgChannelID ?? channel.id,
            title: event.displayTitle,
            description: "\(event.league.fullName)",
            start: event.startDate,
            end: event.startDate.addingTimeInterval(3 * 3600)
        )
    }

    private func setReminder(for channel: Channel) {
        guard let playlistID = activePlaylistID else { return }
        let program = syntheticProgram(for: channel)
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
        guard let playlistID = activePlaylistID else { return }
        let program = syntheticProgram(for: channel)
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
        .onChange(of: viewModel.searchIndexVersion) { _, newVersion in
            guard showStreams, newVersion != lastIndexVersion else { return }
            lastIndexVersion = newVersion
            rematchIfNeeded()
        }
        .popover(isPresented: $showStreams, arrowEdge: .trailing) {
            StreamMatchesPopover(
                event: event,
                matches: matches ?? [],
                favoriteIDs: viewModel.favoriteChannelIDs,
                unavailableMessage: matchUnavailableMessage,
                reminderHint: eventIsPlayable ? nil : "Set a reminder",
                onPlay: eventIsPlayable ? { channel in
                    showStreams = false
                    onChannelSelected(channel)
                } : nil,
                onRemind: eventIsPlayable ? nil : { channel in
                    showStreams = false
                    setReminder(for: channel)
                },
                onRecord: { channel in
                    showStreams = false
                    record(channel: channel)
                }
            )
        }
        .overlay(alignment: .topTrailing) {
            if isMatching {
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
        if let matches, !matches.isEmpty {
            showStreams = true
            return
        }
        if let message = viewModel.streamIndexUnavailableMessage {
            matches = []
            matchUnavailableMessage = message
            showStreams = true
            return
        }
        isMatching = true
        Task {
            let result = await viewModel.matchEvent(event)
            isMatching = false
            matches = result
            matchUnavailableMessage = result.isEmpty ? viewModel.streamIndexUnavailableMessage : nil
            if !result.isEmpty || matchUnavailableMessage != nil {
                showStreams = true
            }
        }
        lastIndexVersion = viewModel.searchIndexVersion
    }

    /// Rematch while the popover is open, e.g. when the index transitions
    /// from building to ready.
    private func rematchIfNeeded() {
        guard !isMatching else { return }
        if let matches, !matches.isEmpty { return }
        isMatching = true
        Task {
            let result = await viewModel.matchEvent(event)
            isMatching = false
            matches = result
            matchUnavailableMessage = result.isEmpty ? viewModel.streamIndexUnavailableMessage : nil
        }
    }
}

// MARK: - Streams popover
