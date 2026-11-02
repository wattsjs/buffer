import Foundation

/// Only non-secret selectors and numeric expectations cross the scenario boundary.
struct SavedPlaybackScenarioPlan: Codable {
    struct Case: Codable {
        let sourceName: String?
        let sourceID: UUID?
        let channelName: String?
        let channelID: String?
        let vodName: String?
        let vodID: String?
        let expectedWidth: Int?
        let expectedHeight: Int?
        let expectedFPS: Double?
        let playbackMode: String?
        let catchupOffsetMinutes: Int?
        let vodResumeSeconds: Double?

        var requestsCatchup: Bool { playbackMode == "catchup" }
        var requestsVOD: Bool { playbackMode == "vod" }
    }
    let schema: Int
    let caseSeconds: Int
    let sourceTimeoutSeconds: Int
    let cases: [Case]

    static func decode(_ data: Data) throws -> Self {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys).isSubset(of: ["schema", "caseSeconds", "sourceTimeoutSeconds", "cases"]),
              let cases = raw["cases"] as? [[String: Any]],
              cases.allSatisfy({ Set($0.keys).isSubset(of: ["sourceName", "sourceID", "channelName", "channelID",
                  "vodName", "vodID", "expectedWidth", "expectedHeight", "expectedFPS", "playbackMode", "catchupOffsetMinutes", "vodResumeSeconds"]) }) else { throw SavedScenarioFailure.invalidPlan }
        let plan = try JSONDecoder().decode(Self.self, from: data)
        try plan.validate()
        return plan
    }

    func validate() throws {
        guard schema == 1, (20...60).contains(caseSeconds), (15...300).contains(sourceTimeoutSeconds),
              (1...20).contains(cases.count) else { throw SavedScenarioFailure.invalidPlan }
        func safeSelector(_ value: String?) -> Bool {
            guard let value else { return true }
            return !value.isEmpty && value.count <= 200 && !value.contains("://") &&
                value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
        for item in cases {
            guard (item.sourceName != nil) != (item.sourceID != nil),
                  item.requestsVOD
                    ? ((item.vodName != nil) != (item.vodID != nil)) && item.channelName == nil && item.channelID == nil
                    : ((item.channelName != nil) != (item.channelID != nil)) && item.vodName == nil && item.vodID == nil,
                  safeSelector(item.sourceName), safeSelector(item.channelName), safeSelector(item.channelID),
                  safeSelector(item.vodName), safeSelector(item.vodID),
                  (item.expectedWidth == nil) == (item.expectedHeight == nil),
                  item.expectedWidth.map({ (1...16384).contains($0) }) ?? true,
                  item.expectedHeight.map({ (1...16384).contains($0) }) ?? true,
                  item.expectedFPS.map({ $0.isFinite && $0 > 0 && $0 <= 240 }) ?? true,
                  item.playbackMode == nil || ["live", "catchup", "vod"].contains(item.playbackMode!),
                  item.catchupOffsetMinutes == nil || item.requestsCatchup,
                  item.catchupOffsetMinutes.map({ (1...43200).contains($0) }) ?? true,
                  item.vodResumeSeconds == nil || item.requestsVOD,
                  item.vodResumeSeconds.map({ $0.isFinite && $0 > 0 && $0 <= 86400 }) ?? true else {
                throw SavedScenarioFailure.invalidPlan
            }
        }
    }
}

nonisolated enum SavedScenarioFailure: String, Error {
    case invalidPlan = "invalid-plan"
    case unsupportedOriginalState = "unsupported-original-state"
    case sourceMissing = "source-missing"
    case sourceAmbiguous = "source-ambiguous"
    case channelMissing = "channel-missing"
    case channelAmbiguous = "channel-ambiguous"
    case vodMissing = "vod-item-missing"
    case vodAmbiguous = "vod-item-ambiguous"
    case vodDisabled = "vod-disabled"
    case vodResolutionUnavailable = "vod-playback-resolution-unavailable"
    case sourceTimedOut = "source-timeout"
    case sourceChanged = "source-changed-externally"
    case unrelatedPlayers = "unrelated-player-present"
    case playerWindowTimedOut = "player-window-timeout"
    case playerChanged = "owned-player-changed"
    case stopTimedOut = "backend-stop-unconfirmed"
    case cancelled
    case unavailable = "scenario-unavailable"
    case archiveUnavailable = "archive-unavailable-at-requested-offset"
    case catchupProgrammeUnavailable = "catchup-programme-unavailable"
    case catchupURLUnavailable = "catchup-url-unavailable"
}

@MainActor
protocol SavedPlaybackScenarioBackend {
    associatedtype OriginalState
    associatedtype PreparedCase
    var hasUnrelatedPlayers: Bool { get }
    func captureOriginalState() throws -> OriginalState
    func prepare(_ item: SavedPlaybackScenarioPlan.Case, timeoutSeconds: Int) async throws -> PreparedCase
    func open(_ item: PreparedCase) async throws
    func observe(caseIndex: Int, seconds: Int, emit: @escaping ([String: Any]) -> Void) async throws
    func closeOwnedPlayer(timeoutSeconds: Int) async throws
    func restore(_ state: OriginalState, timeoutSeconds: Int) async -> Bool
}

/// The same coordinator runs against production windows and an independent
/// fake backend in tests. A failed teardown forbids the next source switch.
@MainActor
enum SavedPlaybackScenarioCoordinator {
    static func run<Backend: SavedPlaybackScenarioBackend>(
        plan: SavedPlaybackScenarioPlan, backend: Backend,
        emit: @escaping ([String: Any]) -> Void
    ) async {
        emit(["event": "start", "schema": 1, "cases": plan.cases.count, "caseSeconds": plan.caseSeconds])
        let original: Backend.OriginalState
        do {
            try plan.validate()
            guard !backend.hasUnrelatedPlayers else { throw SavedScenarioFailure.unrelatedPlayers }
            original = try backend.captureOriginalState()
        } catch {
            emit(["event": "failure", "reason": reason(error)])
            emit(["event": "end", "completedCases": 0, "restored": false, "teardownConfirmed": true])
            return
        }
        var completed = 0
        var teardownConfirmed = true
        for (index, item) in plan.cases.enumerated() {
            if Task.isCancelled { break }
            emit(["event": "case-start", "case": index, "seconds": plan.caseSeconds])
            var failure: String?
            var openWasRequested = false
            do {
                guard !backend.hasUnrelatedPlayers else { throw SavedScenarioFailure.unrelatedPlayers }
                let prepared = try await backend.prepare(item, timeoutSeconds: plan.sourceTimeoutSeconds)
                emit(["event": "case-prepared", "case": index])
                // An open call can fail after dispatching a window request;
                // it still requires confirmed cleanup before the next case.
                openWasRequested = true
                try await backend.open(prepared)
                try await backend.observe(caseIndex: index, seconds: plan.caseSeconds, emit: emit)
            } catch { failure = reason(error) }
            if openWasRequested {
                do {
                    try await backend.closeOwnedPlayer(timeoutSeconds: 15)
                    emit(["event": "case-closed", "case": index, "backendIdle": true])
                } catch {
                    failure = reason(error)
                    teardownConfirmed = false
                }
            }
            emit(["event": "case-end", "case": index, "captured": failure == nil,
                  "reason": failure as Any? ?? NSNull(), "teardownConfirmed": teardownConfirmed])
            completed += 1
            if !teardownConfirmed || failure == SavedScenarioFailure.unrelatedPlayers.rawValue ||
                failure == SavedScenarioFailure.sourceChanged.rawValue || Task.isCancelled { break }
        }
        // Never switch sources with an unconfirmed backend stream still live.
        let restored = teardownConfirmed ? await backend.restore(original, timeoutSeconds: plan.sourceTimeoutSeconds) : false
        emit(["event": "end", "completedCases": completed, "restored": restored,
              "teardownConfirmed": teardownConfirmed, "cancelled": Task.isCancelled])
    }

    private static func reason(_ error: Error) -> String {
        if error is CancellationError { return SavedScenarioFailure.cancelled.rawValue }
        return (error as? SavedScenarioFailure)?.rawValue ?? SavedScenarioFailure.unavailable.rawValue
    }
}
