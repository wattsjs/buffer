import Foundation
import CryptoKit

nonisolated struct SmartSportsCatalog: Sendable {
    let playlistID: String
    let name: String
    let feeds: [SmartSportsFeed]
    let reviewItems: [SmartSportsReviewItem]
    let overrides: SmartSportsOverrides
    /// Feed lookups happen once per feed on every rebuild; with automatic
    /// grouping there are thousands, so a linear scan becomes quadratic.
    private let feedIndex: [String: Int]

    init(playlistID: String, name: String, feeds: [SmartSportsFeed],
         reviewItems: [SmartSportsReviewItem], overrides: SmartSportsOverrides) {
        self.playlistID = playlistID
        self.name = name
        self.feeds = feeds
        self.reviewItems = reviewItems
        self.overrides = overrides
        feedIndex = Dictionary(feeds.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func feed(id: String) -> SmartSportsFeed? {
        feedIndex[id].map { feeds[$0] }
    }

    enum LoadError: Error { case missingResource, unsupportedSchema, duplicateFeedID }

    static func loadBundled(bundle: Bundle = .main) throws -> SmartSportsDefinition {
        guard let url = bundle.url(forResource: "SmartSportsCatalog", withExtension: "json")
            ?? bundle.url(forResource: "SmartSportsCatalog", withExtension: "json", subdirectory: "Resources") else {
            throw LoadError.missingResource
        }
        return try loadDefinition(data: Data(contentsOf: url))
    }

    static func loadDefinition(data: Data) throws -> SmartSportsDefinition {
        let definition = try JSONDecoder().decode(SmartSportsDefinition.self, from: data)
        guard definition.schemaVersion == 1 else { throw LoadError.unsupportedSchema }
        guard Set(definition.feeds.map(\.id)).count == definition.feeds.count else {
            throw LoadError.duplicateFeedID
        }
        return definition
    }

    static func reconcile(
        definition: SmartSportsDefinition,
        snapshots: [SmartSportsSourceSnapshot],
        overrides: SmartSportsOverrides = .init(),
        observations: [SmartSportsEndpointKey: SmartSportsObservation] = [:]
    ) -> Self {
        var current: [SmartSportsEndpointKey: Channel] = [:]
        var sourceNames: [UUID: String] = [:]
        var duplicateKeys: Set<SmartSportsEndpointKey> = []
        for snapshot in snapshots {
            sourceNames[snapshot.sourceID] = snapshot.sourceName
            for channel in snapshot.channels {
                let key = SmartSportsEndpointKey(sourceID: snapshot.sourceID,
                    nativeID: channel.sourceChannelIdentity?.nativeID ?? channel.id)
                if current.updateValue(channel, forKey: key) != nil { duplicateKeys.insert(key) }
            }
        }
        let held = Dictionary(definition.heldEndpoints.map { ($0.key, $0.reason) },
                              uniquingKeysWith: { first, _ in first })
        var byFeed: [String: [SmartSportsVariant]] = [:]
        var review: [SmartSportsEndpointKey: SmartSportsReviewItem] = [:]
        var seenKeys: Set<SmartSportsEndpointKey> = []
        let validFeedIDs = Set(definition.feeds.map(\.id) + overrides.customFeeds.map(\.id))

        func add(key: SmartSportsEndpointKey, feedID originalFeedID: String,
                 expected: SmartSportsMetadataIdentity, sourceName: String,
                 advertisedFormat: String, advertisedFPS: Double?,
                 legacyObservation: SmartSportsObservation?) {
            guard seenKeys.insert(key).inserted else { return }
            let manualLink = overrides.links[key.rawValue]
            let feedID = manualLink?.feedID ?? originalFeedID
            guard validFeedIDs.contains(feedID) else {
                review[key] = .init(key: key, feedID: nil, reason: "Manual destination is unavailable.",
                                    state: .heldForReview)
                return
            }
            let expectedIdentity = manualLink?.identity ?? overrides.acceptedIdentities[key.rawValue] ?? expected
            let channel = current[key]
            let state: SmartSportsMembershipState
            let reason: String?
            if overrides.rejectedEndpointKeys.contains(key.rawValue) {
                state = .rejected; reason = "Excluded by your review."
            } else if let heldReason = held[key], manualLink == nil {
                state = .heldForReview; reason = heldReason
            } else if duplicateKeys.contains(key) {
                state = .duplicateNativeID; reason = "Source returned this native ID more than once."
            } else if let channel {
                if channel.contentType != .live || !expectedIdentity.matches(.init(channel: channel)) {
                    state = .changedIdentity
                    reason = "Name, group, guide binding or content type changed; review before using this endpoint."
                } else {
                    state = manualLink != nil || overrides.acceptedIdentities[key.rawValue] != nil
                        ? .manuallyReviewed : .metadataCandidate
                    reason = nil
                }
            } else {
                state = .missing; reason = "Endpoint is absent from the current configured source."
            }
            let observation: SmartSportsObservation? = observations[key].flatMap { observation in
                guard let channel,
                      observation.endpointFingerprint == endpointFingerprint(for: channel) else { return nil }
                return observation
            }
            byFeed[feedID, default: []].append(.init(key: key, feedID: feedID,
                sourceName: sourceNames[key.sourceID] ?? sourceName,
                expectedIdentity: expectedIdentity, physicalChannel: channel,
                state: state, advertisedFormat: advertisedFormat, advertisedFPS: advertisedFPS,
                observation: observation ?? legacyObservation))
            if let reason { review[key] = .init(key: key, feedID: feedID, reason: reason, state: state) }
        }

        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for feed in definition.feeds {
            for variant in feed.variants {
                // Legacy format data did not record endpoint revision or playback mode.
                // Keep it visible as provenance, but never use it to rank current quality.
                let legacy: SmartSportsObservation?
                if let timestamp = variant.measuredAt, let date = dateParser.date(from: timestamp) {
                    legacy = .init(observedAt: date, provenance: .legacyCachedFormat,
                                   width: variant.width, height: variant.height, fps: variant.fps)
                } else { legacy = nil }
                add(key: variant.key, feedID: feed.id, expected: variant.identity,
                    sourceName: variant.sourceName, advertisedFormat: variant.advertisedFormat,
                    advertisedFPS: variant.advertisedFPS, legacyObservation: legacy)
            }
        }
        // Explicit links can accept held endpoints or add unlisted endpoints. They
        // preserve the reviewed metadata so later native-ID reuse is detected.
        for (rawKey, link) in overrides.links {
            guard let key = key(from: rawKey) else { continue }
            add(key: key, feedID: link.feedID, expected: link.identity,
                sourceName: sourceNames[key.sourceID] ?? "Unavailable source",
                advertisedFormat: "", advertisedFPS: nil, legacyObservation: nil)
        }
        for (key, reason) in held where !seenKeys.contains(key) {
            let rejected = overrides.rejectedEndpointKeys.contains(key.rawValue)
            review[key] = .init(key: key, feedID: nil,
                reason: rejected ? "Excluded by your review. " + reason : reason,
                state: rejected ? .rejected : .heldForReview)
        }

        var feeds = definition.feeds.map { feed in
            SmartSportsFeed(id: feed.id, name: feed.name, country: feed.country,
                language: feed.language, edition: feed.edition, guideStatus: feed.guideStatus,
                caveats: feed.caveats, variants: byFeed[feed.id] ?? [])
        }
        feeds += overrides.customFeeds.map { feed in
            SmartSportsFeed(id: feed.id, name: feed.name, country: feed.country,
                language: feed.language, edition: feed.edition, guideStatus: "Manual link",
                caveats: [], variants: byFeed[feed.id] ?? [])
        }
        return .init(playlistID: definition.playlistID, name: definition.name, feeds: feeds,
                     reviewItems: review.values.sorted { $0.id < $1.id }, overrides: overrides)
    }

    func variants(for feedID: String) -> [SmartSportsVariant] {
        feed(id: feedID)?.variants ?? []
    }

    func selection(for feedID: String, context: SmartSportsSelectionContext = .init()) -> SmartSportsSelection? {
        let candidates = variants(for: feedID).filter { isEligible($0, context: context) }
        let preferred = overrides.preferredVariants[feedID]
        let ranked = candidates.sorted { lhs, rhs in
            let lhsFailed = context.recentFailedEndpoints.contains(lhs.key)
            let rhsFailed = context.recentFailedEndpoints.contains(rhs.key)
            if lhsFailed != rhsFailed { return !lhsFailed }
            if lhs.id == preferred || rhs.id == preferred { return lhs.id == preferred }
            return ranksBefore(lhs, rhs, context: context)
        }
        guard let selected = ranked.first else { return nil }
        var reasons = [selected.id == preferred ? "Your source choice" : "Eligible current source"]
        if context.recentFailedEndpoints.contains(selected.key) {
            reasons.append("Recent source observation failed; no unfailed eligible alternative is known.")
        }
        var uncertainty = ["Source variants are metadata candidates; identical stream content is unverified."]
        if let observation = selected.observation {
            if observation.reliabilityClass(now: context.now) == 2 { reasons.append("Recent sustained playback observation") }
            if usableFormat(observation, now: context.now) { reasons.append("Recent observed video format") }
            else { uncertainty.append("Current format is unmeasured; advertised labels are not quality measurements.") }
            if observation.provenance == .legacyCachedFormat {
                uncertainty.append("Legacy cached format has no recorded endpoint revision and does not influence selection.")
            }
            if observation.reliabilityClass(now: context.now) == 1 {
                uncertainty.append("Sustained reliability is unqualified.")
            }
        } else {
            uncertainty.append("Current format and sustained reliability are unmeasured.")
        }
        if let preferred, selected.id != preferred {
            let failed = Self.key(from: preferred).map { context.recentFailedEndpoints.contains($0) } ?? false
            reasons.append(failed ? "Your preferred source recently failed; trying another eligible source. Preference retained."
                : "Your preferred source is currently ineligible; preference retained.")
        }
        return .init(feedID: feedID, selected: selected, alternatives: Array(ranked.dropFirst()),
                     reasons: reasons, uncertainty: uncertainty)
    }

    /// Guide choice has no dependency on which endpoint won playback selection.
    /// Every bucket is passed using a source/native key and retains its raw times.
    func guideSelection(for feedID: String,
                        programs: [SmartSportsEndpointKey: [EPGProgram]],
                        now: Date = Date()) -> SmartSportsGuideSelection? {
        let preferred = overrides.preferredGuides[feedID]
        let candidates = variants(for: feedID).compactMap { variant -> (SmartSportsVariant, SourceGuideBinding, [EPGProgram])? in
            guard let binding = variant.guideBinding,
                  !Self.isSuspiciousGuideID(binding.epgChannelID),
                  let rows = programs[variant.key] else { return nil }
            let matching = rows.filter {
                $0.channelID == binding.epgChannelID && $0.end > $0.start
                    && $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite
                    && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.sorted { $0.start < $1.start }
            guard !matching.isEmpty else { return nil }
            return (variant, binding, matching)
        }.sorted { lhs, rhs in
            if lhs.0.id == preferred || rhs.0.id == preferred { return lhs.0.id == preferred }
            let lhsCurrent = lhs.2.contains { $0.start <= now && $0.end > now }
            let rhsCurrent = rhs.2.contains { $0.start <= now && $0.end > now }
            if lhsCurrent != rhsCurrent { return lhsCurrent }
            let lhsFuture = lhs.2.filter { $0.end > now && $0.start < now.addingTimeInterval(24 * 3600) }.count
            let rhsFuture = rhs.2.filter { $0.end > now && $0.start < now.addingTimeInterval(24 * 3600) }.count
            if lhsFuture != rhsFuture { return lhsFuture > rhsFuture }
            return lhs.0.id < rhs.0.id
        }
        guard let result = candidates.first else { return nil }
        let status = feed(id: feedID)?.guideStatus
        return .init(key: result.0.key, binding: result.1, programs: result.2,
                     timingNeedsReview: status == "Timing review" || status == "Schedule review")
    }

    static func key(from rawValue: String) -> SmartSportsEndpointKey? {
        guard let separator = rawValue.firstIndex(of: "|"),
              let sourceID = UUID(uuidString: String(rawValue[..<separator])) else { return nil }
        let nativeID = String(rawValue[rawValue.index(after: separator)...])
        guard !nativeID.isEmpty else { return nil }
        return .init(sourceID: sourceID, nativeID: nativeID)
    }

    static func endpointFingerprint(for channel: Channel) -> String {
        let digest = SHA256.hash(data: Data(channel.streamURL.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isSuspiciousGuideID(_ guideID: String) -> Bool {
        let id = guideID.lowercased()
        return id.hasSuffix(".bossdummy") || id.hasSuffix(".p13")
            || id.hasPrefix("dummy") || id.hasPrefix("event:") || id.hasPrefix("stan/event")
            || id.contains("bosssports.") || id.hasSuffix(".ncaabgames1")
            || id.range(of: "\\.v[0-9]*$", options: .regularExpression) != nil
    }

    private func isEligible(_ variant: SmartSportsVariant, context: SmartSportsSelectionContext) -> Bool {
        guard variant.isPlayable, let channel = variant.physicalChannel,
              !context.unavailableSources.contains(variant.key.sourceID),
              !context.unavailableEndpoints.contains(variant.key) else { return false }
        if let observation = variant.observation, usableFormat(observation, now: context.now) {
            if let codec = observation.videoCodec,
               context.unsupportedVideoCodecs.contains(codec.lowercased()) { return false }
            if observation.hdr == true && !context.supportsHDR { return false }
        }
        if context.mode == .catchup {
            guard let start = context.requestedArchiveStart,
                  context.validatedArchiveKeys.contains(variant.key),
                  channel.archiveContains(start, now: context.now) else { return false }
        }
        return true
    }

    private func usableFormat(_ observation: SmartSportsObservation, now: Date) -> Bool {
        observation.provenance != .legacyCachedFormat && observation.isFresh(now: now, maximumAge: 14 * 86400)
    }

    private func ranksBefore(_ lhs: SmartSportsVariant, _ rhs: SmartSportsVariant,
                             context: SmartSportsSelectionContext) -> Bool {
        let lhsReliability = lhs.observation?.reliabilityClass(now: context.now) ?? 1
        let rhsReliability = rhs.observation?.reliabilityClass(now: context.now) ?? 1
        if lhsReliability != rhsReliability { return lhsReliability > rhsReliability }
        let lo = lhs.observation.flatMap { usableFormat($0, now: context.now) ? $0 : nil }
        let ro = rhs.observation.flatMap { usableFormat($0, now: context.now) ? $0 : nil }
        // Live delay in 3 s steps: a clearly closer live edge wins before
        // picture quality; small measurement jitter does not reorder feeds.
        let lhsDelay = lo?.liveDelaySeconds.flatMap { $0.isFinite && $0 >= 0 ? Int($0 / 3) : nil }
        let rhsDelay = ro?.liveDelaySeconds.flatMap { $0.isFinite && $0 >= 0 ? Int($0 / 3) : nil }
        if let lhsDelay, let rhsDelay, lhsDelay != rhsDelay { return lhsDelay < rhsDelay }
        let lhsMotion = lo?.fps.flatMap { $0.isFinite && $0 > 0 ? min($0, 60) : nil }
        let rhsMotion = ro?.fps.flatMap { $0.isFinite && $0 > 0 ? min($0, 60) : nil }
        // Missing format stays explicitly unknown; it receives no invented FPS.
        if lhsMotion != rhsMotion {
            if let lhsMotion, let rhsMotion { return lhsMotion > rhsMotion }
            return lhsMotion != nil
        }
        let lhsHeight = lo?.height.flatMap { $0 > 0 ? min($0, max(1, context.usefulHeight)) : nil }
        let rhsHeight = ro?.height.flatMap { $0 > 0 ? min($0, max(1, context.usefulHeight)) : nil }
        if lhsHeight != rhsHeight {
            if let lhsHeight, let rhsHeight { return lhsHeight > rhsHeight }
            return lhsHeight != nil
        }
        // Same resolution: higher bitrate in 2 Mb/s steps.
        let lhsRate = lo?.bitRate.flatMap { $0 > 0 ? Int(min($0, 40_000_000) / 2_000_000) : nil }
        let rhsRate = ro?.bitRate.flatMap { $0 > 0 ? Int(min($0, 40_000_000) / 2_000_000) : nil }
        if let lhsRate, let rhsRate, lhsRate != rhsRate { return lhsRate > rhsRate }
        let lhsStartup = lo?.startupSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let rhsStartup = ro?.startupSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if let lhsStartup, let rhsStartup, lhsStartup != rhsStartup { return lhsStartup < rhsStartup }
        return lhs.id < rhs.id
    }
}
