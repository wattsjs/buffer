import SwiftUI

struct HomeView: View {
    let recentChannels: [Channel]
    let favoriteChannels: [Channel]
    let currentProgram: (Channel) -> EPGProgram?
    let onChannelSelected: (Channel) -> Void
    let sportsViewModel: SportsViewModel
    @AppStorage("hideSport") private var hideSport = false

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)]

    private var liveEvents: [SportEvent] {
        guard !hideSport else { return [] }
        return sportsViewModel.sections
            .first(where: { $0.group == .live })?.events ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
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
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Live Sport

    private var liveSportsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text("Live Sport")
                    .font(.system(size: 18, weight: .semibold))
                Text("\(liveEvents.count)")
                    .font(.system(size: 13, weight: .medium))
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
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if sportsViewModel.isLoading && !sportsViewModel.hasLoadedOnce {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.red.opacity(0.03))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
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
                    .font(.system(size: 12))
                    .foregroundStyle(.quaternary)
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
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
                .font(.system(size: 18, weight: .semibold))
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
                        withAnimation(.easeInOut(duration: 0.25)) {
                            bgColor = Color(nsColor: color)
                        }
                    }
                    .padding(20)
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isHovering ? 0.25 : 0.08), lineWidth: 1)
                )
                .overlay(alignment: .bottomLeading) {
                    StreamProbeBadge(channelID: channel.id, style: .compact)
                        .padding(6)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(program?.title ?? " ")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !channel.group.isEmpty {
                        Text(channel.group)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .padding(.top, 1)
                    }
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(channel.name)
        .onHover { isHovering = $0 }
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
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(event.league.shortName)
                    .font(.system(size: 11, weight: .medium))
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
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    if let subtitle = tournamentSubtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 52, alignment: .center)
            }
        }
        .padding(14)
        .frame(width: 260)
        .frame(minHeight: 100)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red.opacity(hovered ? 0.1 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.red.opacity(0.3), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            if let matches, !matches.isEmpty {
                showStreams = true
            } else if let message = viewModel.streamIndexUnavailableMessage {
                matches = []
                matchUnavailableMessage = message
                showStreams = true
            } else {
                isMatching = true
                Task {
                    let result = await viewModel.matchEvent(event)
                    isMatching = false
                    matches = result
                    matchUnavailableMessage = nil
                    if !result.isEmpty {
                        showStreams = true
                    }
                }
            }
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
            if let url = team.logoURL {
                AsyncImage(url: url) { image in
                    image.resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    Color.clear
                }
                .frame(width: 22, height: 22)
            }

            Text(team.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            if let score = team.score {
                Spacer()
                Text(score)
                    .font(.system(size: 15, weight: .bold))
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
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                Text(detail ?? "LIVE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.red)
            }
        case .halftime:
            Text("HT")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.orange)
        default:
            EmptyView()
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
