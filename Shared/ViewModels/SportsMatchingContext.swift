import Foundation

/// Feeds the Sports tab's stream matcher from the guide view model: the
/// displayed channel set (Smart Channels or the active source), favourites,
/// preference scores and recent probe quality. Each platform's root view owns
/// one and calls it when the matching inputs change.
@MainActor
final class SportsMatchingContext {
    private var channels: [Channel] = []
    private var catalogVersion = 0
    private var usesSmart = false
    private var sourceVersion = -1
    private var qualityCache: [String: StreamMatchQuality] = [:]
    private var qualityProbeVersion = -1
    private var qualityCatalogVersion = -1
    private var qualityUpdatedAt = Date.distantPast
    private var preferencesCache: (favorites: Set<String>, scores: [String: Double]) = ([], [:])
    private var preferencesCatalogVersion = -1
    private var preferencesSourceVersion = -1
    private var preferencesScoreVersion = -1
    private var preferencesFavorites: Set<String> = []
    private var preferencesLogicalBindings: [String: String] = [:]

    func updateContext(viewModel: EPGViewModel, sports: SportsViewModel) {
        let snapshot = viewModel.isSmartSportsActive
            ? viewModel.smartSports.sportsMatchingSnapshot(activeConfig: viewModel.serverConfig,
                activeChannels: viewModel.channels, activePrograms: viewModel.programs,
                activeCatalogVersion: viewModel.channelCatalogVersion)
            : (channels: viewModel.channels, programs: viewModel.programs)
        // Every assignment to an ordinary account's channels bumps its catalog
        // version, so guide publications skip the per-channel comparison.
        let sameSourceCatalog = !viewModel.isSmartSportsActive && !usesSmart
            && sourceVersion == viewModel.channelCatalogVersion
        sourceVersion = viewModel.channelCatalogVersion
        let unchanged = sameSourceCatalog || usesSmart == viewModel.isSmartSportsActive
            && channels.count == snapshot.channels.count
            && zip(channels, snapshot.channels).allSatisfy { lhs, rhs in
                lhs.id == rhs.id && lhs.name == rhs.name && lhs.group == rhs.group
                    && lhs.streamURL == rhs.streamURL && lhs.epgChannelID == rhs.epgChannelID
                    && lhs.catchup == rhs.catchup && lhs.contentType == rhs.contentType && lhs.sourceOwnership == rhs.sourceOwnership
            }
        if !unchanged {
            channels = snapshot.channels
            usesSmart = viewModel.isSmartSportsActive
            catalogVersion &+= 1
        }
        let preferences = matchingPreferences(viewModel: viewModel)
        sports.updateStreamMatchingContext(
            channels: snapshot.channels,
            programs: snapshot.programs,
            favoriteChannelIDs: preferences.favorites,
            channelPreferenceScores: preferences.scores,
            groupPreferenceScores: viewModel.groupPreferenceScores,
            hiddenGroups: viewModel.hiddenGroupNames,
            guideVersion: viewModel.guideVersion,
            channelSetVersion: catalogVersion,
            deferGuideIndex: viewModel.isGuideEnriching || (viewModel.isSmartSportsActive && viewModel.smartSports.isLoading),
            qualityByChannel: matchingQuality()
        )
    }

    func updatePreferences(viewModel: EPGViewModel, sports: SportsViewModel) {
        let preferences = matchingPreferences(viewModel: viewModel)
        sports.updateStreamMatchingPreferences(
            favoriteChannelIDs: preferences.favorites,
            channelPreferenceScores: preferences.scores,
            groupPreferenceScores: viewModel.groupPreferenceScores,
            qualityByChannel: matchingQuality()
        )
    }

    /// Ordinary preference IDs belong to their active playlist. Logical Smart
    /// favorites may prefer each eligible physical variant without changing
    /// the endpoint's action ownership or copying a guide to another source.
    private func matchingPreferences(viewModel: EPGViewModel) -> (favorites: Set<String>, scores: [String: Double]) {
        var logicalByPhysical: [String: String] = [:]
        if viewModel.isSmartSportsActive {
            for feed in viewModel.smartSports.catalog?.feeds ?? [] {
                for variant in feed.variants { logicalByPhysical[variant.key.rawValue] = feed.id }
            }
        }
        if preferencesCatalogVersion == catalogVersion,
           preferencesSourceVersion == viewModel.channelCatalogVersion,
           preferencesScoreVersion == viewModel.preferenceScoresVersion,
           preferencesFavorites == viewModel.favoriteChannelIDs,
           preferencesLogicalBindings == logicalByPhysical { return preferencesCache }
        var favorites = Set<String>()
        var scores: [String: Double] = [:]
        for channel in channels {
            let key = channel.preferenceIdentity
            let preferenceKey: String?
            if viewModel.isSmartSportsActive { preferenceKey = logicalByPhysical[key] }
            else if channel.sourceChannelIdentity?.sourceID == viewModel.activePlaylistID || channel.sourceChannelIdentity == nil {
                preferenceKey = channel.id
            } else { preferenceKey = nil }
            guard let preferenceKey else { continue }
            if viewModel.favoriteChannelIDs.contains(preferenceKey) { favorites.insert(key) }
            if let score = viewModel.channelPreferenceScores[preferenceKey] { scores[key] = score }
        }
        preferencesCache = (favorites, scores)
        preferencesCatalogVersion = catalogVersion
        preferencesSourceVersion = viewModel.channelCatalogVersion
        preferencesScoreVersion = viewModel.preferenceScoresVersion
        preferencesFavorites = viewModel.favoriteChannelIDs
        preferencesLogicalBindings = logicalByPhysical
        return preferencesCache
    }

    private func matchingQuality(now: Date = Date()) -> [String: StreamMatchQuality] {
        let probeVersion = StreamProbeService.shared.version
        if qualityProbeVersion == probeVersion,
           qualityCatalogVersion == catalogVersion,
           now.timeIntervalSince(qualityUpdatedAt) < 60 { return qualityCache }
        var result: [String: StreamMatchQuality] = [:]
        for channel in channels {
            guard let probe = StreamProbeService.shared.probe(for: channel),
                  probe.endpointFingerprint == StreamProbe.endpointFingerprint(for: channel.streamURL) else { continue }
            var quality = StreamMatchQuality()
            let probeAge = now.timeIntervalSince(probe.probedAt)
            if probeAge >= -60 && probeAge <= 15 * 60 {
                if probe.status != .ok { quality.availability = .failed }
                quality.isUnstable = probe.streamHealth.isUnstable
            }
            if let evidence = probe.passivePlaybackEvidence, evidence.ordinaryLive == true {
                let age = now.timeIntervalSince(evidence.lastObservedAt)
                if age >= -60 && age <= 24 * 3600, evidence.healthySeconds.isFinite, evidence.healthySeconds >= 0,
                   evidence.bufferingSeconds.isFinite, evidence.bufferingSeconds >= 0 {
                    quality.healthySeconds = evidence.healthySeconds
                    quality.observedSeconds = evidence.healthySeconds + evidence.bufferingSeconds
                    quality.bufferingSeconds = evidence.bufferingSeconds
                    if evidence.bufferingSeconds > 3 { quality.availability = .failed }
                    else if quality.availability != .failed && evidence.healthySeconds >= 180 && evidence.bufferingSeconds <= 0.5 {
                        quality.availability = .observedAvailable
                    }
                }
            }
            if probe.metadataProvenance != nil, let date = probe.metadataObservedAt {
                let age = now.timeIntervalSince(date)
                if age >= -60 && age <= 14 * 86400 {
                    quality.observedHeight = max(0, probe.height)
                    quality.observedFPS = probe.fps.isFinite ? max(0, probe.fps) : 0
                    quality.observedBitRate = max(0, probe.bitRate)
                }
            }
            result[channel.preferenceIdentity] = quality
        }
        qualityCache = result
        qualityProbeVersion = probeVersion
        qualityCatalogVersion = catalogVersion
        qualityUpdatedAt = now
        return result
    }
}
