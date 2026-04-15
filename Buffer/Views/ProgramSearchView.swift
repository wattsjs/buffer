import SwiftUI

nonisolated struct ProgramSearchEntry: Sendable {
    let program: EPGProgram
    let channel: Channel
    let titleLower: String
    let channelNameLower: String
}

nonisolated struct ChannelSearchEntry: Sendable {
    let channel: Channel
    let nameLower: String
}

nonisolated struct ProgramSearchResult: Identifiable, Sendable {
    var id: String { program.id }
    let program: EPGProgram
    let channel: Channel
    let score: Double
}

nonisolated struct ChannelSearchResult: Identifiable, Sendable {
    var id: String { channel.id }
    let channel: Channel
    let score: Double
}

@Observable
@MainActor
final class ProgramSearchController {
    var query: String = ""
    var programResults: [ProgramSearchResult] = []
    var channelResults: [ChannelSearchResult] = []
    var isSearching: Bool = false

    private var programEntries: [ProgramSearchEntry] = []
    private var channelEntries: [ChannelSearchEntry] = []
    private var currentTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var totalResultCount: Int {
        programResults.count + channelResults.count
    }

    func updateIndex(programs: [ProgramSearchEntry], channels: [Channel]) {
        self.programEntries = programs
        self.channelEntries = channels.map {
            ChannelSearchEntry(channel: $0, nameLower: $0.name.lowercased())
        }
        if hasQuery { runSearch() }
    }

    func setQuery(_ newQuery: String) {
        query = newQuery
        debounceTask?.cancel()

        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            currentTask?.cancel()
            programResults = []
            channelResults = []
            isSearching = false
            return
        }

        isSearching = true
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            if Task.isCancelled { return }
            self?.runSearch()
        }
    }

    func clear() {
        setQuery("")
    }

    private func runSearch() {
        currentTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            programResults = []
            channelResults = []
            isSearching = false
            return
        }

        let programSnapshot = programEntries
        let channelSnapshot = channelEntries
        let now = Date()

        currentTask = Task.detached(priority: .userInitiated) { [trimmed, programSnapshot, channelSnapshot, now] in
            let tokens = trimmed
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)

            // MARK: Program matches
            var programHits: [ProgramSearchResult] = []
            programHits.reserveCapacity(256)

            var checkCounter = 0
            for entry in programSnapshot {
                checkCounter += 1
                if checkCounter & 4095 == 0, Task.isCancelled { return }

                let title = entry.titleLower
                var allMatch = true
                for token in tokens {
                    if !title.contains(token) {
                        allMatch = false
                        break
                    }
                }
                if !allMatch { continue }

                var score: Double = 0
                if title.hasPrefix(trimmed) {
                    score += 120
                } else if title.contains(trimmed) {
                    score += 70
                } else {
                    score += 10
                }

                let p = entry.program
                if p.start <= now && p.end > now {
                    score += 80
                } else if p.start > now {
                    let minutes = p.start.timeIntervalSince(now) / 60
                    if minutes < 24 * 60 {
                        score += 40 - (minutes / (24 * 60)) * 40
                    } else if minutes < 7 * 24 * 60 {
                        score += 4
                    }
                } else {
                    score -= 40
                }

                programHits.append(ProgramSearchResult(program: p, channel: entry.channel, score: score))
            }

            if Task.isCancelled { return }
            programHits.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let lFuture = lhs.program.end > now
                let rFuture = rhs.program.end > now
                if lFuture != rFuture { return lFuture }
                if lFuture {
                    return lhs.program.start < rhs.program.start
                } else {
                    return lhs.program.start > rhs.program.start
                }
            }
            var seenProgramIDs = Set<String>()
            seenProgramIDs.reserveCapacity(min(programHits.count, 300))
            var cappedPrograms: [ProgramSearchResult] = []
            cappedPrograms.reserveCapacity(min(programHits.count, 300))
            for hit in programHits {
                if cappedPrograms.count >= 300 { break }
                if seenProgramIDs.insert(hit.id).inserted {
                    cappedPrograms.append(hit)
                }
            }

            // MARK: Channel matches
            var channelHits: [ChannelSearchResult] = []
            channelHits.reserveCapacity(64)
            for entry in channelSnapshot {
                let name = entry.nameLower
                var allMatch = true
                for token in tokens {
                    if !name.contains(token) {
                        allMatch = false
                        break
                    }
                }
                if !allMatch { continue }

                var score: Double = 0
                if name == trimmed {
                    score += 200
                } else if name.hasPrefix(trimmed) {
                    score += 120
                } else {
                    score += 60
                }
                channelHits.append(ChannelSearchResult(channel: entry.channel, score: score))
            }
            channelHits.sort { $0.score > $1.score }

            if Task.isCancelled { return }

            let finalPrograms = cappedPrograms
            let finalChannels = channelHits
            await MainActor.run { [weak self] in
                guard let self else { return }
                if Task.isCancelled { return }
                self.programResults = finalPrograms
                self.channelResults = finalChannels
                self.isSearching = false
            }
        }
    }
}

// MARK: - Full-page results

struct ProgramSearchResultsPage: View {
    let controller: ProgramSearchController
    let totalIndexed: Int
    let currentProgram: (Channel) -> EPGProgram?
    let onSelect: (Channel) -> Void
    let onShowInEPG: (Channel) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if controller.hasQuery {
                Text("\u{201C}\(controller.query)\u{201D}")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            headerTrailing
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var headerTrailing: some View {
        let total = controller.totalResultCount
        if total > 0 {
            Text("\(total) result\(total == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else if controller.isSearching {
            ProgressView()
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var content: some View {
        let total = controller.totalResultCount
        if !controller.hasQuery {
            emptyState
        } else if total == 0 && !controller.isSearching {
            noResults
        } else if total == 0 && controller.isSearching {
            searching
        } else {
            VStack(spacing: 0) {
                if !controller.channelResults.isEmpty {
                    channelsStrip
                    Divider()
                }
                programsList
            }
        }
    }

    // MARK: Channels strip

    private var channelsStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("CHANNELS", count: controller.channelResults.count)
                .padding(.horizontal, 18)
                .padding(.top, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(controller.channelResults) { result in
                        ChannelCompactCard(
                            channel: result.channel,
                            query: controller.query,
                            nowPlaying: currentProgram(result.channel),
                            onSelect: { onSelect(result.channel) }
                        )
                    }
                }
                .padding(.horizontal, 18)
            }
            .frame(height: 74)
            .padding(.bottom, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Programs list

    private enum ProgramTimeGroup: Int, CaseIterable {
        case onNow = 0
        case next30m
        case laterToday
        case tomorrow
        case thisWeek
        case later
        case alreadyAired

        var title: String {
            switch self {
            case .onNow: "ON NOW"
            case .next30m: "STARTING SOON"
            case .laterToday: "LATER TODAY"
            case .tomorrow: "TOMORROW"
            case .thisWeek: "THIS WEEK"
            case .later: "UPCOMING"
            case .alreadyAired: "ALREADY AIRED"
            }
        }

        var icon: String {
            switch self {
            case .onNow: "play.circle.fill"
            case .next30m: "clock.badge"
            case .laterToday: "sun.horizon.fill"
            case .tomorrow: "sunrise.fill"
            case .thisWeek: "calendar"
            case .later: "calendar.badge.clock"
            case .alreadyAired: "checkmark.circle"
            }
        }

        var accentColor: Color {
            switch self {
            case .onNow: .red
            case .next30m: .orange
            case .laterToday: .yellow
            case .tomorrow: .blue
            case .thisWeek: .purple
            case .later: .indigo
            case .alreadyAired: Color.secondary.opacity(0.6)
            }
        }

        static func group(for program: EPGProgram, now: Date = Date()) -> ProgramTimeGroup {
            let cal = Calendar.current
            if program.start <= now && program.end > now { return .onNow }
            if program.end <= now { return .alreadyAired }
            let minutes = program.start.timeIntervalSince(now) / 60
            if minutes <= 30 { return .next30m }
            if cal.isDateInToday(program.start) { return .laterToday }
            if cal.isDateInTomorrow(program.start) { return .tomorrow }
            if minutes < 7 * 24 * 60 { return .thisWeek }
            return .later
        }
    }

    private var groupedPrograms: [(group: ProgramTimeGroup, results: [ProgramSearchResult])] {
        let now = Date()
        var buckets: [ProgramTimeGroup: [ProgramSearchResult]] = [:]
        for result in controller.programResults {
            let group = ProgramTimeGroup.group(for: result.program, now: now)
            // Only include already-aired programs if the channel supports catchup
            if group == .alreadyAired && !result.channel.supportsRewind { continue }
            buckets[group, default: []].append(result)
        }
        // Sort within each group: on-now by time remaining, future by start time, past by most recent first
        for (group, items) in buckets {
            buckets[group] = items.sorted { lhs, rhs in
                switch group {
                case .alreadyAired:
                    return lhs.program.start > rhs.program.start
                default:
                    return lhs.program.start < rhs.program.start
                }
            }
        }
        return ProgramTimeGroup.allCases.compactMap { group in
            guard let items = buckets[group], !items.isEmpty else { return nil }
            return (group: group, results: items)
        }
    }

    private let programColumns = [
        GridItem(.adaptive(minimum: 420, maximum: .infinity), spacing: 8)
    ]

    @ViewBuilder
    private var programsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("PROGRAMS", count: controller.programResults.count)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if controller.programResults.isEmpty {
                Text("No matching programs")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                        ForEach(groupedPrograms, id: \.group) { section in
                            Section {
                                LazyVGrid(columns: programColumns, alignment: .leading, spacing: 8) {
                                    ForEach(section.results) { result in
                                        ProgramResultRow(
                                            result: result,
                                            query: controller.query,
                                            onSelect: { onSelect(result.channel) },
                                            onShowInEPG: { onShowInEPG(result.channel) }
                                        )
                                    }
                                }
                            } header: {
                                programGroupHeader(section.group, count: section.results.count)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func programGroupHeader(_ group: ProgramTimeGroup, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: group.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(group.accentColor)
                .frame(width: 14)
            Text(group.title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.bar)
        )
    }

    // MARK: Section label

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
        }
    }

    // MARK: Empty states

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Search programs & channels")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("\(totalIndexed.formatted()) programs indexed")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No matches for \u{201C}\(controller.query)\u{201D}")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("Searched \(totalIndexed) program\(totalIndexed == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searching: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Searching…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Highlighting helper

private func highlighted(_ raw: String, query: String) -> AttributedString {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let matchRange = raw.range(of: trimmed, options: .caseInsensitive)
    else {
        return AttributedString(raw)
    }
    let prefix = String(raw[..<matchRange.lowerBound])
    let match = String(raw[matchRange])
    let suffix = String(raw[matchRange.upperBound...])

    var container = AttributeContainer()
    container.backgroundColor = Color.yellow.opacity(0.4)
    container.foregroundColor = .primary

    var output = AttributedString(prefix)
    var matchAttr = AttributedString(match)
    matchAttr.mergeAttributes(container)
    output.append(matchAttr)
    output.append(AttributedString(suffix))
    return output
}

// MARK: - Channel compact card (horizontal strip)

private struct ChannelCompactCard: View {
    let channel: Channel
    let query: String
    let nowPlaying: EPGProgram?
    let onSelect: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            ChannelLogoTile(channel: channel)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlighted(channel.name, query: query))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if !channel.group.isEmpty {
                    Text(channel.group)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let nowPlaying {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 4, height: 4)
                        Text(nowPlaying.title)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 240, height: 72, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovered ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(hovered ? Color.accentColor.opacity(0.4) : Color.black.opacity(0.08), lineWidth: 0.75)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(action: onSelect) {
                Label("Play Channel", systemImage: "play.fill")
            }
            AddToMultiViewMenuItem(channel: channel)
        }
    }
}

// MARK: - Program row (EPG-style)

private struct ProgramResultRow: View {
    let result: ProgramSearchResult
    let query: String
    let onSelect: () -> Void
    let onShowInEPG: () -> Void

    @State private var hovered = false
    @State private var showPopover = false
    @State private var notificationManager = NotificationManager.shared

    private var existingReminder: ProgramReminder? {
        notificationManager.reminder(for: result.program)
    }

    private var canRemind: Bool {
        result.program.end > Date()
    }

    /// The program is in the past (or currently airing) AND the channel's
    /// catchup window still covers its start — suitable for "Play from start".
    private var canPlayFromCatchup: Bool {
        guard let days = result.channel.catchup?.days, days > 0 else { return false }
        let windowStart = Date().addingTimeInterval(-Double(days) * 86400)
        return result.program.start >= windowStart && result.program.start < Date()
    }

    private var isLive: Bool {
        result.program.isNowPlaying
    }

    private func activate() {
        if isLive {
            onSelect()
        } else {
            showPopover = true
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ChannelLogoTile(channel: result.channel)
                .frame(width: 72, height: 72)
                .overlay(alignment: .bottomTrailing) {
                    if result.channel.supportsRewind {
                        Image(systemName: "gobackward")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(.black.opacity(0.5)))
                            .padding(4)
                            .help("Rewind available")
                    }
                }
            programCard
        }
        .frame(height: 80)
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovered ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: activate)
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            ProgramDetailPopover(
                program: result.program,
                channel: result.channel,
                onPlay: {
                    showPopover = false
                    if canPlayFromCatchup {
                        PendingCatchup.set(channelID: result.channel.id, start: result.program.start)
                    }
                    onSelect()
                }
            )
        }
        .contextMenu { reminderMenuItems }
    }

    @ViewBuilder
    private var reminderMenuItems: some View {
        Text(result.program.title.isEmpty ? "Program" : result.program.title)

        Divider()

        if let existing = existingReminder {
            Button {
                notificationManager.cancelReminder(for: result.program)
            } label: {
                Label(
                    "Cancel Reminder (\(existing.leadMinutes == 0 ? "at start" : "\(existing.leadMinutes) min before"))",
                    systemImage: "bell.slash"
                )
            }
        } else if !canRemind {
            Text("Already aired")
        } else {
            Button {
                schedule(lead: 0)
            } label: {
                Label("Remind Me at Start", systemImage: "bell")
            }
            Button {
                schedule(lead: 5)
            } label: {
                Label("Remind Me 5 min Before", systemImage: "bell")
            }
            Button {
                schedule(lead: 15)
            } label: {
                Label("Remind Me 15 min Before", systemImage: "bell")
            }
            Button {
                schedule(lead: 60)
            } label: {
                Label("Remind Me 1 hour Before", systemImage: "bell")
            }
        }

        Divider()

        if canPlayFromCatchup {
            Button {
                activate()
            } label: {
                Label("Play from start", systemImage: "play.fill")
            }
            Button {
                onSelect()
            } label: {
                Label("Play live", systemImage: "dot.radiowaves.left.and.right")
            }
        } else {
            Button {
                onSelect()
            } label: {
                Label("Play Channel", systemImage: "play.fill")
            }
        }
        AddToMultiViewMenuItem(channel: result.channel)

        Divider()

        Button(action: onShowInEPG) {
            Label("Show in Guide", systemImage: "calendar.circle")
        }
    }

    private func schedule(lead: Int) {
        let program = result.program
        let channel = result.channel
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

    private var programCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(highlighted(result.program.title.isEmpty ? "Untitled" : result.program.title, query: query))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if result.program.isNowPlaying {
                    Text("NOW")
                        .font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 8)
                Text(formatWhen(program: result.program))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }
            HStack(spacing: 6) {
                Text(result.channel.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(Color.secondary.opacity(0.6))
                Text(timeRange(for: result.program))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary.opacity(0.85))
                    .monospacedDigit()
            }
            .lineLimit(1)
            Text(result.program.description.isEmpty ? " " : result.program.description)
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary.opacity(0.75))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(result.program.isNowPlaying
                      ? Color(nsColor: .tertiaryLabelColor).opacity(0.55)
                      : Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func timeRange(for program: EPGProgram) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return "\(f.string(from: program.start)) – \(f.string(from: program.end))"
    }

    private func formatWhen(program: EPGProgram) -> String {
        let now = Date()
        if program.start <= now && program.end > now {
            let minsLeft = max(0, Int(program.end.timeIntervalSince(now) / 60))
            return "\(minsLeft)m left"
        }
        if program.end <= now {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .abbreviated
            return f.localizedString(for: program.end, relativeTo: now)
        }
        let interval = program.start.timeIntervalSince(now)
        let hm = DateFormatter()
        hm.dateFormat = "h:mma"
        hm.amSymbol = "am"
        hm.pmSymbol = "pm"
        if interval < 60 * 60 {
            return "in \(max(1, Int(interval / 60)))m"
        }
        let cal = Calendar.current
        if cal.isDateInToday(program.start) {
            return "Today \(hm.string(from: program.start))"
        }
        if cal.isDateInTomorrow(program.start) {
            return "Tomorrow \(hm.string(from: program.start))"
        }
        let full = DateFormatter()
        full.dateFormat = "EEE d MMM, h:mma"
        full.amSymbol = "am"
        full.pmSymbol = "pm"
        return full.string(from: program.start)
    }
}
