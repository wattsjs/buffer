import Foundation
import OSLog

/// Keeps sources other than the active one current while Smart Channels
/// shows all of them. Writes only each source's own cache slots; the active
/// source's in-memory state and its ordinary sync are never touched.
nonisolated enum BackgroundSourceRefresher {
    struct Outcome: Sendable {
        let channelCount: Int?
        let guideKeys: Int?
        let changedChannels: Bool
    }

    static func guideRefreshedKey(for sourceID: UUID) -> String {
        "buffer_background_guide_refreshed_\(sourceID.uuidString)"
    }

    static func refresh(config: ServerConfig, plan: BackgroundRefreshPolicy.Plan) async throws -> Outcome {
        let started = ContinuousClock.now
        let key = DataCache.cacheKey(for: config)
        let cached = DataCache.loadChannels(key: key)?.channels
        var channels = cached ?? []
        var changedChannels = false
        if plan.channels {
            let fresh = try await fetchChannels(config: config)
            try Task.checkCancellation()
            if !fresh.isEmpty {
                changedChannels = !sameCatalog(cached ?? [], fresh)
                channels = fresh
                DataCache.enqueueSaveChannels(fresh, key: key)
            }
        }
        var guideKeys: Int?
        if plan.guide, !channels.isEmpty {
            let incoming = try await fetchCurrentGuide(config: config, channels: channels)
            try Task.checkCancellation()
            if !incoming.isEmpty {
                let merged = mergeIntoCache(incoming, channels: channels, key: key, now: Date())
                DataCache.enqueueSavePrograms(merged, key: key)
                guideKeys = merged.count
                UserDefaults.standard.set(Date(), forKey: guideRefreshedKey(for: config.id))
            }
        }
        PerfMetrics.shared.record("smart.backgroundRefresh.sourceMs", since: started)
        AppLog.sync.info("Background source refresh type=\(config.type.rawValue, privacy: .public) channels=\(plan.channels, privacy: .public) guide=\(plan.guide, privacy: .public) channelCount=\(channels.count, privacy: .public) guideKeys=\(guideKeys ?? -1, privacy: .public) changedChannels=\(changedChannels, privacy: .public) elapsedMs=\(AppLog.elapsedMilliseconds(since: started), privacy: .public)")
        return Outcome(channelCount: plan.channels ? channels.count : nil, guideKeys: guideKeys, changedChannels: changedChannels)
    }

    static func fetchChannels(config: ServerConfig) async throws -> [Channel] {
        let fetched: [Channel]
        switch config.type {
        case .xtream:
            fetched = try await XtreamClient(config: config).fetchChannels()
        case .stalker:
            fetched = try await StalkerClient(config: config).fetchChannels()
        case .m3u:
            guard let url = config.m3uSourceURL else { throw XtreamError.invalidURL }
            fetched = try await M3UParser.parse(from: url)
        }
        return fetched.map { SmartSportsSnapshotLoader.stamp($0, config: config) }
    }

    /// The bulk current guide only. Per-channel catch-up history stays with
    /// the source's own sync; retained history is kept by the merge below.
    private static func fetchCurrentGuide(config: ServerConfig, channels: [Channel]) async throws -> [EPGProgram] {
        switch config.type {
        case .stalker:
            return try await StalkerClient(config: config).fetchEPG(periodHours: 24, channels: channels)
        case .m3u:
            guard let url = config.epgSourceURL else { return [] }
            return try await XMLTVParser.parse(from: url)
        case .xtream:
            guard let base = config.xtreamEPGURL,
                  var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return [] }
            var items = (components.queryItems ?? []).filter { $0.name != "prev_days" && $0.name != "next_days" }
            items += [URLQueryItem(name: "prev_days", value: "1"), URLQueryItem(name: "next_days", value: "1")]
            components.queryItems = items
            guard let url = components.url else { return [] }
            return try await XMLTVParser.parse(from: url)
        }
    }

    /// Same retention rules as an ordinary "current" publication: fresh rows
    /// replace their window, older retained history survives, and guides for
    /// channels no longer offered are dropped.
    static func mergeIntoCache(_ incoming: [EPGProgram], channels: [Channel], key: String, now: Date) -> [String: [EPGProgram]] {
        let existing = DataCache.loadPrograms(key: key)?.programs ?? [:]
        return BackgroundRefreshPolicy.merge(existing: existing, incoming: incoming, channels: channels, now: now)
    }

    private static func sameCatalog(_ lhs: [Channel], _ rhs: [Channel]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
            a.id == b.id && a.name == b.name && a.group == b.group && a.streamURL == b.streamURL
                && a.epgChannelID == b.epgChannelID && a.contentType == b.contentType
        }
    }
}
