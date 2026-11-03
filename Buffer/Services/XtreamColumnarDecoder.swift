import Foundation

// Xtream player_api responses decoded in one pass over the response bytes
// into flat columns (one shared byte table, packed string references,
// integer columns), then materialized into the app models only where the
// existing APIs need them. Each decoder declines (`ConnectorJSONDecline`)
// whenever the reference JSONDecoder path could produce a different
// outcome; XtreamClient then runs that path.

/// Category ID → name, last definition wins (as the reference dictionary).
nonisolated struct XtreamCategoryTable: Sendable {
    private var ids = ConnectorStringTable()
    private var idRefs: [ConnectorStringTable.Ref] = []
    private(set) var names: [String] = []
    /// Open-addressing slots holding row + 1 (0 = empty), keyed by ID bytes.
    private var slots: [Int32] = []
    /// Swift String lookups (canonical equivalence) for non-ASCII IDs.
    private var byString: [String: Int]?
    private var asciiOnly = true

    static let empty = XtreamCategoryTable()

    var dictionary: [String: String] {
        var map: [String: String] = [:]
        for (row, ref) in idRefs.enumerated() { map[ids.string(ref)!] = names[row] }
        return map
    }

    init() {}

    init(dictionary: [String: String]) {
        var builder = Builder()
        for (id, name) in dictionary { try? builder.add(id: Array(id.utf8), name: name) }
        self = builder.table
        seal()
    }

    struct Builder {
        var table = XtreamCategoryTable()
        mutating func add(id: [UInt8], name: String) throws {
            let ref = try table.ids.append(id)
            if !table.ids.isASCII(ref) { table.asciiOnly = false }
            table.idRefs.append(ref)
            table.names.append(name)
        }
    }

    /// Finalizes lookups (last duplicate wins, as the reference dictionary).
    mutating func seal() {
        // Swift String keys: the reference semantics (canonical equivalence),
        // used for non-ASCII IDs on either side.
        var map: [String: Int] = [:]
        map.reserveCapacity(idRefs.count)
        for (row, ref) in idRefs.enumerated() { map[ids.string(ref)!] = row }
        byString = map
        guard asciiOnly else { return }
        let rows = idRefs.count
        var capacity = 8
        while capacity < rows * 2 { capacity <<= 1 }
        slots = [Int32](repeating: 0, count: capacity)
        let mask = capacity - 1
        for (row, ref) in idRefs.enumerated() {
            var slot = Int(ids.hash(ref) & UInt64(mask))
            while slots[slot] != 0 {
                if ids.bytesEqual(idRefs[Int(slots[slot]) - 1], ref) { break }
                slot = (slot + 1) & mask
            }
            slots[slot] = Int32(row + 1)
        }
    }

    /// Name for an ID given as bytes. ASCII IDs against an ASCII table are
    /// compared as bytes (canonical equivalence is byte equality there).
    func name(_ p: UnsafePointer<UInt8>, _ n: Int) -> String? {
        var ascii = asciiOnly && !slots.isEmpty
        if ascii { for i in 0..<n where p[i] >= 0x80 { ascii = false; break } }
        guard ascii else {
            return byString?[String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)].map { names[$0] }
        }
        let mask = slots.count - 1
        var slot = Int(ConnectorStringTable.hash(p, n) & UInt64(mask))
        while true {
            let entry = slots[slot]
            if entry == 0 { return nil }
            let ref = idRefs[Int(entry) - 1]
            if ConnectorStringTable.length(ref) == n,
               ids.withBytes(ref, { q, _ in n == 0 || memcmp(q, p, n) == 0 }) {
                return names[Int(entry) - 1]
            }
            slot = (slot + 1) & mask
        }
    }

    /// Decodes `get_*_categories`: `[{category_id, category_name}]`.
    static func decode(_ data: Data) throws -> XtreamCategoryTable {
        try ConnectorJSONCursor.withCursor(data) { c in
            var builder = Builder()
            var scratch: [UInt8] = []
            if try c.beginArray() {
                repeat {
                    var id = ConnectorJSONSpan.absent, name = ConnectorJSONSpan.absent
                    if try c.beginObject() {
                        repeat {
                            let key = try c.readKey()
                            if c.keyEquals(key, "category_id") {
                                let v = try c.readValue()
                                if !id.isPresent { id = v }
                            } else if c.keyEquals(key, "category_name") {
                                let v = try c.readValue()
                                if !name.isPresent { name = v }
                            } else {
                                try c.skipValue(depth: 2)
                            }
                        } while try c.nextMember()
                    }
                    var local = ConnectorStringTable()
                    let idRef = try local.appendFlex(id, c)
                    let nameRef = try local.appendStrictString(name, c)
                    scratch.removeAll(keepingCapacity: true)
                    local.withBytes(idRef) { p, n in scratch.append(contentsOf: UnsafeBufferPointer(start: p, count: n)) }
                    try builder.add(id: scratch, name: local.string(nameRef) ?? "Unknown")
                } while try c.nextElement()
            }
            try c.finish()
            var table = builder.table
            table.seal()
            return table
        }
    }
}

/// `get_live_streams` as columns.
nonisolated struct XtreamLiveStreamColumns: Sendable {
    typealias Ref = ConnectorStringTable.Ref
    private(set) var text = ConnectorStringTable()
    private(set) var streamID: [Ref] = []
    /// `none` → "Unknown".
    private(set) var name: [Ref] = []
    private(set) var icon: [Ref] = []
    private(set) var epgID: [Ref] = []
    private(set) var categoryID: [Ref] = []
    /// Catchup days; 0 when the stream has no archive.
    private(set) var archiveDays: [Int] = []

    var count: Int { streamID.count }

    init(reservingFor bytes: Int = 0) {
        let estimate = bytes / 380 + 16
        text = ConnectorStringTable(capacity: bytes / 4)
        streamID.reserveCapacity(estimate); name.reserveCapacity(estimate)
        icon.reserveCapacity(estimate); epgID.reserveCapacity(estimate)
        categoryID.reserveCapacity(estimate); archiveDays.reserveCapacity(estimate)
    }

    /// Decodes the response into element-aligned chunks (several cores for
    /// large responses); rows keep response order across chunks.
    static func decode(_ data: Data, workers: Int = ConnectorParallel.workerCount) throws -> [XtreamLiveStreamColumns] {
        try ConnectorJSONCursor.withCursor(data) { c in
            let chunks = try ConnectorParallel.decodeArray(&c, workers: workers, makeResult: { XtreamLiveStreamColumns(reservingFor: $0) },
                                                           element: { cursor, columns in try columns.appendStream(&cursor) })
            try c.finish()
            return chunks
        }
    }

    private mutating func appendStream(_ c: inout ConnectorJSONCursor) throws {
        var sid = ConnectorJSONSpan.absent, nm = ConnectorJSONSpan.absent, ic = ConnectorJSONSpan.absent
        var epg = ConnectorJSONSpan.absent, cat = ConnectorJSONSpan.absent
        var archive = ConnectorJSONSpan.absent, duration = ConnectorJSONSpan.absent
        if try c.beginObject() {
            repeat {
                let key = try c.readKey()
                let length = key.escaped ? -1 : key.end - key.start
                // Dispatch on key length first; unknown keys are skipped.
                switch length {
                case 4 where c.keyEquals(key, "name"):
                    let v = try c.readValue(depth: 2); if !nm.isPresent { nm = v }
                case 9 where c.keyEquals(key, "stream_id"):
                    let v = try c.readValue(depth: 2); if !sid.isPresent { sid = v }
                case 11 where c.keyEquals(key, "stream_icon"):
                    let v = try c.readValue(depth: 2); if !ic.isPresent { ic = v }
                case 11 where c.keyEquals(key, "category_id"):
                    let v = try c.readValue(depth: 2); if !cat.isPresent { cat = v }
                case 10 where c.keyEquals(key, "tv_archive"):
                    let v = try c.readValue(depth: 2); if !archive.isPresent { archive = v }
                case 14 where c.keyEquals(key, "epg_channel_id"):
                    let v = try c.readValue(depth: 2); if !epg.isPresent { epg = v }
                case 19 where c.keyEquals(key, "tv_archive_duration"):
                    let v = try c.readValue(depth: 2); if !duration.isPresent { duration = v }
                case -1:
                    // Escaped key: compare after unescaping.
                    if c.keyEquals(key, "name") { let v = try c.readValue(depth: 2); if !nm.isPresent { nm = v } }
                    else if c.keyEquals(key, "stream_id") { let v = try c.readValue(depth: 2); if !sid.isPresent { sid = v } }
                    else if c.keyEquals(key, "stream_icon") { let v = try c.readValue(depth: 2); if !ic.isPresent { ic = v } }
                    else if c.keyEquals(key, "category_id") { let v = try c.readValue(depth: 2); if !cat.isPresent { cat = v } }
                    else if c.keyEquals(key, "tv_archive") { let v = try c.readValue(depth: 2); if !archive.isPresent { archive = v } }
                    else if c.keyEquals(key, "epg_channel_id") { let v = try c.readValue(depth: 2); if !epg.isPresent { epg = v } }
                    else if c.keyEquals(key, "tv_archive_duration") { let v = try c.readValue(depth: 2); if !duration.isPresent { duration = v } }
                    else { try c.skipValue(depth: 2) }
                default:
                    try c.skipValue(depth: 2)
                }
            } while try c.nextMember()
        }
        streamID.append(try text.appendFlex(sid, c))
        name.append(try text.appendStrictString(nm, c))
        icon.append(try text.appendStrictString(ic, c))
        epgID.append(try text.appendStrictString(epg, c))
        categoryID.append(try text.appendFlexIfPresent(cat, c))
        archiveDays.append(try Self.catchupDays(archive: archive, duration: duration, c))
    }

    /// `tv_archive == "1"` then `Int(tv_archive_duration) > 0 ? d : 1`.
    private static func catchupDays(archive: ConnectorJSONSpan, duration: ConnectorJSONSpan, _ c: ConnectorJSONCursor) throws -> Int {
        switch archive.kind {
        case .number:
            guard try c.codableInt(archive) == 1 else { return 0 }
        case .string:
            if archive.escaped {
                var scratch: [UInt8] = []
                c.appendUnescaped(archive, to: &scratch)
                guard scratch == [0x31] else { return 0 }
            } else {
                guard archive.end - archive.start == 1, c.byte(archive.start) == 0x31 else { return 0 }
            }
        default:
            return 0
        }
        let days: Int?
        switch duration.kind {
        case .number: days = try c.codableInt(duration)
        case .string:
            if duration.escaped {
                var scratch: [UInt8] = []
                c.appendUnescaped(duration, to: &scratch)
                days = scratch.withUnsafeBufferPointer { ConnectorText.swiftInt($0.baseAddress ?? UnsafePointer(bitPattern: 1)!, $0.count) }
            } else {
                days = c.swiftInt(duration)
            }
        default: days = nil
        }
        if let days, days > 0 { return days }
        return 1
    }

    /// Materializes `[Channel]` exactly as `XtreamClient.fetchChannels` maps streams.
    static func channels(_ chunks: [XtreamLiveStreamColumns], categories: XtreamCategoryTable, config: ServerConfig,
                         workers: Int = ConnectorParallel.workerCount) -> [Channel] {
        guard let baseURL = config.xtreamStreamBase else { return [] }
        let base = Array(baseURL.absoluteString.utf8) + [0x2F]
        let catchupPrefix = "\(config.xtreamBaseURL)/timeshift/\(config.username)/\(config.password)/${duration}/${Y}-${m}-${d}:${H}-${M}/"
        return ConnectorParallel.materialize(chunks, rows: \.count, workers: workers) { chunk, rows, out in
            chunk.appendChannels(rows, categories: categories, base: base, catchupPrefix: catchupPrefix, to: &out)
        }
    }

    private func appendChannels(_ rows: Range<Int>, categories: XtreamCategoryTable, base: [UInt8], catchupPrefix: String,
                                to channels: inout [Channel]) {
        let m3u8: [UInt8] = [0x2E, 0x6D, 0x33, 0x75, 0x38]
        var urlBytes = base
        urlBytes.reserveCapacity(base.count + 32)
        text.bytes.withUnsafeBufferPointer { buffer in
            let p = buffer.baseAddress ?? UnsafePointer(bitPattern: 1)!
            func string(_ ref: Ref) -> String {
                String(decoding: UnsafeBufferPointer(start: p + ConnectorStringTable.offset(ref), count: ConnectorStringTable.length(ref)), as: UTF8.self)
            }
            for row in rows {
                let idRef = streamID[row]
                let idLength = ConnectorStringTable.length(idRef)
                urlBytes.removeSubrange(base.count...)
                urlBytes.append(contentsOf: UnsafeBufferPointer(start: p + ConnectorStringTable.offset(idRef), count: idLength))
                urlBytes.append(contentsOf: m3u8)
                guard let streamURL = URL(string: String(decoding: urlBytes, as: UTF8.self)) else { continue }
                let id = string(idRef)
                let catRef = categoryID[row]
                let group = catRef == ConnectorStringTable.none ? nil
                    : categories.name(p + ConnectorStringTable.offset(catRef), ConnectorStringTable.length(catRef))
                let epgRef = epgID[row]
                var epgChannelID: String?
                if epgRef != ConnectorStringTable.none {
                    let offset = ConnectorStringTable.offset(epgRef)
                    let (s, e) = ConnectorText.trimmedRange(p, offset, offset + ConnectorStringTable.length(epgRef))
                    if e > s { epgChannelID = String(decoding: UnsafeBufferPointer(start: p + s, count: e - s), as: UTF8.self) }
                }
                let iconRef = icon[row]
                let days = archiveDays[row]
                channels.append(Channel(
                    id: id,
                    name: name[row] == ConnectorStringTable.none ? "Unknown" : string(name[row]),
                    logoURL: iconRef == ConnectorStringTable.none ? nil : URL(string: string(iconRef)),
                    group: group ?? "Uncategorized",
                    streamURL: streamURL,
                    epgChannelID: epgChannelID ?? "xtream-stream-" + id,
                    catchup: days > 0 ? CatchupInfo(kind: .xc, days: days, source: catchupPrefix + id + ".ts") : nil
                ))
            }
        }
    }
}

/// `get_simple_data_table` listings for one channel.
nonisolated struct XtreamShortEPGColumns: Sendable {
    typealias Ref = ConnectorStringTable.Ref
    var text = ConnectorStringTable()
    /// Provider listing count, including rows the mapper drops.
    var receivedListings = 0
    var start: [Date] = []
    var end: [Date] = []
    /// Trimmed provider listing ID, or `none` (derive from the interval).
    var listingID: [Ref] = []
    var title: [Ref] = []
    /// `none` → "".
    var description: [Ref] = []
    var responseEarliestEpoch = 0.0
    var responseLatestEpoch = 0.0

    var count: Int { start.count }

    /// Decodes and filters exactly as the reference catchup mapping.
    static func decode(_ data: Data, minimumStart: Date?) throws -> XtreamShortEPGColumns {
        try ConnectorJSONCursor.withCursor(data) { c in
            var columns = XtreamShortEPGColumns()
            columns.text = ConnectorStringTable(capacity: data.count / 2)
            var earliest = Double.infinity
            var latest = 0.0
            var seenListings = false
            var scratch: [UInt8] = []
            if try c.beginObject() {
                repeat {
                    let key = try c.readKey()
                    guard !seenListings, c.keyEquals(key, "epg_listings") else { try c.skipValue(depth: 1); continue }
                    seenListings = true
                    switch c.peek() {
                    case 0x6E: _ = try c.readValue() // null → []
                    case 0x5B:
                        if try c.beginArray() {
                            repeat {
                                try columns.appendListing(&c, minimumStart: minimumStart, earliest: &earliest,
                                                          latest: &latest, scratch: &scratch)
                            } while try c.nextElement()
                        }
                    default: throw ConnectorJSONDecline()
                    }
                } while try c.nextMember()
            }
            try c.finish()
            columns.responseEarliestEpoch = earliest.isFinite ? earliest : 0
            columns.responseLatestEpoch = latest
            return columns
        }
    }

    private mutating func appendListing(_ c: inout ConnectorJSONCursor, minimumStart: Date?, earliest: inout Double,
                                        latest: inout Double, scratch: inout [UInt8]) throws {
        var idSpan = ConnectorJSONSpan.absent, titleSpan = ConnectorJSONSpan.absent, descSpan = ConnectorJSONSpan.absent
        var startSpan = ConnectorJSONSpan.absent, stopSpan = ConnectorJSONSpan.absent
        if try c.beginObject() {
            repeat {
                let key = try c.readKey()
                let length = key.escaped ? -1 : key.end - key.start
                // Length gate first; escaped keys compare after unescaping.
                if (length == 5 || length < 0) && c.keyEquals(key, "title") {
                    let v = try c.readValue(depth: 3); if !titleSpan.isPresent { titleSpan = v }
                } else if (length == 11 || length < 0) && c.keyEquals(key, "description") {
                    let v = try c.readValue(depth: 3); if !descSpan.isPresent { descSpan = v }
                } else if (length == 15 || length < 0) && c.keyEquals(key, "start_timestamp") {
                    let v = try c.readValue(depth: 3); if !startSpan.isPresent { startSpan = v }
                } else if (length == 14 || length < 0) && c.keyEquals(key, "stop_timestamp") {
                    let v = try c.readValue(depth: 3); if !stopSpan.isPresent { stopSpan = v }
                } else if (length == 2 || length < 0) && c.keyEquals(key, "id") {
                    let v = try c.readValue(depth: 3); if !idSpan.isPresent { idSpan = v }
                } else {
                    try c.skipValue(depth: 3)
                }
            } while try c.nextMember()
        }
        receivedListings += 1
        // Type checks of the strict fields happen for every listing.
        guard titleSpan.kind == .string || titleSpan.isNullOrAbsent,
              descSpan.kind == .string || descSpan.isNullOrAbsent else { throw ConnectorJSONDecline() }
        guard let startDate = try Self.epochDate(startSpan, c, &scratch),
              let endDate = try Self.epochDate(stopSpan, c, &scratch),
              endDate > startDate else { return }
        earliest = min(earliest, startDate.timeIntervalSince1970)
        latest = max(latest, endDate.timeIntervalSince1970)
        if let minimumStart, endDate <= minimumStart { return }
        guard titleSpan.kind == .string, let titleRef = try text.appendDecodedEPGText(titleSpan, c, &scratch) else { return }
        let descRef = descSpan.kind == .string ? try text.appendDecodedEPGText(descSpan, c, &scratch) : nil
        var idRef = ConnectorStringTable.none
        switch idSpan.kind {
        case .string, .number:
            let raw = try text.appendFlexIfPresent(idSpan, c)
            if raw != ConnectorStringTable.none {
                let trimmed = text.trimmed(raw)
                if ConnectorStringTable.length(trimmed) > 0 { idRef = trimmed }
            }
        default: break
        }
        start.append(startDate)
        end.append(endDate)
        listingID.append(idRef)
        title.append(titleRef)
        description.append(descRef ?? ConnectorStringTable.none)
    }

    /// `date(fromEpochString: flexStringIfPresent(...))`.
    private static func epochDate(_ span: ConnectorJSONSpan, _ c: ConnectorJSONCursor, _ scratch: inout [UInt8]) throws -> Date? {
        let seconds: Double?
        switch span.kind {
        case .string:
            if span.escaped {
                scratch.removeAll(keepingCapacity: true)
                c.appendUnescaped(span, to: &scratch)
                seconds = scratch.withUnsafeBufferPointer { ConnectorText.timeInterval($0.baseAddress ?? UnsafePointer(bitPattern: 1)!, $0.count) }
            } else {
                seconds = ConnectorText.timeInterval(c.base + span.start, span.end - span.start)
            }
        case .number:
            guard let value = try c.codableInt(span) else { return nil }
            seconds = Double(value)
        default:
            return nil
        }
        guard let seconds, seconds.isFinite, seconds > 0, seconds < Double(Int.max) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Materializes programmes exactly as the reference catchup mapping.
    func programs(channelID: String, epgID: String) -> [EPGProgram] {
        var programs: [EPGProgram] = []
        programs.reserveCapacity(count)
        let prefix = "xtream-simple-" + channelID + "-"
        for row in 0..<count {
            let s = start[row], e = end[row]
            let id = text.string(listingID[row])
                ?? "\(Int(s.timeIntervalSince1970))-\(Int(e.timeIntervalSince1970))"
            programs.append(EPGProgram(
                id: prefix + id,
                channelID: epgID,
                title: text.string(title[row])!,
                description: text.string(description[row]) ?? "",
                start: s,
                end: e
            ))
        }
        return programs
    }
}

nonisolated extension ConnectorStringTable {
    /// `decodedEPGText`: trimmed text, replaced by its base64-decoded UTF-8
    /// (trimmed) when that is non-empty; nil when the trimmed text is empty.
    mutating func appendDecodedEPGText(_ span: ConnectorJSONSpan, _ c: ConnectorJSONCursor, _ scratch: inout [UInt8]) throws -> Ref? {
        if span.escaped {
            var unescaped: [UInt8] = []
            c.appendUnescaped(span, to: &unescaped)
            return try unescaped.withUnsafeBufferPointer {
                try appendDecodedEPGText($0.baseAddress ?? UnsafePointer(bitPattern: 1)!, 0, $0.count, &scratch)
            }
        }
        return try appendDecodedEPGText(c.base, span.start, span.end, &scratch)
    }

    private mutating func appendDecodedEPGText(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ scratch: inout [UInt8]) throws -> Ref? {
        let (s, e) = ConnectorText.trimmedRange(p, start, end)
        guard e > s else { return nil }
        scratch.removeAll(keepingCapacity: true)
        switch ConnectorText.decodeBase64(p + s, e - s, into: &scratch) {
        case .notBase64:
            return try append(p + s, e - s)
        case .undetermined:
            // Foundation's lenient base64 spellings: use it directly.
            let text = String(decoding: UnsafeBufferPointer(start: p + s, count: e - s), as: UTF8.self)
            guard let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8) else { return try append(p + s, e - s) }
            let clean = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? try append(p + s, e - s) : try append(Array(clean.utf8))
        case .decoded:
            return try scratch.withUnsafeBufferPointer { decoded -> Ref in
                guard let d = decoded.baseAddress, ConnectorText.isValidUTF8(d, decoded.count) else { return try append(p + s, e - s) }
                if decoded.count >= 3, d[0] == 0xEF, d[1] == 0xBB, d[2] == 0xBF {
                    // String(data:encoding:) drops a leading BOM.
                    guard let text = String(data: Data(decoded), encoding: .utf8) else { return try append(p + s, e - s) }
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return clean.isEmpty ? try append(p + s, e - s) : try append(Array(clean.utf8))
                }
                let (ds, de) = ConnectorText.trimmedRange(d, 0, decoded.count)
                return de > ds ? try append(d + ds, de - ds) : try append(p + s, e - s)
            }
        }
    }
}

nonisolated enum XtreamVODColumns {
    static let fields: [ConnectorRecordColumns.Field] = [
        .init(key: "name", kind: .strictString), .init(key: "stream_id", kind: .flex),
        .init(key: "stream_icon", kind: .strictString), .init(key: "category_id", kind: .flexIfPresent),
        .init(key: "container_extension", kind: .strictString), .init(key: "rating", kind: .flexIfPresent),
        .init(key: "rating_5based", kind: .flexIfPresent), .init(key: "plot", kind: .strictString),
        .init(key: "year", kind: .flexIfPresent), .init(key: "release_date", kind: .strictString),
        .init(key: "director", kind: .strictString), .init(key: "cast", kind: .strictString),
        .init(key: "country", kind: .strictString), .init(key: "genre", kind: .strictString),
        .init(key: "duration_secs", kind: .flexIfPresent),
    ]
    static let name = 0, streamID = 1, icon = 2, category = 3, containerExtension = 4, rating = 5, rating5 = 6, plot = 7
    static let year = 8, releaseDate = 9, director = 10, cast = 11, country = 12, genre = 13, duration = 14

    static func decode(_ data: Data, workers: Int = ConnectorParallel.workerCount) throws -> [ConnectorRecordColumns] {
        try ConnectorRecordColumns.decode(data, fields: fields, workers: workers)
    }

    /// Exactly as `XtreamClient.fetchVODItems` maps streams.
    static func items(_ chunks: [ConnectorRecordColumns], categories: XtreamCategoryTable, config: ServerConfig,
                      workers: Int = ConnectorParallel.workerCount) -> [VODItem] {
        let prefix = "\(config.xtreamBaseURL)/movie/\(config.username)/\(config.password)/"
        return ConnectorParallel.materialize(chunks, rows: \.count, workers: workers) { columns, rows, items in
            appendItems(columns, rows, categories: categories, prefix: prefix, to: &items)
        }
    }

    private static func appendItems(_ columns: ConnectorRecordColumns, _ rows: Range<Int>, categories: XtreamCategoryTable,
                                    prefix: String, to items: inout [VODItem]) {
        for row in rows {
            let ext = normalizedContainerExtension(columns, row)
            let id = columns.string(row, streamID)!
            guard let streamURL = URL(string: prefix + id + "." + ext) else { continue }
            let categoryName = columns.categoryName(row, category, in: categories) ?? "Movies"
            let rating = columns.string(row, Self.rating)
            items.append(VODItem(
                id: id,
                name: columns.string(row, name) ?? "Unknown",
                posterURL: columns.string(row, icon).flatMap { URL(string: $0) },
                group: categoryName,
                streamURL: streamURL,
                kind: .movie,
                genre: columns.nonEmpty(row, genre) ?? categoryName,
                durationSeconds: columns.int(row, duration),
                rating: rating?.isEmpty == false ? rating : columns.string(row, rating5),
                releaseDate: columns.string(row, releaseDate) ?? columns.string(row, year),
                containerExtension: ext,
                summary: columns.string(row, plot),
                director: columns.string(row, director),
                cast: columns.string(row, cast),
                country: columns.string(row, country)
            ))
        }
    }

    /// `(value ?? "mp4").trimmingCharacters(in: "." + whitespace)`, "mp4" when empty.
    static func normalizedContainerExtension(_ columns: ConnectorRecordColumns, _ row: Int) -> String {
        let ref = columns[row, containerExtension]
        guard ref != ConnectorStringTable.none else { return "mp4" }
        let plain = columns.text.withBytes(ref) { p, n -> Bool in
            guard n > 0, p[0] != 0x2E, p[n - 1] != 0x2E else { return false }
            return !ConnectorText.isASCIIWhitespace(p[0]) && !ConnectorText.isASCIIWhitespace(p[n - 1])
                && p[0] < 0x80 && p[n - 1] < 0x80
        }
        let value = columns.text.string(ref)!
        if plain { return value }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? "mp4" : trimmed
    }
}

nonisolated enum XtreamSeriesColumns {
    static let fields: [ConnectorRecordColumns.Field] = [
        .init(key: "series_id", kind: .flex), .init(key: "name", kind: .strictString),
        .init(key: "cover", kind: .strictString), .init(key: "category_id", kind: .flexIfPresent),
        .init(key: "plot", kind: .strictString), .init(key: "cast", kind: .strictString),
        .init(key: "director", kind: .strictString), .init(key: "genre", kind: .strictString),
        .init(key: "release_date", kind: .strictString), .init(key: "rating", kind: .flexIfPresent),
    ]
    static let seriesID = 0, name = 1, cover = 2, category = 3, plot = 4, cast = 5, director = 6, genre = 7, releaseDate = 8, rating = 9

    static func decode(_ data: Data, workers: Int = ConnectorParallel.workerCount) throws -> [ConnectorRecordColumns] {
        try ConnectorRecordColumns.decode(data, fields: fields, workers: workers)
    }

    /// Exactly as `XtreamClient.fetchSeries` maps entries.
    static func series(_ chunks: [ConnectorRecordColumns], categories: XtreamCategoryTable,
                       workers: Int = ConnectorParallel.workerCount) -> [VODSeries] {
        ConnectorParallel.materialize(chunks, rows: \.count, workers: workers) { columns, rows, result in
            appendSeries(columns, rows, categories: categories, to: &result)
        }
    }

    private static func appendSeries(_ columns: ConnectorRecordColumns, _ rows: Range<Int>, categories: XtreamCategoryTable,
                                     to result: inout [VODSeries]) {
        for row in rows {
            let categoryName = columns.categoryName(row, category, in: categories)
            result.append(VODSeries(
                id: columns.string(row, seriesID)!,
                name: columns.string(row, name) ?? "Unknown",
                posterURL: columns.string(row, cover).flatMap { URL(string: $0) },
                group: categoryName ?? "Series",
                genre: columns.string(row, genre) ?? categoryName,
                rating: columns.nonEmpty(row, rating),
                releaseDate: columns.string(row, releaseDate),
                summary: columns.string(row, plot),
                director: columns.string(row, director),
                cast: columns.string(row, cast)
            ))
        }
    }
}

nonisolated extension ConnectorRecordColumns {
    func categoryName(_ row: Int, _ field: Int, in categories: XtreamCategoryTable) -> String? {
        let ref = self[row, field]
        guard ref != ConnectorStringTable.none else { return nil }
        return text.withBytes(ref) { categories.name($0, $1) }
    }

}
