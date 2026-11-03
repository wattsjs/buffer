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
        var hex: [UInt8] = []
        hex.reserveCapacity(64)
        for byte in SHA256.hash(data: bytes) {
            hex.append(Self.hexDigits[Int(byte >> 4)])
            hex.append(Self.hexDigits[Int(byte & 0xF)])
        }
        self.init(opaqueValue: "account:" + String(decoding: hex, as: UTF8.self))
    }

    nonisolated private static let hexDigits = Array("0123456789abcdef".utf8)

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
        /// Seconds since the reference date; plain arithmetic, no Date calls.
        let observedAt: TimeInterval
    }

    /// One reservation without its account key (the account owns it):
    /// plain values only, so it can live in inline storage.
    private struct LeaseRecord: Equatable {
        var id: UUID
        var ownerID: UUID
        var generation: UInt64
        var kind: Kind
    }

    /// An account rarely holds more than a few connections (its plan limit
    /// plus at most two probes). They live inline in the account record;
    /// only an unusually large plan spills into a heap array. Each inline
    /// slot's kind is also packed into `kindBits` (2 bits per slot) so
    /// per-kind counts never read the records.
    private struct InlineLeases {
        static let capacity = 8
        private typealias Storage = (LeaseRecord, LeaseRecord, LeaseRecord, LeaseRecord,
                                     LeaseRecord, LeaseRecord, LeaseRecord, LeaseRecord)
        private static let empty = LeaseRecord(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
                                               ownerID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
                                               generation: 0, kind: .probe)
        private var inline: Storage = (empty, empty, empty, empty, empty, empty, empty, empty)
        private var inlineCount = 0
        private var kindBits: UInt32 = 0
        private var overflow: [LeaseRecord] = []

        var count: Int { inlineCount + overflow.count }

        @inline(__always) private static func code(_ kind: Kind) -> UInt32 {
            switch kind { case .player: 1; case .recording: 2; case .probe: 3 }
        }

        private mutating func setInline(_ index: Int, _ record: LeaseRecord) {
            withUnsafeMutableBytes(of: &inline) {
                $0.storeBytes(of: record, toByteOffset: index * MemoryLayout<LeaseRecord>.stride, as: LeaseRecord.self)
            }
            let shift = UInt32(index * 2)
            kindBits = kindBits & ~(3 << shift) | Self.code(record.kind) << shift
        }

        subscript(_ index: Int) -> LeaseRecord {
            if index >= inlineCount { return overflow[index - inlineCount] }
            return withUnsafeBytes(of: inline) {
                $0.load(fromByteOffset: index * MemoryLayout<LeaseRecord>.stride, as: LeaseRecord.self)
            }
        }

        mutating func append(_ record: LeaseRecord) {
            guard inlineCount < Self.capacity, overflow.isEmpty else { overflow.append(record); return }
            setInline(inlineCount, record)
            inlineCount += 1
        }

        /// Order is not meaningful; the last record fills the hole.
        mutating func remove(at index: Int) {
            let last = count - 1
            if index != last {
                let moved = self[last]
                if index >= inlineCount { overflow[index - inlineCount] = moved } else { setInline(index, moved) }
            }
            if overflow.isEmpty {
                inlineCount -= 1
                kindBits &= ~(3 << UInt32(inlineCount * 2))
            } else {
                overflow.removeLast()
            }
        }

        /// One borrow of the inline records, then the overflow.
        func firstIndex(where predicate: (LeaseRecord) -> Bool) -> Int? {
            let found = withUnsafeBytes(of: inline) { raw -> Int? in
                let records = raw.bindMemory(to: LeaseRecord.self)
                for i in 0..<inlineCount where predicate(records[i]) { return i }
                return nil
            }
            if let found { return found }
            for (i, record) in overflow.enumerated() where predicate(record) { return inlineCount + i }
            return nil
        }

        /// Player, recording and probe counts from the packed kind bits.
        func counts() -> (player: Int, recording: Int, probe: Int) {
            var result = (player: 0, recording: 0, probe: 0)
            var bits = kindBits
            while bits != 0 {
                switch bits & 3 {
                case 1: result.player += 1
                case 2: result.recording += 1
                case 3: result.probe += 1
                default: break
                }
                bits >>= 2
            }
            for record in overflow {
                switch record.kind {
                case .player: result.player += 1
                case .recording: result.recording += 1
                case .probe: result.probe += 1
                }
            }
            return result
        }
    }

    private struct Account {
        var status: Status?
        var leases = InlineLeases()
        var nextGeneration: UInt64 = 0
    }

    private let lock = NSLock()
    /// Accounts live in one flat array, mutated in place; the dictionary
    /// only maps an account key to its slot.
    private var slotByAccount: [SourceAccountKey: Int] = [:]
    private var accounts: [Account] = []
    private let statusLifetime: TimeInterval

    /// Caller holds `lock`.
    private func slot(for key: SourceAccountKey) -> Int {
        if let slot = slotByAccount[key] { return slot }
        slotByAccount[key] = accounts.count
        accounts.append(Account())
        return accounts.count - 1
    }

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
            let slot = slot(for: accountKey)
            let observed = observedAt.timeIntervalSinceReferenceDate
            guard accounts[slot].status.map({ observed >= $0.observedAt }) ?? true else { return }
            let maximum = maxConnections.flatMap { $0 > 0 ? $0 : nil }
            let active = activeConnections.flatMap { $0 >= 0 ? $0 : nil }
            let leaseCount = accounts[slot].leases.count
            let owned = knownOwnedConnections.flatMap { value -> Int? in
                guard value >= 0, let active, value <= active, value <= leaseCount else { return nil }
                return value
            }
            accounts[slot].status = Status(maximum: maximum, active: active,
                                           knownOwnedAtObservation: owned, observedAt: observed)
        }
    }

    func snapshot(accountKey: SourceAccountKey, now: Date = Date()) -> Snapshot {
        lock.withLock {
            guard let slot = slotByAccount[accountKey] else { return snapshot(status: nil, counts: (0, 0, 0), now: now) }
            return snapshot(status: accounts[slot].status, counts: accounts[slot].leases.counts(), now: now)
        }
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
            let slot = slot(for: accountKey)
            // Retrying an open cannot reserve the same connection twice.
            if let index = accounts[slot].leases.firstIndex(where: { $0.ownerID == ownerID && $0.kind == kind }) {
                let existing = accounts[slot].leases[index]
                return .success(Lease(id: existing.id, accountKey: accountKey, kind: existing.kind,
                                      ownerID: existing.ownerID, generation: existing.generation))
            }
            let status = accounts[slot].status
            let counts = accounts[slot].leases.counts()
            let state = snapshot(status: status, counts: counts, now: now)
            guard (kind == .probe ? state.available : userAvailable(status: status, counts: counts)) > 0 else {
                return .failure(.capacityReached(limit: state.limit,
                    localReservations: state.localReservations, externalConnections: state.knownExternalConnections))
            }
            accounts[slot].nextGeneration &+= 1
            let lease = Lease(id: UUID(), accountKey: accountKey, kind: kind,
                              ownerID: ownerID, generation: accounts[slot].nextGeneration)
            accounts[slot].leases.append(LeaseRecord(id: lease.id, ownerID: ownerID, generation: lease.generation, kind: kind))
            return .success(lease)
        }
    }

    /// Call only after STOP/END_FILE, worker exit, or equivalent confirmation
    /// of backend idle. Repeated and stale callbacks are harmless.
    @discardableResult
    func confirmTeardown(lease: Lease) -> Bool {
        lock.withLock {
            guard let slot = slotByAccount[lease.accountKey] else { return false }
            let record = LeaseRecord(id: lease.id, ownerID: lease.ownerID, generation: lease.generation, kind: lease.kind)
            guard let index = accounts[slot].leases.firstIndex(where: { $0.id == lease.id }),
                  accounts[slot].leases[index] == record else { return false }
            accounts[slot].leases.remove(at: index)
            return true
        }
    }

    /// Players and recordings are explicit user requests. Providers keep
    /// counting a stream for a while after it closes, and an account's plan
    /// limit does not shrink when the status ages, so these are checked only
    /// against Buffer's own player/recording connections and the last
    /// declared limit. Probes are short-lived and yield; a genuine provider
    /// refusal still reaches the player's own recovery path.
    private func userAvailable(status: Status?, counts: (player: Int, recording: Int, probe: Int)) -> Int {
        let limit = status?.maximum ?? 1
        let local = counts.player + counts.recording
        return max(0, limit - min(limit, local))
    }

    private func snapshot(status: Status?, counts byKind: (player: Int, recording: Int, probe: Int), now: Date) -> Snapshot {
        let age = status.map { now.timeIntervalSinceReferenceDate - $0.observedAt }
        let fresh = age.map { $0.isFinite && $0 >= 0 && $0 <= statusLifetime } ?? false
        let freshness: StatusFreshness = status == nil ? .unknown : (fresh ? .fresh : .stale)
        let limit = fresh ? (status?.maximum ?? 1) : 1
        let external = status?.active.map { active in
            max(0, active - (status?.knownOwnedAtObservation ?? 0))
        }
        let local = byKind.player + byKind.recording + byKind.probe
        var counts: [Kind: Int] = [:]
        if local > 0 {
            if byKind.player > 0 { counts[.player] = byKind.player }
            if byKind.recording > 0 { counts[.recording] = byKind.recording }
            if byKind.probe > 0 { counts[.probe] = byKind.probe }
        }
        // Avoid overflow for malformed advertised counts and retain stale
        // external usage until a newer status explicitly establishes it ended.
        let available = max(0, limit - min(limit, local) - min(limit, external ?? 0))
        return Snapshot(limit: limit, localReservations: local,
                        reportedActiveConnections: status?.active,
                        knownExternalConnections: external, statusFreshness: freshness,
                        available: available, reservationsByKind: counts)
    }
}
