import SwiftUI

struct HomeView: View {
    let recentChannels: [Channel]
    let favoriteChannels: [Channel]
    let inProgressVOD: [VODResumeEntry]
    let currentProgram: (Channel) -> EPGProgram?
    let onChannelSelected: (Channel) -> Void
    let onVODSelected: (VODResumeEntry) -> Void
    let onVODRemoved: (VODResumeEntry) -> Void
    let sportsViewModel: SportsViewModel
    @AppStorage("hideSport") private var hideSport = false

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)]

    init(
        recentChannels: [Channel],
        favoriteChannels: [Channel],
        inProgressVOD: [VODResumeEntry],
        currentProgram: @escaping (Channel) -> EPGProgram?,
        onChannelSelected: @escaping (Channel) -> Void,
        onVODSelected: @escaping (VODResumeEntry) -> Void,
        onVODRemoved: @escaping (VODResumeEntry) -> Void,
        sportsViewModel: SportsViewModel
    ) {
        self.recentChannels = recentChannels
        self.favoriteChannels = favoriteChannels
        self.inProgressVOD = inProgressVOD
        self.currentProgram = currentProgram
        self.onChannelSelected = onChannelSelected
        self.onVODSelected = onVODSelected
        self.onVODRemoved = onVODRemoved
        self.sportsViewModel = sportsViewModel
    }

    private var liveEvents: [SportEvent] {
        guard !hideSport else { return [] }
        return sportsViewModel.sections
            .first(where: { $0.group == .live })?.events ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BufferLayout.section) {
                if !inProgressVOD.isEmpty {
                    continueWatchingSection
                }

                if !hideSport {
                    if !liveEvents.isEmpty {
                        liveSportsSection
                    } else {
                        liveSportsPlaceholder
                    }
                }

                if !recentChannels.isEmpty {
                    section(title: "Recently Watched", channels: recentChannels)
                } else {
                    sectionPlaceholder(title: "Recently Watched", icon: "clock.arrow.circlepath")
                }

                if !favoriteChannels.isEmpty {
                    section(title: "Favorites", channels: favoriteChannels)
                } else {
                    sectionPlaceholder(title: "Favorites", icon: "heart")
                }
            }
            .padding(BufferLayout.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .bufferPageBackground()
    }

    // MARK: - Continue Watching

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(BufferFont.bodyMedium)
                    .foregroundStyle(.secondary)
                Text("Continue Watching")
                    .font(BufferFont.sectionTitle)
                Text("\(inProgressVOD.count)")
                    .font(BufferFont.bodyMedium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(inProgressVOD) { entry in
                        HomeVODProgressCard(entry: entry) {
                            onVODSelected(entry)
                        } onRemove: {
                            onVODRemoved(entry)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Live Sport

    private var liveSportsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LiveIndicatorDot(size: 8)
                Text("Live Sport")
                    .font(BufferFont.sectionTitle)
                Text("\(liveEvents.count)")
                    .font(BufferFont.bodyMedium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(liveEvents) { event in
                        HomeLiveEventCard(
                            event: event,
                            viewModel: sportsViewModel,
                            onChannelSelected: onChannelSelected
                        )
                    }
                }
            }
        }
    }

    private var liveSportsPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red.opacity(0.3))
                    .frame(width: 8, height: 8)
                Text("Live Sport")
                    .font(BufferFont.sectionTitle)
                    .foregroundStyle(.secondary)
                Spacer()
                if sportsViewModel.isLoading && !sportsViewModel.hasLoadedOnce {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BufferLayout.cardGap) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: BufferLayout.cardRadius, style: .continuous)
                            .fill(Color.red.opacity(0.03))
                            .overlay(
                                RoundedRectangle(cornerRadius: BufferLayout.cardRadius, style: .continuous)
                                    .strokeBorder(Color.red.opacity(0.15), lineWidth: 0.5)
                            )
                            .frame(width: 260, height: 100)
                    }
                }
            }
        }
    }

    private func sectionPlaceholder(title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(BufferFont.caption)
                    .foregroundStyle(.quaternary)
                Text(title)
                    .font(BufferFont.sectionTitle)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: BufferLayout.compactRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: BufferLayout.compactRadius, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .frame(minWidth: 220, maxWidth: 280)
                }
            }
        }
    }

    private func section(title: String, channels: [Channel]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(BufferFont.sectionTitle)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(channels) { channel in
                    RecentChannelCard(
                        channel: channel,
                        program: currentProgram(channel),
                        onTap: { onChannelSelected(channel) }
                    )
                }
            }
        }
    }
}

private struct HomeVODProgressCard: View {
    let entry: VODResumeEntry
    let onTap: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    private var subtitle: String {
        let kind = entry.item.kind == .seriesEpisode ? "Episode" : "Movie"
        if let progress = entry.progressFraction {
            return "\(kind) · \(Int(progress * 100))% watched"
        }
        return kind
    }

    var body: some View {
        HStack(spacing: 12) {
            poster

            VStack(alignment: .leading, spacing: 7) {
                Text(entry.item.name)
                    .font(BufferFont.cardTitleMedium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(subtitle)
                    .font(BufferFont.metaMedium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ProgressView(value: entry.progressFraction ?? 0)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .controlSize(.small)

                if !entry.item.group.isEmpty {
                    Text(entry.item.genre ?? entry.item.group)
                        .font(BufferFont.microMedium)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 170, alignment: .leading)
        }
        .padding(10)
        .frame(width: 300, height: 128, alignment: .leading)
        .bufferHoverHighlight(
            isHovering: isHovering,
            cornerRadius: BufferLayout.compactRadius,
            idleFill: Color(nsColor: .controlBackgroundColor).opacity(0.65),
            hoverFill: Color(nsColor: .controlBackgroundColor).opacity(0.95),
            idleStroke: Color.primary.opacity(0.08),
            hoverStroke: Color.primary.opacity(0.22),
            lineWidth: 1,
            elevated: true
        )
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(BufferFont.microBadge)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(BufferPressStyle(scale: 0.92))
            .background(.thinMaterial, in: Circle())
            .foregroundStyle(.secondary)
            .padding(7)
            .help("Remove from Continue Watching")
        }
        .contentShape(RoundedRectangle(cornerRadius: BufferLayout.compactRadius, style: .continuous))
        .scaleEffect(isHovering ? 1.01 : 1)
        .animation(BufferMotion.hover, value: isHovering)
        .onTapGesture(perform: onTap)
        .help("Play \(entry.item.name)")
        .bufferHoverTracking($isHovering)
        .contextMenu {
            Button(action: onRemove) {
                Label("Remove from Continue Watching", systemImage: "xmark.circle")
            }
        }
    }

    private var poster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))

            RemoteArtworkView(
                url: entry.item.posterURL,
                fallbackSystemImage: entry.item.kind == .seriesEpisode ? "play.rectangle" : "film",
                width: 72,
                height: 108
            )
        }
        .frame(width: 72, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var fallbackIcon: some View {
        Image(systemName: entry.item.kind == .seriesEpisode ? "play.rectangle" : "film")
            .font(BufferFont.heroIcon)
            .foregroundStyle(.tertiary)
    }
}

private struct RecentChannelCard: View {
    let channel: Channel
    let program: EPGProgram?
    let onTap: () -> Void

    @State private var bgColor: Color
    @State private var isHovering = false

    init(channel: Channel, program: EPGProgram?, onTap: @escaping () -> Void) {
        self.channel = channel
        self.program = program
        self.onTap = onTap
        if let url = channel.logoURL, let cached = LogoColorAnalyzer.cachedColor(for: url) {
            _bgColor = State(initialValue: Color(nsColor: cached))
        } else {
            _bgColor = State(initialValue: Color(nsColor: .windowBackgroundColor))
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(bgColor)
                    ChannelLogoView(url: channel.logoURL) { color in
                        withAnimation(BufferMotion.color) {
                            bgColor = Color(nsColor: color)
                        }
                    }
                    .padding(20)
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: BufferLayout.compactRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isHovering ? 0.25 : 0.08), lineWidth: 1)
                        .animation(BufferMotion.hover, value: isHovering)
                )
                .shadow(
                    color: isHovering ? BufferLayout.cardShadow : .clear,
                    radius: BufferLayout.cardShadowRadius,
                    y: BufferLayout.cardShadowY
                )
                .overlay(alignment: .bottomLeading) {
                    StreamProbeBadge(channelID: channel.id, style: .compact)
                        .padding(6)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(BufferFont.cardTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(program?.title ?? " ")
                        .font(BufferFont.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !channel.group.isEmpty {
                        Text(channel.group)
                            .font(BufferFont.microMedium)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .padding(.top, 1)
                    }
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(BufferPressStyle())
        .help(channel.name)
        .bufferHoverTracking($isHovering)
        .requestStreamProbe(for: channel)
        .fadeIfStreamDead(channelID: channel.id)
        .contextMenu {
            Button(action: onTap) {
                Label("Play Channel", systemImage: "play.fill")
            }
            AddToMultiViewMenuItem(channel: channel)
        }
    }
}

// MARK: - Live sport card for homepage

private struct HomeLiveEventCard: View {
    let event: SportEvent
    let viewModel: SportsViewModel
    let onChannelSelected: (Channel) -> Void

    @State private var hovered = false
    @State private var showStreams = false
    @State private var matches: [StreamMatch]?
    @State private var matchUnavailableMessage: String?
    @State private var isMatching = false
    @State private var lastIndexVersion: Int = 0

    private var tournamentSubtitle: String? {
        var parts: [String] = []
        if let detail = event.detail, !detail.isEmpty {
            let lower = detail.lowercased()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: event.sport.icon)
                    .font(BufferFont.micro)
                    .foregroundStyle(.secondary)
                Text(event.league.shortName)
                    .font(BufferFont.metaMedium)
                    .foregroundStyle(.secondary)
                Spacer()
                statusBadge
            }
            .padding(.bottom, 10)

            if let away = event.awayTeam, let home = event.homeTeam {
                teamRow(away)
                    .padding(.bottom, 6)
                teamRow(home)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(BufferFont.cardTitle)
                        .lineLimit(2)
                    if let subtitle = tournamentSubtitle {
                        Text(subtitle)
                            .font(BufferFont.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 52, alignment: .center)
            }
        }
        .padding(BufferLayout.cardPadding)
        .frame(width: 260)
        .frame(minHeight: 100)
        .bufferCardSurface(isHovering: hovered, isLive: true)
        .contentShape(Rectangle())
        .scaleEffect(hovered ? 1.015 : 1)
        .bufferHoverTracking($hovered)
        .onTapGesture {
            handleTap()
        }
        .onChange(of: viewModel.searchIndexVersion) { _, newVersion in
            guard showStreams, newVersion != lastIndexVersion else { return }
            lastIndexVersion = newVersion
            rematchIfNeeded()
        }
        .popover(isPresented: $showStreams, arrowEdge: .bottom) {
            HomeLiveStreamsPopover(
                event: event,
                matches: matches ?? [],
                favoriteIDs: viewModel.favoriteChannelIDs,
                unavailableMessage: matchUnavailableMessage,
                onChannelSelected: { channel in
                    showStreams = false
                    onChannelSelected(channel)
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

    private func teamRow(_ team: TeamInfo) -> some View {
        HStack(spacing: 8) {
            RemoteArtworkView(
                url: team.logoURL,
                fallbackSystemImage: "sportscourt",
                width: 22,
                height: 22,
                scaledToFill: false
            )

            Text(team.displayName)
                .font(BufferFont.cardTitle)
                .lineLimit(1)

            if let score = team.score {
                Spacer()
                Text(score)
                    .font(BufferFont.score)
                    .monospacedDigit()
                    .foregroundStyle(.red)
            }
        }
    }

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
        default:
            EmptyView()
        }
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
        // If we already have valid matches from a previous rematch, keep them.
        if let matches, !matches.isEmpty { return }
        isMatching = true
        Task {
            let result = await viewModel.matchEvent(event)
            isMatching = false
            matches = result
            matchUnavailableMessage = result.isEmpty ? viewModel.streamIndexUnavailableMessage : nil
            // If the index became ready and we found matches, update the popover.
            // If it's still not ready, keep showing the indexing message.
        }
    }
}

// MARK: - Compact streams popover for live sport on homepage

private struct HomeLiveStreamsPopover: View {
    let event: SportEvent
    let matches: [StreamMatch]
    let favoriteIDs: Set<String>
    var unavailableMessage: String? = nil
    let onChannelSelected: (Channel) -> Void

    var body: some View {
        StreamMatchesPopover(
            event: event,
            matches: matches,
            favoriteIDs: favoriteIDs,
            unavailableMessage: unavailableMessage,
            onPlay: onChannelSelected
        )
    }
}
