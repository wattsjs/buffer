import Foundation

nonisolated struct ChannelSearchEntry: Sendable {
    let channel: Channel
    let nameLower: String
}

nonisolated struct VODSearchEntry: Sendable {
    let item: VODItem?
    let series: VODSeries?
    let title: String
    let subtitle: String
    let searchText: String
    let posterURL: URL?

    var id: String {
        if let item { return "vod-item:\(item.id)" }
        if let series { return "vod-series:\(series.id)" }
        return title
    }
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

nonisolated struct VODSearchResult: Identifiable, Sendable {
    var id: String { entry.id }
    let entry: VODSearchEntry
    let score: Double
}

@Observable
@MainActor
final class ProgramSearchController {
    var query: String = ""
    var programResults: [ProgramSearchResult] = []
    var channelResults: [ChannelSearchResult] = []
    var vodResults: [VODSearchResult] = []
    var isSearching: Bool = false

    private var programIndex = ProgramSearchIndex()
    /// Index guide slot -> position in `channelList`, or -1 when the guide's
    /// channel is not in the current channel list. Rebuilt per index update.
    private var programSlotChannel: [Int32] = []
    private var channelList: [Channel] = []
    private var channelEntries: [ChannelSearchEntry] = []
    private var vodEntries: [VODSearchEntry] = []
    private var currentTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var totalResultCount: Int {
        programResults.count + channelResults.count + vodResults.count
    }

    func updateIndex(
        programs: ProgramSearchIndex,
        programStore: [String: [EPGProgram]] = [:],
        channels: [Channel],
        vodItems: [VODItem],
        vodSeries: [VODSeries]
    ) {
        // `programStore` is retained by the index itself; kept for callers.
        self.programIndex = programs
        self.channelList = channels
        var positionByID: [String: Int32] = [:]
        positionByID.reserveCapacity(channels.count)
        for (position, channel) in channels.enumerated() where positionByID[channel.id] == nil {
            positionByID[channel.id] = Int32(position)
        }
        self.programSlotChannel = programs.channelIDs.map { positionByID[$0] ?? -1 }
        self.channelEntries = channels.map {
            ChannelSearchEntry(channel: $0, nameLower: $0.name.lowercased())
        }
        self.vodEntries = vodItems.map { item in
            VODSearchEntry(
                item: item,
                series: nil,
                title: item.name,
                subtitle: item.genre ?? item.group,
                searchText: [item.name, item.group, item.genre, item.rating, item.releaseDate, item.summary]
                    .compactMap { $0?.lowercased() }
                    .joined(separator: " "),
                posterURL: item.posterURL
            )
        } + vodSeries.map { series in
            VODSearchEntry(
                item: nil,
                series: series,
                title: series.name,
                subtitle: series.group,
                searchText: "\(series.name) \(series.group)".lowercased(),
                posterURL: series.posterURL
            )
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
            vodResults = []
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
            vodResults = []
            isSearching = false
            return
        }

        let programIndexSnapshot = programIndex
        let slotChannelSnapshot = programSlotChannel
        let channelListSnapshot = channelList
        let channelSnapshot = channelEntries
        let vodSnapshot = vodEntries
        let now = Date()

        currentTask = Task.detached(priority: .userInitiated) { [trimmed, programIndexSnapshot, slotChannelSnapshot, channelListSnapshot, channelSnapshot, vodSnapshot, now] in
            let tokens = trimmed
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)

            // MARK: Program matches
            let normalized = ProgramSearchIndex.normalize(trimmed)
            let hits = programIndexSnapshot.search(
                phrase: Array(normalized.utf8),
                tokens: normalized.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { Array($0.utf8) },
                now: now,
                slotChannel: slotChannelSnapshot
            )
            if Task.isCancelled { return }
            var cappedPrograms: [ProgramSearchResult] = []
            cappedPrograms.reserveCapacity(hits.count)
            for hit in hits {
                let (program, slot) = programIndexSnapshot.program(ordinal: Int(hit.ordinal))
                let channel = channelListSnapshot[Int(slotChannelSnapshot[slot])]
                cappedPrograms.append(ProgramSearchResult(program: program, channel: channel, score: hit.score))
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

            // MARK: VOD matches
            var vodHits: [VODSearchResult] = []
            vodHits.reserveCapacity(64)
            for entry in vodSnapshot {
                let haystack = entry.searchText
                var allMatch = true
                for token in tokens {
                    if !haystack.contains(token) {
                        allMatch = false
                        break
                    }
                }
                if !allMatch { continue }

                let title = entry.title.lowercased()
                var score: Double = 0
                if title == trimmed {
                    score += 210
                } else if title.hasPrefix(trimmed) {
                    score += 130
                } else if title.contains(trimmed) {
                    score += 90
                } else {
                    score += 45
                }
                vodHits.append(VODSearchResult(entry: entry, score: score))
            }
            vodHits.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.entry.title.localizedStandardCompare($1.entry.title) == .orderedAscending
            }

            if Task.isCancelled { return }

            let finalPrograms = cappedPrograms
            let finalChannels = channelHits
            let finalVOD = Array(vodHits.prefix(120))
            await MainActor.run { [weak self] in
                guard let self else { return }
                if Task.isCancelled { return }
                self.programResults = finalPrograms
                self.channelResults = finalChannels
                self.vodResults = finalVOD
                self.isSearching = false
            }
        }
    }
}
