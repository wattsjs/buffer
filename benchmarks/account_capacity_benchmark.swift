import Foundation

// Ledger hot paths: one snapshot per Smart variant during selection and
// availability passes, and reserve/teardown churn from probes and players.
// swiftc -O -swift-version 6 Buffer/Models/ServerConfig.swift Buffer/Models/SourceChannelIdentity.swift \
//   Buffer/Models/Channel.swift Buffer/Models/EPGProgram.swift Buffer/Services/AccountCapacityLedger.swift \
//   benchmarks/account_capacity_benchmark.swift -o .local/bench/account-capacity-bench

@main struct AccountCapacityBenchmark {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ledger = AccountCapacityLedger(statusLifetime: 120)
        let accounts = (0..<3).map { SourceAccountKey(opaqueValue: "account:bench-\($0)") }
        for account in accounts {
            ledger.updateStatus(accountKey: account, maxConnections: 4, activeConnections: 1, observedAt: now)
            _ = ledger.reserve(accountKey: account, kind: .player, ownerID: UUID(), now: now)
            _ = ledger.reserve(accountKey: account, kind: .probe, ownerID: UUID(), now: now)
        }
        func time(_ label: String, _ body: () -> Int) {
            var samples: [Double] = []
            var sink = 0
            for _ in 0..<7 {
                let start = ContinuousClock.now
                sink &+= body()
                let d = ContinuousClock.now - start
                samples.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
            }
            print(String(format: "%-44@ median %8.2f ms [%d]", label as NSString, samples.sorted()[3], sink % 100))
        }
        time("snapshot x 600k (600 variants x 1000 passes)") {
            var n = 0
            for i in 0..<600_000 { n &+= ledger.snapshot(accountKey: accounts[i % 3], now: now).available }
            return n
        }
        let owners = (0..<64).map { _ in UUID() }
        time("reserve + teardown x 200k") {
            var n = 0
            for i in 0..<200_000 {
                let account = accounts[i % 3]
                if case .success(let lease) = ledger.reserve(accountKey: account, kind: .probe, ownerID: owners[i % 64], now: now) {
                    n &+= ledger.confirmTeardown(lease: lease) ? 1 : 0
                }
            }
            return n
        }
    }
}
