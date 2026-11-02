import Foundation
import OSLog

nonisolated struct SmartSportsLoadedSource: Sendable {
    let config: ServerConfig
    let snapshot: SmartSportsSourceSnapshot
    /// Raw provider guide keys and times; never borrowed from another source.
    let programs: [String: [EPGProgram]]
    let savedAt: Date?
    var guideReadSucceeded = true
}

nonisolated struct SmartSportsSnapshotLoadResult: Sendable {
    let sources: [SmartSportsLoadedSource]
    let issues: [UUID: String]
    /// Present even when a content read failed, but only after credentials
    /// resolve. This proves which exact input revision was attempted.
    var resolvedConfigurations: [UUID: ServerConfig] = [:]
}

nonisolated struct SmartSportsSnapshotRequest: Sendable {
    let configurations: [ServerConfig]
    let definition: SmartSportsDefinition
    let overrides: SmartSportsOverrides
    let activeConfig: ServerConfig?
    let activeChannels: [Channel]
    let activePrograms: [String: [EPGProgram]]
}

nonisolated struct SmartAutoDiscoveryRequest: Sendable {
    let configurations: [ServerConfig]
    let activeConfig: ServerConfig?
    let activeChannels: [Channel]
    let curatedKeys: Set<SmartSportsEndpointKey>
    var filter = SmartChannelFilter()
}

nonisolated struct SmartAutoDiscoveryResult: Sendable {
    let feeds: [SmartSportsFeedDefinition]
    var inventory: [SmartRegionSummary] = []
    /// Credentials resolved during discovery, so the snapshot load that
    /// follows does not repeat each Keychain read.
    let resolvedConfigurations: [ServerConfig]
}

nonisolated enum SmartSportsSnapshotLoader {
    /// Reads every configured source's cached channel list (no guide data) and
    /// groups the channels that several accounts carry into automatic feeds.
    static func discoverAutoFeeds(_ request: SmartAutoDiscoveryRequest) async -> SmartAutoDiscoveryResult {
        let started = ContinuousClock.now
        var snapshots: [SmartSportsSourceSnapshot] = []
        var resolved: [UUID: ServerConfig] = [:]
        let configs = request.configurations
        for offset in stride(from: 0, to: configs.count, by: 4) {
            if Task.isCancelled { break }
            let batch = Array(configs[offset..<min(configs.count, offset + 4)])
            let results = await withTaskGroup(of: (ServerConfig, [Channel]?).self) { group in
                for metadata in batch {
                    group.addTask {
                        var config = metadata
                        if let active = request.activeConfig, active.id == metadata.id {
                            config = active
                            if !request.activeChannels.isEmpty { return (config, request.activeChannels) }
                        } else if config.type != .m3u && config.password.isEmpty {
                            guard let saved = await ServerPasswordStore.loadPasswordAsync(for: config.id) else { return (config, nil) }
                            config.password = saved
                        }
                        let key = DataCache.cacheKey(for: config)
                        let channels = await Task.detached(priority: .utility) { DataCache.loadChannels(key: key)?.channels }.value
                        return (config, channels)
                    }
                }
                var values: [(ServerConfig, [Channel]?)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (config, channels) in results {
                resolved[config.id] = config
                if let channels {
                    snapshots.append(.init(sourceID: config.id, sourceName: config.name, channels: channels))
                }
            }
        }
        let loadMs = AppLog.elapsedMilliseconds(since: started)
        let groupStarted = ContinuousClock.now
        let (feeds, inventory) = await Task.detached(priority: .utility) {
            AutoChannelGrouper.analyze(snapshots, excluding: request.curatedKeys, filter: request.filter)
        }.value
        let groupMs = AppLog.elapsedMilliseconds(since: groupStarted)
        PerfMetrics.shared.record("smart.autoDiscovery.ms", since: started)
        AppLog.sync.info("Smart auto-grouping sources=\(snapshots.count, privacy: .public) channels=\(snapshots.reduce(0) { $0 + $1.channels.count }, privacy: .public) feeds=\(feeds.count, privacy: .public) variants=\(feeds.reduce(0) { $0 + $1.variants.count }, privacy: .public) loadMs=\(loadMs, privacy: .public) groupMs=\(groupMs, privacy: .public) elapsedMs=\(AppLog.elapsedMilliseconds(since: started), privacy: .public)")
        return .init(feeds: feeds, inventory: inventory, resolvedConfigurations: configs.map { resolved[$0.id] ?? $0 })
    }

    static func load(_ request: SmartSportsSnapshotRequest) async -> SmartSportsSnapshotLoadResult {
        await load(configurations: request.configurations, definition: request.definition,
            overrides: request.overrides, activeConfig: request.activeConfig,
            activeChannels: request.activeChannels, activePrograms: request.activePrograms)
    }
    /// Cached hydration only. Source switching and provider refresh stay owned
    /// by the ordinary playlist flow; this loader never changes active source.
    static func load(
        configurations: [ServerConfig],
        definition: SmartSportsDefinition,
        overrides: SmartSportsOverrides,
        activeConfig: ServerConfig? = nil,
        activeChannels: [Channel] = [],
        activePrograms: [String: [EPGProgram]] = [:]
    ) async -> SmartSportsSnapshotLoadResult {
        let allowedKeys = Set(definition.feeds.flatMap { $0.variants.map(\.key) }
            + definition.heldEndpoints.map(\.key)
            + overrides.links.keys.compactMap { SmartSportsCatalog.key(from: $0) })
        var loaded: [SmartSportsLoadedSource] = []
        var issues: [UUID: String] = [:]
        var resolvedConfigurations: [UUID: ServerConfig] = [:]
        // Batches bound credential/cache work when many ordinary sources exist.
        let configs = configurations.filter { config in allowedKeys.contains { $0.sourceID == config.id } }
        for offset in stride(from: 0, to: configs.count, by: 4) {
            if Task.isCancelled { break }
            let batch = Array(configs[offset..<min(configs.count, offset + 4)])
            let results = await withTaskGroup(of: (UUID, SmartSportsLoadedSource?, String?, ServerConfig?).self) { group in
                for metadata in batch {
                    group.addTask {
                        var config = metadata
                        if let activeConfig, activeConfig.id == metadata.id {
                            config = activeConfig
                        } else if config.type != .m3u && config.password.isEmpty {
                            let savedPassword = await ServerPasswordStore.loadPasswordAsync(for: config.id)
                            guard !Task.isCancelled else { return (config.id, nil, nil, nil) }
                            if let savedPassword { config.password = savedPassword }
                            else if config.type == .xtream {
                                return (config.id, nil, "Saved source credentials are unavailable.", nil)
                            }
                        }
                        guard !Task.isCancelled else { return (config.id, nil, nil, nil) }
                        let resolved = config
                        let isActive = activeConfig?.id == config.id && !activeChannels.isEmpty
                        let reader = Task.detached(priority: .utility) {
                            guard !Task.isCancelled else { return nil as SmartSportsLoadedSource? }
                            if isActive {
                                return activeSource(config: resolved, channels: activeChannels,
                                    programs: activePrograms, allowedKeys: allowedKeys)
                            }
                            // Current content keys include the credential/guide revision.
                            // Never inspect legacy keys or insecure cached URL migrations.
                            let cacheKey = DataCache.cacheKey(for: resolved)
                            guard let cached = DataCache.loadChannels(key: cacheKey) else { return nil }
                            let selected = selectedChannels(cached.channels, sourceID: resolved.id, allowedKeys: allowedKeys)
                            let stamped = selected.map { stamp($0, config: resolved) }
                            let guideIDs = Set(stamped.compactMap(\.epgChannelID))
                            guard !Task.isCancelled else { return nil }
                            let guideCache = DataCache.loadPrograms(key: cacheKey)
                            let allPrograms = guideCache?.programs ?? [:]
                            let programs = filteredPrograms(allPrograms, guideIDs: guideIDs)
                            return SmartSportsLoadedSource(config: resolved,
                                snapshot: .init(sourceID: resolved.id, sourceName: resolved.name, channels: stamped),
                                programs: programs, savedAt: cached.savedAt, guideReadSucceeded: guideCache != nil)
                        }
                        let result = await withTaskCancellationHandler { await reader.value } onCancel: { reader.cancel() }
                        guard !Task.isCancelled else { return (config.id, nil, nil, nil) }
                        let issue = result == nil ? "Current source cache is unavailable; refresh its ordinary playlist."
                            : result?.guideReadSucceeded == false ? "Current source guide cache is unavailable." : nil
                        return (config.id, result, issue, resolved)
                    }
                }
                var values: [(UUID, SmartSportsLoadedSource?, String?, ServerConfig?)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (id, source, issue, resolved) in results {
                if let source { loaded.append(source) }
                if let issue { issues[id] = issue }
                if let resolved { resolvedConfigurations[id] = resolved }
            }
        }
        return .init(sources: loaded, issues: issues, resolvedConfigurations: resolvedConfigurations)
    }

    static func activeSource(config: ServerConfig, channels: [Channel], programs: [String: [EPGProgram]],
                             allowedKeys: Set<SmartSportsEndpointKey>) -> SmartSportsLoadedSource {
        let selected = selectedChannels(channels, sourceID: config.id, allowedKeys: allowedKeys).map { stamp($0, config: config) }
        return .init(config: config,
            snapshot: .init(sourceID: config.id, sourceName: config.name, channels: selected),
            programs: filteredPrograms(programs, guideIDs: Set(selected.compactMap(\.epgChannelID))), savedAt: nil)
    }

    static func stamp(_ channel: Channel, config: ServerConfig, accountKey: SourceAccountKey? = nil) -> Channel {
        let nativeID = channel.sourceChannelIdentity?.nativeID ?? channel.id
        let guideBinding = channel.epgChannelID.map { SourceGuideBinding(sourceID: config.id, epgChannelID: $0) }
        let ownership = ChannelSourceOwnership(channelIdentity: .init(sourceID: config.id, nativeID: nativeID),
            accountKey: accountKey ?? .init(config: config), guideBinding: guideBinding)
        if channel.id == nativeID, channel.sourceOwnership == ownership { return channel }
        return Channel(id: nativeID, name: channel.name, logoURL: channel.logoURL, group: channel.group,
            streamURL: channel.streamURL, epgChannelID: channel.epgChannelID, catchup: channel.catchup,
            contentType: channel.contentType, sourceOwnership: ownership)
    }

    /// A failed read cannot prove deletion. Keep only rows still bound to the
    /// same physical metadata/endpoint, and apply the ordinary retention bound.
    static func retainingWarmGuide(_ previous: SmartSportsLoadedSource,
                                   for current: SmartSportsLoadedSource,
                                   now: Date = Date()) -> SmartSportsLoadedSource {
        guard DataCache.cacheKey(for: previous.config) == DataCache.cacheKey(for: current.config) else { return current }
        let previousChannels = Dictionary(previous.snapshot.channels.compactMap { channel in
            channel.sourceChannelIdentity.map { ($0, channel) }
        }, uniquingKeysWith: { first, _ in first })
        let eligible = current.snapshot.channels.filter { channel in
            guard let identity = channel.sourceChannelIdentity, let old = previousChannels[identity] else { return false }
            return SmartSportsMetadataIdentity(channel: old).matches(.init(channel: channel))
                && old.streamURL == channel.streamURL && old.contentType == channel.contentType
        }
        let starts = GuideHistory.retentionStarts(channels: eligible, now: now)
        var raw: [String: [EPGProgram]] = [:]
        for guideID in starts.keys {
            if let rows = previous.programs[guideID] {
                raw[guideID] = rows.filter { $0.channelID == guideID }
            }
        }
        return .init(config: current.config, snapshot: current.snapshot,
            programs: GuideHistory.prune(raw, starts: starts, now: now),
            savedAt: previous.savedAt, guideReadSucceeded: false)
    }

    private static func selectedChannels(_ channels: [Channel], sourceID: UUID,
                                         allowedKeys: Set<SmartSportsEndpointKey>) -> [Channel] {
        channels.filter { channel in
            allowedKeys.contains(.init(sourceID: sourceID, nativeID: channel.sourceChannelIdentity?.nativeID ?? channel.id))
        }
    }

    private static func filteredPrograms(_ programs: [String: [EPGProgram]],
                                         guideIDs: Set<String>) -> [String: [EPGProgram]] {
        var result: [String: [EPGProgram]] = [:]
        result.reserveCapacity(guideIDs.count)
        for guideID in guideIDs {
            if let rows = programs[guideID] { result[guideID] = rows }
        }
        return result
    }
}
