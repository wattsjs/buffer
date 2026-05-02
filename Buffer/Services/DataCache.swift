import Foundation
import CryptoKit

nonisolated enum DataCache {
    struct CachedChannels: Codable, Sendable {
        let savedAt: Date
        let channels: [Channel]
    }

    struct CachedPrograms: Codable, Sendable {
        let savedAt: Date
        let programs: [String: [EPGProgram]]
    }

    struct CachedProbes: Codable, Sendable {
        let savedAt: Date
        let probes: [String: StreamProbe]
    }

    struct CachedStreamSearchIndex: Codable, Sendable {
        let savedAt: Date
        let fingerprint: String
        let index: StreamSearchIndex
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
    private static let schemaVersion = "v2"

    nonisolated static func cacheKey(for config: ServerConfig) -> String {
        let raw: String
        switch config.type {
        case .xtream:
            raw = "xtream|\(config.xtreamBaseURL)|\(config.username)|\(schemaVersion)"
        case .m3u:
            let m3uKey = cacheInput(for: config.m3uSourceURL, fallback: config.m3uURL)
            let epgKey = cacheInput(for: config.epgSourceURL, fallback: config.epgURL)
            raw = "m3u|\(m3uKey)|\(epgKey)|\(schemaVersion)"
        }
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

    nonisolated private static func probesURL(for key: String) -> URL? {
        cacheDirectory()?.appendingPathComponent("probes_\(key).json")
    }

    nonisolated private static func streamSearchIndexURL(for key: String) -> URL? {
        cacheDirectory()?.appendingPathComponent("sports_index_\(key).plist")
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

    // MARK: - Sports stream search index

    nonisolated static func streamSearchIndexFingerprint(
        channels: [Channel],
        programs: [String: [EPGProgram]],
        hiddenGroups: Set<String>
    ) -> String {
        var hasher = SHA256()

        func update(_ value: String) {
            hasher.update(data: Data(value.utf8))
            hasher.update(data: Data([0]))
        }

        update("sports-index-v1")
        update(String(channels.count))
        for channel in channels.sorted(by: { $0.id < $1.id }) {
            update(channel.id)
            update(channel.name)
            update(channel.group)
            update(channel.epgChannelID ?? "")
        }

        update(String(hiddenGroups.count))
        for group in hiddenGroups.sorted() {
            update(group)
        }

        update(String(programs.count))
        for key in programs.keys.sorted() {
            update(key)
            let list = programs[key] ?? []
            update(String(list.count))
            for program in list {
                update(program.id)
                update(program.channelID)
                update(String(program.start.timeIntervalSince1970))
                update(String(program.end.timeIntervalSince1970))
                update(program.title)
                update(program.description)
            }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func loadStreamSearchIndex(
        key: String,
        fingerprint: String,
        maxAge: TimeInterval = 6 * 3600,
        now: Date = Date()
    ) -> StreamSearchIndex? {
        purgeExpiredStreamSearchIndexCaches(now: now)

        guard let url = streamSearchIndexURL(for: key),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let payload = try? PropertyListDecoder.cacheDecoder.decode(
                CachedStreamSearchIndex.self,
                from: data
              ),
              payload.fingerprint == fingerprint,
              now.timeIntervalSince(payload.savedAt) <= maxAge,
              let latestEnd = payload.index.latestProgramEnd,
              latestEnd > now.addingTimeInterval(-3600),
              !payload.index.entries.isEmpty,
              payload.index.epgTitleCount > 0
        else {
            return nil
        }

        return payload.index
    }

    nonisolated static func saveStreamSearchIndex(
        _ index: StreamSearchIndex,
        key: String,
        fingerprint: String
    ) {
        guard let url = streamSearchIndexURL(for: key),
              !index.entries.isEmpty,
              index.epgTitleCount > 0
        else { return }

        let payload = CachedStreamSearchIndex(
            savedAt: Date(),
            fingerprint: fingerprint,
            index: index
        )
        if let data = try? PropertyListEncoder.cacheEncoder.encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
        purgeExpiredStreamSearchIndexCaches()
    }

    nonisolated static func purgeExpiredStreamSearchIndexCaches(
        olderThan maxAge: TimeInterval = 24 * 3600,
        now: Date = Date()
    ) {
        guard let dir = cacheDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              )
        else { return }

        for url in files where url.lastPathComponent.hasPrefix("sports_index_") {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > maxAge {
                try? FileManager.default.removeItem(at: url)
            }
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

private extension PropertyListEncoder {
    nonisolated static let cacheEncoder: PropertyListEncoder = {
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        return e
    }()
}

private extension PropertyListDecoder {
    nonisolated static let cacheDecoder = PropertyListDecoder()
}
