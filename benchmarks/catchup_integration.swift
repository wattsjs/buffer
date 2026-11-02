import Foundation

private actor ProgressProbe {
    var callbacks = 0
    var programmes = 0
    var explicitNoEvent = 0
    func accept(_ progress: XtreamClient.CatchupProgress) {
        precondition(progress.receivedListings == 6)
        precondition(progress.responseEarliestEpoch == 1_699_990_000 && progress.responseLatestEpoch == 1_700_000_700)
        precondition(progress.programs.allSatisfy { !$0.title.isEmpty })
        callbacks += 1
        programmes += progress.programs.count
        explicitNoEvent += progress.programs.filter { $0.title == "No Event Today" }.count
    }
    func verify() {
        precondition(callbacks == 24 && programmes == 48 && explicitNoEvent == 24)
    }
}

@main
struct CatchupIntegration {
    static func main() async throws {
        guard CommandLine.arguments.count >= 3 else { exit(1) }
        let base = CommandLine.arguments[1]
        let scenario = CommandLine.arguments[2]
        let count = 24
        let channels = (0..<count).map { i in
            Channel(id: String(i), name: "Fixture \(i)", logoURL: nil, group: "Test",
                    streamURL: URL(string: "\(base)/\(i).ts")!, epgChannelID: "epg-\(i)")
        }
        let client = XtreamClient(config: ServerConfig(serverURL: base, username: "fixture", password: "fixture"))
        if scenario == "progress-metadata" {
            let probe = ProgressProbe()
            let returned = try await client.fetchCatchupEPG(for: channels, since: Date(timeIntervalSince1970: 1_700_000_000), collectResults: false) { progress in
                await probe.accept(progress)
            }
            precondition(returned.isEmpty, "stream-only mode allocated an aggregate result")
            await probe.verify()
            print("PASS raw coverage, finite timestamps, titleless omission, explicit No Event, stream-only progress")
            return
        }
        if scenario == "benchmark" {
            var serial: [Int] = []
            var parallel: [Int] = []
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for _ in 0..<3 {
                var start = ContinuousClock.now
                let before = try await client.fetchCatchupEPG(for: channels, since: Date(timeIntervalSince1970: 1_700_000_000), maxConcurrentRequests: 1)
                serial.append(AppLog.elapsedMilliseconds(since: start))
                start = .now
                let after = try await client.fetchCatchupEPG(for: channels, since: Date(timeIntervalSince1970: 1_700_000_000), maxConcurrentRequests: 8)
                parallel.append(AppLog.elapsedMilliseconds(since: start))
                let beforeData = try encoder.encode(before.sorted { $0.id < $1.id })
                let afterData = try encoder.encode(after.sorted { $0.id < $1.id })
                precondition(before.count == count && beforeData == afterData, "Parallel results changed")
            }
            let report: [String: Any] = ["fixture": "catchup-http-24-v1", "serialMs": serial, "parallelMs": parallel, "programs": count]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("CATCHUP_BENCH_JSON " + String(decoding: data, as: UTF8.self))
            return
        }
        let start = ContinuousClock.now
        let task = Task { try await client.fetchCatchupEPG(for: channels, since: Date(timeIntervalSince1970: 1_700_000_000)) }
        if scenario == "cancel" {
            try await Task.sleep(for: .milliseconds(100))
            task.cancel()
            do {
                _ = try await task.value
                fputs("FAIL cancellation returned success\n", stderr)
                exit(1)
            } catch is CancellationError {
                print("PASS cancellation")
                return
            }
        }
        if scenario == "all-fail" {
            do { _ = try await task.value; exit(1) }
            catch { print("PASS all failed throws"); return }
        }
        let programs = try await task.value
        let expected = scenario == "partial" ? count - count / 3 : count
        precondition(programs.count == expected, "Wrong number of programs: \(programs.count)")
        for program in programs {
            precondition(program.title == "Sport Fixture")
            precondition(program.description == "Match description")
            precondition(program.end > Date(timeIntervalSince1970: 1_700_000_000))
        }
        print("PASS \(scenario) programs=\(programs.count) elapsedMs=\(AppLog.elapsedMilliseconds(since: start))")
    }
}
