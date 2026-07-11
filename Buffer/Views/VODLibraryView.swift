import SwiftUI
import Nuke
import NukeUI

private enum VODSortOrder: String, CaseIterable, Identifiable {
    case title = "Title"
    case genre = "Genre"

    var id: String { rawValue }
}

private enum VODPosterMetrics {
    static let width: CGFloat = 156
    static let height: CGFloat = 234
    static let titleHeight: CGFloat = 36
    static let subtitleHeight: CGFloat = 16
    static let cardHeight: CGFloat = 313
    static let cornerRadius: CGFloat = 8
}

struct VODLibraryView: View {
    let items: [VODItem]
    let itemProvider: (VODItem) -> VODItem
    let isItemLoading: (VODItem) -> Bool
    let itemLoadError: (VODItem) -> String?
    let resumeProvider: (VODItem) -> VODResumeEntry?
    let hasLoadedOnce: Bool
    let onItemFocused: (VODItem) -> Void
    let onItemSelected: (VODItem, Double?) -> Void

    @State private var selectedGenre = "All"
    @State private var sortOrder: VODSortOrder = .title
    @State private var selectedItem: VODItem?

    private let columns = [
        GridItem(.adaptive(minimum: VODPosterMetrics.width, maximum: VODPosterMetrics.width), spacing: 18)
    ]

    private var genres: [String] {
        ["All"] + Set(items.map { $0.genre ?? $0.group }.filter { !$0.isEmpty }).sorted()
    }

    private var filteredItems: [VODItem] {
        var result = items
        if selectedGenre != "All" {
            result = result.filter { ($0.genre ?? $0.group) == selectedGenre }
        }
        switch sortOrder {
        case .title:
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .genre:
            return result.sorted {
                let lhs = "\($0.genre ?? $0.group) \($0.name)"
                let rhs = "\($1.genre ?? $1.group) \($1.name)"
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        }
    }

    var body: some View {
        Group {
            if let selectedItem {
                VODItemDetailPage(
                    item: itemProvider(selectedItem),
                    isLoadingMetadata: isItemLoading(selectedItem),
                    metadataLoadError: itemLoadError(selectedItem),
                    resumeEntry: resumeProvider(itemProvider(selectedItem)),
                    backTitle: "Movies",
                    onBack: { self.selectedItem = nil },
                    onPlay: { resumePosition in
                        onItemSelected(itemProvider(selectedItem), resumePosition)
                    }
                )
                .task(id: selectedItem.id) {
                    onItemFocused(selectedItem)
                }
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label(hasLoadedOnce ? "No Movies" : "Loading Movies", systemImage: "film")
                } description: {
                    Text(hasLoadedOnce ? "This playlist does not expose movies." : "Syncing the playlist.")
                }
            } else {
                VStack(spacing: 0) {
                    VODFilterBar(
                        count: filteredItems.count,
                        genres: genres,
                        selectedGenre: $selectedGenre,
                        sortOrder: $sortOrder
                    )
                    Divider()
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                            ForEach(filteredItems) { item in
                                VODPosterCard(
                                    title: item.name,
                                    subtitle: item.genre ?? item.group,
                                    posterURL: item.posterURL,
                                    fallbackSystemImage: "film",
                                    badge: item.containerExtension?.uppercased(),
                                    resumeEntry: resumeProvider(item),
                                    onOpen: { selectedItem = item }
                                )
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .bufferPageBackground()
        .onChange(of: items.count) { _, _ in
            if selectedGenre != "All" && !genres.contains(selectedGenre) {
                selectedGenre = "All"
            }
            if let selectedItem, !items.contains(where: { $0.id == selectedItem.id }) {
                self.selectedItem = nil
            }
        }
    }
}

struct SeriesLibraryView: View {
    let series: [VODSeries]
    let episodesProvider: (VODSeries) -> [VODItem]
    let isLoading: (VODSeries) -> Bool
    let loadError: (VODSeries) -> String?
    let resumeProvider: (VODItem) -> VODResumeEntry?
    let hasLoadedOnce: Bool
    let onSeriesSelected: (VODSeries) -> Void
    let onEpisodeSelected: (VODItem, Double?) -> Void

    @State private var selectedGenre = "All"
    @State private var sortOrder: VODSortOrder = .title
    @State private var selectedSeries: VODSeries?

    private let columns = [
        GridItem(.adaptive(minimum: VODPosterMetrics.width, maximum: VODPosterMetrics.width), spacing: 18)
    ]

    private var genres: [String] {
        ["All"] + Set(series.map(\.group).filter { !$0.isEmpty }).sorted()
    }

    private var filteredSeries: [VODSeries] {
        var result = series
        if selectedGenre != "All" {
            result = result.filter { $0.group == selectedGenre }
        }
        switch sortOrder {
        case .title:
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .genre:
            return result.sorted {
                let lhs = "\($0.group) \($0.name)"
                let rhs = "\($1.group) \($1.name)"
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        }
    }

    var body: some View {
        Group {
            if let selectedSeries {
                SeriesDetailPage(
                    series: selectedSeries,
                    episodes: episodesProvider(selectedSeries),
                    isLoading: isLoading(selectedSeries),
                    loadError: loadError(selectedSeries),
                    resumeProvider: resumeProvider,
                    backTitle: "TV",
                    onBack: { self.selectedSeries = nil },
                    onEpisodeSelected: onEpisodeSelected
                )
            } else if series.isEmpty {
                ContentUnavailableView {
                    Label(hasLoadedOnce ? "No TV Shows" : "Loading TV", systemImage: "rectangle.stack")
                } description: {
                    Text(hasLoadedOnce ? "This playlist does not expose TV shows." : "Syncing the playlist.")
                }
            } else {
                VStack(spacing: 0) {
                    VODFilterBar(
                        count: filteredSeries.count,
                        genres: genres,
                        selectedGenre: $selectedGenre,
                        sortOrder: $sortOrder
                    )
                    Divider()
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                            ForEach(filteredSeries) { item in
                                VODPosterCard(
                                    title: item.name,
                                    subtitle: item.group,
                                    posterURL: item.posterURL,
                                    fallbackSystemImage: "rectangle.stack",
                                    badge: nil,
                                    resumeEntry: nil,
                                    onOpen: {
                                        selectedSeries = item
                                        onSeriesSelected(item)
                                    }
                                )
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .bufferPageBackground()
        .onChange(of: series.count) { _, _ in
            if selectedGenre != "All" && !genres.contains(selectedGenre) {
                selectedGenre = "All"
            }
            if let selectedSeries, !series.contains(where: { $0.id == selectedSeries.id }) {
                self.selectedSeries = nil
            }
        }
    }
}

private struct VODFilterBar: View {
    let count: Int
    let genres: [String]
    @Binding var selectedGenre: String
    @Binding var sortOrder: VODSortOrder

    var body: some View {
        BufferFilterBar {
            HStack(spacing: 12) {
                Text("\(count) title\(count == 1 ? "" : "s")")
                    .font(BufferFont.captionMedium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()

                Picker("Genre", selection: $selectedGenre) {
                    ForEach(genres, id: \.self) { genre in
                        Text(genre).tag(genre)
                    }
                }
                .frame(width: 190)

                Picker("Sort", selection: $sortOrder) {
                    ForEach(VODSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .frame(width: 120)
            }
        }
    }
}

private struct VODPosterCard: View {
    let title: String
    let subtitle: String
    let posterURL: URL?
    let fallbackSystemImage: String
    let badge: String?
    let resumeEntry: VODResumeEntry?
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                VODPosterArtwork(url: posterURL, fallbackSystemImage: fallbackSystemImage)
                    .overlay(
                        RoundedRectangle(cornerRadius: VODPosterMetrics.cornerRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isHovering ? 0.25 : 0.08), lineWidth: 1)
                            .animation(BufferMotion.hover, value: isHovering)
                    )
                    .shadow(
                        color: isHovering ? BufferLayout.cardShadow : .clear,
                        radius: BufferLayout.cardShadowRadius,
                        y: BufferLayout.cardShadowY
                    )
                    .scaleEffect(isHovering ? 1.02 : 1)
                    .animation(BufferMotion.hover, value: isHovering)
                    .overlay(alignment: .bottomTrailing) {
                        if let badge, !badge.isEmpty {
                            Text(badge)
                                .font(BufferFont.microSemibold)
                                .monospaced()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.thinMaterial, in: Capsule())
                                .padding(8)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress = resumeEntry?.progressFraction {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .tint(.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 8)
                        }
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(BufferFont.cardTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(height: VODPosterMetrics.titleHeight, alignment: .topLeading)

                    Text(subtitle)
                        .font(BufferFont.metaMedium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: VODPosterMetrics.subtitleHeight, alignment: .topLeading)
                    if let resumeEntry {
                        Text(resumeText(for: resumeEntry))
                            .font(BufferFont.microSemibold)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: VODPosterMetrics.width, height: VODPosterMetrics.cardHeight, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(BufferPressStyle())
        .help(title)
        .bufferHoverTracking($isHovering)
    }
}

private struct VODPosterArtwork: View {
    let url: URL?
    let fallbackSystemImage: String
    var width: CGFloat = VODPosterMetrics.width
    var height: CGFloat = VODPosterMetrics.height

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: VODPosterMetrics.cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.04))

            RemoteArtworkView(
                url: url,
                fallbackSystemImage: fallbackSystemImage,
                width: width,
                height: height
            )
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: VODPosterMetrics.cornerRadius, style: .continuous))
    }

}

struct VODItemDetailPage: View {
    let item: VODItem
    var isLoadingMetadata = false
    var metadataLoadError: String? = nil
    var resumeEntry: VODResumeEntry? = nil
    let backTitle: String
    let onBack: () -> Void
    let onPlay: (Double?) -> Void

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 28) {
                VODPosterArtwork(
                    url: item.posterURL,
                    fallbackSystemImage: "film",
                    width: 220,
                    height: 330
                )
                .overlay(
                    RoundedRectangle(cornerRadius: VODPosterMetrics.cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name)
                            .font(BufferFont.display)
                            .lineLimit(3)
                        Text(item.genre ?? item.group)
                            .font(BufferFont.titleMedium)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            onPlay(resumeEntry?.positionSeconds)
                        } label: {
                            Label(resumeEntry == nil ? "Play" : "Resume", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        if let resumeEntry {
                            VODResumeProgress(entry: resumeEntry)
                                .frame(maxWidth: 260)
                        }
                    }

                    VODMetadataGrid(rows: metadataRows(for: item))

                    if isLoadingMetadata {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading metadata")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    } else if let metadataLoadError {
                        Label(metadataLoadError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let summary = item.summary, !summary.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Summary")
                                .font(.headline)
                            Text(summary)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(item.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                VODHeaderBackButton(title: backTitle, action: onBack)
            }
        }
        .bufferPageBackground()
    }
}

struct SeriesDetailPage: View {
    let series: VODSeries
    let episodes: [VODItem]
    let isLoading: Bool
    let loadError: String?
    let resumeProvider: (VODItem) -> VODResumeEntry?
    let backTitle: String
    let onBack: () -> Void
    let onEpisodeSelected: (VODItem, Double?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 28) {
                    VODPosterArtwork(
                        url: series.posterURL,
                        fallbackSystemImage: "rectangle.stack",
                        width: 190,
                        height: 285
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: VODPosterMetrics.cornerRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(series.name)
                                .font(BufferFont.display)
                                .lineLimit(3)
                            Text(series.group)
                                .font(BufferFont.titleMedium)
                                .foregroundStyle(.secondary)
                        }

                            VODMetadataGrid(rows: [
                                ("Type", "TV"),
                                ("Genre", series.genre ?? series.group),
                                ("Episodes", episodeCountText(series: series, episodes: episodes, isLoading: isLoading)),
                                ("Released", series.releaseDate ?? ""),
                                ("Rating", series.rating ?? ""),
                                ("Director", series.director ?? ""),
                                ("Cast", series.cast ?? "")
                            ])

                            if let summary = series.summary, !summary.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Summary")
                                        .font(.headline)
                                    Text(summary)
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: 520, alignment: .leading)
                    }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Episodes")
                        .font(.title3.weight(.semibold))

                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading episodes")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 18)
                    } else if let loadError {
                        ContentUnavailableView(
                            "Could Not Load Episodes",
                            systemImage: "exclamationmark.triangle",
                            description: Text(loadError)
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else if episodes.isEmpty {
                        ContentUnavailableView(
                            "No Episodes in Playlist",
                            systemImage: "rectangle.stack",
                            description: Text("The provider returned metadata for this series, but no playable episode entries.")
                        )
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(episodes) { episode in
                                EpisodeRow(episode: episode, resumeEntry: resumeProvider(episode)) { resumePosition in
                                    onEpisodeSelected(episode, resumePosition)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(series.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                VODHeaderBackButton(title: backTitle, action: onBack)
            }
        }
        .bufferPageBackground()
    }
}

private struct VODResumeProgress: View {
    let entry: VODResumeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(BufferFont.metaMedium)
                Text(resumeText(for: entry))
                    .font(BufferFont.captionMedium)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)

            ProgressView(value: entry.progressFraction ?? 0)
                .progressViewStyle(.linear)
                .tint(.accentColor)
        }
    }
}

private struct VODHeaderBackButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(BufferFont.cardTitleMedium)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .accessibilityLabel("Back to \(title)")
        .help("Back to \(title)")
    }
}

private struct EpisodeRow: View {
    let episode: VODItem
    let resumeEntry: VODResumeEntry?
    let onPlay: (Double?) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VODPosterArtwork(
                url: episode.posterURL,
                fallbackSystemImage: "play.rectangle",
                width: 68,
                height: 102
            )

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(episode.name)
                        .font(BufferFont.cardTitleMedium)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        onPlay(resumeEntry?.positionSeconds)
                    } label: {
                        Label(resumeEntry == nil ? "Play" : "Resume", systemImage: "play.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }

                EpisodeMetadataStrip(episode: episode)

                if let resumeEntry {
                    VODResumeProgress(entry: resumeEntry)
                        .frame(maxWidth: 240)
                }

                if let summary = episode.summary, !summary.isEmpty {
                    Text(summary)
                        .font(BufferFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: BufferLayout.compactRadius, style: .continuous))
        .onTapGesture {
            onPlay(resumeEntry?.positionSeconds)
        }
        .bufferHoverTracking($isHovering)
        .bufferHoverHighlight(
            isHovering: isHovering,
            cornerRadius: BufferLayout.compactRadius,
            idleFill: Color(nsColor: .controlBackgroundColor),
            hoverFill: Color.accentColor.opacity(0.10),
            idleStroke: Color.primary.opacity(0.08),
            hoverStroke: Color.accentColor.opacity(0.35),
            lineWidth: 1,
            elevated: true
        )
        .accessibilityAddTraits(.isButton)
        .help("\(resumeEntry == nil ? "Play" : "Resume") \(episode.name)")
    }
}

private struct EpisodeMetadataStrip: View {
    let episode: VODItem

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(episodeMetadataBadges(for: episode), id: \.self) { value in
                    EpisodeMetadataBadge(value)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    ForEach(Array(episodeMetadataBadges(for: episode).prefix(4)), id: \.self) { value in
                        EpisodeMetadataBadge(value)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(Array(episodeMetadataBadges(for: episode).dropFirst(4)), id: \.self) { value in
                        EpisodeMetadataBadge(value)
                    }
                }
            }
        }
    }
}

private struct EpisodeMetadataBadge: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(BufferFont.metaMedium)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.055))
            )
    }
}

private struct VODMetadataGrid: View {
    let rows: [(String, String)]
    var compact = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: compact ? 8 : 14, verticalSpacing: compact ? 3 : 7) {
            ForEach(rows.filter { !$0.1.isEmpty }, id: \.0) { row in
                GridRow {
                    Text(row.0)
                        .font(compact ? .caption2 : .callout.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text(row.1)
                        .font(compact ? .caption : .callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 1 : (row.0 == "Cast" ? 4 : 2))
                }
            }
        }
    }
}

private func metadataRows(for item: VODItem) -> [(String, String)] {
    var rows: [(String, String)] = [("Type", item.kind == .seriesEpisode ? "Episode" : "Movie")]
    rows.append(("Genre", item.genre ?? item.group))
    if let seasonNumber = item.seasonNumber {
        rows.append(("Season", "\(seasonNumber)"))
    }
    if let episodeNumber = item.episodeNumber {
        rows.append(("Episode", "\(episodeNumber)"))
    }
    if let releaseDate = item.releaseDate, !releaseDate.isEmpty {
        rows.append(("Released", releaseDate))
    }
    if let rating = item.rating, !rating.isEmpty {
        rows.append(("Rating", rating))
    }
    if let duration = item.durationSeconds, duration > 0 {
        rows.append(("Runtime", runtimeString(seconds: duration)))
    }
    if let ext = item.containerExtension, !ext.isEmpty {
        rows.append(("Format", ext.uppercased()))
    }
    if let country = item.country, !country.isEmpty {
        rows.append(("Country", country))
    }
    if let director = item.director, !director.isEmpty {
        rows.append(("Director", director))
    }
    if let cast = item.cast, !cast.isEmpty {
        rows.append(("Cast", cast))
    }
    return rows
}

private func resumeText(for entry: VODResumeEntry) -> String {
    let position = playbackTimeString(seconds: entry.positionSeconds)
    guard let duration = entry.durationSeconds, duration > 0 else {
        return "Resume \(position)"
    }
    return "Resume \(position) of \(playbackTimeString(seconds: duration))"
}

private func playbackTimeString(seconds: Double) -> String {
    let totalSeconds = max(Int(seconds.rounded()), 0)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
}

private func episodeMetadataBadges(for item: VODItem) -> [String] {
    var badges: [String] = []
    if let season = item.seasonNumber, let episode = item.episodeNumber {
        badges.append("S\(String(format: "%02d", season)) E\(String(format: "%02d", episode))")
    } else if let season = item.seasonNumber {
        badges.append("Season \(season)")
    } else if let episode = item.episodeNumber {
        badges.append("Episode \(episode)")
    }
    if let duration = item.durationSeconds, duration > 0 {
        badges.append(runtimeString(seconds: duration))
    }
    if let rating = item.rating, !rating.isEmpty {
        badges.append("Rating \(rating)")
    }
    if let releaseDate = item.releaseDate, !releaseDate.isEmpty {
        badges.append(releaseDate)
    }
    if let ext = item.containerExtension, !ext.isEmpty {
        badges.append(ext.uppercased())
    }
    if badges.isEmpty, let genre = item.genre, !genre.isEmpty {
        badges.append(genre)
    }
    return badges
}

private func episodeCountText(series: VODSeries, episodes: [VODItem], isLoading: Bool) -> String {
    if !episodes.isEmpty {
        return "\(episodes.count)"
    }
    if let count = series.episodeCount, count > 0 {
        return "\(count)"
    }
    return isLoading ? "Loading" : "0"
}

private func runtimeString(seconds: Int) -> String {
    let minutes = max(seconds / 60, 1)
    if minutes >= 60 {
        return "\(minutes / 60)h \(minutes % 60)m"
    }
    return "\(minutes)m"
}
