import CryptoKit
import Foundation

nonisolated enum DataCache {
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
    private static let schemaVersion = "v6"
    private static let legacySchemaVersions = ["v5", "v4", "v3", "v2", "v1"]

    nonisolated static func cacheKey(for config: ServerConfig) -> String {
        cacheKey(for: config, schemaVersion: schemaVersion)
    }

    nonisolated static func preferenceKey(for config: ServerConfig) -> String {
        digestKey("prefs|\(sourceIdentity(for: config))")
    }

    nonisolated static func legacyCacheKeys(for config: ServerConfig) -> [String] {
        [cacheKey(for: config)] + legacySchemaVersions.map { cacheKey(for: config, schemaVersion: $0) }
    }

    nonisolated private static func cacheKey(for config: ServerConfig, schemaVersion: String) -> String {
        digestKey("\(sourceIdentity(for: config))|\(schemaVersion)")
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
        return try? JSONDecoder.cacheDecoder.decode(CachedChannels.self, from: data)
    }

    nonisolated static func saveChannels(_ channels: [Channel], key: String) {
        guard let url = channelsURL(for: key) else { return }
        let payload = CachedChannels(savedAt: Date(), channels: channels)
        if let data = try? JSONEncoder.cacheEncoder.encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Programs

    nonisolated static func loadPrograms(key: String) -> CachedPrograms? {
        guard let url = programsURL(for: key),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? JSONDecoder.cacheDecoder.decode(CachedPrograms.self, from: data)
    }

    nonisolated static func savePrograms(_ programs: [String: [EPGProgram]], key: String) {
        guard let url = programsURL(for: key) else { return }
        let payload = CachedPrograms(savedAt: Date(), programs: programs)
        if let data = try? JSONEncoder.cacheEncoder.encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - VOD

    nonisolated static func loadVODItems(key: String) -> CachedVODItems? {
        guard let url = vodURL(for: key),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? JSONDecoder.cacheDecoder.decode(CachedVODItems.self, from: data)
    }

    nonisolated static func saveVODItems(_ items: [VODItem], key: String) {
        guard let url = vodURL(for: key) else { return }
        let payload = CachedVODItems(savedAt: Date(), items: items)
        if let data = try? JSONEncoder.cacheEncoder.encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    nonisolated static func loadVODSeries(key: String) -> CachedVODSeries? {
        guard let url = vodSeriesURL(for: key),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? JSONDecoder.cacheDecoder.decode(CachedVODSeries.self, from: data)
    }

    nonisolated static func saveVODSeries(_ series: [VODSeries], key: String) {
        guard let url = vodSeriesURL(for: key) else { return }
        let payload = CachedVODSeries(savedAt: Date(), series: series)
        if let data = try? JSONEncoder.cacheEncoder.encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Stream probes

    nonisolated static func loadProbes(key: String) -> CachedProbes? {
        guard let url = probesURL(for: key),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? JSONDecoder.cacheDecoder.decode(CachedProbes.self, from: data)
    }

    nonisolated static func saveProbes(_ probes: [String: StreamProbe], key: String) {
        guard let url = probesURL(for: key) else { return }
        let payload = CachedProbes(savedAt: Date(), probes: probes)
        if let data = try? JSONEncoder.cacheEncoder.encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

private extension JSONEncoder {
    nonisolated static let cacheEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
}

private extension JSONDecoder {
    nonisolated static let cacheDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
