// Platform dependencies are isolated so integration tests cannot access the
// user's saved accounts, keychain, stream probes or cache files. Sync logic,
// clients and playlist/guide parsers are the actual production source files.
import CryptoKit
import Foundation

nonisolated enum PerformanceBenchmark { static let shouldRun = !CommandLine.arguments.contains("--test-bootstrap") }
nonisolated enum PlaybackValidation { static let isEnabled = false }
@MainActor final class AppLifecycleCoordinator {
    static let shared = AppLifecycleCoordinator()
    var shouldPauseBackgroundWork = false
}
@MainActor final class StreamProbeService {
    static let shared = StreamProbeService()
    func setActiveCacheKey(_ key: String, legacyKeys: [String], sourceID: UUID? = nil) {}
    func registerSourceCacheKey(sourceID: UUID, cacheKey: String) {}
    func probe(for channel: Channel) -> StreamProbe? { nil }
    var version: Int { 0 }
    func requestProbe(for channel: Channel, priority: TaskPriority = .utility) {}
    func retryQueuedProbes() {}
    var onCapacityStatusStale: (@MainActor (SourceAccountKey) -> Void)?
}
@MainActor final class PlayerSlot {
    func configureLiveAlternatives(_ channels: [Channel], resolver: ((SourceChannelIdentity) -> Channel?)? = nil) {}
    let channel: Channel
    init(channel: Channel) { self.channel = channel }
}
@MainActor final class PlayerSessionRegistry {
    static let shared = PlayerSessionRegistry()
    func channel(matching channel: Channel) -> Channel? { nil }
}
struct AppFeedbackMessage {
    enum Tone { case warning }
    init(title: String, message: String, symbol: String, tone: Tone, showsActivity: Bool) {}
}
@MainActor final class AppFeedbackCenter {
    static let shared = AppFeedbackCenter()
    func show(_ message: AppFeedbackMessage) {}
}
@MainActor final class NotificationManager {
    static let shared = NotificationManager()
    func cancelReminders(forPlaylistID: UUID) {}
}
nonisolated enum ServerPasswordStore {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var passwords: [UUID: String] = [:]
        var delays: [UUID: TimeInterval] = [:]
        var writeCounts: [UUID: Int] = [:]
        var writeFailures: Set<UUID> = []
    }
    private static let storage = Storage()
    private static let ioQueue = DispatchQueue(label: "buffer.test.keychain")
    static func configure(for id: UUID, password: String?, delay: TimeInterval, saveSucceeds: Bool = true) {
        storage.lock.withLock {
            storage.passwords[id] = password
            storage.delays[id] = delay
            if !saveSucceeds { storage.writeFailures.insert(id) }
        }
    }
    static func writeCount(for id: UUID) -> Int { storage.lock.withLock { storage.writeCounts[id] ?? 0 } }
    static func savePassword(_ password: String, for id: UUID) -> Bool {
        storage.lock.withLock {
            guard !storage.writeFailures.contains(id) else { return false }
            storage.passwords[id] = password
            storage.writeCounts[id, default: 0] += 1
            return true
        }
    }
    static func deletePassword(for id: UUID) -> Bool { true }
    static func loadPassword(for id: UUID) -> String? {
        let (password, delay) = storage.lock.withLock { (storage.passwords[id], storage.delays[id] ?? 0) }
        Thread.sleep(forTimeInterval: delay)
        return password
    }
    static func loadPasswordAsync(for id: UUID) async -> String? {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: loadPassword(for: id)) }
        }
    }
    static func savePasswordAsync(_ password: String, for id: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: savePassword(password, for: id)) }
        }
    }
    static func deletePasswordAsync(for id: UUID) async -> Bool { deletePassword(for: id) }
}
nonisolated struct ProgramSearchEntry: Sendable {
    let id: String
    let epgID: String
    let programIndex: Int
    let channelID: String
    let titleLower: String
    let start: Date
    let end: Date
}
nonisolated enum DataCache {
    struct CachedChannels: Sendable { let savedAt: Date; let channels: [Channel] }
    struct CachedPrograms: Sendable { let savedAt: Date; let programs: [String: [EPGProgram]] }
    struct CachedVODItems: Sendable { let savedAt: Date; let items: [VODItem] }
    struct CachedVODSeries: Sendable { let savedAt: Date; let series: [VODSeries] }
    // The test cache can intentionally block a disk read after it captured old
    // data, reproducing the main-actor reentrancy race on a source switch.
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var channels: [String: CachedChannels] = [:]
        var programs: [String: CachedPrograms] = [:]
        var items: [String: CachedVODItems] = [:]
        var series: [String: CachedVODSeries] = [:]
        var delayedKey: String?
        var channelReads: [String: Int] = [:]
        var itemReads: [String: Int] = [:]
        var seriesReads: [String: Int] = [:]
        var delayedVODKey: String?
    }
    private static let storage = Storage()
    static func cacheKey(for config: ServerConfig) -> String {
        let fields = ["v8", config.type.rawValue, config.xtreamBaseURL, config.username, config.password,
                      cacheInput(for: config.m3uSourceURL, fallback: config.m3uURL),
                      cacheInput(for: config.epgSourceURL, fallback: config.epgURL)]
        return digestKey((try? JSONEncoder().encode(fields)) ?? Data())
    }
    static func preferenceKey(for config: ServerConfig) -> String {
        digestKey(Data("prefs|\(sourceIdentity(for: config))".utf8))
    }
    static func legacyCacheKeys(for config: ServerConfig) -> [String] {
        [cacheKey(for: config)] + ["v7", "v6", "v5", "v4", "v3", "v2", "v1"].map {
            digestKey(Data("\(sourceIdentity(for: config))|\($0)".utf8))
        }
    }
    private static func sourceIdentity(for config: ServerConfig) -> String {
        switch config.type {
        case .xtream: return "xtream|\(config.xtreamBaseURL)|\(config.username)"
        case .stalker: return "stalker|\(config.stalkerRootBaseURL)|\(config.stalkerMACAddress)"
        case .m3u: return "m3u|\(cacheInput(for: config.m3uSourceURL, fallback: config.m3uURL))|\(cacheInput(for: config.epgSourceURL, fallback: config.epgURL))"
        }
    }
    private static func cacheInput(for url: URL?, fallback: String) -> String {
        guard let url else { return fallback }
        return url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }
    private static func digestKey(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
    static func delayReads(for key: String) { storage.lock.withLock { storage.delayedKey = key } }
    static func channelReadCount(for key: String) -> Int { storage.lock.withLock { storage.channelReads[key] ?? 0 } }
    static func itemReadCount(for key: String) -> Int { storage.lock.withLock { storage.itemReads[key] ?? 0 } }
    static func seriesReadCount(for key: String) -> Int { storage.lock.withLock { storage.seriesReads[key] ?? 0 } }
    static func delayVODReads(for key: String) { storage.lock.withLock { storage.delayedVODKey = key } }
    static func loadChannels(key: String) -> CachedChannels? {
        let (result, delay) = storage.lock.withLock {
            storage.channelReads[key, default: 0] += 1
            return (storage.channels[key], storage.delayedKey == key)
        }
        if delay { Thread.sleep(forTimeInterval: 0.4) }
        return result
    }
    static func loadPrograms(key: String) -> CachedPrograms? { storage.lock.withLock { storage.programs[key] } }
    static func loadVODItems(key: String) -> CachedVODItems? {
        let (result, delay) = storage.lock.withLock {
            storage.itemReads[key, default: 0] += 1
            return (storage.items[key], storage.delayedVODKey == key)
        }
        if delay { Thread.sleep(forTimeInterval: 0.4) }
        return result
    }
    static func loadVODSeries(key: String) -> CachedVODSeries? {
        storage.lock.withLock {
            storage.seriesReads[key, default: 0] += 1
            return storage.series[key]
        }
    }
    static func saveChannels(_ channels: [Channel], key: String) {
        storage.lock.withLock { storage.channels[key] = CachedChannels(savedAt: .now, channels: channels) }
    }
    static func savePrograms(_ programs: [String: [EPGProgram]], key: String) {
        storage.lock.withLock { storage.programs[key] = CachedPrograms(savedAt: .now, programs: programs) }
    }
    static func saveVODItems(_ items: [VODItem], key: String) {
        storage.lock.withLock { storage.items[key] = CachedVODItems(savedAt: .now, items: items) }
    }
    static func saveVODSeries(_ series: [VODSeries], key: String) {
        storage.lock.withLock { storage.series[key] = CachedVODSeries(savedAt: .now, series: series) }
    }
    static func enqueueSaveChannels(_ channels: [Channel], key: String) { saveChannels(channels, key: key) }
    static func flushPendingWrites() {}
    static func enqueueSavePrograms(_ programs: [String: [EPGProgram]], key: String) { savePrograms(programs, key: key) }
    static func enqueueSaveVODItems(_ items: [VODItem], key: String) { saveVODItems(items, key: key) }
    static func enqueueSaveVODSeries(_ series: [VODSeries], key: String) { saveVODSeries(series, key: key) }
}
