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
    /// Ranking facts for every variant, feed-major, as flat columns.
    private let rank: VariantRankColumns

    init(playlistID: String, name: String, feeds: [SmartSportsFeed],
         reviewItems: [SmartSportsReviewItem], overrides: SmartSportsOverrides) {
        self.playlistID = playlistID
        self.name = name
        self.feeds = feeds
        self.reviewItems = reviewItems
        self.overrides = overrides
        feedIndex = Dictionary(feeds.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        rank = VariantRankColumns(feeds: feeds)
    }

    func feed(id: String) -> SmartSportsFeed? {
        feedIndex[id].map { feeds[$0] }
    }

    enum LoadError: Error { case missingResource, unsupportedSchema, duplicateFeedID }

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
        // Current endpoints as one flat table: a key resolves to an index
        // once, and seen/duplicate state and observations live in columns.
        var endpointIndex: [SmartSportsEndpointKey: Int32] = [:]
        var endpoints: [Channel] = []
        var sourceNames: [UUID: String] = [:]
        let duplicate: UInt8 = 1, seen: UInt8 = 2
        var endpointFlags: [UInt8] = []
        let channelCount = snapshots.reduce(0) { $0 + $1.channels.count }
        endpointIndex.reserveCapacity(channelCount); endpoints.reserveCapacity(channelCount)
        endpointFlags.reserveCapacity(channelCount)
        for snapshot in snapshots {
            sourceNames[snapshot.sourceID] = snapshot.sourceName
            for channel in snapshot.channels {
                let key = SmartSportsEndpointKey(sourceID: snapshot.sourceID,
                    nativeID: channel.sourceChannelIdentity?.nativeID ?? channel.id)
                if let existing = endpointIndex[key] {
                    // The latest row wins; the key is marked duplicate.
                    endpoints[Int(existing)] = channel
                    endpointFlags[Int(existing)] |= duplicate
                } else {
                    endpointIndex[key] = Int32(endpoints.count)
                    endpoints.append(channel)
                    endpointFlags.append(0)
                }
            }
        }
        // Observations bound to an endpoint slot; one hash per observation.
        var observationSlot = [Int32](repeating: -1, count: endpoints.count)
        var observationList: [SmartSportsObservation] = []
        for (key, observation) in observations {
            guard let index = endpointIndex[key] else { continue }
            observationSlot[Int(index)] = Int32(observationList.count)
            observationList.append(observation)
        }
        var seenMissing: Set<SmartSportsEndpointKey> = []
        func wasSeen(_ key: SmartSportsEndpointKey) -> Bool {
            if let index = endpointIndex[key] { return endpointFlags[Int(index)] & seen != 0 }
            return seenMissing.contains(key)
        }
        let held = Dictionary(definition.heldEndpoints.map { ($0.key, $0.reason) },
                              uniquingKeysWith: { first, _ in first })
        // One bucket per distinct feed ID, addressed by slot rather than by
        // hashing the feed ID for every endpoint.
        var slotByFeedID: [String: Int] = [:]
        slotByFeedID.reserveCapacity(definition.feeds.count + overrides.customFeeds.count)
        for id in definition.feeds.map(\.id) + overrides.customFeeds.map(\.id) where slotByFeedID[id] == nil {
            slotByFeedID[id] = slotByFeedID.count
        }
        var buckets = [[SmartSportsVariant]](repeating: [], count: slotByFeedID.count)
        var review: [SmartSportsEndpointKey: SmartSportsReviewItem] = [:]
        // Raw override keys are only built when some override is keyed by them.
        let hasKeyedOverrides = !overrides.links.isEmpty || !overrides.rejectedEndpointKeys.isEmpty
            || !overrides.acceptedIdentities.isEmpty
        var rawPrefixes: [UUID: String] = [:]
        func rawKey(_ key: SmartSportsEndpointKey) -> String {
            if let prefix = rawPrefixes[key.sourceID] { return prefix + key.nativeID }
            let prefix = key.sourceID.uuidString.lowercased() + "|"
            rawPrefixes[key.sourceID] = prefix
            return prefix + key.nativeID
        }

        func add(key: SmartSportsEndpointKey, feedID originalFeedID: String, slot originalSlot: Int?,
                 expected: SmartSportsMetadataIdentity, sourceName: String,
                 advertisedFormat: String, advertisedFPS: Double?,
                 legacyObservation: SmartSportsObservation?) {
            let index = endpointIndex[key].map(Int.init)
            if let index {
                guard endpointFlags[index] & seen == 0 else { return }
                endpointFlags[index] |= seen
            } else {
                guard seenMissing.insert(key).inserted else { return }
            }
            let raw = hasKeyedOverrides ? rawKey(key) : nil
            let manualLink = raw.flatMap { overrides.links[$0] }
            let accepted = raw.flatMap { overrides.acceptedIdentities[$0] }
            let feedID = manualLink?.feedID ?? originalFeedID
            guard let slot = manualLink == nil ? (originalSlot ?? slotByFeedID[feedID]) : slotByFeedID[feedID] else {
                review[key] = .init(key: key, feedID: nil, reason: "Manual destination is unavailable.",
                                    state: .heldForReview)
                return
            }
            let expectedIdentity = manualLink?.identity ?? accepted ?? expected
            let channel = index.map { endpoints[$0] }
            let state: SmartSportsMembershipState
            let reason: String?
            if let raw, overrides.rejectedEndpointKeys.contains(raw) {
                state = .rejected; reason = "Excluded by your review."
            } else if !held.isEmpty, let heldReason = held[key], manualLink == nil {
                state = .heldForReview; reason = heldReason
            } else if let index, endpointFlags[index] & duplicate != 0 {
                state = .duplicateNativeID; reason = "Source returned this native ID more than once."
            } else if let channel {
                if channel.contentType != .live || !expectedIdentity.matches(.init(channel: channel)) {
                    state = .changedIdentity
                    reason = "Name, group, guide binding or content type changed; review before using this endpoint."
                } else {
                    state = manualLink != nil || accepted != nil ? .manuallyReviewed : .metadataCandidate
                    reason = nil
                }
            } else {
                state = .missing; reason = "Endpoint is absent from the current configured source."
            }
            var observation: SmartSportsObservation?
            if let index, let channel, observationSlot[index] >= 0 {
                let candidate = observationList[Int(observationSlot[index])]
                if candidate.endpointFingerprint == endpointFingerprint(for: channel) { observation = candidate }
            }
            buckets[slot].append(.init(key: key, feedID: feedID,
                sourceName: sourceNames[key.sourceID] ?? sourceName,
                expectedIdentity: expectedIdentity, physicalChannel: channel,
                state: state, advertisedFormat: advertisedFormat, advertisedFPS: advertisedFPS,
                observation: observation ?? legacyObservation))
            if let reason { review[key] = .init(key: key, feedID: feedID, reason: reason, state: state) }
        }

        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for feed in definition.feeds {
            let slot = slotByFeedID[feed.id]
            for variant in feed.variants {
                // Legacy format data did not record endpoint revision or playback mode.
                // Keep it visible as provenance, but never use it to rank current quality.
                let legacy: SmartSportsObservation?
                if let timestamp = variant.measuredAt, let date = dateParser.date(from: timestamp) {
                    legacy = .init(observedAt: date, provenance: .legacyCachedFormat,
                                   width: variant.width, height: variant.height, fps: variant.fps)
                } else { legacy = nil }
                add(key: variant.key, feedID: feed.id, slot: slot, expected: variant.identity,
                    sourceName: variant.sourceName, advertisedFormat: variant.advertisedFormat,
                    advertisedFPS: variant.advertisedFPS, legacyObservation: legacy)
            }
        }
        // Explicit links can accept held endpoints or add unlisted endpoints. They
        // preserve the reviewed metadata so later native-ID reuse is detected.
        for (rawKey, link) in overrides.links {
            guard let key = key(from: rawKey) else { continue }
            add(key: key, feedID: link.feedID, slot: nil, expected: link.identity,
                sourceName: sourceNames[key.sourceID] ?? "Unavailable source",
                advertisedFormat: "", advertisedFPS: nil, legacyObservation: nil)
        }
        for (key, reason) in held where !wasSeen(key) {
            let rejected = overrides.rejectedEndpointKeys.contains(key.rawValue)
            review[key] = .init(key: key, feedID: nil,
                reason: rejected ? "Excluded by your review. " + reason : reason,
                state: rejected ? .rejected : .heldForReview)
        }

        var feeds = definition.feeds.map { feed in
            SmartSportsFeed(id: feed.id, name: feed.name, country: feed.country,
                language: feed.language, edition: feed.edition, guideStatus: feed.guideStatus,
                caveats: feed.caveats, variants: buckets[slotByFeedID[feed.id]!])
        }
        feeds += overrides.customFeeds.map { feed in
            SmartSportsFeed(id: feed.id, name: feed.name, country: feed.country,
                language: feed.language, edition: feed.edition, guideStatus: "Manual link",
                caveats: [], variants: buckets[slotByFeedID[feed.id]!])
        }
        return .init(playlistID: definition.playlistID, name: definition.name, feeds: feeds,
                     reviewItems: review.values.sorted { $0.id < $1.id }, overrides: overrides)
    }

    func variants(for feedID: String) -> [SmartSportsVariant] {
        feed(id: feedID)?.variants ?? []
    }

    func selection(for feedID: String, context: SmartSportsSelectionContext = .init()) -> SmartSportsSelection? {
        guard let index = feedIndex[feedID] else { return nil }
        let variants = feeds[index].variants
        let ranked = rankedVariants(feed: index, context: context)
        guard let first = ranked.first else { return nil }
        let selected = variants[first]
        let preferred = overrides.preferredVariants[feedID]
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
        return .init(feedID: feedID, selected: selected, alternatives: ranked.dropFirst().map { variants[$0] },
                     reasons: reasons, uncertainty: uncertainty)
    }

    /// The variant `selection(for:context:)` would pick, without building
    /// its explanation; what a display pass over every feed needs.
    func selectedVariant(for feedID: String, context: SmartSportsSelectionContext = .init()) -> SmartSportsVariant? {
        guard let index = feedIndex[feedID] else { return nil }
        return selectedVariant(feedAt: index, context: context)
    }

    /// `selectedVariant(for:)` by position in `feeds`; no lookup, no heap.
    func selectedVariant(feedAt index: Int, context: SmartSportsSelectionContext = .init()) -> SmartSportsVariant? {
        withRankedVariants(feed: index, context: context) { ranked in
            ranked.first.map { feeds[index].variants[Int($0.offset)] }
        }
    }

    private func rankedVariants(feed index: Int, context: SmartSportsSelectionContext) -> [Int] {
        withRankedVariants(feed: index, context: context) { ranked in ranked.map { Int($0.offset) } }
    }

    /// One eligible candidate with everything its comparisons read.
    private struct RankedCandidate {
        var offset: Int32
        var failed: Bool
        var preferred: Bool
        var facts: VariantRankColumns.Facts
    }

    /// Eligible variants of one feed, best first, in a stack buffer. The
    /// comparator is the historical one over precomputed facts, and the
    /// standard library sort orders the buffer exactly as it ordered the
    /// variants themselves.
    private func withRankedVariants<R>(feed index: Int, context: SmartSportsSelectionContext,
                                       _ body: (UnsafeMutableBufferPointer<RankedCandidate>) -> R) -> R {
        let feed = feeds[index]
        let variants = feed.variants
        let base = Int(rank.feedStart[index])
        let now = context.now.timeIntervalSinceReferenceDate
        let usefulHeight = Int32(clamping: max(1, context.usefulHeight))
        let preferred = overrides.preferredVariants.isEmpty ? nil : overrides.preferredVariants[feed.id]
        return withUnsafeTemporaryAllocation(of: RankedCandidate.self, capacity: max(1, variants.count)) { buffer in
            var count = 0
            for offset in variants.indices where isEligible(variants[offset], ordinal: base + offset, context: context) {
                let failed = !context.recentFailedEndpoints.isEmpty && context.recentFailedEndpoints.contains(variants[offset].key)
                let isPreferred = preferred != nil && variants[offset].id == preferred
                (buffer.baseAddress! + count).initialize(to: RankedCandidate(
                    offset: Int32(offset), failed: failed, preferred: isPreferred,
                    facts: rank.facts(ordinal: base + offset, now: now, usefulHeight: usefulHeight)))
                count += 1
            }
            var ranked = UnsafeMutableBufferPointer(rebasing: buffer[0..<count])
            if count > 1 {
                ranked.sort { l, r in
                    if l.failed != r.failed { return !l.failed }
                    if l.preferred || r.preferred { return l.preferred }
                    return rank.ranksBefore(l.facts, r.facts, variants[Int(l.offset)].key, variants[Int(r.offset)].key)
                }
            }
            defer { ranked.deinitialize() }
            return body(ranked)
        }
    }

    /// Guide choice has no dependency on which endpoint won playback selection.
    /// Every bucket is passed using a source/native key and retains its raw times.
    func guideSelection(for feedID: String,
                        programs: [SmartSportsEndpointKey: [EPGProgram]],
                        now: Date = Date()) -> SmartSportsGuideSelection? {
        guard let index = feedIndex[feedID] else { return nil }
        let variants = feeds[index].variants
        let preferred = overrides.preferredGuides.isEmpty ? nil : overrides.preferredGuides[feedID]
        struct Candidate {
            let offset: Int
            let binding: SourceGuideBinding
            let rows: [EPGProgram]
            let isPreferred: Bool
            let current: Bool
            let upcoming: Int
        }
        let nowValue = now.timeIntervalSinceReferenceDate
        let horizon = now.addingTimeInterval(24 * 3600).timeIntervalSinceReferenceDate
        var candidates: [Candidate] = []
        for offset in variants.indices {
            guard let binding = variants[offset].guideBinding,
                  let rows = programs[variants[offset].key],
                  !Self.isSuspiciousGuideID(binding.epgChannelID) else { continue }
            let guide = Self.guideRows(rows, channelID: binding.epgChannelID, now: nowValue, horizon: horizon)
            guard !guide.rows.isEmpty else { continue }
            candidates.append(Candidate(offset: offset, binding: binding, rows: guide.rows,
                isPreferred: preferred != nil && variants[offset].id == preferred,
                current: guide.current, upcoming: guide.upcoming))
        }
        let best: Candidate?
        if candidates.count <= 1 {
            best = candidates.first
        } else {
            best = candidates.sorted { lhs, rhs in
                if lhs.isPreferred || rhs.isPreferred { return lhs.isPreferred }
                if lhs.current != rhs.current { return lhs.current }
                if lhs.upcoming != rhs.upcoming { return lhs.upcoming > rhs.upcoming }
                return Self.idPrecedes(variants[lhs.offset].key, variants[rhs.offset].key)
            }.first
        }
        guard let result = best else { return nil }
        let status = feeds[index].guideStatus
        return .init(key: variants[result.offset].key, binding: result.binding, programs: result.rows,
                     timingNeedsReview: status == "Timing review" || status == "Schedule review")
    }

    /// Valid rows for one guide ID in start order, plus whether one is on
    /// now and how many fall in the next day. Provider guides arrive valid
    /// and sorted, so that case shares the original storage in one pass.
    private static func guideRows(_ rows: [EPGProgram], channelID: String, now: Double, horizon: Double)
        -> (rows: [EPGProgram], current: Bool, upcoming: Int) {
        var current = false, upcoming = 0
        var previous = -Double.infinity
        var clean = true
        for row in rows {
            let start = row.start.timeIntervalSinceReferenceDate, end = row.end.timeIntervalSinceReferenceDate
            guard row.channelID == channelID, end > start, start.isFinite, end.isFinite,
                  hasVisibleText(row.title) else { clean = false; continue }
            if start < previous { clean = false }
            previous = start
            if start <= now && end > now { current = true }
            if end > now && start < horizon { upcoming += 1 }
        }
        if clean { return (rows, current, upcoming) }
        var matching: [EPGProgram] = []
        matching.reserveCapacity(rows.count)
        var ordered = true
        previous = -Double.infinity
        for row in rows {
            let start = row.start.timeIntervalSinceReferenceDate, end = row.end.timeIntervalSinceReferenceDate
            guard row.channelID == channelID, end > start, start.isFinite, end.isFinite,
                  hasVisibleText(row.title) else { continue }
            if start < previous { ordered = false }
            previous = start
            matching.append(row)
        }
        return (ordered ? matching : matching.sorted { $0.start < $1.start }, current, upcoming)
    }

    /// `!title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`.
    private static func hasVisibleText(_ title: String) -> Bool {
        let ascii = title.utf8.withContiguousStorageIfAvailable { bytes -> Bool? in
            for b in bytes {
                if b >= 0x80 { return nil }
                if !(b == 0x20 || (b >= 0x09 && b <= 0x0D)) { return true }
            }
            return false
        } ?? nil
        if let ascii { return ascii }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `lhs.rawValue < rhs.rawValue` without building either string: the
    /// lowercase UUID text is fixed-width, so it decides first.
    static func idPrecedes(_ lhs: SmartSportsEndpointKey, _ rhs: SmartSportsEndpointKey) -> Bool {
        if lhs.sourceID != rhs.sourceID {
            return lhs.sourceID.uuidString.lowercased() < rhs.sourceID.uuidString.lowercased()
        }
        return lhs.nativeID < rhs.nativeID
    }

    static func key(from rawValue: String) -> SmartSportsEndpointKey? {
        guard let separator = rawValue.firstIndex(of: "|"),
              let sourceID = UUID(uuidString: String(rawValue[..<separator])) else { return nil }
        let nativeID = String(rawValue[rawValue.index(after: separator)...])
        guard !nativeID.isEmpty else { return nil }
        return .init(sourceID: sourceID, nativeID: nativeID)
    }

    static func endpointFingerprint(for channel: Channel) -> String {
        HexDigest.string(SHA256.hash(data: Data(channel.streamURL.absoluteString.utf8)))
    }

    static func isSuspiciousGuideID(_ guideID: String) -> Bool {
        let ascii = guideID.utf8.withContiguousStorageIfAvailable { g -> Bool? in
            guard g.allSatisfy({ $0 < 0x80 && $0 != 0x0D }) else { return nil }
            return suspiciousASCII(g)
        } ?? nil
        if let ascii { return ascii }
        let id = guideID.lowercased()
        return id.hasSuffix(".bossdummy") || id.hasSuffix(".p13")
            || id.hasPrefix("dummy") || id.hasPrefix("event:") || id.hasPrefix("stan/event")
            || id.contains("bosssports.") || id.hasSuffix(".ncaabgames1")
            || hasVersionSuffix(id)
    }

    private static let suspiciousSuffixes = [".bossdummy", ".p13", ".ncaabgames1"].map { Array($0.utf8) }
    private static let suspiciousPrefixes = ["dummy", "event:", "stan/event"].map { Array($0.utf8) }
    private static let suspiciousInfix = Array("bosssports.".utf8)

    /// The same tests on lowercased ASCII bytes, without allocating.
    private static func suspiciousASCII(_ g: UnsafeBufferPointer<UInt8>) -> Bool {
        @inline(__always) func lower(_ b: UInt8) -> UInt8 { b >= 65 && b <= 90 ? b | 0x20 : b }
        @inline(__always) func matches(_ pattern: [UInt8], at offset: Int) -> Bool {
            guard offset >= 0, offset + pattern.count <= g.count else { return false }
            for k in 0..<pattern.count where lower(g[offset + k]) != pattern[k] { return false }
            return true
        }
        for suffix in suspiciousSuffixes where matches(suffix, at: g.count - suffix.count) { return true }
        for prefix in suspiciousPrefixes where matches(prefix, at: 0) { return true }
        if g.count >= suspiciousInfix.count {
            for offset in 0...(g.count - suspiciousInfix.count) where matches(suspiciousInfix, at: offset) { return true }
        }
        var i = g.count
        while i > 0, g[i - 1] >= 0x30, g[i - 1] <= 0x39 { i -= 1 }
        return i >= 2 && lower(g[i - 1]) == UInt8(ascii: "v") && g[i - 2] == UInt8(ascii: ".")
    }

    /// `range(of: "\\.v[0-9]*$", options: .regularExpression) != nil` without
    /// compiling a regex per call. Foundation anchors `$` at the very end.
    private static func hasVersionSuffix(_ id: String) -> Bool {
        var scalars = id.unicodeScalars.reversed().makeIterator()
        var next = scalars.next()
        while let digit = next, digit.value >= 0x30, digit.value <= 0x39 { next = scalars.next() }
        return next == "v" && scalars.next() == "."
    }

    private func isEligible(_ variant: SmartSportsVariant, ordinal: Int, context: SmartSportsSelectionContext) -> Bool {
        guard variant.isPlayable, let channel = variant.physicalChannel else { return false }
        if !context.unavailableSources.isEmpty, context.unavailableSources.contains(variant.key.sourceID) { return false }
        if !context.unavailableEndpoints.isEmpty, context.unavailableEndpoints.contains(variant.key) { return false }
        if rank.hasUsableFormat(ordinal: ordinal, now: context.now.timeIntervalSinceReferenceDate),
           let observation = variant.observation {
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
}

/// Ranking facts for every catalog variant as flat columns, one row per
/// variant in feed-major order. Built once per catalog; a selection reads a
/// handful of integers per candidate instead of unwrapping observations and
/// redoing date arithmetic in every comparison.
nonisolated struct VariantRankColumns: Sendable {
    /// Source ordinal in the upper 32 bits, catalog variant ordinal below,
    /// so source checks never dereference the variant.
    typealias Handle = UInt64

    /// Context-resolved facts for one candidate; sentinels mean unknown
    /// (delay/rate -1, motion/startup NaN, height 0).
    struct Facts {
        var reliability: Int8
        var delay: Int
        var motion: Double
        var height: Int
        var rate: Int
        var startup: Double
    }

    private static let observed: UInt8 = 1, countsForReliability: UInt8 = 2, legacy: UInt8 = 4

    private(set) var feedStart: [UInt32] = [0]
    private(set) var handles: [Handle] = []
    private var flags: [UInt8] = []
    private var observedAt: [Double] = []
    private var baseReliability: [Int8] = []
    private var delayBucket: [Int] = []
    private var motion: [Double] = []
    private var height: [Int] = []
    private var rateBucket: [Int] = []
    private var startup: [Double] = []

    init(feeds: [SmartSportsFeed]) {
        let total = feeds.reduce(0) { $0 + $1.variants.count }
        feedStart.reserveCapacity(feeds.count + 1)
        handles.reserveCapacity(total); flags.reserveCapacity(total); observedAt.reserveCapacity(total)
        baseReliability.reserveCapacity(total); delayBucket.reserveCapacity(total); motion.reserveCapacity(total)
        height.reserveCapacity(total); rateBucket.reserveCapacity(total); startup.reserveCapacity(total)
        var sourceOrdinals: [UUID: UInt64] = [:]
        for feed in feeds {
            for variant in feed.variants {
                let source: UInt64
                if let known = sourceOrdinals[variant.key.sourceID] { source = known } else {
                    source = UInt64(sourceOrdinals.count)
                    sourceOrdinals[variant.key.sourceID] = source
                }
                handles.append(source << 32 | UInt64(handles.count))
                guard let o = variant.observation else {
                    flags.append(0); observedAt.append(.nan); baseReliability.append(1)
                    delayBucket.append(-1); motion.append(.nan); height.append(0); rateBucket.append(-1); startup.append(.nan)
                    continue
                }
                var f = Self.observed
                if o.provenance != .formatProbe && o.provenance != .legacyCachedFormat { f |= Self.countsForReliability }
                if o.provenance == .legacyCachedFormat { f |= Self.legacy }
                flags.append(f)
                observedAt.append(o.observedAt.timeIntervalSinceReferenceDate)
                // `reliabilityClass` once freshness is established.
                var reliability: Int8 = 1
                if o.failures > 0 || o.stalledSeconds > 3 { reliability = 0 }
                else if let dropped = o.droppedFrames, let rendered = o.renderedFrames, rendered > 0,
                        Double(dropped) / Double(rendered) > 0.02 { reliability = 0 }
                else if o.provenance == .passivePlayback && o.playedSeconds >= 180 && o.stalledSeconds <= 0.5 { reliability = 2 }
                baseReliability.append(reliability)
                // Live delay in 3 s steps, bitrate in 2 Mb/s steps.
                delayBucket.append(o.liveDelaySeconds.flatMap { $0.isFinite && $0 >= 0 ? Int($0 / 3) : nil } ?? -1)
                motion.append(o.fps.flatMap { $0.isFinite && $0 > 0 ? min($0, 60) : nil } ?? .nan)
                height.append(o.height.flatMap { $0 > 0 ? $0 : nil } ?? 0)
                rateBucket.append(o.bitRate.flatMap { $0 > 0 ? Int(min($0, 40_000_000) / 2_000_000) : nil } ?? -1)
                startup.append(o.startupSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? .nan)
            }
            feedStart.append(UInt32(handles.count))
        }
    }

    @inline(__always) private static func fresh(_ age: Double, _ maximum: Double) -> Bool {
        age >= -60 && age <= maximum
    }

    /// Observation present, not legacy, and at most 14 days old.
    func hasUsableFormat(ordinal o: Int, now: Double) -> Bool {
        flags[o] & Self.observed != 0 && flags[o] & Self.legacy == 0 && Self.fresh(now - observedAt[o], 14 * 86400)
    }

    func facts(ordinal o: Int, now: Double, usefulHeight: Int32) -> Facts {
        var result = Facts(reliability: 1, delay: -1, motion: .nan, height: 0, rate: -1, startup: .nan)
        let f = flags[o]
        guard f & Self.observed != 0 else { return result }
        let age = now - observedAt[o]
        if f & Self.countsForReliability != 0 && Self.fresh(age, 24 * 3600) { result.reliability = baseReliability[o] }
        guard f & Self.legacy == 0, Self.fresh(age, 14 * 86400) else { return result }
        result.delay = delayBucket[o]
        result.motion = motion[o]
        result.height = height[o] > 0 ? min(height[o], Int(usefulHeight)) : 0
        result.rate = rateBucket[o]
        result.startup = startup[o]
        return result
    }

    /// Reliability, then a clearly closer live edge, motion, useful height,
    /// bitrate and startup; missing measurements never receive invented
    /// values, and the endpoint ID breaks ties.
    func ranksBefore(_ l: Facts, _ r: Facts, _ lk: SmartSportsEndpointKey, _ rk: SmartSportsEndpointKey) -> Bool {
        if l.reliability != r.reliability { return l.reliability > r.reliability }
        if l.delay >= 0, r.delay >= 0, l.delay != r.delay { return l.delay < r.delay }
        let lm = !l.motion.isNaN, rm = !r.motion.isNaN
        if lm != rm { return lm }
        if lm, l.motion != r.motion { return l.motion > r.motion }
        let lh = l.height > 0, rh = r.height > 0
        if lh != rh { return lh }
        if lh, l.height != r.height { return l.height > r.height }
        if l.rate >= 0, r.rate >= 0, l.rate != r.rate { return l.rate > r.rate }
        if !l.startup.isNaN, !r.startup.isNaN, l.startup != r.startup { return l.startup < r.startup }
        return SmartSportsCatalog.idPrecedes(lk, rk)
    }
}
