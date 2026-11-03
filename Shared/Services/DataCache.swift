import CryptoKit
import Synchronization
import Foundation
import OSLog

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
        let override = ProcessInfo.processInfo.environment["BUFFER_CACHE_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        guard let base = override ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
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

    /// Columnar, memory-mappable slots (see `ColumnarCache`).
    nonisolated private static func channelsURL(for key: String) -> URL? {
        cacheDirectory()?.appendingPathComponent("channels_\(key).bin")
    }

    nonisolated private static func programsURL(for key: String) -> URL? {
        cacheDirectory()?.appendingPathComponent("programs_\(key).bin")
    }

    /// Pre-columnar JSON slots: read once when no columnar file exists yet
    /// (provider data is never re-fetched just because the format changed),
    /// and removed by the first columnar write.
    nonisolated private static func legacyChannelsURL(for key: String) -> URL? {
        cacheDirectory()?.appendingPathComponent("channels_\(key).json")
    }

    nonisolated private static func legacyProgramsURL(for key: String) -> URL? {
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
        if let url = channelsURL(for: key), let data = try? Data(contentsOf: url, options: .alwaysMapped) {
            return measuredColumnarDecode(data, slot: "channels", ColumnarCache.decodeChannels)
        }
        guard let url = legacyChannelsURL(for: key),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return measuredDecode(CachedChannels.self, from: data, slot: "channels")
    }

    nonisolated static func saveChannels(_ channels: [Channel], key: String) {
        guard let url = channelsURL(for: key) else { return }
        let started = ContinuousClock.now
        let bytes = ColumnarCache.encodeChannels(channels, savedAt: Date())
        measuredColumnarWrite(bytes, to: url, slot: "channels", started: started, legacy: legacyChannelsURL(for: key))
    }

    // MARK: - Programs

    nonisolated static func loadPrograms(key: String) -> CachedPrograms? {
        loadPrograms(key: key, retaining: nil)
    }

    /// Loads the guide with retention applied during decode; equal to
    /// `GuideHistory.prune` over `loadPrograms(key:)` but without
    /// materializing expired or unretained listings.
    nonisolated static func loadPrograms(key: String, retaining policy: EPGProgram.RetentionPolicy?) -> CachedPrograms? {
        if let url = programsURL(for: key), let data = try? Data(contentsOf: url, options: .alwaysMapped) {
            return measuredColumnarDecode(data, slot: "programs") { ColumnarCache.decodePrograms($0, policy: policy) }
        }
        guard let url = legacyProgramsURL(for: key),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let cached = measuredDecode(CachedPrograms.self, from: data, slot: "programs") else { return nil }
        guard let policy else { return cached }
        var retained: [String: [EPGProgram]] = [:]
        for (id, earliest) in policy.starts {
            let list = policy.normalize(cached.programs[id] ?? [], earliest)
            if !list.isEmpty { retained[id] = list }
        }
        return CachedPrograms(savedAt: cached.savedAt, programs: retained)
    }

    nonisolated static func savePrograms(_ programs: [String: [EPGProgram]], key: String) {
        guard let url = programsURL(for: key) else { return }
        let started = ContinuousClock.now
        let bytes = ColumnarCache.encodePrograms(programs, savedAt: Date())
        measuredColumnarWrite(bytes, to: url, slot: "programs", started: started, legacy: legacyProgramsURL(for: key))
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
        guard data.withUnsafeBytes({ ColumnarCache.writeAtomically($0, to: url) }) else { return }
        PerfMetrics.shared.record("cache.\(slot).encodeMs", PerfMetrics.milliseconds(since: started, now: encodedAt))
        PerfMetrics.shared.record("cache.\(slot).writeMs", since: encodedAt)
        PerfMetrics.shared.record("cache.\(slot).writeMB", Double(data.count) / 1_048_576)
    }

    nonisolated private static func measuredColumnarDecode<T>(_ data: Data, slot: String, _ decode: (UnsafeRawBufferPointer) -> T?) -> T? {
        let started = ContinuousClock.now
        let value = data.withUnsafeBytes(decode)
        PerfMetrics.shared.record("cache.\(slot).decodeMs", since: started)
        PerfMetrics.shared.record("cache.\(slot).readMB", Double(data.count) / 1_048_576)
        if value == nil { AppLog.sync.error("Columnar cache rejected slot=\(slot, privacy: .public) bytes=\(data.count, privacy: .public)") }
        return value
    }

    nonisolated private static func measuredColumnarWrite(_ bytes: [UInt8]?, to url: URL, slot: String,
                                                          started: ContinuousClock.Instant, legacy: URL?) {
        guard let bytes else { return }
        let encodedAt = ContinuousClock.now
        guard ColumnarCache.writeAtomically(bytes, to: url) else { return }
        if let legacy { try? FileManager.default.removeItem(at: legacy) }
        PerfMetrics.shared.record("cache.\(slot).encodeMs", PerfMetrics.milliseconds(since: started, now: encodedAt))
        PerfMetrics.shared.record("cache.\(slot).writeMs", since: encodedAt)
        PerfMetrics.shared.record("cache.\(slot).writeMB", Double(bytes.count) / 1_048_576)
    }
}

/// Binary, little-endian, memory-mappable layout for the two largest cache
/// slots. Each file is a 64-byte header followed by 8-byte-aligned sections:
///
///     header   magic, version, savedAt, row/key/string/exception counts,
///              blob length, total length
///     strings  UInt32 offsets[stringCount + 1] + UTF-8 blob; every text
///              field is interned once and referenced by a UInt32 ID
///     columns  one contiguous array per field (structure of arrays)
///
/// Programmes: run keys UInt32[k], run offsets UInt32[k + 1] (a channel's
/// listings are the contiguous range `[offsets[i], offsets[i + 1])`),
/// start/end Int32 seconds from `EPGProgram.columnEpoch`, title,
/// description, ID and channel-ID string IDs, then exact `Date` values for
/// the rare listings whose times are not whole in-range seconds.
/// `none` marks an absent optional, an ID of the form `<channel>_<start>`,
/// or a channel ID equal to the run key.
///
/// Loading maps the file, validates every offset and ID while it builds the
/// façade values, and rejects the whole file on any inconsistency.
nonisolated enum ColumnarCache {
    private struct UncheckedSendable<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    static let programsMagic: UInt32 = 0x5250_4742 // "BGPR"
    static let channelsMagic: UInt32 = 0x4843_4742 // "BGCH"
    static let version: UInt32 = 1
    static let headerSize = 64
    static let none: UInt32 = .max

    // MARK: Writing

    private struct StringTable {
        var ids: [String: UInt32] = [:]
        var offsets: [UInt32] = [0]
        var blob: [UInt8] = []
        var overflow = false

        mutating func intern(_ string: String) -> UInt32 {
            if let id = ids[string] { return id }
            let id = UInt32(truncatingIfNeeded: offsets.count - 1)
            blob.append(contentsOf: string.utf8)
            guard blob.count < Int(UInt32.max), offsets.count < Int(UInt32.max) - 1 else {
                overflow = true
                return 0
            }
            offsets.append(UInt32(blob.count))
            ids[string] = id
            return id
        }

        mutating func intern(_ string: String?) -> UInt32 {
            string.map { intern($0) } ?? ColumnarCache.none
        }
    }

    private struct Writer {
        var bytes: [UInt8] = []

        mutating func align() {
            while bytes.count % 8 != 0 { bytes.append(0) }
        }

        mutating func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }

        mutating func append<T: FixedWidthInteger>(column: [T]) {
            align()
            #if _endian(little)
            column.withUnsafeBytes { bytes.append(contentsOf: $0) }
            #else
            for value in column { append(value) }
            #endif
        }

        mutating func append(strings table: StringTable) {
            append(column: table.offsets)
            align()
            bytes.append(contentsOf: table.blob)
        }

        mutating func header(magic: UInt32, savedAt: Date, rows: Int, keys: Int, strings: Int,
                             exceptions: Int, blobLength: Int) {
            append(magic)
            append(ColumnarCache.version)
            append(savedAt.timeIntervalSinceReferenceDate.bitPattern)
            append(UInt32(rows))
            append(UInt32(keys))
            append(UInt32(strings))
            append(UInt32(exceptions))
            append(UInt64(blobLength))
            append(UInt64(0)) // total length, patched in `finish`
            while bytes.count < ColumnarCache.headerSize { bytes.append(0) }
        }

        mutating func finish() -> [UInt8] {
            align()
            let total = UInt64(bytes.count).littleEndian
            withUnsafeBytes(of: total) { bytes.replaceSubrange(40..<48, with: $0) }
            return bytes
        }
    }

    static func encodePrograms(_ programs: [String: [EPGProgram]], savedAt: Date) -> [UInt8]? {
        var table = StringTable()
        let total = programs.values.reduce(0) { $0 + $1.count }
        guard total < Int(UInt32.max) else { return nil }
        var keys: [UInt32] = [], runOffsets: [UInt32] = [0]
        keys.reserveCapacity(programs.count)
        runOffsets.reserveCapacity(programs.count + 1)
        var starts = [Int32](), ends = [Int32](), titles = [UInt32](), descriptions = [UInt32]()
        var ids = [UInt32](), channelIDs = [UInt32](), exceptionIndices = [UInt32](), exceptionTimes = [UInt64]()
        starts.reserveCapacity(total); ends.reserveCapacity(total)
        titles.reserveCapacity(total); descriptions.reserveCapacity(total)
        ids.reserveCapacity(total); channelIDs.reserveCapacity(total)
        // Sorted keys make the file a deterministic function of the guide.
        for key in programs.keys.sorted() {
            let list = programs[key]!
            keys.append(table.intern(key))
            for program in list {
                if let s = column(program.start), let e = column(program.end) {
                    starts.append(s); ends.append(e)
                } else {
                    starts.append(0); ends.append(0)
                    exceptionIndices.append(UInt32(starts.count - 1))
                    exceptionTimes.append(program.start.timeIntervalSinceReferenceDate.bitPattern)
                    exceptionTimes.append(program.end.timeIntervalSinceReferenceDate.bitPattern)
                }
                titles.append(table.intern(program.title))
                descriptions.append(table.intern(program.description))
                channelIDs.append(program.channelID == key ? none : table.intern(program.channelID))
                ids.append(program.hasChannelStartID ? none : table.intern(program.id))
            }
            runOffsets.append(UInt32(starts.count))
        }
        guard !table.overflow else { return nil }
        var writer = Writer()
        writer.bytes.reserveCapacity(headerSize + table.blob.count + table.offsets.count * 4 + total * 24 + keys.count * 8 + 64)
        writer.header(magic: programsMagic, savedAt: savedAt, rows: total, keys: keys.count,
                      strings: table.offsets.count - 1, exceptions: exceptionIndices.count, blobLength: table.blob.count)
        writer.append(strings: table)
        writer.append(column: keys)
        writer.append(column: runOffsets)
        writer.append(column: starts)
        writer.append(column: ends)
        writer.append(column: titles)
        writer.append(column: descriptions)
        writer.append(column: ids)
        writer.append(column: channelIDs)
        writer.append(column: exceptionIndices)
        writer.append(column: exceptionTimes)
        return writer.finish()
    }

    /// Channel fields in column order. Every field is a string ID except
    /// `catchupDays` (Int32 bit pattern) and `flags` (bit 0: has catchup).
    private enum ChannelColumn: Int, CaseIterable {
        case id, name, logoURL, group, streamURL, epgChannelID
        case catchupKind, catchupDays, catchupSource, contentType
        case ownerSourceID, ownerNativeID, ownerAccountKey, ownerLogicalID, guideSourceID, guideEPGChannelID
    }

    static func encodeChannels(_ channels: [Channel], savedAt: Date) -> [UInt8]? {
        var table = StringTable()
        var columns = [[UInt32]](repeating: [], count: ChannelColumn.allCases.count)
        for index in columns.indices { columns[index].reserveCapacity(channels.count) }
        func put(_ column: ChannelColumn, _ value: UInt32) { columns[column.rawValue].append(value) }
        for channel in channels {
            put(.id, table.intern(channel.id))
            put(.name, table.intern(channel.name))
            put(.logoURL, table.intern(channel.logoURL?.absoluteString))
            put(.group, table.intern(channel.group))
            put(.streamURL, table.intern(channel.streamURL.absoluteString))
            put(.epgChannelID, table.intern(channel.epgChannelID))
            put(.catchupKind, table.intern(channel.catchup?.kind.rawValue))
            put(.catchupDays, UInt32(bitPattern: Int32(clamping: channel.catchup?.days ?? 0)))
            put(.catchupSource, table.intern(channel.catchup?.source))
            put(.contentType, table.intern(channel.contentType.rawValue))
            let owner = channel.sourceOwnership
            put(.ownerSourceID, table.intern(owner?.channelIdentity.sourceID.uuidString))
            put(.ownerNativeID, table.intern(owner?.channelIdentity.nativeID))
            put(.ownerAccountKey, table.intern(owner?.accountKey.rawValue))
            put(.ownerLogicalID, table.intern(owner?.logicalChannelID))
            put(.guideSourceID, table.intern(owner?.guideBinding?.sourceID.uuidString))
            put(.guideEPGChannelID, table.intern(owner?.guideBinding?.epgChannelID))
        }
        guard !table.overflow, channels.count < Int(UInt32.max) else { return nil }
        var writer = Writer()
        writer.header(magic: channelsMagic, savedAt: savedAt, rows: channels.count, keys: columns.count,
                      strings: table.offsets.count - 1, exceptions: 0, blobLength: table.blob.count)
        writer.append(strings: table)
        for column in columns { writer.append(column: column) }
        return writer.finish()
    }

    @inline(__always)
    private static func column(_ date: Date) -> Int32? {
        let seconds = date.timeIntervalSince1970 - Double(EPGProgram.columnEpoch)
        guard let value = Int32(exactly: seconds), value != .min, value != .max,
              // Whole seconds only when the Int32 round-trips to the same Date.
              Date(timeIntervalSince1970: Double(EPGProgram.columnEpoch) + Double(value)) == date else { return nil }
        return value
    }

    /// Writes beside the destination and renames over it, so readers see the
    /// old file or the complete new one, never a torn write.
    static func writeAtomically(_ bytes: [UInt8], to url: URL) -> Bool {
        bytes.withUnsafeBytes { writeAtomically($0, to: url) }
    }

    static func writeAtomically(_ buffer: UnsafeRawBufferPointer, to url: URL) -> Bool {
        let staged = url.path + ".tmp-\(UUID().uuidString)"
        let descriptor = open(staged, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { return false }
        var written = 0
        var ok = true
        while ok, written < buffer.count {
            let result = write(descriptor, buffer.baseAddress! + written, buffer.count - written)
            if result < 0 { if errno != EINTR { ok = false } } else { written += result }
        }
        if close(descriptor) != 0 { ok = false }
        guard ok, rename(staged, url.path) == 0 else {
            unlink(staged)
            return false
        }
        return true
    }

    // MARK: Reading

    private struct Reader {
        let buffer: UnsafeRawBufferPointer
        var cursor = ColumnarCache.headerSize
        var valid = true

        init(_ buffer: UnsafeRawBufferPointer) { self.buffer = buffer }

        func field<T: FixedWidthInteger>(_ offset: Int, as: T.Type) -> T {
            T(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: T.self))
        }

        /// Returns a typed view of the next aligned column, or an empty view
        /// (and `valid = false`) when it would run past the file.
        mutating func column<T: FixedWidthInteger>(_ count: Int, of _: T.Type) -> UnsafeBufferPointer<T> {
            cursor = (cursor + 7) & ~7
            let length = count.multipliedReportingOverflow(by: MemoryLayout<T>.stride)
            guard valid, count >= 0, !length.overflow, cursor <= buffer.count - length.partialValue,
                  let base = buffer.baseAddress, Int(bitPattern: base + cursor) % MemoryLayout<T>.alignment == 0 else {
                valid = false
                return UnsafeBufferPointer(start: nil, count: 0)
            }
            defer { cursor += length.partialValue }
            return UnsafeBufferPointer(start: (base + cursor).assumingMemoryBound(to: T.self), count: count)
        }

        mutating func bytes(_ count: Int) -> UnsafeRawBufferPointer {
            cursor = (cursor + 7) & ~7
            guard valid, count >= 0, cursor <= buffer.count - count else {
                valid = false
                return UnsafeRawBufferPointer(start: nil, count: 0)
            }
            defer { cursor += count }
            return UnsafeRawBufferPointer(rebasing: buffer[cursor..<(cursor + count)])
        }

        /// Decodes the interned table once; façade values share these Strings.
        mutating func strings(count: Int, blobLength: Int) -> [String]? {
            let offsets = column(count + 1, of: UInt32.self)
            let blob = bytes(blobLength)
            guard valid, offsets.first == 0, Int(UInt32(littleEndian: offsets[count])) == blobLength else { return nil }
            var result: [String] = []
            result.reserveCapacity(count)
            var previous = 0
            for index in 0..<count {
                let next = Int(UInt32(littleEndian: offsets[index + 1]))
                guard next >= previous, next <= blobLength else { return nil }
                let slice = UnsafeRawBufferPointer(rebasing: blob[previous..<next])
                guard let string = String(validating: slice.bindMemory(to: UInt8.self), as: UTF8.self) else { return nil }
                result.append(string)
                previous = next
            }
            return result
        }
    }

    private struct Header {
        let savedAt: Date
        let rows: Int
        let keys: Int
        let strings: Int
        let exceptions: Int
        let blobLength: Int
    }

    private static func header(_ reader: Reader, magic: UInt32) -> Header? {
        guard reader.buffer.count >= headerSize,
              reader.field(0, as: UInt32.self) == magic,
              reader.field(4, as: UInt32.self) == version,
              reader.field(40, as: UInt64.self) == UInt64(reader.buffer.count) else { return nil }
        let blob = reader.field(32, as: UInt64.self)
        guard blob <= UInt64(reader.buffer.count) else { return nil }
        let savedAt = Double(bitPattern: reader.field(8, as: UInt64.self))
        guard savedAt.isFinite else { return nil }
        return Header(savedAt: Date(timeIntervalSinceReferenceDate: savedAt),
                      rows: Int(reader.field(16, as: UInt32.self)), keys: Int(reader.field(20, as: UInt32.self)),
                      strings: Int(reader.field(24, as: UInt32.self)), exceptions: Int(reader.field(28, as: UInt32.self)),
                      blobLength: Int(blob))
    }

    /// Decodes a guide slot. With a `policy`, retention is applied on the
    /// Int32 columns first: runs for unretained IDs are skipped outright and
    /// expired rows are never materialized (see `EPGProgram.RetentionPolicy`).
    static func decodePrograms(_ buffer: UnsafeRawBufferPointer) -> DataCache.CachedPrograms? {
        decodePrograms(buffer, policy: nil)
    }

    static func decodePrograms(_ buffer: UnsafeRawBufferPointer, policy: EPGProgram.RetentionPolicy?) -> DataCache.CachedPrograms? {
        var reader = Reader(buffer)
        guard let header = header(reader, magic: programsMagic),
              let strings = reader.strings(count: header.strings, blobLength: header.blobLength) else { return nil }
        let n = header.rows
        let keys = reader.column(header.keys, of: UInt32.self)
        let runOffsets = reader.column(header.keys + 1, of: UInt32.self)
        let starts = reader.column(n, of: Int32.self)
        let ends = reader.column(n, of: Int32.self)
        let titles = reader.column(n, of: UInt32.self)
        let descriptions = reader.column(n, of: UInt32.self)
        let ids = reader.column(n, of: UInt32.self)
        let channelIDs = reader.column(n, of: UInt32.self)
        let exceptionIndices = reader.column(header.exceptions, of: UInt32.self)
        let exceptionTimes = reader.column(header.exceptions * 2, of: UInt64.self)
        guard reader.valid, reader.cursor <= buffer.count, runOffsets.first == 0,
              header.keys == 0 ? n == 0 : Int(UInt32(littleEndian: runOffsets[header.keys])) == n else { return nil }

        // Exceptions must be strictly increasing row indices; each chunk then
        // finds its first one by binary search and consumes its own range.
        var previousException = -1
        for index in 0..<header.exceptions {
            let row = Int(UInt32(littleEndian: exceptionIndices[index]))
            guard row > previousException, row < n else { return nil }
            previousException = row
        }
        let stringCount = UInt32(strings.count)
        let base = Double(EPGProgram.columnEpoch)
        let latestKey = policy.map { ceilingKey($0.latest) } ?? .max
        let maximumDuration = policy.map { Int64($0.maximumDuration.rounded(.down)) } ?? .max
        let words = (strings.count + 63) >> 6

        /// Materializes runs `[firstRun, lastRun)`; nil on any inconsistency.
        func decodeRuns(_ firstRun: Int, _ lastRun: Int) -> [(String, [EPGProgram])]? {
            // Title visibility is a property of the interned string: two
            // bitsets (evaluated, visible) make the rule one bit test per row.
            var titleEvaluated = [UInt64](repeating: 0, count: policy == nil ? 0 : words)
            var titleVisible = [UInt64](repeating: 0, count: policy == nil ? 0 : words)
            let firstRow = Int(UInt32(littleEndian: runOffsets[firstRun]))
            var nextException = 0, high = header.exceptions
            while nextException < high {
                let mid = (nextException + high) >> 1
                if Int(UInt32(littleEndian: exceptionIndices[mid])) < firstRow { nextException = mid + 1 } else { high = mid }
            }
            var result: [(String, [EPGProgram])] = []
            result.reserveCapacity(lastRun - firstRun)
            for run in firstRun..<lastRun {
                let keyID = UInt32(littleEndian: keys[run])
                let lo = Int(UInt32(littleEndian: runOffsets[run])), hi = Int(UInt32(littleEndian: runOffsets[run + 1]))
                guard keyID < stringCount, lo <= hi, hi <= n else { return nil }
                let key = strings[Int(keyID)]
                var earliest = Date.distantPast
                if let policy {
                    guard let retainedFrom = policy.starts[key] else {
                        while nextException < header.exceptions, Int(UInt32(littleEndian: exceptionIndices[nextException])) < hi {
                            nextException += 1
                        }
                        continue
                    }
                    earliest = retainedFrom
                }
                let earliestKey = floorKey(earliest)
                var list: [EPGProgram] = []
                list.reserveCapacity(hi - lo)
                var sorted = true
                var previousStart = Date.distantPast
                for row in lo..<hi {
                    let title = UInt32(littleEndian: titles[row]), description = UInt32(littleEndian: descriptions[row])
                    let id = UInt32(littleEndian: ids[row]), channel = UInt32(littleEndian: channelIDs[row])
                    guard title < stringCount, description < stringCount,
                          id < stringCount || id == none, channel < stringCount || channel == none else { return nil }
                    let start: Date, end: Date
                    var exact = false
                    if nextException < header.exceptions, Int(UInt32(littleEndian: exceptionIndices[nextException])) == row {
                        start = Date(timeIntervalSinceReferenceDate: Double(bitPattern: UInt64(littleEndian: exceptionTimes[2 * nextException])))
                        end = Date(timeIntervalSinceReferenceDate: Double(bitPattern: UInt64(littleEndian: exceptionTimes[2 * nextException + 1])))
                        nextException += 1
                        exact = true
                    } else {
                        let s = Int32(littleEndian: starts[row]), e = Int32(littleEndian: ends[row])
                        if let policy {
                            // `GuideHistory.isUsable` on whole-second columns.
                            guard e > s, Int64(e) - Int64(s) <= maximumDuration, e > earliestKey, s < latestKey else { continue }
                            let word = Int(title) >> 6, bit = UInt64(1) << UInt64(title & 63)
                            if titleEvaluated[word] & bit == 0 {
                                titleEvaluated[word] |= bit
                                if policy.hasVisibleTitle(strings[Int(title)]) { titleVisible[word] |= bit }
                            }
                            guard titleVisible[word] & bit != 0 else { continue }
                        }
                        start = Date(timeIntervalSince1970: base + Double(s))
                        end = Date(timeIntervalSince1970: base + Double(e))
                    }
                    let channelID = channel == none ? key : strings[Int(channel)]
                    let program = id == none
                        ? EPGProgram(channelStartIDWithChannelID: channelID, title: strings[Int(title)],
                                     description: strings[Int(description)], start: start, end: end)
                        : EPGProgram(id: strings[Int(id)], channelID: channelID, title: strings[Int(title)],
                                     description: strings[Int(description)], start: start, end: end)
                    if exact, let policy, !policy.isUsable(program, earliest) { continue }
                    if start < previousStart { sorted = false }
                    previousStart = start
                    list.append(program)
                }
                if let policy, !sorted || list.count > policy.maximumCount {
                    list = policy.normalize(list, earliest)
                }
                if policy != nil && list.isEmpty { continue }
                result.append((key, list))
            }
            return result
        }

        // Runs are independent: decode contiguous groups of them in parallel
        // (balanced by row count), then join the per-chunk results.
        let chunkCount = header.keys < 256 || n < 65_536 ? 1 : min(16, ProcessInfo.processInfo.activeProcessorCount)
        var bounds = [0]
        for chunk in 1..<max(chunkCount, 1) {
            let targetRow = UInt32(n / chunkCount * chunk)
            var low = bounds.last!, high = header.keys
            while low < high {
                let mid = (low + high) >> 1
                if UInt32(littleEndian: runOffsets[mid]) < targetRow { low = mid + 1 } else { high = mid }
            }
            bounds.append(low)
        }
        bounds.append(header.keys)
        let chunks = bounds.count - 1
        let results = UnsafeMutableBufferPointer<[(String, [EPGProgram])]?>.allocate(capacity: chunks)
        results.initialize(repeating: nil)
        defer { results.deinitialize(); results.deallocate() }
        if chunks == 1 {
            results[0] = decodeRuns(0, header.keys)
        } else {
            // Each iteration writes only its own slot; all inputs are read-only.
            let output = UncheckedSendable(results), decode = UncheckedSendable(decodeRuns), ranges = bounds
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                output.value[chunk] = decode.value(ranges[chunk], ranges[chunk + 1])
            }
        }
        var programs: [String: [EPGProgram]] = [:]
        programs.reserveCapacity(policy?.starts.count ?? header.keys)
        for chunk in results {
            guard let chunk else { return nil }
            for (key, list) in chunk {
                guard programs.updateValue(list, forKey: key) == nil else { return nil }
            }
        }
        return DataCache.CachedPrograms(savedAt: header.savedAt, programs: programs)
    }

    /// For whole-second columns: `end > t ⇔ end > floorKey(t)`.
    @inline(__always)
    static func floorKey(_ date: Date) -> Int32 {
        let t = (date.timeIntervalSince1970 - Double(EPGProgram.columnEpoch)).rounded(.down)
        if t.isNaN || t >= Double(Int32.max) { return .max }
        if t <= Double(Int32.min) { return .min }
        return Int32(t)
    }

    /// For whole-second columns: `start < t ⇔ start < ceilingKey(t)`.
    @inline(__always)
    static func ceilingKey(_ date: Date) -> Int32 {
        let t = (date.timeIntervalSince1970 - Double(EPGProgram.columnEpoch)).rounded(.up)
        if t.isNaN || t <= Double(Int32.min) { return .min }
        if t >= Double(Int32.max) { return .max }
        return Int32(t)
    }

    static func decodeChannels(_ buffer: UnsafeRawBufferPointer) -> DataCache.CachedChannels? {
        var reader = Reader(buffer)
        guard let header = header(reader, magic: channelsMagic), header.keys == ChannelColumn.allCases.count,
              let strings = reader.strings(count: header.strings, blobLength: header.blobLength) else { return nil }
        let n = header.rows
        let columns = ChannelColumn.allCases.map { _ in reader.column(n, of: UInt32.self) }
        guard reader.valid else { return nil }
        let stringCount = UInt32(strings.count)
        var uuids: [UInt32: UUID] = [:]
        var invalid = false
        func value(_ column: ChannelColumn, _ row: Int) -> UInt32 { UInt32(littleEndian: columns[column.rawValue][row]) }
        func optional(_ column: ChannelColumn, _ row: Int) -> String? {
            let id = value(column, row)
            if id == none { return nil }
            guard id < stringCount else { invalid = true; return nil }
            return strings[Int(id)]
        }
        func required(_ column: ChannelColumn, _ row: Int) -> String {
            guard let string = optional(column, row) else { invalid = true; return "" }
            return string
        }
        func uuid(_ column: ChannelColumn, _ row: Int) -> UUID? {
            let id = value(column, row)
            if let cached = uuids[id] { return cached }
            guard let string = optional(column, row) else { return nil }
            guard let parsed = UUID(uuidString: string) else { invalid = true; return nil }
            uuids[id] = parsed
            return parsed
        }
        var channels: [Channel] = []
        channels.reserveCapacity(n)
        for row in 0..<n {
            guard let streamURL = URL(string: required(.streamURL, row)) else { return nil }
            var catchup: CatchupInfo?
            if let kind = optional(.catchupKind, row) {
                guard let parsed = CatchupInfo.Kind(rawValue: kind) else { return nil }
                catchup = CatchupInfo(kind: parsed, days: Int(Int32(bitPattern: value(.catchupDays, row))),
                                      source: optional(.catchupSource, row))
            }
            guard let contentType = ChannelContentType(rawValue: required(.contentType, row)) else { return nil }
            var ownership: ChannelSourceOwnership?
            if let sourceID = uuid(.ownerSourceID, row) {
                let guideSource = uuid(.guideSourceID, row)
                let guideEPG = optional(.guideEPGChannelID, row)
                guard (guideSource == nil) == (guideEPG == nil) else { return nil }
                ownership = ChannelSourceOwnership(
                    channelIdentity: SourceChannelIdentity(sourceID: sourceID, nativeID: required(.ownerNativeID, row)),
                    accountKey: SourceAccountKey(opaqueValue: required(.ownerAccountKey, row)),
                    logicalChannelID: optional(.ownerLogicalID, row),
                    guideBinding: guideSource.flatMap { source in guideEPG.map { SourceGuideBinding(sourceID: source, epgChannelID: $0) } })
            }
            var logoURL: URL?
            if let logo = optional(.logoURL, row) {
                guard let parsed = URL(string: logo) else { return nil }
                logoURL = parsed
            }
            channels.append(Channel(id: required(.id, row), name: required(.name, row), logoURL: logoURL,
                                    group: required(.group, row), streamURL: streamURL,
                                    epgChannelID: optional(.epgChannelID, row), catchup: catchup,
                                    contentType: contentType, sourceOwnership: ownership))
            if invalid { return nil }
        }
        return DataCache.CachedChannels(savedAt: header.savedAt, channels: channels)
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
