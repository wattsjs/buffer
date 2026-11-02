import CryptoKit
import Synchronization
import Foundation

nonisolated enum DataCache {
    // Enqueue snapshots at publication time. A detached task per write can
    // reach disk out of order and replace a fresh snapshot with an older one.
    private static let writeQueue = DispatchQueue(label: "com.wattsjs.buffer.cache-writes", qos: .utility)

    static func enqueueSaveChannels(_ channels: [Channel], key: String) {
        writeQueue.async { saveChannels(channels, key: key) }
    }

    // Guide snapshots are large (~100 MB of JSON, 0.6-2 s to encode) and are
    // published every few seconds while history loads. Writes are throttled
    // per key: at most one encode per interval, always of the newest snapshot.
    private struct ProgramWrites {
        var pending: [String: [String: [EPGProgram]]] = [:]
        var lastWriteAt: [String: DispatchTime] = [:]
    }
    private static let programWrites = Mutex(ProgramWrites())
    private static let programsWriteDelay: TimeInterval = 3
    private static let programsWriteInterval: TimeInterval = 20

    static func enqueueSavePrograms(_ programs: [String: [EPGProgram]], key: String) {
        let delay: TimeInterval? = programWrites.withLock { state in
            defer { state.pending[key] = programs }
            guard state.pending[key] == nil else { return nil }
            guard let last = state.lastWriteAt[key] else { return programsWriteDelay }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- last.uptimeNanoseconds) / 1_000_000_000
            return max(programsWriteDelay, programsWriteInterval - elapsed)
        }
        guard let delay else {
            PerfMetrics.shared.increment("cache.programs.coalescedWrites")
            return
        }
        writeQueue.asyncAfter(deadline: .now() + delay) {
            drainPendingPrograms(key: key)
        }
    }

    private static func drainPendingPrograms(key: String) {
        let latest = programWrites.withLock { state -> [String: [EPGProgram]]? in
            guard let latest = state.pending.removeValue(forKey: key) else { return nil }
            state.lastWriteAt[key] = .now()
            return latest
        }
        guard let latest else { return }
        savePrograms(latest, key: key)
    }

    static func enqueueSaveVODItems(_ items: [VODItem], key: String) {
        writeQueue.async { saveVODItems(items, key: key) }
    }

    static func enqueueSaveVODSeries(_ series: [VODSeries], key: String) {
        writeQueue.async { saveVODSeries(series, key: key) }
    }

    /// Flushes previously submitted writes. Never call from a UI path; used
    /// by persistence regression checks and explicit shutdown tools only.
    static func flushPendingWrites() {
        writeQueue.sync {
            // Delayed guide writes are not on the queue yet; write them now.
            for key in programWrites.withLock({ Array($0.pending.keys) }) { drainPendingPrograms(key: key) }
        }
    }
    struct CachedChannels: Codable, Sendable {
        let savedAt: Date
        let channels: [Channel]
    }

    struct CachedPrograms: Codable, Sendable {
        let savedAt: Date
        let programs: [String: [EPGProgram]]
    }

    struct CachedVODItems: Codable, Sendable {
        let savedAt: Date
        let items: [VODItem]
    }

    struct CachedVODSeries: Codable, Sendable {
        let savedAt: Date
        let series: [VODSeries]
    }

    struct CachedProbes: Codable, Sendable {
        let savedAt: Date
        let probes: [String: StreamProbe]
    }

    nonisolated private static func cacheDirectory() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("buffer", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // Bumped when Channel/EPGProgram layouts change so old on-disk caches
    // don't silently hide newly-parsed fields (e.g. catchup support).
    private static let schemaVersion = "v8"
    private static let legacySchemaVersions = ["v7", "v6", "v5", "v4", "v3", "v2", "v1"]

    nonisolated static func cacheKey(for config: ServerConfig) -> String {
        cacheKey(for: config, schemaVersion: schemaVersion)
    }

    nonisolated static func preferenceKey(for config: ServerConfig) -> String {
        digestKey("prefs|\(sourceIdentity(for: config))")
    }

    nonisolated static func legacyCacheKeys(for config: ServerConfig) -> [String] {
        // Legacy keys are used for preferences/probe metadata migration only.
        // Content hydration reads the primary key so obsolete authenticated
        // URLs or a previous custom guide cannot return after relaunch.
        [cacheKey(for: config)] + legacySchemaVersions.map {
            digestKey("\(sourceIdentity(for: config))|\($0)")
        }
    }

    nonisolated private static func cacheKey(for config: ServerConfig, schemaVersion: String) -> String {
        // A structured identity avoids delimiter ambiguity. Secrets enter
        // only the digest input; neither filenames nor reports contain them.
        var fields = [schemaVersion, config.type.rawValue]
        switch config.type {
        case .xtream:
            fields += [config.xtreamBaseURL, config.username, config.password,
                       cacheInput(for: config.epgSourceURL, fallback: config.epgURL)]
        case .stalker:
            fields += [config.stalkerRootBaseURL, config.stalkerMACAddress, config.password,
                       cacheInput(for: config.epgSourceURL, fallback: config.epgURL)]
        case .m3u:
            fields += [cacheInput(for: config.m3uSourceURL, fallback: config.m3uURL),
                       cacheInput(for: config.epgSourceURL, fallback: config.epgURL)]
        }
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    nonisolated private static func sourceIdentity(for config: ServerConfig) -> String {
        let raw: String
        switch config.type {
        case .xtream:
            raw = "xtream|\(config.xtreamBaseURL)|\(config.username)"
        case .stalker:
            raw = "stalker|\(config.stalkerRootBaseURL)|\(config.stalkerMACAddress)"
        case .m3u:
            let m3uKey = cacheInput(for: config.m3uSourceURL, fallback: config.m3uURL)
            let epgKey = cacheInput(for: config.epgSourceURL, fallback: config.epgURL)
            raw = "m3u|\(m3uKey)|\(epgKey)"
        }
        return raw
    }

    nonisolated private static func digestKey(_ raw: String) -> String {
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    nonisolated private static func cacheInput(for url: URL?, fallback: String) -> String {
        guard let url else { return fallback }
        if url.isFileURL {
            return url.standardizedFileURL.path
        }
        return url.absoluteString
    }

    nonisolated private static func channelsURL(for key: String) -> URL? {
        cacheDirectory()?.appendingPathComponent("channels_\(key).json")
    }

    nonisolated private static func programsURL(for key: String) -> URL? {
        cacheDirectory()?.appendingPathComponent("programs_\(key).json")
    }

    nonisolated private static func vodURL(for key: String) -> URL? {
        cacheDirectory()?.appendingPathComponent("vod_\(key).json")
    }

    nonisolated private static func vodSeriesURL(for key: String) -> URL? {
        cacheDirectory()?.appendingPathComponent("vod_series_\(key).json")
    }

    nonisolated private static func probesURL(for key: String) -> URL? {
        cacheDirectory()?.appendingPathComponent("probes_\(key).json")
    }

    // MARK: - Channels

    nonisolated static func loadChannels(key: String) -> CachedChannels? {
        guard let url = channelsURL(for: key),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return measuredDecode(CachedChannels.self, from: data, slot: "channels")
    }

    nonisolated static func saveChannels(_ channels: [Channel], key: String) {
        guard let url = channelsURL(for: key) else { return }
        let payload = CachedChannels(savedAt: Date(), channels: channels)
        measuredWrite(payload, to: url)
    }

    // MARK: - Programs

    nonisolated static func loadPrograms(key: String) -> CachedPrograms? {
        guard let url = programsURL(for: key),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return measuredDecode(CachedPrograms.self, from: data, slot: "programs")
    }

    nonisolated static func savePrograms(_ programs: [String: [EPGProgram]], key: String) {
        guard let url = programsURL(for: key) else { return }
        let payload = CachedPrograms(savedAt: Date(), programs: programs)
        measuredWrite(payload, to: url)
    }

    // MARK: - VOD

    nonisolated static func loadVODItems(key: String) -> CachedVODItems? {
        guard let url = vodURL(for: key),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return measuredDecode(CachedVODItems.self, from: data, slot: "voditems")
    }

    nonisolated static func saveVODItems(_ items: [VODItem], key: String) {
        guard let url = vodURL(for: key) else { return }
        let payload = CachedVODItems(savedAt: Date(), items: items)
        measuredWrite(payload, to: url)
    }

    nonisolated static func loadVODSeries(key: String) -> CachedVODSeries? {
        guard let url = vodSeriesURL(for: key),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return measuredDecode(CachedVODSeries.self, from: data, slot: "vodseries")
    }

    nonisolated static func saveVODSeries(_ series: [VODSeries], key: String) {
        guard let url = vodSeriesURL(for: key) else { return }
        let payload = CachedVODSeries(savedAt: Date(), series: series)
        measuredWrite(payload, to: url)
    }

    // MARK: - Stream probes

    nonisolated static func loadProbes(key: String) -> CachedProbes? {
        guard let url = probesURL(for: key),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return measuredDecode(CachedProbes.self, from: data, slot: "probes")
    }

    nonisolated static func saveProbes(_ probes: [String: StreamProbe], key: String) {
        guard let url = probesURL(for: key) else { return }
        let payload = CachedProbes(savedAt: Date(), probes: probes)
        measuredWrite(payload, to: url)
    }
}

extension DataCache {
    nonisolated private static func measuredDecode<T: Decodable>(_ type: T.Type, from data: Data, slot: String) -> T? {
        let started = ContinuousClock.now
        let value = try? JSONDecoder.cacheDecoder.decode(type, from: data)
        PerfMetrics.shared.record("cache.\(slot).decodeMs", since: started)
        PerfMetrics.shared.record("cache.\(slot).readMB", Double(data.count) / 1_048_576)
        return value
    }

    nonisolated private static func measuredWrite<T: Encodable>(_ payload: T, to url: URL) {
        let slot = url.deletingPathExtension().lastPathComponent.split(separator: "_").dropLast().joined(separator: "_")
        let started = ContinuousClock.now
        guard let data = try? JSONEncoder.cacheEncoder.encode(payload) else { return }
        let encodedAt = ContinuousClock.now
        try? data.write(to: url, options: .atomic)
        PerfMetrics.shared.record("cache.\(slot).encodeMs", PerfMetrics.milliseconds(since: started, now: encodedAt))
        PerfMetrics.shared.record("cache.\(slot).writeMs", since: encodedAt)
        PerfMetrics.shared.record("cache.\(slot).writeMB", Double(data.count) / 1_048_576)
    }
}

private extension JSONEncoder {
    nonisolated static var cacheEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}

private extension JSONDecoder {
    nonisolated static var cacheDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
