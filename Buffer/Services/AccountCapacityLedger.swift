import Foundation
import CryptoKit

extension SourceAccountKey {
    /// Account aliases with the same endpoint/account share one budget. The
    /// password is deliberately excluded so password rotation cannot evade it.
    nonisolated init(config: ServerConfig) {
        let fields: [String]
        switch config.type {
        case .xtream:
            guard let origin = Self.canonicalEndpoint(config.serverURL), !config.username.isEmpty else {
                self = .unconfiguredSource(config.id)
                return
            }
            fields = ["xtream", origin, config.username]
        case .stalker:
            guard let origin = Self.canonicalEndpoint(config.stalkerRootBaseURL), !config.username.isEmpty else {
                self = .unconfiguredSource(config.id)
                return
            }
            let mac = config.stalkerMACAddress
            let digits = mac.filter(\.isHexDigit)
            let canonicalMAC = digits.count == 12 ? digits : mac
            fields = ["stalker", origin, canonicalMAC]
        case .m3u:
            // An arbitrary M3U does not declare an account. Never derive one
            // from an authenticated URL or assume two playlists share a cap.
            self = .unconfiguredSource(config.id)
            return
        }
        let bytes = (try? JSONEncoder().encode(fields)) ?? Data()
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        self.init(opaqueValue: "account:" + digest)
    }

    nonisolated private static func canonicalEndpoint(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string
    }
}

/// Reservations have no expiry. A cancelled task or a stale status response
/// cannot prove that a provider connection has ended; only its media owner can
/// confirm teardown. The same ledger is shared by every playback window,
/// recording and optional probe in this process.
nonisolated final class AccountCapacityLedger: @unchecked Sendable {
    static let shared = AccountCapacityLedger()

    enum Kind: String, Codable, Sendable {
        case player, recording, probe
    }

    struct Lease: Hashable, Sendable {
        let id: UUID
        let accountKey: SourceAccountKey
        let kind: Kind
        let ownerID: UUID
        let generation: UInt64
    }

    enum StatusFreshness: String, Sendable {
        case unknown, fresh, stale
    }

    struct Snapshot: Sendable {
        let limit: Int
        let localReservations: Int
        let reportedActiveConnections: Int?
        let knownExternalConnections: Int?
        let statusFreshness: StatusFreshness
        let available: Int
        let reservationsByKind: [Kind: Int]
    }

    enum ReservationFailure: Error, Equatable, Sendable {
        case ownershipMissing
        case capacityReached(limit: Int, localReservations: Int, externalConnections: Int?)
    }

    private struct Status {
        let maximum: Int?
        let active: Int?
        let knownOwnedAtObservation: Int?
        let observedAt: Date
    }

    private struct Account {
        var status: Status?
        var leases: [UUID: Lease] = [:]
        var nextGeneration: UInt64 = 0
    }

    private let lock = NSLock()
    private var accounts: [SourceAccountKey: Account] = [:]
    private let statusLifetime: TimeInterval

    init(statusLifetime: TimeInterval = 120) {
        self.statusLifetime = statusLifetime.isFinite ? max(0, statusLifetime) : 120
    }

    /// `knownOwnedConnections` is only supplied when ownership is established
    /// independently. Aggregate provider totals alone cannot identify which
    /// connections belong to Buffer, so their default interpretation is
    /// conservative: all may be external.
    func updateStatus(
        accountKey: SourceAccountKey,
        maxConnections: Int?,
        activeConnections: Int?,
        observedAt: Date = Date(),
        knownOwnedConnections: Int? = nil
    ) {
        guard observedAt.timeIntervalSince1970.isFinite else { return }
        lock.withLock {
            var account = accounts[accountKey] ?? Account()
            guard account.status.map({ observedAt >= $0.observedAt }) ?? true else { return }
            let maximum = maxConnections.flatMap { $0 > 0 ? $0 : nil }
            let active = activeConnections.flatMap { $0 >= 0 ? $0 : nil }
            let owned = knownOwnedConnections.flatMap { value -> Int? in
                guard value >= 0, let active, value <= active, value <= account.leases.count else { return nil }
                return value
            }
            account.status = Status(maximum: maximum, active: active,
                                    knownOwnedAtObservation: owned, observedAt: observedAt)
            accounts[accountKey] = account
        }
    }

    func snapshot(accountKey: SourceAccountKey, now: Date = Date()) -> Snapshot {
        lock.withLock { snapshot(account: accounts[accountKey] ?? Account(), now: now) }
    }

    func reserve(
        for channel: Channel,
        kind: Kind,
        ownerID: UUID,
        now: Date = Date()
    ) -> Result<Lease, ReservationFailure> {
        guard let key = channel.sourceOwnership?.accountKey else { return .failure(.ownershipMissing) }
        return reserve(accountKey: key, kind: kind, ownerID: ownerID, now: now)
    }

    func reserve(
        accountKey: SourceAccountKey,
        kind: Kind,
        ownerID: UUID,
        now: Date = Date()
    ) -> Result<Lease, ReservationFailure> {
        lock.withLock {
            var account = accounts[accountKey] ?? Account()
            // Retrying an open cannot reserve the same connection twice.
            if let existing = account.leases.values.first(where: { $0.ownerID == ownerID && $0.kind == kind }) {
                return .success(existing)
            }
            let state = snapshot(account: account, now: now)
            guard state.available > 0 else {
                return .failure(.capacityReached(limit: state.limit,
                    localReservations: state.localReservations, externalConnections: state.knownExternalConnections))
            }
            account.nextGeneration &+= 1
            let lease = Lease(id: UUID(), accountKey: accountKey, kind: kind,
                              ownerID: ownerID, generation: account.nextGeneration)
            account.leases[lease.id] = lease
            accounts[accountKey] = account
            return .success(lease)
        }
    }

    /// Call only after STOP/END_FILE, worker exit, or equivalent confirmation
    /// of backend idle. Repeated and stale callbacks are harmless.
    @discardableResult
    func confirmTeardown(lease: Lease) -> Bool {
        lock.withLock {
            guard var account = accounts[lease.accountKey], account.leases[lease.id] == lease else { return false }
            account.leases.removeValue(forKey: lease.id)
            accounts[lease.accountKey] = account
            return true
        }
    }

    private func snapshot(account: Account, now: Date) -> Snapshot {
        let age = account.status.map { now.timeIntervalSince($0.observedAt) }
        let fresh = age.map { $0.isFinite && $0 >= 0 && $0 <= statusLifetime } ?? false
        let freshness: StatusFreshness = account.status == nil ? .unknown : (fresh ? .fresh : .stale)
        let limit = fresh ? (account.status?.maximum ?? 1) : 1
        let external = account.status?.active.map { active in
            max(0, active - (account.status?.knownOwnedAtObservation ?? 0))
        }
        var counts: [Kind: Int] = [:]
        for lease in account.leases.values { counts[lease.kind, default: 0] += 1 }
        // Avoid overflow for malformed advertised counts and retain stale
        // external usage until a newer status explicitly establishes it ended.
        let local = account.leases.count
        let available = max(0, limit - min(limit, local) - min(limit, external ?? 0))
        return Snapshot(limit: limit, localReservations: local,
                        reportedActiveConnections: account.status?.active,
                        knownExternalConnections: external, statusFreshness: freshness,
                        available: available, reservationsByKind: counts)
    }
}
