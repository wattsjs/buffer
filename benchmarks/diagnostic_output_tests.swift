import Foundation
import Darwin

@main
struct DiagnosticOutputTests {
    @MainActor
    static func main() async throws {
        // Verify that the production helper's per-fd suppression is sufficient
        // even with the process's default SIGPIPE behavior left active.
        _ = signal(SIGPIPE, SIG_DFL)
        if CommandLine.arguments.contains("--capture-stdout") {
            guard let writer = DiagnosticOutput.capturingStdout(prefix: "BUFFER_TEST_JSON ", footprint: false) else {
                exit(2)
            }
            let second = DiagnosticOutput.capturingStdout(prefix: "BUFFER_OTHER_JSON ")
            writer.append(encode(["event": "start"]))
            writer.append(encode(["event": "ownership", "exclusive": second == nil]))
            writer.append(encode(["event": "end"]))
            writer.close()
            for _ in 0..<100 where !writer.statistics.closed { try await Task.sleep(for: .milliseconds(5)) }
            exit(writer.statistics.writtenRecords == 3 && writer.statistics.droppedRecords == 0 ? 0 : 3)
        }
        var checks = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); checks += 1 }
        func pipePair() -> (Int32, Int32) {
            var descriptors: [Int32] = [-1, -1]
            precondition(pipe(&descriptors) == 0)
            precondition(fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0)
            precondition(fcntl(descriptors[1], F_SETFL, O_NONBLOCK) == 0)
            return (descriptors[0], descriptors[1])
        }
        func fill(_ descriptor: Int32) {
            let bytes = Data(repeating: 120, count: 4096)
            while bytes.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress!, $0.count) }) > 0 {}
            precondition(errno == EAGAIN)
        }
        func readAvailable(_ descriptor: Int32) -> Data {
            var result = Data()
            var bytes = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count <= 0 { break }
                result.append(contentsOf: bytes.prefix(count))
            }
            return result
        }
        func records(_ data: Data) -> [[String: Any]] {
            String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
                guard line.hasPrefix("BUFFER_TEST_JSON ") else { return nil }
                return (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(17).utf8))) as? [String: Any]
            }
        }

        // A full unread pipe used to freeze the app's MainActor in close().
        do {
            let (readFD, writeFD) = pipePair(); defer { Darwin.close(readFD) }
            fill(writeFD)
            let writer = DiagnosticOutput(descriptor: writeFD, prefix: "BUFFER_TEST_JSON ", maxQueuedBytes: 8192,
                maxQueuedRecords: 4, closeDrainMilliseconds: 100)!
            Darwin.close(writeFD)
            for index in 0..<100 { writer.append(encode(["event": "sample", "index": index, "padding": String(repeating: "x", count: 1500)])) }
            let before = ContinuousClock.now
            writer.close()
            check(milliseconds(before.duration(to: .now)) < 50, "MainActor close blocked on a full pipe")
            var heartbeats = 0
            for _ in 0..<40 { try await Task.sleep(for: .milliseconds(5)); heartbeats += 1 }
            let stats = writer.statistics
            check(heartbeats == 40 && stats.closed, "MainActor stopped responding or close did not reach its deadline")
            check(stats.producedRecords == 100 && stats.droppedRecords == 100 && stats.writtenRecords == 0, "Unwritable close must count every dropped source record")
            check(stats.queuedRecords == 0 && stats.queuedBytes == 0 && stats.peakQueuedBytes <= 8192, "Pressure queue exceeded its memory budget")
        }

        // When capacity returns, deliver explicit, exact cumulative drop
        // evidence before allowing later normal records to imply success.
        do {
            let (readFD, writeFD) = pipePair(); defer { Darwin.close(readFD) }
            fill(writeFD)
            let writer = DiagnosticOutput(descriptor: writeFD, prefix: "BUFFER_TEST_JSON ", maxQueuedBytes: 8192,
                maxQueuedRecords: 4, closeDrainMilliseconds: 500)!
            Darwin.close(writeFD)
            for index in 0..<20 { writer.append(encode(["event": "sample", "index": index, "padding": String(repeating: "x", count: 1500)])) }
            try await Task.sleep(for: .milliseconds(40))
            var captured = readAvailable(readFD)
            writer.close()
            for _ in 0..<100 {
                captured.append(readAvailable(readFD))
                if writer.statistics.closed { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            captured.append(readAvailable(readFD))
            let events = records(captured)
            let stats = writer.statistics
            check(stats.closed && stats.producedRecords == 20 && stats.writtenRecords == 4 && stats.droppedRecords == 16, "Recovered pipe accounting changed")
            check(events.filter { $0["event"] as? String == "sample" }.count == 4, "Accepted records did not reach collector")
            check(events.contains { $0["event"] as? String == "output-failure" && $0["droppedRecords"] as? Int == 16 && $0["outputHealthy"] as? Bool == false }, "Recoverable pressure silently discarded records")
        }

        // Partial nonblocking writes preserve the JSON line when a reader
        // resumes before the close deadline.
        do {
            let (readFD, writeFD) = pipePair(); defer { Darwin.close(readFD) }
            let writer = DiagnosticOutput(descriptor: writeFD, prefix: "BUFFER_TEST_JSON ", maxQueuedBytes: 65536,
                closeDrainMilliseconds: 500)!
            Darwin.close(writeFD)
            writer.append(encode(["event": "sample", "padding": String(repeating: "x", count: 50000)]))
            try await Task.sleep(for: .milliseconds(30))
            writer.close()
            var captured = Data()
            for _ in 0..<100 {
                captured.append(readAvailable(readFD))
                if writer.statistics.closed { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            captured.append(readAvailable(readFD))
            check(writer.statistics.writtenRecords == 1 && writer.statistics.droppedRecords == 0, "Partial writes lost a resumable record")
            check((records(captured).first?["padding"] as? String)?.count == 50000, "Partial write corrupted JSON framing")
        }

        // A vanished consumer must produce EPIPE, not SIGPIPE termination.
        do {
            let (readFD, writeFD) = pipePair()
            let writer = DiagnosticOutput(descriptor: writeFD, prefix: "BUFFER_TEST_JSON ")!
            Darwin.close(writeFD); Darwin.close(readFD)
            writer.append(encode(["event": "sample"]))
            for _ in 0..<100 where !writer.statistics.closed { try await Task.sleep(for: .milliseconds(5)) }
            check(writer.statistics.closed && writer.statistics.droppedRecords == 1, "Broken consumer killed or blocked the writer")
            let before = ContinuousClock.now; writer.close()
            check(milliseconds(before.duration(to: .now)) < 50, "Closed transport blocked MainActor close")
            var action = sigaction()
            precondition(sigaction(SIGPIPE, nil, &action) == 0)
            check(unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self) == 0, "Helper changed process-wide SIGPIPE policy")
        }

        // Invalid serialization and oversize input must produce explicit
        // evidence failure even when later end records fit in the pipe.
        do {
            let (readFD, writeFD) = pipePair(); defer { Darwin.close(readFD) }
            let writer = DiagnosticOutput(descriptor: writeFD, prefix: "BUFFER_TEST_JSON ", maxRecordBytes: 1024)!
            Darwin.close(writeFD)
            writer.append(Data())
            writer.append(Data(repeating: 120, count: 2048))
            writer.append(encode(["event": "end"]))
            writer.close()
            var captured = Data()
            for _ in 0..<100 {
                captured.append(readAvailable(readFD))
                if writer.statistics.closed { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            captured.append(readAvailable(readFD))
            check(writer.statistics.producedRecords == 3 && writer.statistics.writtenRecords == 1 && writer.statistics.droppedRecords == 2,
                  "Invalid/oversize source records were silently ignored")
            check(records(captured).contains { $0["event"] as? String == "output-failure" && $0["droppedRecords"] as? Int == 2 },
                  "End record concealed invalid/oversize loss")
        }

        // Exercise an actual named FIFO, matching LaunchServices capture.
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("events.pipe").path
            precondition(mkfifo(path, 0o600) == 0)
            let readFD = Darwin.open(path, O_RDONLY | O_NONBLOCK)
            let writeFD = Darwin.open(path, O_WRONLY | O_NONBLOCK)
            precondition(readFD >= 0 && writeFD >= 0)
            defer { Darwin.close(readFD) }
            let writer = DiagnosticOutput(descriptor: writeFD, prefix: "BUFFER_TEST_JSON ", footprint: true)!
            Darwin.close(writeFD)
            writer.append(encode(["event": "start"]))
            writer.append(encode(["event": "sample"]))
            writer.append(encode(["event": "end"]))
            writer.close()
            var captured = Data()
            for _ in 0..<100 {
                captured.append(readAvailable(readFD))
                if writer.statistics.closed { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            captured.append(readAvailable(readFD))
            let events = records(captured)
            check(events.compactMap { $0["event"] as? String } == ["start", "sample", "end"], "FIFO capture lost required record ordering")
            check((events[1]["physicalFootprintBytes"] as? NSNumber)?.intValue ?? 0 > 0, "Production footprint sampling did not run")
            check(writer.statistics.writtenRecords == 3 && writer.statistics.droppedRecords == 0, "FIFO capture falsely reported success")
        }
        print("Diagnostic output: \(checks) checks passed")
    }

    private static func encode(_ fields: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
}
