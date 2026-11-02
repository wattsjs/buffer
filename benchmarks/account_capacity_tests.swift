import Foundation

private final class LeaseResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AccountCapacityLedger.Lease] = []

    func append(_ lease: AccountCapacityLedger.Lease) { lock.withLock { values.append(lease) } }
    var snapshot: [AccountCapacityLedger.Lease] { lock.withLock { values } }
}

@main
enum AccountCapacityTests {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        func lease(_ result: Result<AccountCapacityLedger.Lease, AccountCapacityLedger.ReservationFailure>) -> AccountCapacityLedger.Lease {
            guard case .success(let value) = result else { preconditionFailure("Expected available capacity") }
            return value
        }
        func rejected(_ result: Result<AccountCapacityLedger.Lease, AccountCapacityLedger.ReservationFailure>) -> Bool {
            if case .failure = result { return true }
            return false
        }

        let sourceA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let sourceB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let keyA = SourceChannelIdentity(sourceID: sourceA, nativeID: "42")
        let keyB = SourceChannelIdentity(sourceID: sourceB, nativeID: "42")
        expect(keyA != keyB, "Colliding provider IDs retain distinct source ownership")
        expect(keyA.rawValue != keyB.rawValue, "Serialized native keys do not collide")
        expect(Set([keyA, keyB]).count == 2, "Identity is safe as a dictionary key")
        expect(try JSONDecoder().decode(SourceChannelIdentity.self, from: JSONEncoder().encode(keyA)) == keyA,
               "Source/native identity survives cache persistence")

        let accountA = SourceAccountKey(config: ServerConfig(id: sourceA, type: .xtream,
            serverURL: "https://ACCOUNT.invalid:443/", username: "fixture-user", password: "fixture-secret"))
        let alias = SourceAccountKey(config: ServerConfig(id: sourceB, type: .xtream,
            serverURL: "https://account.invalid", username: "fixture-user", password: "rotated-secret"))
        let accountB = SourceAccountKey(config: ServerConfig(id: sourceB, type: .xtream,
            serverURL: "https://account.invalid", username: "different-user", password: "fixture-secret"))
        expect(accountA == alias, "Source aliases for the same actual account share one budget")
        expect(accountA != accountB, "Different accounts on the same provider have separate budgets")
        expect(!accountA.rawValue.contains("fixture-user") && !accountA.rawValue.contains("ACCOUNT")
               && !accountA.rawValue.contains("fixture-secret"), "Account key exposes no account input")
        expect(accountA.rawValue.count == "account:".count + 64, "Account uses full SHA256 digest")
        let alternatePath = SourceAccountKey(config: ServerConfig(type: .xtream,
            serverURL: "https://account.invalid/another-portal", username: "fixture-user"))
        expect(alternatePath != accountA, "Different portal paths cannot be assumed to share an account")
        let stalkerA = SourceAccountKey(config: ServerConfig(type: .stalker,
            serverURL: "https://portal.invalid/c/", username: "00:1a:79:00:00:01"))
        let stalkerB = SourceAccountKey(config: ServerConfig(type: .stalker,
            serverURL: "https://portal.invalid/", username: "00-1A-79-00-00-01"))
        expect(stalkerA == stalkerB, "MAC case/separator and portal entry path aliases share capacity")
        expect(SourceAccountKey(config: ServerConfig(id: sourceA, type: .m3u)) !=
               SourceAccountKey(config: ServerConfig(id: sourceB, type: .m3u)), "Undeclared M3U accounts remain source-scoped")
        expect(SourceAccountKey(config: ServerConfig(id: sourceA, type: .xtream)) == .unconfiguredSource(sourceA),
               "Invalid/missing configuration retains a conservative source fallback")

        func channel(_ key: SourceChannelIdentity?, logicalID: String? = nil) -> Channel {
            Channel(id: "42", name: "Test", logoURL: nil, group: "Tests",
                streamURL: URL(string: "http://127.0.0.1/test.m3u8")!, epgChannelID: "BBCOne.uk",
                sourceOwnership: key.map {
                    ChannelSourceOwnership(channelIdentity: $0, accountKey: accountA,
                        logicalChannelID: logicalID,
                        guideBinding: SourceGuideBinding(sourceID: $0.sourceID, epgChannelID: "BBCOne.uk"))
                })
        }
        expect(channel(keyA) != channel(keyB), "Channel equality does not merge raw IDs across providers")
        expect(Set([channel(keyA), channel(keyB)]).count == 2, "Channel hash matches scoped equality")
        expect(channel(keyA).sourceOwnership?.guideBinding != channel(keyB).sourceOwnership?.guideBinding,
               "Even a wrong shared EPG ID remains separately source-bound")
        expect(channel(keyA, logicalID: "smart:sports:fixture") == channel(keyB, logicalID: "smart:sports:fixture"),
               "Logical preference identity survives a physical source switch")
        expect(channel(keyA, logicalID: "smart:sports:fixture").sourceChannelIdentity == keyA,
               "Logical identity does not replace physical action ownership")
        let encoded = try JSONEncoder().encode(channel(keyA))
        expect(try JSONDecoder().decode(Channel.self, from: encoded).sourceOwnership == channel(keyA).sourceOwnership,
               "Channel ownership round-trips")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(channel(nil))) as! [String: Any]
        legacy.removeValue(forKey: "sourceOwnership")
        let legacyChannel = try JSONDecoder().decode(Channel.self, from: JSONSerialization.data(withJSONObject: legacy))
        expect(legacyChannel.sourceOwnership == nil && legacyChannel.preferenceIdentity == "42",
               "Pre-ownership channel caches retain legacy IDs")

        let now = Date(timeIntervalSince1970: 1_000_000)
        let ledger = AccountCapacityLedger(statusLifetime: 120)
        expect(ledger.snapshot(accountKey: accountA, now: now).limit == 1, "Unknown cap defaults to one")
        expect(ledger.snapshot(accountKey: accountA, now: now).statusFreshness == .unknown,
               "Unknown external usage is explicit")
        let owner = UUID()
        let earlyProbe = lease(ledger.reserve(accountKey: accountA, kind: .probe, ownerID: UUID(), now: now))
        expect(rejected(ledger.reserve(accountKey: alias, kind: .probe, ownerID: UUID(), now: now)),
               "Aliases cannot open a probe beyond the shared default cap")
        let player = lease(ledger.reserve(accountKey: accountA, kind: .player, ownerID: owner, now: now))
        expect(rejected(ledger.reserve(accountKey: alias, kind: .probe, ownerID: UUID(), now: now)),
               "A running player blocks further probes")
        ledger.confirmTeardown(lease: earlyProbe)
        expect(rejected(ledger.reserve(accountKey: alias, kind: .player, ownerID: UUID(), now: now)),
               "A second player cannot exceed the default cap")
        expect(lease(ledger.reserve(accountKey: alias, kind: .player, ownerID: owner, now: now)) == player,
               "Duplicate reservation by the same owner is idempotent")
        let independent = lease(ledger.reserve(accountKey: accountB, kind: .recording, ownerID: UUID(), now: now))
        expect(independent.accountKey == accountB, "An unrelated account can open independently")
        expect(ledger.snapshot(accountKey: accountA, now: now.addingTimeInterval(10_000)).localReservations == 1,
               "Elapsed time cannot release a potentially live backend")
        expect(ledger.confirmTeardown(lease: player), "Confirmed teardown releases the owned connection")
        expect(!ledger.confirmTeardown(lease: player), "Repeated teardown is idempotent")
        let replacement = lease(ledger.reserve(accountKey: accountA, kind: .player, ownerID: owner, now: now))
        expect(replacement.generation > player.generation && replacement.id != player.id,
               "A reused owner receives a new lease generation")
        expect(!ledger.confirmTeardown(lease: player), "A stale callback cannot release its replacement")
        expect(ledger.snapshot(accountKey: accountA, now: now).localReservations == 1,
               "Replacement capacity remains reserved after stale callback")
        ledger.confirmTeardown(lease: replacement)

        ledger.updateStatus(accountKey: accountA, maxConnections: 3, activeConnections: 0, observedAt: now)
        let p = lease(ledger.reserve(accountKey: accountA, kind: .player, ownerID: UUID(), now: now))
        let r = lease(ledger.reserve(accountKey: accountA, kind: .recording, ownerID: UUID(), now: now))
        let q = lease(ledger.reserve(accountKey: accountA, kind: .probe, ownerID: UUID(), now: now))
        expect(rejected(ledger.reserve(accountKey: accountA, kind: .probe, ownerID: UUID(), now: now)),
               "Players, recordings and probes compete within one account limit")
        let full = ledger.snapshot(accountKey: accountA, now: now)
        expect(full.reservationsByKind[.player] == 1 && full.reservationsByKind[.recording] == 1
               && full.reservationsByKind[.probe] == 1 && full.available == 0, "Capacity reports each owner kind")
        ledger.confirmTeardown(lease: q)
        expect(ledger.snapshot(accountKey: accountA, now: now).available == 1, "Probe exit frees exactly one slot")
        ledger.updateStatus(accountKey: accountA, maxConnections: 3, activeConnections: 2,
                            observedAt: now.addingTimeInterval(1))
        expect(ledger.snapshot(accountKey: accountA, now: now.addingTimeInterval(1)).available == 0,
               "Aggregate totals are not assumed to be owned by Buffer")
        let lingering = lease(ledger.reserve(accountKey: accountA, kind: .player, ownerID: UUID(), now: now.addingTimeInterval(1)))
        expect(rejected(ledger.reserve(accountKey: accountA, kind: .player, ownerID: UUID(), now: now.addingTimeInterval(1))),
               "Players and recordings still share the declared limit")
        ledger.confirmTeardown(lease: lingering)
        ledger.updateStatus(accountKey: accountA, maxConnections: 3, activeConnections: 2,
                            observedAt: now.addingTimeInterval(2), knownOwnedConnections: 2)
        expect(ledger.snapshot(accountKey: accountA, now: now.addingTimeInterval(2)).knownExternalConnections == 0,
               "Independently established ownership avoids double-counting")
        expect(ledger.snapshot(accountKey: accountA, now: now.addingTimeInterval(2)).available == 1,
               "Only explicitly owned connections may be subtracted from a total")
        ledger.updateStatus(accountKey: accountA, maxConnections: 50, activeConnections: 0,
                            observedAt: now.addingTimeInterval(1))
        expect(ledger.snapshot(accountKey: accountA, now: now.addingTimeInterval(2)).limit == 3,
               "Out-of-order status cannot overwrite newer capacity")
        ledger.confirmTeardown(lease: p)
        ledger.confirmTeardown(lease: r)
        ledger.updateStatus(accountKey: accountA, maxConnections: 3, activeConnections: 1,
                            observedAt: now.addingTimeInterval(3))
        let stale = ledger.snapshot(accountKey: accountA, now: now.addingTimeInterval(124))
        expect(stale.statusFreshness == .stale && stale.limit == 1 && stale.knownExternalConnections == 1,
               "Stale status falls back conservatively without expiring external usage")
        expect(rejected(ledger.reserve(accountKey: accountA, kind: .probe, ownerID: UUID(), now: now.addingTimeInterval(124))),
               "Stale external connections still block background probes")
        let afterSwitch = lease(ledger.reserve(accountKey: accountA, kind: .player, ownerID: UUID(), now: now.addingTimeInterval(124)))
        expect(ledger.snapshot(accountKey: accountA, now: now.addingTimeInterval(124)).reservationsByKind[.player] == 1,
               "A user's play request is not refused by a stale provider active count")
        ledger.confirmTeardown(lease: afterSwitch)
        ledger.updateStatus(accountKey: accountA, maxConnections: 0, activeConnections: -1,
                            observedAt: now.addingTimeInterval(125))
        expect(ledger.snapshot(accountKey: accountA, now: now.addingTimeInterval(125)).limit == 1,
               "Zero/invalid declared capacity is unknown, never unlimited")
        expect(ledger.snapshot(accountKey: accountA, now: now.addingTimeInterval(125)).knownExternalConnections == nil,
               "Invalid external counts remain unknown")
        ledger.updateStatus(accountKey: accountA, maxConnections: Int.max, activeConnections: Int.max,
                            observedAt: now.addingTimeInterval(126))
        expect(ledger.snapshot(accountKey: accountA, now: now.addingTimeInterval(126)).available == 0,
               "Malformed huge counts cannot overflow to available capacity")
        expect(rejected(ledger.reserve(for: channel(nil), kind: .player, ownerID: UUID(), now: now)),
               "Unowned channels cannot invent an account")

        let concurrent = AccountCapacityLedger()
        concurrent.updateStatus(accountKey: accountA, maxConnections: 3, activeConnections: 0, observedAt: now)
        let results = LeaseResults()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if case .success(let value) = concurrent.reserve(accountKey: accountA, kind: .probe, ownerID: UUID(), now: now) {
                results.append(value)
            }
        }
        let successful = results.snapshot
        expect(successful.count == 3, "Atomic reservations enforce cap under simultaneous media opens")
        for value in successful { concurrent.confirmTeardown(lease: value) }
        expect(concurrent.snapshot(accountKey: accountA, now: now).localReservations == 0,
               "Concurrent owners release all confirmed teardowns")

        // Large plans spill past the inline lease storage and stay exact.
        let large = AccountCapacityLedger(statusLifetime: 120)
        large.updateStatus(accountKey: accountA, maxConnections: 12, activeConnections: 0, observedAt: now)
        var held: [AccountCapacityLedger.Lease] = []
        for _ in 0..<12 {
            if case .success(let value) = large.reserve(accountKey: accountA, kind: .player, ownerID: UUID(), now: now) {
                held.append(value)
            }
        }
        expect(held.count == 12 && large.snapshot(accountKey: accountA, now: now).localReservations == 12,
               "Twelve player leases fit a twelve-connection plan")
        if case .success = large.reserve(accountKey: accountA, kind: .player, ownerID: UUID(), now: now) {
            expect(false, "A thirteenth player exceeded the plan")
        }
        let retry = large.reserve(accountKey: accountA, kind: .player, ownerID: held[10].ownerID, now: now)
        expect((try? retry.get()) == held[10], "An overflowed owner's retry returns its existing lease")
        expect(large.confirmTeardown(lease: held[2]) && large.confirmTeardown(lease: held[11]),
               "Teardown removes inline and overflowed leases")
        expect(!large.confirmTeardown(lease: held[2]), "Repeated teardown is harmless")
        let remaining = large.snapshot(accountKey: accountA, now: now)
        expect(remaining.localReservations == 10 && remaining.reservationsByKind[.player] == 10,
               "Counts stay exact after removal from both regions")
        for (index, value) in held.enumerated() where index != 2 && index != 11 {
            expect(large.confirmTeardown(lease: value), "Every remaining lease is still found after compaction")
        }
        expect(large.snapshot(accountKey: accountA, now: now).localReservations == 0
               && large.snapshot(accountKey: accountA, now: now).reservationsByKind.isEmpty,
               "All leases released")
        print("Source ownership/account capacity checks: \(checks) passed")
    }
}
