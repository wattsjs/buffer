/// Correlates libmpv item events with the request which actually created the
/// playlist entry. FILE_LOADED has no payload: its identity comes from the
/// preceding START_FILE, never from the most recently requested Swift load.
/// loadfile's command reply returns playlist_entry_id (mpv 0.41 command.c).
struct MPVItemLifecycle {
    struct Identity: Equatable, Sendable {
        let generation: Int
        let playlistEntryID: Int64
    }

    enum Command: Equatable {
        case load(String)
        case stop
    }

    struct Request: Equatable {
        let id: UInt64
        let generation: Int
        let command: Command
    }

    struct End {
        let identity: Identity
        let reason: MPVEndReason
    }

    struct Completion {
        let request: Request
        let loaded: Identity?
        let ended: End?
        let next: Request?
    }

    private(set) var generation = 0
    private(set) var inFlight: Request?
    private var pending: (generation: Int, command: Command)?
    private var requestSerial: UInt64 = 0
    private var targetEntryID: Int64?
    private var startedEntryID: Int64?
    private var loadedEntryID: Int64?
    private var earlyEnds: [Int64: MPVEndReason] = [:]
    private var earlyRedirects: [Int64: (first: Int64, count: Int)] = [:]
    private var redirectedEntries: [ClosedRange<Int64>] = []

    /// A command reply alone does not prove that playback closed. Retain the
    /// actual START_FILE until END_FILE, even after its owner invalidates it.
    var isBackendIdle: Bool {
        inFlight == nil && pending == nil && startedEntryID == nil
    }

    var activeIdentity: Identity? {
        guard let targetEntryID, targetEntryID == startedEntryID else { return nil }
        return Identity(generation: generation, playlistEntryID: targetEntryID)
    }

    var loadedIdentity: Identity? {
        guard let identity = activeIdentity, identity.playlistEntryID == loadedEntryID else { return nil }
        return identity
    }

    func acceptsProperty(for identity: Identity?) -> Bool {
        guard let identity else { return false }
        return activeIdentity == identity
    }

    mutating func invalidate(generation: Int) {
        self.generation = generation
        targetEntryID = nil
        loadedEntryID = nil
        earlyEnds = [:]
        earlyRedirects = [:]
        redirectedEntries = []
        // The backend request is not cancellable, but a newer item action can
        // supersede an action which has not reached it yet.
        pending = nil
    }

    /// Serialize item mutations through their replies. libmpv explicitly
    /// permits arbitrary reordering of overlapping async commands.
    mutating func enqueue(_ command: Command, generation: Int) -> Request? {
        guard generation == self.generation else { return nil }
        pending = (generation, command)
        return nextRequest()
    }

    mutating func complete(requestID: UInt64, playlistEntryID: Int64?) -> Completion? {
        guard let request = inFlight, request.id == requestID else { return nil }
        inFlight = nil
        var loaded: Identity?
        var ended: End?
        if request.generation == generation, case .load = request.command, let playlistEntryID {
            targetEntryID = playlistEntryID
            while let targetEntryID, let redirect = earlyRedirects.removeValue(forKey: targetEntryID) {
                adoptRedirect(first: redirect.first, count: redirect.count)
            }
            loaded = loadedIdentity
            if let targetEntryID, let reason = earlyEnds[targetEntryID] {
                ended = End(identity: Identity(generation: generation, playlistEntryID: targetEntryID), reason: reason)
                self.targetEntryID = nil
            }
            earlyEnds = [:]
            earlyRedirects = [:]
        }
        return Completion(request: request, loaded: loaded, ended: ended, next: nextRequest())
    }

    mutating func started(playlistEntryID: Int64) {
        startedEntryID = playlistEntryID
        loadedEntryID = nil
        if redirectedEntries.contains(where: { $0.contains(playlistEntryID) }) {
            targetEntryID = playlistEntryID
        }
    }

    mutating func loaded() -> Identity? {
        loadedEntryID = startedEntryID
        return loadedIdentity
    }

    mutating func ended(playlistEntryID: Int64, reason: MPVEndReason) -> End? {
        if startedEntryID == playlistEntryID {
            startedEntryID = nil
            loadedEntryID = nil
        }
        guard targetEntryID == playlistEntryID else {
            // Some backends can publish events before COMMAND_REPLY. Keep the
            // outcome until the actual entry-to-request association arrives.
            if let request = inFlight, request.generation == generation, case .load = request.command {
                earlyEnds[playlistEntryID] = reason
            }
            return nil
        }
        targetEntryID = nil
        return End(identity: Identity(generation: generation, playlistEntryID: playlistEntryID), reason: reason)
    }

    /// A playlist expands into different entry IDs without a new Swift load.
    /// libmpv documents the inserted IDs as a contiguous range in END_FILE.
    mutating func redirected(playlistEntryID: Int64, first: Int64, count: Int) {
        guard count > 0, first > 0, first <= Int64.max - Int64(count - 1) else { return }
        if startedEntryID == playlistEntryID {
            startedEntryID = nil
            loadedEntryID = nil
        }
        if targetEntryID == playlistEntryID {
            adoptRedirect(first: first, count: count)
        } else if let request = inFlight, request.generation == generation, case .load = request.command {
            earlyRedirects[playlistEntryID] = (first, count)
        }
    }

    private mutating func adoptRedirect(first: Int64, count: Int) {
        let range = first...(first + Int64(count - 1))
        redirectedEntries.append(range)
        targetEntryID = startedEntryID.flatMap { range.contains($0) ? $0 : nil } ?? first
    }

    private mutating func nextRequest() -> Request? {
        guard inFlight == nil, let pending else { return nil }
        self.pending = nil
        requestSerial &+= 1
        let request = Request(id: (1 << 61) | requestSerial, generation: pending.generation, command: pending.command)
        inFlight = request
        return request
    }
}
