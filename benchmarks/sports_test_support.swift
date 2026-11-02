import Foundation

// Intercepts every request; these tests never reach ESPN or the saved provider.
final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var started = 0
        var active = 0
        var peak = 0
        var delay: Double = 0.05
        var golfEvents = 12
        var eventTitle: String?
        var eventDate = ""
        var httpStatus = 200
        var rangeStatus: Int?
        var rangeLimitStatus: [Int: Int] = [:]
        var invalidJSON = false
        var requestedDates: [String] = []
    }
    static let state = State()
    private var ended = false

    static func reset(delay: Double = 0.05, golfEvents: Int = 12, eventTitle: String? = nil,
                      httpStatus: Int = 200, rangeStatus: Int? = nil, invalidJSON: Bool = false,
                      rangeLimitStatus: [Int: Int] = [:]) {
        state.lock.withLock {
            precondition(state.active == 0, "Fixture requests still running")
            state.started = 0
            state.peak = 0
            state.delay = delay
            state.golfEvents = golfEvents
            state.eventTitle = eventTitle
            state.eventDate = ISO8601DateFormatter().string(from: Date())
            state.httpStatus = httpStatus
            state.rangeStatus = rangeStatus
            state.rangeLimitStatus = rangeLimitStatus
            state.invalidJSON = invalidJSON
            state.requestedDates = []
        }
    }

    static var requestedDates: [String] { state.lock.withLock { state.requestedDates } }

    static var counts: (started: Int, active: Int, peak: Int) {
        state.lock.withLock { (state.started, state.active, state.peak) }
    }

    static func setResponse(delay: Double, eventTitle: String) {
        state.lock.withLock {
            state.delay = delay
            state.eventTitle = eventTitle
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (delay, golfEvents, eventTitle, eventDate, status, invalidJSON) = Self.state.lock.withLock {
            Self.state.started += 1
            Self.state.active += 1
            Self.state.peak = max(Self.state.peak, Self.state.active)
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let dateValue = queryItems.first { $0.name == "dates" }?.value ?? ""
            Self.state.requestedDates.append(dateValue)
            let limit = Int(queryItems.first { $0.name == "limit" }?.value ?? "") ?? 0
            let status = dateValue.contains("-")
                ? (Self.state.rangeLimitStatus[limit] ?? Self.state.rangeStatus ?? Self.state.httpStatus)
                : Self.state.httpStatus
            return (Self.state.delay, Self.state.golfEvents, Self.state.eventTitle, Self.state.eventDate, status, Self.state.invalidJSON)
        }
        let url = request.url!
        let payload: String
        if invalidJSON {
            payload = "{\"message\":\"Unavailable\"}"
        } else if url.path.contains("/golf/"), url.path.hasSuffix("scoreboard") {
            let events = (0..<golfEvents).map { "{\"id\":\"\($0)\"}" }.joined(separator: ",")
            payload = "{\"events\":[\(events)]}"
        } else if let eventTitle, url.path.hasSuffix("scoreboard") {
            let json: [String: Any] = ["events": [[
                "id": "same-match", "name": eventTitle, "shortName": "Fixture",
                "date": eventDate,
                "status": ["type": ["state": "in", "shortDetail": "Live"]],
                "competitions": [["broadcasts": [["names": ["Fixture TV"]]]]],
            ]]]
            payload = String(data: try! JSONSerialization.data(withJSONObject: json), encoding: .utf8)!
        } else {
            payload = "{\"events\":[]}"
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            let shouldComplete = Self.state.lock.withLock {
                guard !ended else { return false }
                ended = true
                Self.state.active -= 1
                return true
            }
            guard shouldComplete else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(payload.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.state.lock.withLock {
            guard !ended else { return }
            ended = true
            Self.state.active -= 1
        }
    }
}

func fixtureSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureURLProtocol.self]
    return URLSession(configuration: config)
}

func waitUntil(_ description: String, timeout: Double = 3,
               isolation: isolated (any Actor)? = #isolation, _ predicate: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    precondition(predicate(), description)
}


@MainActor final class PlayerSessionRegistry {
    static let shared = PlayerSessionRegistry()
    var activeSession: Int?
}

@MainActor final class WeakSportsModel {
    weak var value: SportsViewModel?
    init(_ value: SportsViewModel?) { self.value = value }
}
