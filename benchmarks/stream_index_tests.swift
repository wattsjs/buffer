import Foundation

final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func cancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls >= 3
    }
}

@main
struct StreamIndexTests {
    static func main() throws {
        let now = Date()
        let channels = ["Alpha", "Beta", "Gamma"].enumerated().map { i, name in
            Channel(id: "\(i)", name: name, logoURL: nil, group: i == 1 ? "Hidden/Sports" : "Sports",
                    streamURL: URL(string: "http://127.0.0.1/\(i).m3u8")!, epgChannelID: "shared")
        }
        let programs = ["shared": [
            EPGProgram(id: "a", channelID: "shared", title: "Atlético v São Paulo", description: String(repeating: "Café ⚽ ", count: 100), start: now, end: now.addingTimeInterval(3600)),
            EPGProgram(id: "old", channelID: "shared", title: "Expired", description: "", start: now.addingTimeInterval(-10000), end: now.addingTimeInterval(-9000))
        ]]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for guide in [programs, [:]] {
            let combined = StreamMatcher.buildIndex(channels: channels, programs: guide, hiddenGroups: ["Hidden"])
            var expectedTokens: [String: [Int]] = [:]
            for (index, channel) in channels.enumerated() {
                let independent = StreamMatcher.buildIndex(channels: [channel], programs: guide, hiddenGroups: ["Hidden"])
                let actual = try encoder.encode(combined.entries[index])
                let expected = try encoder.encode(independent.entries[0])
                precondition(actual == expected, "Cached entry changed")
                for token in independent.tokenToEntryIndices.keys {
                    expectedTokens[token, default: []].append(index)
                }
            }
            precondition(combined.tokenToEntryIndices.mapValues { Array($0) } == expectedTokens, "Channel tokens leaked through guide cache")
            for (token, indices) in expectedTokens {
                let df = Double(indices.count)
                let expected = log((Double(channels.count) - df + 0.5) / (df + 0.5) + 1)
                precondition(combined.inverseDocumentFrequency[token] == expected)
            }
        }
        let cancelled = StreamMatcher.buildIndex(channels: channels, programs: programs, shouldCancel: { true })
        precondition(cancelled.entries.isEmpty && cancelled.tokenToEntryIndices.isEmpty)
        let probe = CancellationProbe()
        let interrupted = StreamMatcher.buildIndex(channels: channels, programs: programs, shouldCancel: { probe.cancelled() })
        precondition(interrupted.entries.isEmpty && interrupted.tokenToEntryIndices.isEmpty, "Partial cancelled index escaped")
        print("PASS cancellation before and during index build")
        print("PASS shared-guide cache equals independent production indexing: entries, tokens, IDF, Unicode, hidden groups, empty guide")
    }
}
