import Foundation

@main
struct ESPNRequestTests {
    static func main() async {
        let measureOnly = CommandLine.arguments.contains("--measure-only")
        let session = fixtureSession()
        let client = ESPNClient(session: session)

        // Eight leagues should not multiply the requested HTTP budget by
        // their per-day cricket expansion or tournament leaderboard expansion.
        let cricket = Array(League.all.filter { $0.sport == .cricket }.prefix(8))
        FixtureURLProtocol.reset()
        let cricketStarted = ContinuousClock.now
        await withTaskGroup(of: [SportEvent].self) { group in
            for league in cricket { group.addTask { await client.fetchEvents(for: league) } }
            for await _ in group {}
        }
        let cricketCounts = FixtureURLProtocol.counts
        let cricketMs = AppLog.elapsedMilliseconds(since: cricketStarted)
        precondition(cricketCounts.started == 72)
        precondition(cricketCounts.active == 0)
        if !measureOnly { precondition(cricketCounts.peak <= 8, "Cricket exceeded the HTTP concurrency budget") }

        let golf = Array(League.all.filter { $0.sport == .golf }.prefix(8))
        FixtureURLProtocol.reset()
        let golfStarted = ContinuousClock.now
        await withTaskGroup(of: [SportEvent].self) { group in
            for league in golf { group.addTask { await client.fetchEvents(for: league) } }
            for await _ in group {}
        }
        let golfCounts = FixtureURLProtocol.counts
        let golfMs = AppLog.elapsedMilliseconds(since: golfStarted)
        precondition(golfCounts.started == 104)
        if !measureOnly { precondition(golfCounts.peak <= 8, "Golf exceeded the HTTP concurrency budget") }
        precondition(golfCounts.active == 0)

        FixtureURLProtocol.reset(delay: 5)
        let fetch = Task { await client.fetchAllEvents() }
        await waitUntil("Initial ESPN requests did not start") { FixtureURLProtocol.counts.started >= 8 }
        let startedBeforeCancel = FixtureURLProtocol.counts.started
        let cancelledAt = ContinuousClock.now
        fetch.cancel()
        let cancelled = await fetch.value
        let cancelMs = AppLog.elapsedMilliseconds(since: cancelledAt)
        precondition(cancelled.isEmpty)
        let cancelledRequestCount = FixtureURLProtocol.counts.started
        if !measureOnly { precondition(cancelledRequestCount == startedBeforeCancel, "New requests began after cancellation") }
        await waitUntil("Cancelled requests did not release") { FixtureURLProtocol.counts.active == 0 }
        if !measureOnly { precondition(cancelMs < 1000, "Cancellation did not release requests promptly") }

        // Cancellation before starting does not create transport work.
        FixtureURLProtocol.reset()
        let beforeStart = Task { withUnsafeCurrentTask { $0?.cancel() }; return await client.fetchAllEvents() }
        let notStarted = await beforeStart.value
        precondition(notStarted.isEmpty)
        let preCancelledRequests = FixtureURLProtocol.counts.started
        if !measureOnly { precondition(preCancelledRequests == 0) }

        if !measureOnly {
            // Cancel while the cricket expansion has suspended more requests
            // than can obtain transport permits, then verify permit reuse.
            FixtureURLProtocol.reset(delay: 5)
            let queued = Task {
                await withTaskGroup(of: [SportEvent].self) { group in
                    for league in cricket { group.addTask { await client.fetchEvents(for: league) } }
                    for await _ in group {}
                }
            }
            await waitUntil("Cricket requests did not obtain permits") { FixtureURLProtocol.counts.started == 8 }
            queued.cancel()
            await queued.value
            await waitUntil("Cancelled cricket request slots remained occupied") { FixtureURLProtocol.counts.active == 0 }
            precondition(FixtureURLProtocol.counts.started == 8, "Queued requests started after cancellation")

            FixtureURLProtocol.reset()
            _ = await client.fetchEvents(for: cricket[0])
            precondition(FixtureURLProtocol.counts.started == 9)
            precondition(FixtureURLProtocol.counts.peak <= 8, "Cancellation leaked or over-released permits")

            FixtureURLProtocol.reset()
            let serialClient = ESPNClient(session: session, maxConcurrentRequests: 1)
            _ = await serialClient.fetchEvents(for: cricket[0])
            precondition(FixtureURLProtocol.counts.started == 9 && FixtureURLProtocol.counts.peak == 1)

            FixtureURLProtocol.reset(eventTitle: "Stable cricket match")
            let concurrentEvents = await client.fetchEvents(for: cricket[0])
            precondition(concurrentEvents.count == 1, "Adjacent cricket date results were not deduplicated")
            let serialEvents = await serialClient.fetchEvents(for: cricket[0])
            precondition(serialEvents.count == concurrentEvents.count)
            precondition(serialEvents[0].id == concurrentEvents[0].id)
            precondition(serialEvents[0].title == concurrentEvents[0].title && serialEvents[0].startDate == concurrentEvents[0].startDate)
            precondition(serialEvents[0].broadcast == concurrentEvents[0].broadcast && serialEvents[0].status.isLive)
        }

        if !measureOnly {
            let nfl = League.all.first { $0.slug == "nfl" }!
            FixtureURLProtocol.reset(eventTitle: "Daily fallback", rangeStatus: 400)
            let fallback = await client.fetchEvents(for: nfl)
            precondition(fallback.count == 1 && FixtureURLProtocol.counts.started == 4,
                         "Rejected ranges did not use bounded overnight day buckets or deduplicate results")
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = .current
            let requestedDays = Set(FixtureURLProtocol.requestedDates.filter { !$0.contains("-") })
            let overnightDays = Set([formatter.string(from: Date().addingTimeInterval(-86400)),
                                     formatter.string(from: Date())])
            precondition(requestedDays == overnightDays, "Brisbane overnight league-day coverage was missing")
            FixtureURLProtocol.reset(eventTitle: "Full horizon", rangeLimitStatus: [250: 400, 100: 200])
            let smallerLimit = await client.fetchEvents(for: nfl)
            precondition(smallerLimit.count == 1 && FixtureURLProtocol.counts.started == 2,
                         "A rejected count unnecessarily expanded into daily requests")
            FixtureURLProtocol.reset(httpStatus: 403)
            let denied = await client.fetchEvents(for: nfl)
            precondition(denied.isEmpty && FixtureURLProtocol.counts.started == 1,
                         "Access denial was retried")
            FixtureURLProtocol.reset(delay: 0.001, golfEvents: 0, httpStatus: 503)
            let unavailable = await client.fetchAllEventsResult()
            precondition(unavailable.isUnavailable && unavailable.failedLeagueIDs.count == League.all.count)
            FixtureURLProtocol.reset(delay: 0.001, golfEvents: 0)
            let empty = await client.fetchAllEventsResult()
            precondition(!empty.isUnavailable && !empty.isPartial && empty.events.isEmpty,
                         "Successful empty fixtures were misclassified as an outage")
            FixtureURLProtocol.reset(delay: 0.001, golfEvents: 0, invalidJSON: true)
            let invalid = await client.fetchAllEventsResult()
            precondition(invalid.isUnavailable, "An error JSON was accepted as an empty scoreboard")
        }

        print("ESPN_REQUEST_JSON {\"cricketRequests\":\(cricketCounts.started),\"cricketPeak\":\(cricketCounts.peak),\"golfRequests\":\(golfCounts.started),\"golfPeak\":\(golfCounts.peak),\"cricketMs\":\(cricketMs),\"golfMs\":\(golfMs),\"cancelMs\":\(cancelMs),\"requestsAtCancel\":\(startedBeforeCancel),\"requestsAfterCancel\":\(cancelledRequestCount),\"preCancelledRequests\":\(preCancelledRequests)}")
        if !measureOnly { print("PASS ESPN leaf HTTP concurrency, cricket/golf fan-out, pre-cancellation, in-flight cancellation, rejected-range fallback, denied/no-retry, outage/empty/malformed outcomes") }
        session.invalidateAndCancel()
    }
}
