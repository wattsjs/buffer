import Foundation
import Observation

/// Settings backing the on-demand stream probe feature. Off by default — the
/// probe opens a real connection to each channel, which costs bandwidth and
/// can show up as a "viewer" against an Xtream session limit.
nonisolated enum StreamProbeSetting {
    static let enabledKey = "buffer_stream_probe_enabled"
    static let defaultEnabled = true

    static var isEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? defaultEnabled }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

/// On-demand stream metadata probing. Channels feed in by id+url, the service
/// schedules limited concurrent ffmpeg probes off the main thread and exposes
/// the most recent result via `probe(for:)`.
@MainActor
@Observable
final class StreamProbeService {
    static let shared = StreamProbeService()

    /// Bumped on every result write so SwiftUI views can depend on a single
    /// observable token without subscribing to the whole dictionary.
    private(set) var version: Int = 0

    /// Includes a reserved launch until its pre-IO check or blocking C call
    /// finishes. Diagnostics can wait for zero before opening their player.
    private(set) var probeRunningCount: Int = 0
    var isProbeRunning: Bool { probeRunningCount != 0 }

    nonisolated struct SuspensionLease: Hashable, Sendable {
        fileprivate let id: UUID
    }

    @ObservationIgnored private var suspensionLeases: Set<UUID> = []

    /// Ephemeral connection isolation for diagnostics. Cached metadata,
    /// queued requests, and the user's enabled setting are retained.
    func suspendProbing() -> SuspensionLease {
        let lease = SuspensionLease(id: UUID())
        suspensionLeases.insert(lease.id)
        retryTask?.cancel()
        retryTask = nil
        return lease
    }

    /// Idempotent: nested owners must all release before queued probes resume.
    func resumeProbing(_ lease: SuspensionLease) {
        guard suspensionLeases.remove(lease.id) != nil else { return }
        if suspensionLeases.isEmpty { drainQueue() }
    }

    /// Cache key currently in scope. Probes are scoped per-playlist so
    /// switching playlists doesn't show metadata from a different provider.
    @ObservationIgnored private var activeCacheKey: String?
    @ObservationIgnored private var activeSourceID: UUID?
    @ObservationIgnored private var sourceCacheKeys: [UUID: String] = [:]
    @ObservationIgnored private var pendingSourceCacheLoads: Set<UUID> = []
    private var sourceProbes: [UUID: [String: StreamProbe]] = [:]
    @ObservationIgnored private var generation: UInt64 = 0
    private var probes: [String: StreamProbe] = [:]
    @ObservationIgnored private var channelRevisions: [String: UInt64] = [:]
    @ObservationIgnored private var pending: [PendingProbe] = []
    @ObservationIgnored private var pendingIDs: Set<String> = []
    /// Probes in flight, keyed by `PendingProbe.scopedID`. Each holds its
    /// account's capacity lease, so parallelism never exceeds a provider's
    /// connection limit; the global cap bounds local CPU and bandwidth.
    @ObservationIgnored private var activeProbes: [String: PendingProbe] = [:]
    static let maximumConcurrentProbes = 4
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    @ObservationIgnored private let hasPlaybackSessions: @MainActor () -> Bool
    @ObservationIgnored private let runProbe: @Sendable (String) -> StreamProbe
    @ObservationIgnored private let loadCache: @Sendable (String, [String]) -> [String: StreamProbe]?
    @ObservationIgnored private let saveCache: @Sendable ([String: StreamProbe], String) -> Void
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private let retryDelay: Duration

    private struct PendingProbe: Sendable {
        let id: String
        let url: URL
        let priority: TaskPriority
        let generation: UInt64
        let cacheKey: String
        let ownership: ChannelSourceOwnership?
        /// nil for the active source; otherwise the Smart source whose own
        /// cache receives the result.
        var sourceID: UUID? = nil
        var channelRevision: UInt64 = 0

        /// Native IDs are only unique within one source.
        var scopedID: String { (sourceID?.uuidString ?? "") + "|" + id }
    }

    private func isCurrentScope(_ request: PendingProbe) -> Bool {
        guard let sourceID = request.sourceID else { return activeCacheKey == request.cacheKey }
        return sourceCacheKeys[sourceID] == request.cacheKey && sourceProbes[sourceID] != nil
    }

    private func storedProbe(for request: PendingProbe) -> StreamProbe? {
        guard let sourceID = request.sourceID else { return probes[request.id] }
        return sourceProbes[sourceID]?[request.id]
    }

    /// Inject only IO and application state. Tests exercise this service's
    /// real queue and publication logic without opening provider connections.
    init(
        isEnabled: @escaping @MainActor () -> Bool = { StreamProbeSetting.isEnabled },
        hasPlaybackSessions: @escaping @MainActor () -> Bool = {
            !PlayerSessionRegistry.shared.allSessions.isEmpty
        },
        runProbe: @escaping @Sendable (String) -> StreamProbe = {
            StreamProbeService.runBlockingProbe(urlString: $0)
        },
        loadCache: @escaping @Sendable (String, [String]) -> [String: StreamProbe]? = { key, legacyKeys in
            (DataCache.loadProbes(key: key)
                ?? legacyKeys.lazy.compactMap { DataCache.loadProbes(key: $0) }.first)?.probes
        },
        saveCache: @escaping @Sendable ([String: StreamProbe], String) -> Void = { probes, key in
            DataCache.saveProbes(probes, key: key)
        },
        saveDelay: Duration = .seconds(1),
        retryDelay: Duration = .milliseconds(500)
    ) {
        self.isEnabled = isEnabled
        self.hasPlaybackSessions = hasPlaybackSessions
        self.runProbe = runProbe
        self.loadCache = loadCache
        self.saveCache = saveCache
        self.saveDelay = saveDelay
        self.retryDelay = retryDelay
    }

    /// Retire queued identities on every scope change. A C probe already
    /// inside libavformat cannot be cancelled; it continues to occupy the one
    /// active slot until its bounded IO call returns, and its result is rejected.
    func setActiveCacheKey(_ key: String?, legacyKeys: [String] = [], sourceID: UUID? = nil) {
        guard activeCacheKey != key || activeSourceID != sourceID else { return }
        if let activeSourceID { sourceProbes[activeSourceID] = probes }
        invalidateQueuedWork()
        activeCacheKey = key
        activeSourceID = sourceID
        if let sourceID, let key { sourceCacheKeys[sourceID] = key }
        probes = key.flatMap { dirtySnapshots[$0] ?? writingSnapshots[$0] } ?? [:]
        channelRevisions.removeAll()
        version &+= 1
        guard let key else { return }
        let expectedGeneration = generation
        let loadCache = self.loadCache
        Task.detached(priority: .utility) { [weak self] in
            let cached = loadCache(key, legacyKeys)
            await MainActor.run { [weak self] in
                guard let self, self.generation == expectedGeneration,
                      self.activeCacheKey == key, let cached else { return }
                // Playback and health updates can arrive during disk IO.
                // Merge the loaded cache without replacing those newer values.
                self.probes = cached.merging(self.probes) { cached, current in
                    Self.fillingMissingMetadata(in: current, from: cached)
                }
                self.version &+= 1
                self.persist(for: key)
            }
        }
    }

    /// Returns the most recent probe for a channel, if any.
    func probe(for channelID: String) -> StreamProbe? {
        probes[channelID]
    }

    func probe(for channel: Channel) -> StreamProbe? {
        guard let ownership = channel.sourceOwnership else { return probe(for: channel.id) }
        if ownership.channelIdentity.sourceID == activeSourceID {
            return probes[ownership.channelIdentity.nativeID]
        }
        return sourceProbes[ownership.channelIdentity.sourceID]?[ownership.channelIdentity.nativeID]
    }

    /// Smart catalogues retain physical source caches independently of the
    /// playlist currently shown. Passive observations never enter another
    /// provider's cache merely because its native stream ID happens to match.
    func registerSourceCacheKey(sourceID: UUID, cacheKey: String) {
        sourceCacheKeys[sourceID] = cacheKey
        guard sourceID != activeSourceID, sourceProbes[sourceID] == nil else { return }
        pendingSourceCacheLoads.insert(sourceID)
        let loadCache = self.loadCache
        Task.detached(priority: .utility) { [weak self] in
            let cached = loadCache(cacheKey, []) ?? [:]
            await MainActor.run { [weak self] in
                guard let self, self.sourceCacheKeys[sourceID] == cacheKey else { return }
                self.pendingSourceCacheLoads.remove(sourceID)
                self.sourceProbes[sourceID] = cached.merging(self.sourceProbes[sourceID] ?? [:]) {
                    Self.fillingMissingMetadata(in: $1, from: $0)
                }
                self.persist(snapshot: self.sourceProbes[sourceID] ?? [:], for: cacheKey)
                self.version &+= 1
            }
        }
    }

    /// Request a probe for the given channel. Cheap to call repeatedly: skips
    /// when we already have a result inside the freshness window (good or bad
    /// — a recent failure shouldn't trigger another open against a flaky
    /// provider just because the user scrolled past). No-ops when disabled.
    func requestProbe(for channel: Channel, priority: TaskPriority = .utility) {
        guard isEnabled() else {
            if !pending.isEmpty { invalidateQueuedWork() }
            return
        }
        // Smart rows can belong to any configured source; their results go to
        // that source's own cache once it has been registered and loaded.
        var scopeKey = activeCacheKey
        var scopeSourceID: UUID?
        if let sourceID = channel.sourceOwnership?.channelIdentity.sourceID, sourceID != activeSourceID {
            guard let key = sourceCacheKeys[sourceID], sourceProbes[sourceID] != nil else { return }
            scopeKey = key
            scopeSourceID = sourceID
        }
        guard let key = scopeKey else { return }
        let id = channel.sourceOwnership?.channelIdentity.nativeID ?? channel.id
        let request = PendingProbe(id: id, url: channel.streamURL, priority: priority,
                                   generation: generation, cacheKey: key, ownership: channel.sourceOwnership,
                                   sourceID: scopeSourceID)
        guard !pendingIDs.contains(request.scopedID),
              activeProbes[request.scopedID]?.generation != generation else { return }
        if let existing = storedProbe(for: request), existing.isFresh, existing.isComplete,
           channel.sourceOwnership == nil || existing.endpointFingerprint == StreamProbe.endpointFingerprint(for: channel.streamURL) { return }
        pendingIDs.insert(request.scopedID)
        pending.append(request)
        drainQueue()
    }

    /// Update the cached probe with fresh data observed during actual playback
    /// (mpv has already opened the stream — its numbers are authoritative and
    /// arrive without spending an extra session slot on probing). Caller
    /// passes whatever subset of fields it has; we merge into the existing
    /// record so half-loaded mpv state doesn't overwrite a complete probe.
    func recordPlaybackInfo(
        channelID: String,
        width: Int,
        height: Int,
        fps: Double,
        videoCodec: String,
        audioCodec: String,
        audioChannels: Int,
        liveLatencySeconds: Double?
    ) {
        guard let probe = Self.updatedPlaybackProbe(existing: probes[channelID], width: width, height: height,
            fps: fps, videoCodec: videoCodec, audioCodec: audioCodec, audioChannels: audioChannels,
            liveLatencySeconds: liveLatencySeconds) else { return }
        probes[channelID] = probe
        channelRevisions[channelID, default: 0] &+= 1
        version &+= 1
        if let key = activeCacheKey { persist(for: key) }
    }

    func recordPlaybackInfo(channel: Channel, width: Int, height: Int, fps: Double,
                            videoCodec: String, audioCodec: String, audioChannels: Int,
                            liveLatencySeconds: Double?) {
        guard let identity = channel.sourceOwnership?.channelIdentity else {
            recordPlaybackInfo(channelID: channel.id, width: width, height: height, fps: fps,
                videoCodec: videoCodec, audioCodec: audioCodec, audioChannels: audioChannels,
                liveLatencySeconds: liveLatencySeconds)
            return
        }
        if identity.sourceID == activeSourceID {
            guard var probe = Self.updatedPlaybackProbe(existing: Self.currentEndpointRecord(probes[identity.nativeID], channel: channel), width: width, height: height,
                fps: fps, videoCodec: videoCodec, audioCodec: audioCodec, audioChannels: audioChannels,
                liveLatencySeconds: liveLatencySeconds) else { return }
            probe.endpointFingerprint = StreamProbe.endpointFingerprint(for: channel.streamURL)
            probes[identity.nativeID] = probe
            channelRevisions[identity.nativeID, default: 0] &+= 1
            version &+= 1
            sourceProbes[identity.sourceID] = probes
            if let key = activeCacheKey { persist(for: key) }
            return
        }
        guard var probe = Self.updatedPlaybackProbe(existing: Self.currentEndpointRecord(sourceProbes[identity.sourceID]?[identity.nativeID], channel: channel),
            width: width, height: height, fps: fps, videoCodec: videoCodec, audioCodec: audioCodec,
            audioChannels: audioChannels, liveLatencySeconds: liveLatencySeconds) else { return }
        probe.endpointFingerprint = StreamProbe.endpointFingerprint(for: channel.streamURL)
        sourceProbes[identity.sourceID, default: [:]][identity.nativeID] = probe
        version &+= 1
        if let key = sourceCacheKeys[identity.sourceID], !pendingSourceCacheLoads.contains(identity.sourceID) {
            persist(snapshot: sourceProbes[identity.sourceID] ?? [:], for: key)
        }
    }

    /// Video bitrate measured by the player during ordinary live playback.
    /// Container probes rarely report one for live HLS, so this is usually the
    /// only bitrate evidence ranking gets. Smoothed so one burst does not
    /// reorder near-identical feeds; bound to the endpoint that played.
    func recordPlaybackBitrate(channel: Channel, bitsPerSecond: Int64) {
        guard bitsPerSecond > 0 else { return }
        let fingerprint = StreamProbe.endpointFingerprint(for: channel.streamURL)
        func smoothed(_ existing: StreamProbe) -> StreamProbe? {
            guard channel.sourceOwnership == nil || existing.endpointFingerprint == fingerprint else { return nil }
            var probe = existing
            probe.bitRate = existing.bitRate > 0 ? (existing.bitRate * 3 + bitsPerSecond) / 4 : bitsPerSecond
            return probe
        }
        guard let identity = channel.sourceOwnership?.channelIdentity, identity.sourceID != activeSourceID else {
            let id = channel.sourceOwnership?.channelIdentity.nativeID ?? channel.id
            guard let existing = probes[id], let probe = smoothed(existing) else { return }
            probes[id] = probe
            if let sourceID = activeSourceID { sourceProbes[sourceID] = probes }
            version &+= 1
            if let key = activeCacheKey { persist(for: key) }
            return
        }
        guard let existing = sourceProbes[identity.sourceID]?[identity.nativeID], let probe = smoothed(existing) else { return }
        sourceProbes[identity.sourceID, default: [:]][identity.nativeID] = probe
        version &+= 1
        if let key = sourceCacheKeys[identity.sourceID], !pendingSourceCacheLoads.contains(identity.sourceID) {
            persist(snapshot: sourceProbes[identity.sourceID] ?? [:], for: key)
        }
    }

    private static func updatedPlaybackProbe(existing: StreamProbe?, width: Int, height: Int, fps: Double,
        videoCodec: String, audioCodec: String, audioChannels: Int, liveLatencySeconds: Double?) -> StreamProbe? {
        let hasVideo = width > 0 && height > 0
        let hasAudio = !audioCodec.isEmpty || audioChannels > 0
        if !hasVideo && !hasAudio { return nil }

        var probe = existing ?? StreamProbe(
            status: .ok,
            probedAt: Date(),
            probeSeconds: 0,
            width: 0, height: 0, fps: 0,
            videoCodec: "", audioCodec: "",
            audioChannels: 0, sampleRate: 0,
            bitRate: 0, hasVideo: false, hasAudio: false,
            errorMessage: nil
        )

        probe.status = .ok
        probe.probedAt = Date()
        // A partial audio callback must not make old cached video fields look
        // freshly measured. Rank video format only after a complete sample.
        if (hasVideo && fps > 0 && !videoCodec.isEmpty) ||
           (!hasVideo && !probe.hasVideo && !audioCodec.isEmpty) {
            probe.metadataObservedAt = probe.probedAt
            probe.metadataProvenance = .passivePlayback
        }
        probe.errorMessage = nil
        if hasVideo {
            probe.width = width
            probe.height = height
            probe.hasVideo = true
        }
        if fps > 0 { probe.fps = fps }
        if !videoCodec.isEmpty { probe.videoCodec = videoCodec }
        if !audioCodec.isEmpty { probe.audioCodec = audioCodec; probe.hasAudio = true }
        if audioChannels > 0 { probe.audioChannels = audioChannels; probe.hasAudio = true }
        if let latency = liveLatencySeconds, latency.isFinite {
            probe.liveLatencySeconds = max(0, latency)
        }

        return probe
    }

    private static func currentEndpointRecord(_ probe: StreamProbe?, channel: Channel) -> StreamProbe? {
        guard let probe, probe.endpointFingerprint == StreamProbe.endpointFingerprint(for: channel.streamURL) else { return nil }
        return probe
    }

    func recordPlaybackHealth(channel: Channel, health: StreamHealth,
                              healthySeconds: Double, bufferingSeconds: Double, at date: Date = Date(),
                              ordinaryLive: Bool = false) {
        guard ordinaryLive, !channel.isOnDemand,
              healthySeconds.isFinite, bufferingSeconds.isFinite, date.timeIntervalSince1970.isFinite,
              healthySeconds >= 0, bufferingSeconds >= 0 else { return }
        let identity = channel.sourceOwnership?.channelIdentity
        let isActive = identity == nil || identity?.sourceID == activeSourceID
        let nativeID = identity?.nativeID ?? channel.id
        let existing = isActive ? probes[nativeID] : sourceProbes[identity!.sourceID]?[nativeID]
        var probe = Self.currentEndpointRecord(existing, channel: channel) ?? StreamProbe(
            status: .ok, probedAt: date, probeSeconds: 0, width: 0, height: 0, fps: 0,
            videoCodec: "", audioCodec: "", audioChannels: 0, sampleRate: 0, bitRate: 0,
            hasVideo: false, hasAudio: false, errorMessage: nil)
        probe.streamHealth = health
        probe.endpointFingerprint = StreamProbe.endpointFingerprint(for: channel.streamURL)
        if healthySeconds > 0 {
            probe.status = .ok
            probe.probedAt = date
        }
        var evidence = probe.passivePlaybackEvidence
        if evidence?.ordinaryLive != true || date.timeIntervalSince(evidence!.windowStartedAt) > 15 * 60 ||
            date.timeIntervalSince(evidence!.lastObservedAt) > 60 {
            evidence = .init(windowStartedAt: date, lastObservedAt: date, healthySeconds: 0, bufferingSeconds: 0,
                             ordinaryLive: true)
        }
        evidence!.lastObservedAt = date
        evidence!.healthySeconds += min(healthySeconds, 30)
        evidence!.bufferingSeconds += min(bufferingSeconds, 30)
        probe.passivePlaybackEvidence = evidence
        if isActive {
            probes[nativeID] = probe
            channelRevisions[nativeID, default: 0] &+= 1
            if let key = activeCacheKey { persist(for: key) }
        } else if let identity {
            sourceProbes[identity.sourceID, default: [:]][nativeID] = probe
            if let key = sourceCacheKeys[identity.sourceID], !pendingSourceCacheLoads.contains(identity.sourceID) {
                persist(snapshot: sourceProbes[identity.sourceID] ?? [:], for: key)
            }
        }
        version &+= 1
    }

    /// Record stream health observed during live playback. Unlike static
    /// probing, this annotates the active channel without opening a second
    /// provider connection.
    func recordStreamHealthEvent(
        channelID: String,
        event: StreamHealthEvent,
        at date: Date = Date()
    ) {
        var probe = probes[channelID] ?? StreamProbe(
            status: .ok,
            probedAt: date,
            probeSeconds: 0,
            width: 0, height: 0, fps: 0,
            videoCodec: "", audioCodec: "",
            audioChannels: 0, sampleRate: 0,
            bitRate: 0, hasVideo: false, hasAudio: false,
            errorMessage: nil
        )

        probe.streamHealth.record(event, at: date)
        probe.probedAt = date
        probes[channelID] = probe
        channelRevisions[channelID, default: 0] &+= 1
        version &+= 1
        if let key = activeCacheKey {
            persist(for: key)
        }
    }

    /// Convenience for batch warming (e.g. all visible favorites). Same dedupe
    /// rules as the single-channel call.
    /// Re-evaluates queued probes, e.g. after account capacity was refreshed.
    func retryQueuedProbes() { drainQueue() }

    func requestProbes(for channels: some Sequence<Channel>) {
        for channel in channels {
            requestProbe(for: channel, priority: .utility)
        }
    }

    /// Forget the result for one channel — used when the user manually asks
    /// for a re-probe (Cmd-click "Refresh" in the UI later).
    func invalidate(channelID: String) {
        pending.removeAll { $0.id == channelID && $0.sourceID == nil }
        pendingIDs.remove("|" + channelID)
        channelRevisions[channelID, default: 0] &+= 1
        probes.removeValue(forKey: channelID)
        version &+= 1
    }

    /// Forget every result and persist the empty cache.
    func clearAll() {
        invalidateQueuedWork()
        probes.removeAll()
        channelRevisions.removeAll()
        version &+= 1
        if let key = activeCacheKey { persist(for: key) }
    }

    private func invalidateQueuedWork() {
        generation &+= 1
        pending.removeAll()
        pendingIDs.removeAll()
        retryTask?.cancel()
        retryTask = nil
    }

    private func drainQueue() {
        guard isEnabled() else {
            if !pending.isEmpty { invalidateQueuedWork() }
            return
        }
        guard suspensionLeases.isEmpty, !pending.isEmpty,
              activeProbes.count < Self.maximumConcurrentProbes else { return }
        // Probes are optional. Never consume a provider connection while an
        // open player session may be loading, playing, paused, or reconnecting.
        guard !hasPlaybackSessions() else {
            scheduleQueueRetry()
            return
        }
        // Accounts at capacity wait; other accounts' probes still start.
        var waiting: [PendingProbe] = []
        while !pending.isEmpty, activeProbes.count < Self.maximumConcurrentProbes {
            var next = pending.removeFirst()
            pendingIDs.remove(next.scopedID)
            guard next.generation == generation, isCurrentScope(next) else { continue }
            if let existing = storedProbe(for: next), existing.isFresh, existing.isComplete,
               next.ownership == nil || existing.endpointFingerprint == StreamProbe.endpointFingerprint(for: next.url) { continue }
            // Without an account the ledger cannot bound connections, so an
            // unowned probe runs alone and nothing else starts beside it.
            let unownedActive = activeProbes.values.contains { $0.ownership == nil }
            if unownedActive || (next.ownership == nil && !activeProbes.isEmpty) {
                waiting.append(next)
                continue
            }
            if next.sourceID == nil { next.channelRevision = channelRevisions[next.id, default: 0] }
            let capacityLease: AccountCapacityLedger.Lease?
            if let ownership = next.ownership {
                switch AccountCapacityLedger.shared.reserve(accountKey: ownership.accountKey, kind: .probe, ownerID: UUID()) {
                case .success(let lease): capacityLease = lease
                case .failure:
                    waiting.append(next)
                    continue
                }
            } else { capacityLease = nil }
            activeProbes[next.scopedID] = next
            probeRunningCount = activeProbes.count
            launch(next, capacityLease: capacityLease)
        }
        if !waiting.isEmpty {
            pending.insert(contentsOf: waiting, at: 0)
            for request in waiting { pendingIDs.insert(request.scopedID) }
            scheduleQueueRetry()
        }
    }

    private func scheduleQueueRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self, retryDelay] in
            try? await Task.sleep(for: retryDelay)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.drainQueue()
        }
    }

    private func launch(_ request: PendingProbe, capacityLease: AccountCapacityLedger.Lease?) {
        let runProbe = self.runProbe
        Task.detached(priority: request.priority) { [weak self] in
            // Recheck after leaving the main executor, immediately before the
            // blocking boundary; a player can have registered in the meantime.
            let mayStart = await MainActor.run { [weak self] in
                guard let self else { return false }
                return self.generation == request.generation && self.isEnabled()
                    && self.isCurrentScope(request) && self.suspensionLeases.isEmpty
                    && !self.hasPlaybackSessions()
            }
            let probeStarted = ContinuousClock.now
            let result = mayStart ? runProbe(request.url.absoluteString) : nil
            if let result {
                PerfMetrics.shared.record("probe.durationMs", since: probeStarted)
                PerfMetrics.shared.increment(result.status == .ok ? "probe.ok" : "probe.failed")
            }
            // The C boundary returns only after avformat has closed its IO.
            // Release here even if the service owner disappeared meanwhile.
            if let capacityLease { _ = AccountCapacityLedger.shared.confirmTeardown(lease: capacityLease) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activeProbes[request.scopedID] = nil
                self.probeRunningCount = self.activeProbes.count
                guard self.generation == request.generation, self.isEnabled(),
                      self.isCurrentScope(request) else {
                    self.drainQueue()
                    return
                }
                if let result, let sourceID = request.sourceID {
                    // Another Smart source: keep its playback evidence and
                    // write only to that source's own cache.
                    var merged = result
                    merged.endpointFingerprint = StreamProbe.endpointFingerprint(for: request.url)
                    merged.metadataProvenance = .streamProbe
                    merged.metadataObservedAt = result.probedAt
                    if let existing = self.sourceProbes[sourceID]?[request.id],
                       existing.endpointFingerprint == merged.endpointFingerprint {
                        merged.streamHealth = existing.streamHealth
                        merged.passivePlaybackEvidence = existing.passivePlaybackEvidence
                    }
                    self.sourceProbes[sourceID, default: [:]][request.id] = merged
                    self.version &+= 1
                    self.persist(snapshot: self.sourceProbes[sourceID] ?? [:], for: request.cacheKey)
                    PerfMetrics.shared.increment("probe.completed.otherSource")
                } else if let result {
                    if self.channelRevisions[request.id, default: 0] != request.channelRevision,
                       self.probes[request.id] == nil {
                        self.drainQueue()
                        return
                    }
                    var merged = result
                    merged.endpointFingerprint = StreamProbe.endpointFingerprint(for: request.url)
                    merged.metadataProvenance = .streamProbe
                    merged.metadataObservedAt = result.probedAt
                    if let existing = self.probes[request.id] {
                        if self.channelRevisions[request.id, default: 0] != request.channelRevision {
                            // A current playback observation may already own
                            // a new endpoint revision under the same native ID.
                            guard request.ownership == nil || existing.endpointFingerprint == merged.endpointFingerprint else {
                                self.drainQueue()
                                return
                            }
                            merged = Self.fillingMissingMetadata(in: existing, from: merged)
                        } else {
                            merged.streamHealth = existing.streamHealth
                            merged.passivePlaybackEvidence = existing.passivePlaybackEvidence
                        }
                    }
                    self.probes[request.id] = merged
                    self.version &+= 1
                    self.persist(for: request.cacheKey)
                } else {
                    // The playback gate closed between dequeue and launch.
                    // Keep the request pending until the player windows close.
                    self.pending.insert(request, at: 0)
                    self.pendingIDs.insert(request.scopedID)
                }
                self.drainQueue()
            }
        }
    }

    private static func fillingMissingMetadata(in current: StreamProbe, from cached: StreamProbe) -> StreamProbe {
        if let fingerprint = current.endpointFingerprint, fingerprint != cached.endpointFingerprint {
            return current
        }
        var merged = current
        if merged.width <= 0 { merged.width = cached.width }
        if merged.height <= 0 { merged.height = cached.height }
        if merged.fps <= 0 { merged.fps = cached.fps }
        if merged.videoCodec.isEmpty { merged.videoCodec = cached.videoCodec }
        if merged.audioCodec.isEmpty { merged.audioCodec = cached.audioCodec }
        if merged.audioChannels <= 0 { merged.audioChannels = cached.audioChannels }
        if merged.sampleRate <= 0 { merged.sampleRate = cached.sampleRate }
        if merged.bitRate <= 0 { merged.bitRate = cached.bitRate }
        if merged.liveLatencySeconds == nil { merged.liveLatencySeconds = cached.liveLatencySeconds }
        if merged.metadataProvenance == nil { merged.metadataProvenance = cached.metadataProvenance }
        if merged.metadataObservedAt == nil { merged.metadataObservedAt = cached.metadataObservedAt }
        if merged.passivePlaybackEvidence == nil { merged.passivePlaybackEvidence = cached.passivePlaybackEvidence }
        merged.hasVideo = merged.hasVideo || (merged.width > 0 && merged.height > 0)
        merged.hasAudio = merged.hasAudio || !merged.audioCodec.isEmpty || merged.audioChannels > 0
        return merged
    }

    /// Runs on a background detached Task. Calls into the C bridge.
    nonisolated private static func runBlockingProbe(urlString: String) -> StreamProbe {
        let cResult = urlString.withCString { ptr in
            // 30s budget — slow IPTV origins can take 10-15s just to start
            // returning bytes after TLS, and avformat_find_stream_info needs
            // a couple of seconds on top to settle on codec params.
            buffer_probe_stream(ptr, 30)
        }
        return StreamProbe(cResult: cResult)
    }

    /// Keep the newest snapshot for every dirty source, then serialize IO.
    /// Source switches cannot redirect a save or lose the previous source's
    /// write, and updates during an in-progress write schedule another pass.
    @ObservationIgnored private var dirtySnapshots: [String: [String: StreamProbe]] = [:]
    @ObservationIgnored private var writingSnapshots: [String: [String: StreamProbe]] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private func persist(for key: String) {
        persist(snapshot: probes, for: key)
    }

    private func persist(snapshot: [String: StreamProbe], for key: String) {
        dirtySnapshots[key] = snapshot
        guard saveTask == nil else { return }
        saveTask = Task { [weak self, saveDelay, saveCache] in
            while let self {
                try? await Task.sleep(for: saveDelay)
                let snapshots = self.dirtySnapshots
                self.dirtySnapshots.removeAll()
                self.writingSnapshots = snapshots
                await Task.detached(priority: .utility) {
                    for (key, snapshot) in snapshots { saveCache(snapshot, key) }
                }.value
                self.writingSnapshots.removeAll()
                if self.dirtySnapshots.isEmpty {
                    self.saveTask = nil
                    return
                }
            }
        }
    }
}
