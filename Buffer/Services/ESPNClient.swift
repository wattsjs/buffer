import Foundation
import OSLog

/// A successful empty scoreboard differs from an unavailable feed. Callers
/// retain prior fixtures only for leagues that did not provide a fresh result.
nonisolated struct ESPNRefreshResult: Sendable {
    let events: [SportEvent]
    let successfulLeagueIDs: Set<String>
    let failedLeagueIDs: Set<String>
    let partialLeagueIDs: Set<String>
    var isUnavailable: Bool { successfulLeagueIDs.isEmpty }
    var isPartial: Bool { !failedLeagueIDs.isEmpty || !partialLeagueIDs.isEmpty }
}

private nonisolated struct ESPNLeagueResult: Sendable {
    let leagueID: String
    let events: [SportEvent]
    let succeeded: Bool
    var partial = false
}

private enum ESPNFeedError: Error {
    case http(Int)
    case invalidResponse
}

/// Fetches live and upcoming sporting events from ESPN's public scoreboard API
/// and parses them into canonical `SportEvent` models.
actor ESPNClient {
    private let session: URLSession
    private let requestLimiter: ESPNRequestLimiter
    private let baseURL = "https://site.api.espn.com/apis/site/v2/sports"
    private let lookbackDays = 1
    private let futureDays = 7
    private let requestLimit = 250
    private let maxConcurrentLeagueFetches = 8

    init(session: URLSession = .shared, maxConcurrentRequests: Int = 8) {
        self.session = session
        self.requestLimiter = ESPNRequestLimiter(limit: max(1, min(8, maxConcurrentRequests)))
    }

    // MARK: - Public

    /// Fetch events for all configured leagues concurrently.
    func fetchAllEvents() async -> [SportEvent] {
        await fetchAllEventsResult().events
    }

    func fetchAllEventsResult() async -> ESPNRefreshResult {
        guard !Task.isCancelled else {
            return ESPNRefreshResult(events: [], successfulLeagueIDs: [], failedLeagueIDs: [], partialLeagueIDs: [])
        }
        return await withTaskGroup(of: ESPNLeagueResult.self) { group in
            let leagues = League.all
            var nextIndex = 0
            let initialCount = min(maxConcurrentLeagueFetches, leagues.count)
            for _ in 0..<initialCount {
                let league = leagues[nextIndex]
                nextIndex += 1
                group.addTask { [self] in await self.fetchEventsResult(for: league) }
            }
            var all: [SportEvent] = []
            var successful = Set<String>()
            var failed = Set<String>()
            var partial = Set<String>()
            while let result = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return ESPNRefreshResult(events: [], successfulLeagueIDs: [], failedLeagueIDs: [], partialLeagueIDs: [])
                }
                all.append(contentsOf: result.events)
                if result.succeeded { successful.insert(result.leagueID) }
                else { failed.insert(result.leagueID) }
                if result.partial { partial.insert(result.leagueID) }
                if nextIndex < leagues.count {
                    let league = leagues[nextIndex]
                    nextIndex += 1
                    group.addTask { [self] in await self.fetchEventsResult(for: league) }
                }
            }
            return ESPNRefreshResult(events: all, successfulLeagueIDs: successful,
                                     failedLeagueIDs: failed, partialLeagueIDs: partial)
        }
    }

    func fetchEvents(for league: League) async -> [SportEvent] {
        await fetchEventsResult(for: league).events
    }

    private func fetchEventsResult(for league: League) async -> ESPNLeagueResult {
        let failed = ESPNLeagueResult(leagueID: league.id, events: [], succeeded: false)
        guard !Task.isCancelled else { return failed }
        if league.sport == .cricket { return await fetchCricketEvents(for: league) }
        let df = scoreboardDateFormatter()
        let start = df.string(from: Date().addingTimeInterval(TimeInterval(-lookbackDays * 86400)))
        let end = df.string(from: Date().addingTimeInterval(TimeInterval(futureDays * 86400)))
        do {
            let datasets: [ESPNDocument]
            var partial = false
            do {
                datasets = [try await scoreboardData(for: league, dates: "\(start)-\(end)")]
            } catch ESPNFeedError.http(400) {
                try Task.checkCancellation()
                do {
                    // A server may reject the requested count rather than
                    // the date range. Preserve the full horizon when a smaller
                    // count is accepted; access denials are never retried.
                    let document = try await scoreboardData(for: league, dates: "\(start)-\(end)", limit: 100)
                    datasets = [document]
                    partial = parser.eventCount(document) == 100
                    AppLog.sports.info("ESPN smaller-limit fallback league=\(league.shortName, privacy: .public)")
                } catch ESPNFeedError.http(400) {
                    // Brisbane's Monday starts before the league's Sunday
                    // games. Both day buckets are needed to retain overnight
                    // fixtures; do not multiply a rejected range into nine
                    // daily requests across every configured league.
                    try Task.checkCancellation()
                    datasets = await fallbackDailyScoreboards(for: league, dates: [start, df.string(from: Date())])
                    try Task.checkCancellation()
                    guard !datasets.isEmpty else { throw ESPNFeedError.invalidResponse }
                    partial = true
                    AppLog.sports.info("ESPN overnight-day fallback league=\(league.shortName, privacy: .public) successfulDays=\(datasets.count, privacy: .public)")
                }
            }
            var events: [SportEvent] = []
            for document in datasets {
                try Task.checkCancellation()
                events.append(contentsOf: league.sport == .golf
                    ? await expandGolfScoreboard(document, league: league)
                    : filterStaleLookbackEvents(parser.parse(document, league: league)))
            }
            var seen = Set<String>()
            // Daily buckets are chronological; the later bucket contains the
            // newer score/status when ESPN repeats an overnight fixture.
            let deduplicated = events.reversed().filter { seen.insert($0.id).inserted }.reversed()
            return ESPNLeagueResult(leagueID: league.id, events: Array(deduplicated),
                                    succeeded: true, partial: partial)
        } catch {
            guard !Task.isCancelled else { return failed }
            if case ESPNFeedError.http(let status) = error {
                AppLog.sports.error("ESPN scoreboard unavailable league=\(league.shortName, privacy: .public) status=\(status, privacy: .public)")
            } else {
                // Log a classification rather than localized transport text,
                // which can embed the request URL.
                AppLog.sports.error("ESPN scoreboard unavailable league=\(league.shortName, privacy: .public) transportOrFormatError=true")
            }
            return failed
        }
    }

    private func fallbackDailyScoreboards(for league: League, dates: [String]) async -> [ESPNDocument] {
        await withTaskGroup(of: (String, ESPNDocument?).self) { group in
            for date in Set(dates) {
                guard !Task.isCancelled else { break }
                group.addTask { [self] in
                    guard !Task.isCancelled else { return (date, nil) }
                    return (date, try? await self.scoreboardData(for: league, dates: date, limit: 100))
                }
            }
            var result: [(String, ESPNDocument)] = []
            for await (date, data) in group {
                guard !Task.isCancelled else { group.cancelAll(); return [] }
                if let data { result.append((date, data)) }
            }
            return result.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    private func scoreboardDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = .current
        return formatter
    }

    /// The scoreboard response decoded once; every later read uses the same document.
    private func scoreboardData(for league: League, dates: String, limit: Int? = nil) async throws -> ESPNDocument {
        guard let url = URL(string: "\(baseURL)/\(league.espnPath)/scoreboard?dates=\(dates)&limit=\(limit ?? requestLimit)") else {
            throw ESPNFeedError.invalidResponse
        }
        let (data, response) = try await fetchData(from: url)
        guard let http = response as? HTTPURLResponse else { throw ESPNFeedError.invalidResponse }
        guard http.statusCode == 200 else { throw ESPNFeedError.http(http.statusCode) }
        let document = ESPNDocument(data)
        guard parser.isValidScoreboard(document) else { throw ESPNFeedError.invalidResponse }
        return document
    }

    /// Cricket only supports individual dates. Preserve successful days even
    /// if another day is unavailable, and surface the incomplete refresh.
    private func fetchCricketEvents(for league: League) async -> ESPNLeagueResult {
        let failed = ESPNLeagueResult(leagueID: league.id, events: [], succeeded: false)
        guard !Task.isCancelled else { return failed }
        let df = scoreboardDateFormatter()
        let fetched: [ESPNDocument?] = await withTaskGroup(of: ESPNDocument?.self) { group in
            for dayOffset in (-lookbackDays)...futureDays {
                guard !Task.isCancelled else { break }
                let dateStr = df.string(from: Date().addingTimeInterval(Double(dayOffset) * 86400))
                group.addTask { [self] in
                    guard !Task.isCancelled else { return nil }
                    return try? await self.scoreboardData(for: league, dates: dateStr)
                }
            }
            var results: [ESPNDocument?] = []
            for await data in group {
                guard !Task.isCancelled else { group.cancelAll(); return [] }
                results.append(data)
            }
            return results
        }
        guard !Task.isCancelled else { return failed }
        var all: [SportEvent] = []
        let successfulDays = fetched.compactMap { $0 }
        for data in successfulDays {
            guard !Task.isCancelled else { return failed }
            all.append(contentsOf: parser.parse(data, league: league))
        }
        all = filterStaleLookbackEvents(all)
        var seen = Set<String>()
        return ESPNLeagueResult(leagueID: league.id, events: all.filter { seen.insert($0.id).inserted },
                                succeeded: !successfulDays.isEmpty, partial: successfulDays.count != fetched.count)
    }

    /// A lookback keeps genuinely live overnight events available in time
    /// zones ahead of the league, without surfacing yesterday's finished games.
    private func filterStaleLookbackEvents(_ events: [SportEvent]) -> [SportEvent] {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return events.filter { $0.startDate >= startOfToday || $0.status.isLive }
    }

    // MARK: - JSON Parsing
    // ESPNScoreboardParser holds the parsing rules; documents are decoded by
    // the byte tape, falling back to JSONSerialization when it declines.

    private var parser: ESPNScoreboardParser {
        ESPNScoreboardParser(parseDate: { self.parseDate($0) })
    }

    // MARK: - Golf expansion (per-round events)

    /// Enumerate the tournaments in a golf scoreboard response and fan out to
    /// the leaderboard endpoint for each, so we can surface per-round start
    /// times and round-level completion state.
    private func expandGolfScoreboard(_ document: ESPNDocument, league: League) async -> [SportEvent] {
        guard !Task.isCancelled else { return [] }
        let ids = parser.golfEventIDs(document)

        var all: [SportEvent] = []
        await withTaskGroup(of: [SportEvent].self) { group in
            for id in ids {
                guard !Task.isCancelled else { break }
                group.addTask { [self] in
                    await self.fetchGolfEventRounds(eventID: id, league: league)
                }
            }
            for await rounds in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                all.append(contentsOf: rounds)
            }
        }
        return Task.isCancelled ? [] : all
    }

    /// Fetch the leaderboard for a single golf event and expand it into one
    /// SportEvent per round.
    private func fetchGolfEventRounds(eventID: String, league: League) async -> [SportEvent] {
        guard !Task.isCancelled else { return [] }
        guard let url = URL(string: "https://site.web.api.espn.com/apis/site/v2/sports/golf/leaderboard?league=\(league.slug)&event=\(eventID)") else {
            return []
        }
        do {
            let (data, response) = try await fetchData(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return []
            }
            return parser.golfRounds(ESPNDocument(data), league: league)
        } catch {
            guard !Task.isCancelled else { return [] }
            AppLog.sports.error("ESPN leaderboard fetch failed eventID=\(eventID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // ISO8601DateFormatter is not Sendable. Keep these mutable formatter
    // objects isolated to this client instead of sharing across actors.
    private let dateFormatters: [ISO8601DateFormatter] = {
        // ESPN returns dates like "2026-04-15T23:30Z" (no seconds) or
        // "2026-04-15T23:30:00Z" (with seconds). Build formatters for both.
        let withSeconds = ISO8601DateFormatter()
        withSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]

        // No-seconds variant: "2026-04-15T23:30Z"
        let noSeconds = ISO8601DateFormatter()
        noSeconds.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate,
                                   .withTime, .withColonSeparatorInTime,
                                   .withTimeZone]

        return [withSeconds, standard, noSeconds]
    }()

    /// ESPN's two common spellings are parsed from bytes; anything else goes
    /// through the formatters exactly as before.
    private func parseDate(_ string: String) -> Date {
        if let date = ESPNScoreboardParser.fastDate(string) { return date }
        for formatter in dateFormatters {
            if let date = formatter.date(from: string) { return date }
        }

        // Fallback: use DateFormatter with explicit format
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mmZ"] {
            df.dateFormat = format
            if let date = df.date(from: string) { return date }
        }

        return .distantPast
    }

    /// The league budget alone is insufficient: cricket expands into daily
    /// requests and golf into leaderboard requests. Apply one budget at the
    /// actual transport boundary across all nested work and refreshes.
    private func fetchData(from url: URL) async throws -> (Data, URLResponse) {
        let queuedAt = ContinuousClock.now
        try await requestLimiter.acquire()
        let requestStarted = ContinuousClock.now
        do {
            try Task.checkCancellation()
            let result = try await session.data(from: url)
            try Task.checkCancellation()
            await requestLimiter.release()
            AppLog.sports.debug("ESPN HTTP completed queueMs=\(AppLog.elapsedMilliseconds(since: queuedAt, now: requestStarted), privacy: .public) requestMs=\(AppLog.elapsedMilliseconds(since: requestStarted), privacy: .public) bytes=\(result.0.count, privacy: .public)")
            return result
        } catch {
            await requestLimiter.release()
            throw error
        }
    }
}

/// Suspended requests hold no URLSession task. Cancellation removes queued
/// waiters immediately, so a superseded refresh cannot drain its entire queue.
private actor ESPNRequestLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if active < limit {
                    active += 1
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            // Transfer this permit without momentarily opening an extra slot.
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
