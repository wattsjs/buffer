import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class SmartSportsCoordinator {
    static let playlistID = "smart:sports:v1"
    private(set) var catalog: SmartSportsCatalog?
    private(set) var displayedChannels: [Channel] = []
    private(set) var displayedPrograms: [String: [EPGProgram]] = [:]
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var sourceIssues: [UUID: String] = [:]
    private(set) var revision: UInt64 = 0
    /// Channel counts per detected region/category across all sources, for
    /// the filter UI. Empty until the first automatic discovery.
    private(set) var regionInventory: [SmartRegionSummary] = []
    private(set) var filter = SmartChannelFilter.load()
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored var probeLookup: (@MainActor (Channel) -> StreamProbe?)?
    /// Changes whenever any probe or playback measurement is recorded.
    @ObservationIgnored var probeVersion: (@MainActor () -> Int)?
    @ObservationIgnored private var observedProbeVersion: Int?

    @ObservationIgnored private let store: SmartSportsCatalogStore
    @ObservationIgnored private let ledger: AccountCapacityLedger
    @ObservationIgnored private let snapshotLoader: @Sendable (SmartSportsSnapshotRequest) async -> SmartSportsSnapshotLoadResult
    /// Curated feeds plus, when enabled, feeds grouped automatically across
    /// every configured source on the latest refresh.
    @ObservationIgnored private var definition: SmartSportsDefinition?
    @ObservationIgnored private var curatedDefinition: SmartSportsDefinition?
    @ObservationIgnored private let autoDiscovery: (@Sendable (SmartAutoDiscoveryRequest) async -> SmartAutoDiscoveryResult)?
    static let autoAggregationKey = "smartAutoAggregation"
    /// Grouping depends only on channel lists, never on guide data, so a
    /// guide-only refresh reuses the previous discovery.
    @ObservationIgnored private var autoDiscoveryCache: (signature: Int, result: SmartAutoDiscoveryResult)?

    /// Source caches may have changed while Smart was inactive.
    func invalidateAutoDiscovery() { autoDiscoveryCache = nil }

    /// Saves the filter; the caller refreshes so feeds regroup under it.
    func setFilter(_ next: SmartChannelFilter) {
        guard next != filter else { return }
        filter = next
        next.save()
        autoDiscoveryCache = nil
    }

    private static func discoverySignature(configurations: [ServerConfig], activeConfig: ServerConfig?,
                                           activeChannels: [Channel]) -> Int {
        var hasher = Hasher()
        for config in configurations {
            hasher.combine(config.id)
            hasher.combine(config.password.isEmpty ? "" : DataCache.cacheKey(for: config))
        }
        hasher.combine(activeConfig.map { DataCache.cacheKey(for: $0) })
        hasher.combine(activeChannels.count)
        for channel in activeChannels {
            hasher.combine(channel.id)
            hasher.combine(channel.name)
            hasher.combine(channel.group)
            hasher.combine(channel.streamURL)
        }
        return hasher.finalize()
    }
    @ObservationIgnored private var state = SmartSportsCatalogStore.State()
    @ObservationIgnored private var loadedSources: [UUID: SmartSportsLoadedSource] = [:]
    @ObservationIgnored private var refreshEpoch: UInt64 = 0
    @ObservationIgnored private var stateLoaded = false

    private struct SportsMatchingCache {
        var activeSourceID: UUID?
        var activeInputRevision: String?
        var activeCatalogVersion: Int
        var loadedChannels: [UUID: [Channel]]
        var blockedKeys: Set<String>
        var channels: [Channel]
        var guideKeys: [(sourceID: UUID, rawID: String, scopedID: String)]
    }
    @ObservationIgnored private var sportsMatchingCache: SportsMatchingCache?
    /// Internal diagnostic counter also verifies that guide-only publications
    /// reuse physical rows rather than redoing account digests on the main actor.
    private(set) var sportsMatchingCatalogBuildCount = 0

    init(definition: SmartSportsDefinition? = nil,
         store: SmartSportsCatalogStore = .shared,
         ledger: AccountCapacityLedger = .shared,
         snapshotLoader: @escaping @Sendable (SmartSportsSnapshotRequest) async -> SmartSportsSnapshotLoadResult = { request in
             await SmartSportsSnapshotLoader.load(request)
         },
         autoDiscovery: (@Sendable (SmartAutoDiscoveryRequest) async -> SmartAutoDiscoveryResult)? = nil) {
        self.definition = definition
        self.curatedDefinition = definition
        // Only the production catalog discovers; injected test definitions
        // never read real source caches unless a discovery is supplied.
        if let autoDiscovery {
            self.autoDiscovery = autoDiscovery
        } else if definition == nil {
            self.autoDiscovery = { request in await SmartSportsSnapshotLoader.discoverAutoFeeds(request) }
        } else {
            self.autoDiscovery = nil
        }
        self.store = store
        self.ledger = ledger
        self.snapshotLoader = snapshotLoader
    }

    func refresh(configurations: [ServerConfig], activeConfig: ServerConfig? = nil,
                 activeChannels: [Channel] = [], activePrograms: [String: [EPGProgram]] = [:]) async {
        refreshEpoch &+= 1
        let epoch = refreshEpoch
        isLoading = true
        errorMessage = nil
        var configurations = configurations
        do {
            if curatedDefinition == nil {
                curatedDefinition = try await Task.detached(priority: .utility) { try SmartSportsCatalog.loadBundled() }.value
            }
            guard epoch == refreshEpoch, !Task.isCancelled, let curated = curatedDefinition else { return }
            if let autoDiscovery, UserDefaults.standard.object(forKey: Self.autoAggregationKey) as? Bool ?? true {
                let curatedKeys = Set(curated.feeds.flatMap { $0.variants.map(\.key) } + curated.heldEndpoints.map(\.key))
                var signatureHasher = Hasher()
                signatureHasher.combine(Self.discoverySignature(configurations: configurations,
                    activeConfig: activeConfig, activeChannels: activeChannels))
                signatureHasher.combine((try? JSONEncoder().encode(filter)) ?? Data())
                let signature = signatureHasher.finalize()
                let discovered: SmartAutoDiscoveryResult
                if let cached = autoDiscoveryCache, cached.signature == signature {
                    discovered = cached.result
                    PerfMetrics.shared.increment("smart.autoDiscovery.reused")
                } else {
                    discovered = await autoDiscovery(.init(configurations: configurations, activeConfig: activeConfig,
                        activeChannels: activeChannels, curatedKeys: curatedKeys, filter: filter))
                    guard epoch == refreshEpoch, !Task.isCancelled else { return }
                    autoDiscoveryCache = (signature, discovered)
                }
                configurations = discovered.resolvedConfigurations
                if !discovered.inventory.isEmpty { regionInventory = discovered.inventory }
                definition = SmartSportsDefinition(schemaVersion: curated.schemaVersion, playlistID: curated.playlistID,
                    name: curated.name, provenance: curated.provenance,
                    feeds: curated.feeds + discovered.feeds, heldEndpoints: curated.heldEndpoints)
            } else {
                definition = curated
            }
            guard let definition else { return }
            if !stateLoaded {
                let loaded = try await store.load()
                guard epoch == refreshEpoch, !Task.isCancelled else { return }
                state = loaded
                stateLoaded = true
            }
            let configuredIDs = Set(configurations.map(\.id))
            let priorSources = loadedSources
            let configurationsByID = Dictionary(configurations.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            let previousSourceCount = loadedSources.count
            loadedSources = loadedSources.filter { sourceID, loaded in
                guard let metadata = configurationsByID[sourceID] else { return false }
                let current = activeConfig?.id == sourceID ? activeConfig! : metadata
                // Credential or guide edits obsolete authenticated endpoints
                // immediately, even while their replacement Keychain read waits.
                return DataCache.cacheKey(for: current) == DataCache.cacheKey(for: loaded.config)
            }
            sourceIssues = [:]
            if loadedSources.count != previousSourceCount { rebuild() }
            let allowed = Set(definition.feeds.flatMap { $0.variants.map(\.key) }
                + definition.heldEndpoints.map(\.key)
                + state.overrides.links.keys.compactMap { SmartSportsCatalog.key(from: $0) })
            if let activeConfig, configuredIDs.contains(activeConfig.id), !activeChannels.isEmpty {
                // Publish active source immediately, before another source's
                // Keychain read or large guide cache can delay the first rows.
                let active = await Task.detached(priority: .utility) {
                    SmartSportsSnapshotLoader.activeSource(config: activeConfig, channels: activeChannels,
                        programs: activePrograms, allowedKeys: allowed)
                }.value
                guard epoch == refreshEpoch, !Task.isCancelled else { return }
                loadedSources[activeConfig.id] = active
                rebuild()
            }
            let result = await snapshotLoader(.init(configurations: configurations,
                definition: definition, overrides: state.overrides, activeConfig: activeConfig,
                activeChannels: activeChannels, activePrograms: activePrograms))
            guard epoch == refreshEpoch, !Task.isCancelled else { return }
            let warmSources = priorSources.merging(loadedSources, uniquingKeysWith: { _, active in active })
            let worker = Task.detached(priority: .utility) {
                var next = Dictionary(result.sources.filter { configuredIDs.contains($0.config.id) }
                    .map { ($0.config.id, $0) }, uniquingKeysWith: { _, latest in latest })
                var usedWarm = false
                for (sourceID, previous) in warmSources {
                    guard !Task.isCancelled, configuredIDs.contains(sourceID) else { continue }
                    let resolved = result.resolvedConfigurations[sourceID] ?? next[sourceID]?.config
                    guard let resolved,
                          DataCache.cacheKey(for: resolved) == DataCache.cacheKey(for: previous.config) else { continue }
                    if let current = next[sourceID] {
                        guard !current.guideReadSucceeded else { continue }
                        let retained = SmartSportsSnapshotLoader.retainingWarmGuide(previous, for: current)
                        next[sourceID] = retained
                        usedWarm = usedWarm || !retained.programs.isEmpty
                    } else if result.issues[sourceID] != nil {
                        // Only a successfully resolved matching revision can
                        // retain an entire source after a local read failure.
                        let current = SmartSportsLoadedSource(config: resolved,
                            snapshot: .init(sourceID: sourceID, sourceName: resolved.name, channels: previous.snapshot.channels),
                            programs: [:], savedAt: previous.savedAt, guideReadSucceeded: false)
                        next[sourceID] = SmartSportsSnapshotLoader.retainingWarmGuide(previous, for: current)
                        usedWarm = true
                    }
                }
                return (next, usedWarm)
            }
            let (next, usedWarm) = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard epoch == refreshEpoch, !Task.isCancelled else { return }
            loadedSources = next
            sourceIssues = result.issues
            if !result.issues.isEmpty {
                errorMessage = usedWarm ? "Some source caches could not refresh. Showing their last available listings."
                    : "Some sources are unavailable. Refresh their original playlists to load current data."
            }
            rebuild()
            isLoading = false
        } catch {
            guard epoch == refreshEpoch, !Task.isCancelled else { return }
            errorMessage = "Smart Sports could not load its local catalog or saved reviews."
            isLoading = false
        }
    }

    func cancelRefresh() {
        refreshEpoch &+= 1
        isLoading = false
    }

    func config(for sourceID: UUID) -> ServerConfig? { loadedSources[sourceID]?.config }

    func sourcePrograms(for sourceID: UUID) -> [String: [EPGProgram]] {
        loadedSources[sourceID]?.programs ?? [:]
    }

    func programs(for physicalChannel: Channel) -> [EPGProgram] {
        guard let identity = physicalChannel.sourceChannelIdentity,
              let guideID = physicalChannel.epgChannelID else { return [] }
        return loadedSources[identity.sourceID]?.programs[guideID] ?? []
    }

    /// Event alternatives are physical source rows, including dedicated UHD
    /// editions held out of permanent merging. Matching namespaces only the
    /// guide dictionary; actions retain the original native ID and guide.
    func sportsMatchingSnapshot(activeConfig: ServerConfig? = nil,
                                activeChannels: [Channel] = [],
                                activePrograms: [String: [EPGProgram]] = [:],
                                activeCatalogVersion: Int? = nil)
        -> (channels: [Channel], programs: [String: [EPGProgram]]) {
        let hasActiveCatalog = activeConfig != nil && !activeChannels.isEmpty
        let activeSourceID = hasActiveCatalog ? activeConfig?.id : nil
        // One revision digest per publication; never one account digest per row.
        let activeInputRevision = hasActiveCatalog ? activeConfig.map { DataCache.cacheKey(for: $0) } : nil
        var blocked = state.overrides.rejectedEndpointKeys
        for item in catalog?.reviewItems ?? [] {
            if [.changedIdentity, .duplicateNativeID, .rejected].contains(item.state) { blocked.insert(item.key.rawValue) }
        }
        let loadedChannels = loadedSources.mapValues { $0.snapshot.channels }
        let cacheIsCurrent = sportsMatchingCache.map { cached in
            activeCatalogVersion != nil && cached.activeCatalogVersion == activeCatalogVersion
                && cached.activeSourceID == activeSourceID && cached.activeInputRevision == activeInputRevision
                && cached.blockedKeys == blocked && Self.samePhysicalCatalogs(cached.loadedChannels, loadedChannels)
        } ?? false
        if !cacheIsCurrent {
            var sources = loadedChannels
            if let activeConfig, hasActiveCatalog {
                let accountKey = SourceAccountKey(config: activeConfig)
                sources[activeConfig.id] = activeChannels.map {
                    SmartSportsSnapshotLoader.stamp($0, config: activeConfig, accountKey: accountKey)
                }
            }
            var channels: [Channel] = []
            var guideKeys: [(sourceID: UUID, rawID: String, scopedID: String)] = []
            var seenGuides = Set<String>()
            for sourceID in sources.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let sourceChannels = sources[sourceID] else { continue }
                let prefix = sourceID.uuidString.lowercased() + "|"
                var seenNativeIDs = Set<String>()
                for channel in sourceChannels where channel.contentType == .live {
                    guard let identity = channel.sourceChannelIdentity,
                          !blocked.contains(identity.rawValue),
                          seenNativeIDs.insert(identity.nativeID).inserted else { continue }
                    channels.append(channel)
                    if let rawID = channel.epgChannelID {
                        let key = prefix + rawID
                        if seenGuides.insert(key).inserted { guideKeys.append((sourceID, rawID, key)) }
                    }
                }
            }
            sportsMatchingCache = .init(activeSourceID: activeSourceID, activeInputRevision: activeInputRevision,
                activeCatalogVersion: activeCatalogVersion ?? -1, loadedChannels: loadedChannels,
                blockedKeys: blocked, channels: channels, guideKeys: guideKeys)
            sportsMatchingCatalogBuildCount &+= 1
        }
        guard let cached = sportsMatchingCache else { return ([], [:]) }
        var programs: [String: [EPGProgram]] = [:]
        programs.reserveCapacity(cached.guideKeys.count)
        for key in cached.guideKeys {
            let rows = key.sourceID == activeSourceID ? activePrograms[key.rawID] : loadedSources[key.sourceID]?.programs[key.rawID]
            if let rows { programs[key.scopedID] = rows }
        }
        return (cached.channels, programs)
    }

    private static func samePhysicalCatalogs(_ lhs: [UUID: [Channel]], _ rhs: [UUID: [Channel]]) -> Bool {
        guard lhs.keys.count == rhs.keys.count else { return false }
        for (sourceID, channels) in lhs {
            guard let other = rhs[sourceID], channels.count == other.count else { return false }
            guard zip(channels, other).allSatisfy({ a, b in
                a.id == b.id && a.name == b.name && a.group == b.group && a.logoURL == b.logoURL
                    && a.streamURL == b.streamURL && a.epgChannelID == b.epgChannelID
                    && a.catchup == b.catchup && a.contentType == b.contentType && a.sourceOwnership == b.sourceOwnership
            }) else { return false }
        }
        return true
    }

    func variants(for feedID: String) -> [SmartSportsVariant] { catalog?.variants(for: feedID) ?? [] }

    func preferredVariant(for feedID: String) -> SmartSportsEndpointKey? {
        state.overrides.preferredVariants[feedID].flatMap { SmartSportsCatalog.key(from: $0) }
    }

    func preferredGuide(for feedID: String) -> SmartSportsEndpointKey? {
        state.overrides.preferredGuides[feedID].flatMap { SmartSportsCatalog.key(from: $0) }
    }

    /// Planning for an existing owner may ignore the slot it currently holds;
    /// PlayerSlot still reserves after confirmed teardown. Initial opens use
    /// the default capacity gate, and caller-supplied exclusions always apply.
    func selection(for feedID: String, context: SmartSportsSelectionContext = .init(),
                   ignoreCapacity: Bool = false) -> SmartSportsSelection? {
        var gated = context
        for variant in variants(for: feedID) {
            guard let account = variant.physicalChannel?.sourceOwnership?.accountKey else {
                gated.unavailableEndpoints.insert(variant.key)
                continue
            }
            if !ignoreCapacity, ledger.snapshot(accountKey: account, now: context.now).available == 0 {
                gated.unavailableEndpoints.insert(variant.key)
            }
            if context.mode == .live, currentProbeState(for: variant, now: context.now) == .observedFailures {
                gated.recentFailedEndpoints.insert(variant.key)
            }
        }
        return catalog?.selection(for: feedID, context: gated)
    }

    /// Membership, capacity and observations remain distinct. Unknown or
    /// legacy alternatives prevent one failed selected endpoint from dimming
    /// the entire logical feed, without claiming those alternatives are online.
    func aggregateAvailability(for feedID: String, now: Date = Date()) -> SmartSportsAvailability {
        let current = variants(for: feedID).filter(\.isPlayable)
        let eligible = current.filter { variant in
            guard let account = variant.physicalChannel?.sourceOwnership?.accountKey else { return false }
            return ledger.snapshot(accountKey: account, now: now).available > 0
        }
        let observed = eligible.map { currentProbeState(for: $0, now: now) }
        let availableCount = observed.filter { $0 == .observedAvailable }.count
        let failedCount = observed.filter { $0 == .observedFailures }.count
        let uncertainCount = observed.count - availableCount - failedCount
        let state: SmartSportsAvailability.State
        if current.isEmpty { state = .unavailable }
        else if eligible.isEmpty { state = .busy }
        else if availableCount > 0 { state = .observedAvailable }
        else if uncertainCount > 0 { state = .uncertain }
        else { state = .observedFailures }
        return .init(state: state, variantCount: current.count,
            observedAvailableCount: availableCount, uncertainCount: uncertainCount,
            observedFailureCount: failedCount)
    }

    private func currentProbeState(for variant: SmartSportsVariant, now: Date) -> SmartSportsAvailability.State {
        guard let channel = variant.physicalChannel else { return .uncertain }
        if let probe = probeLookup?(channel),
           probe.endpointFingerprint == SmartSportsCatalog.endpointFingerprint(for: channel),
           let provenance = probe.metadataProvenance {
            let timestamp = probe.status == .ok ? (probe.metadataObservedAt ?? probe.probedAt) : probe.probedAt
            let age = now.timeIntervalSince(timestamp)
            if age.isFinite && age >= 0 && age <= 15 * 60 {
                // A newer passive observation supersedes an older failed probe.
                let newerPlayback = variant.observation.map {
                    $0.provenance == .passivePlayback && $0.observedAt > timestamp
                        && now.timeIntervalSince($0.observedAt) >= 0
                        && $0.isFresh(now: now, maximumAge: 15 * 60) && $0.failures == 0
                        && $0.playedSeconds > 0 && $0.stalledSeconds < 0.5
                } ?? false
                if newerPlayback { return .observedAvailable }
                if probe.status == .ok, probe.hasVideo, probe.width > 0, probe.height > 0,
                   provenance == .streamProbe || provenance == .passivePlayback { return .observedAvailable }
                if probe.status != .ok { return .observedFailures }
            }
        }
        if let observed = variant.observation, observed.provenance == .passivePlayback,
           now.timeIntervalSince(observed.observedAt) >= 0,
           observed.isFresh(now: now, maximumAge: 15 * 60),
           observed.failures == 0, observed.playedSeconds > 0, observed.stalledSeconds < 0.5 {
            return .observedAvailable
        }
        return .uncertain
    }

    /// Playback carries the physical guide, not the guide displayed on a logical
    /// row. An archive caller must pass validated source timing in its context.
    func playbackChannel(for feedID: String, context: SmartSportsSelectionContext = .init()) -> Channel? {
        guard let selected = selection(for: feedID, context: context)?.selected,
              let channel = selected.physicalChannel else { return nil }
        return logicalPlaybackChannel(channel, feedID: feedID)
    }

    func logicalPlaybackChannel(_ physicalChannel: Channel, feedID: String) -> Channel {
        let feed = catalog?.feed(id: feedID)
        guard let ownership = physicalChannel.sourceOwnership else { return physicalChannel }
        return Channel(id: feedID, name: feed?.name ?? physicalChannel.name, logoURL: physicalChannel.logoURL,
            group: feed.map { "\($0.country) | Sports" } ?? physicalChannel.group,
            streamURL: physicalChannel.streamURL, epgChannelID: physicalChannel.epgChannelID,
            catchup: physicalChannel.catchup, contentType: physicalChannel.contentType,
            sourceOwnership: .init(channelIdentity: ownership.channelIdentity, accountKey: ownership.accountKey,
                logicalChannelID: feedID, guideBinding: ownership.guideBinding))
    }

    func setPreferredVariant(_ key: SmartSportsEndpointKey?, for feedID: String) async {
        state.overrides.preferredVariants[feedID] = key?.rawValue
        await persistOverrides()
    }

    func setPreferredGuide(_ key: SmartSportsEndpointKey?, for feedID: String) async {
        state.overrides.preferredGuides[feedID] = key?.rawValue
        await persistOverrides()
    }

    func acceptIdentity(_ key: SmartSportsEndpointKey) async {
        guard let channel = currentChannel(for: key) else { return }
        state.overrides.acceptedIdentities[key.rawValue] = .init(channel: channel)
        state.overrides.rejectedEndpointKeys.remove(key.rawValue)
        await persistOverrides()
    }

    func reject(_ key: SmartSportsEndpointKey) async {
        state.overrides.reject(key)
        await persistOverrides()
    }

    /// Restore this endpoint's frozen proposal. This also removes its explicit
    /// split/link acceptance, so a still-changed identity requires review again.
    func restoreProposal(_ key: SmartSportsEndpointKey) async {
        let previousFeedID = state.overrides.links.removeValue(forKey: key.rawValue)?.feedID
        state.overrides.rejectedEndpointKeys.remove(key.rawValue)
        state.overrides.acceptedIdentities.removeValue(forKey: key.rawValue)
        state.overrides.preferredVariants = state.overrides.preferredVariants.filter { $0.value != key.rawValue }
        state.overrides.preferredGuides = state.overrides.preferredGuides.filter { $0.value != key.rawValue }
        if let previousFeedID, !state.overrides.links.values.contains(where: { $0.feedID == previousFeedID }) {
            state.overrides.customFeeds.removeAll { $0.id == previousFeedID }
        }
        await persistOverrides()
    }

    func link(_ key: SmartSportsEndpointKey, to feedID: String) async {
        guard let channel = currentChannel(for: key) else { return }
        state.overrides.link(key, to: feedID, identity: .init(channel: channel))
        await persistOverrides()
    }

    @discardableResult
    func split(_ key: SmartSportsEndpointKey, name: String, country: String,
               language: String = "en", edition: String = "reviewed") async -> String? {
        guard let channel = currentChannel(for: key) else { return nil }
        let id = state.overrides.split(key, name: name, country: country, language: language,
            edition: edition, identity: .init(channel: channel))
        await persistOverrides()
        return id
    }

    func record(_ observation: SmartSportsObservation, for channel: Channel) async {
        guard let key = channel.sourceChannelIdentity else { return }
        var scoped = observation
        scoped.endpointFingerprint = SmartSportsCatalog.endpointFingerprint(for: channel)
        do {
            try await store.record(scoped, for: key)
            let latest = try await store.load()
            // Do not replace local override edits that may be in flight.
            state.observations = latest.observations
            rebuild()
        } catch { errorMessage = "Playback observation could not be saved." }
    }

    func currentChannel(for key: SmartSportsEndpointKey) -> Channel? {
        loadedSources[key.sourceID]?.snapshot.channels.first { $0.sourceChannelIdentity == key }
    }

    private func persistOverrides() async {
        rebuild()
        let overrides = state.overrides
        do { try await store.save(overrides: overrides) }
        catch { errorMessage = "Your Smart Sports review could not be saved." }
    }

    /// Rebuilds the catalog when playback/probe measurements changed since the
    /// last build, so the next selection uses what was actually observed.
    func refreshObservationsIfNeeded() {
        guard let version = probeVersion?(), version != observedProbeVersion else { return }
        rebuild()
    }

    /// Saved observations plus current endpoint-bound probe and passive
    /// playback measurements; the newer of the two wins per endpoint.
    private func currentObservations(sources: [SmartSportsLoadedSource]) -> [SmartSportsEndpointKey: SmartSportsObservation] {
        var merged = state.keyedObservations
        guard let probeLookup else { return merged }
        observedProbeVersion = probeVersion?()
        let now = Date()
        for source in sources {
            for channel in source.snapshot.channels {
                guard let key = channel.sourceChannelIdentity, let probe = probeLookup(channel),
                      probe.endpointFingerprint == StreamProbe.endpointFingerprint(for: channel.streamURL),
                      var observation = Self.observation(from: probe, now: now) else { continue }
                if let stored = merged[key], stored.observedAt >= observation.observedAt { continue }
                observation.endpointFingerprint = SmartSportsCatalog.endpointFingerprint(for: channel)
                merged[key] = observation
            }
        }
        return merged
    }

    nonisolated static func observation(from probe: StreamProbe, now: Date) -> SmartSportsObservation? {
        var observation: SmartSportsObservation
        if let evidence = probe.passivePlaybackEvidence, evidence.ordinaryLive == true,
           evidence.healthySeconds.isFinite, evidence.bufferingSeconds.isFinite,
           now.timeIntervalSince(evidence.lastObservedAt) <= 24 * 3600 {
            observation = .init(observedAt: evidence.lastObservedAt, provenance: .passivePlayback,
                playedSeconds: max(0, evidence.healthySeconds) + max(0, evidence.bufferingSeconds),
                stalledSeconds: max(0, evidence.bufferingSeconds))
        } else if probe.status != .ok, abs(now.timeIntervalSince(probe.probedAt)) <= 15 * 60 {
            observation = .init(observedAt: probe.probedAt, provenance: .shortPlayback, failures: 1)
        } else if probe.metadataProvenance != nil, let observedAt = probe.metadataObservedAt {
            observation = .init(observedAt: observedAt, provenance: .formatProbe)
        } else {
            return nil
        }
        if probe.streamHealth.isUnstable { observation.failures = max(1, observation.failures) }
        if probe.metadataProvenance != nil, probe.height > 0 {
            observation.width = probe.width
            observation.height = probe.height
            observation.fps = probe.fps.isFinite && probe.fps > 0 ? probe.fps : nil
            observation.videoCodec = probe.videoCodec.isEmpty ? nil : probe.videoCodec
        }
        observation.liveDelaySeconds = probe.liveLatencySeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        observation.bitRate = probe.bitRate > 0 ? probe.bitRate : nil
        return observation
    }

    private func rebuild() {
        guard let definition else { return }
        let rebuildStarted = ContinuousClock.now
        let sources = loadedSources.values.sorted { $0.config.id.uuidString < $1.config.id.uuidString }
        let observations = currentObservations(sources: sources)
        let observationsMs = PerfMetrics.milliseconds(since: rebuildStarted)
        let catalog = definition.reconcile(snapshots: sources.map(\.snapshot),
            overrides: state.overrides, observations: observations)
        let reconcileMs = PerfMetrics.milliseconds(since: rebuildStarted) - observationsMs
        defer {
            let totalMs = PerfMetrics.milliseconds(since: rebuildStarted)
            PerfMetrics.shared.record("smart.rebuild.totalMs", totalMs)
            AppLog.sync.info("Smart rebuild feeds=\(catalog.feeds.count, privacy: .public) observationsMs=\(Int(observationsMs), privacy: .public) reconcileMs=\(Int(reconcileMs), privacy: .public) totalMs=\(Int(totalMs), privacy: .public)")
        }
        var byEndpoint: [SmartSportsEndpointKey: [EPGProgram]] = [:]
        for feed in catalog.feeds {
            for variant in feed.variants {
                guard let guideID = variant.physicalChannel?.epgChannelID else { continue }
                byEndpoint[variant.key] = loadedSources[variant.key.sourceID]?.programs[guideID] ?? []
            }
        }
        var channels: [Channel] = []
        var displayed: [String: [EPGProgram]] = [:]
        for feed in catalog.feeds {
            let category = AutoChannelGrouper.isAutomatic(feedID: feed.id) ? feed.edition : "Sports"
            guard filter.allows(region: feed.country, category: category) else { continue }
            // Display existing endpoints even when a capacity budget is busy;
            // the action and media owner perform the actual reservation gate.
            guard let selected = catalog.selection(for: feed.id)?.selected,
                  let physical = selected.physicalChannel,
                  let ownership = physical.sourceOwnership else { continue }
            let guide = catalog.guideSelection(for: feed.id, programs: byEndpoint)
            let lookupKey = "smart-guide:" + feed.id
            if let guide {
                displayed[lookupKey] = guide.programs.map { program in
                    EPGProgram(id: guide.key.rawValue + "|" + program.id, channelID: lookupKey,
                        title: program.title, description: program.description, start: program.start, end: program.end)
                }
            }
            let group = AutoChannelGrouper.isAutomatic(feedID: feed.id) ? "\(feed.country) | \(feed.edition)" : "\(feed.country) | Sports"
            channels.append(Channel(id: feed.id, name: feed.name, logoURL: physical.logoURL,
                group: group, streamURL: physical.streamURL,
                epgChannelID: lookupKey,
                // Ordinary guide affordances may only advertise this exact
                // physical source's own programme times. The action resolver
                // can explicitly validate a different source archive later.
                catchup: guide?.key == selected.key && guide?.timingNeedsReview == false ? physical.catchup : nil,
                contentType: .live,
                sourceOwnership: .init(channelIdentity: ownership.channelIdentity, accountKey: ownership.accountKey,
                    logicalChannelID: feed.id, guideBinding: guide?.binding ?? ownership.guideBinding)))
        }
        self.catalog = catalog
        displayedChannels = channels
        displayedPrograms = displayed
        revision &+= 1
        onChange?()
    }
}
