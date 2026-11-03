import Foundation

// Stalker/Ministra portal responses (`{"js": …}` envelopes) decoded in one
// pass into flat columns. Declines (`ConnectorJSONDecline`) whenever the
// reference JSONDecoder path could differ; StalkerClient then runs it.

nonisolated enum StalkerColumnarDecoder {
    typealias Field = ConnectorRecordColumns.Field

    /// Walks `{"js": X}` (first `js` wins, other keys skipped) and runs
    /// `body` with the cursor at X. Absent `js` declines (keyNotFound).
    static func withEnvelope<R>(_ data: Data, _ body: (inout ConnectorJSONCursor) throws -> R) throws -> R {
        try ConnectorJSONCursor.withCursor(data) { c in
            var result: R?
            if try c.beginObject() {
                repeat {
                    let key = try c.readKey()
                    if result == nil, c.keyEquals(key, "js") {
                        result = try body(&c)
                    } else {
                        try c.skipValue(depth: 1)
                    }
                } while try c.nextMember()
            }
            try c.finish()
            guard let result else { throw ConnectorJSONDecline() }
            return result
        }
    }

    struct OrderedList: Sendable {
        var totalItems: Int
        var maxPageItems: Int
        var chunks: [ConnectorRecordColumns]
        var count: Int { chunks.reduce(0) { $0 + $1.count } }
    }

    /// `OrderedList<Item>`: required integral `total_items`, `max_page_items`
    /// and an array `data` of records.
    static func orderedList(_ data: Data, fields: [Field], workers: Int = ConnectorParallel.workerCount) throws -> OrderedList {
        try withEnvelope(data) { c in
            guard c.peek() == 0x7B else { throw ConnectorJSONDecline() }
            var total = ConnectorJSONSpan.absent, pageSize = ConnectorJSONSpan.absent
            var chunks: [ConnectorRecordColumns]?
            if try c.beginObject() {
                repeat {
                    let key = try c.readKey()
                    if !total.isPresent, c.keyEquals(key, "total_items") {
                        total = try c.readValue(depth: 2)
                    } else if !pageSize.isPresent, c.keyEquals(key, "max_page_items") {
                        pageSize = try c.readValue(depth: 2)
                    } else if chunks == nil, c.keyEquals(key, "data") {
                        guard c.peek() == 0x5B else { throw ConnectorJSONDecline() }
                        chunks = try ConnectorParallel.decodeArray(&c, workers: workers, makeResult: { bytes -> ConnectorRecordColumns in
                            ConnectorRecordColumns(fieldCount: fields.count)
                        }, element: { cursor, columns in try columns.appendRecord(&cursor, fields: fields, depth: 3) })
                    } else {
                        try c.skipValue(depth: 2)
                    }
                } while try c.nextMember()
            }
            guard total.kind == .number, pageSize.kind == .number, let chunks,
                  let totalItems = try c.codableInt(total), let maxPageItems = try c.codableInt(pageSize) else {
                throw ConnectorJSONDecline()
            }
            return OrderedList(totalItems: totalItems, maxPageItems: maxPageItems, chunks: chunks)
        }
    }

    // MARK: Categories

    static let categoryFields: [Field] = [
        .init(key: "id", kind: .requiredString), .init(key: "title", kind: .strictString), .init(key: "alias", kind: .strictString),
    ]

    /// `Envelope<[Category]>` → the reference `fetchCategories` map.
    static func categories(_ data: Data, nonEmpty: (String?) -> String?) throws -> [String: String] {
        let columns: ConnectorRecordColumns = try withEnvelope(data) { c in
            guard c.peek() == 0x5B else { throw ConnectorJSONDecline() }
            var columns = ConnectorRecordColumns(fieldCount: categoryFields.count)
            if try c.beginArray() {
                repeat { try columns.appendRecord(&c, fields: categoryFields, depth: 2) } while try c.nextElement()
            }
            return columns
        }
        var map: [String: String] = [:]
        for row in 0..<columns.count {
            let id = columns.string(row, 0)!
            guard id != "*" else { continue }
            map[id] = nonEmpty(columns.string(row, 1)) ?? nonEmpty(columns.string(row, 2)) ?? id
        }
        return map
    }

    // MARK: Channels

    static let channelFields: [Field] = [
        .init(key: "id", kind: .requiredString), .init(key: "name", kind: .strictString), .init(key: "logo", kind: .strictString),
        .init(key: "cmd", kind: .strictString), .init(key: "tv_genre_id", kind: .stalkerFlexible),
        .init(key: "genres_str", kind: .strictString), .init(key: "xmltv_id", kind: .strictString),
        .init(key: "enable_tv_archive", kind: .stalkerFlexible), .init(key: "tv_archive_duration", kind: .stalkerFlexible),
    ]
    enum ChannelField { static let id = 0, name = 1, logo = 2, cmd = 3, genreID = 4, genres = 5, xmltv = 6, archive = 7, archiveDays = 8 }

    // MARK: Media (VOD / series)

    static let mediaFields: [Field] = [
        .init(key: "id", kind: .requiredString), .init(key: "name", kind: .strictString),
        .init(key: "category_id", kind: .stalkerFlexible), .init(key: "cmd", kind: .strictString),
        .init(key: "screenshot_uri", kind: .strictString), .init(key: "pic", kind: .strictString),
        .init(key: "genres_str", kind: .strictString), .init(key: "actors", kind: .strictString),
        .init(key: "director", kind: .strictString), .init(key: "rating_imdb", kind: .stalkerFlexible),
        .init(key: "year", kind: .strictString), .init(key: "added", kind: .strictString),
        .init(key: "description", kind: .strictString), .init(key: "series", kind: .intList),
        .init(key: "path", kind: .strictString),
    ]
    enum MediaField {
        static let id = 0, name = 1, categoryID = 2, cmd = 3, screenshot = 4, pic = 5, genres = 6, actors = 7, director = 8
        static let rating = 9, year = 10, added = 11, description = 12, series = 13, path = 14
    }

    // MARK: EPG

    static let epgFields: [Field] = [
        .init(key: "id", kind: .stalkerFlexible), .init(key: "ch_id", kind: .stalkerFlexible),
        .init(key: "name", kind: .strictString), .init(key: "descr", kind: .strictString),
        .init(key: "start_timestamp", kind: .stalkerFlexible), .init(key: "stop_timestamp", kind: .stalkerFlexible),
    ]
    enum EPGField { static let id = 0, channelID = 1, name = 2, description = 3, start = 4, stop = 5 }

    struct EPGInfo: Sendable {
        var entries = ConnectorRecordColumns(fieldCount: epgFields.count)
        /// Map key (channel ID) per group, with the group's entry rows.
        var keys: [String] = []
        var rows: [Range<Int>] = []
    }

    /// `Envelope<EPGInfo>` where `data` is `[String: [EPGEntry]]`. Groups
    /// keep response order; duplicate or non-ASCII keys decline (the
    /// reference dictionary would merge them).
    static func epgInfo(_ data: Data) throws -> EPGInfo {
        try withEnvelope(data) { c in
            guard c.peek() == 0x7B else { throw ConnectorJSONDecline() }
            var info: EPGInfo?
            if try c.beginObject() {
                repeat {
                    let key = try c.readKey()
                    guard info == nil, c.keyEquals(key, "data") else { try c.skipValue(depth: 2); continue }
                    guard c.peek() == 0x7B else { throw ConnectorJSONDecline() }
                    var decoded = EPGInfo()
                    var seen = Set<String>()
                    var scratch: [UInt8] = []
                    if try c.beginObject() {
                        repeat {
                            let channelKey = try c.readKey()
                            for i in channelKey.start..<channelKey.end where c.byte(i) >= 0x80 { throw ConnectorJSONDecline() }
                            let name = c.string(channelKey, scratch: &scratch)
                            guard seen.insert(name).inserted, c.peek() == 0x5B else { throw ConnectorJSONDecline() }
                            let first = decoded.entries.count
                            if try c.beginArray() {
                                repeat { try decoded.entries.appendRecord(&c, fields: epgFields, depth: 4) } while try c.nextElement()
                            }
                            decoded.keys.append(name)
                            decoded.rows.append(first..<decoded.entries.count)
                        } while try c.nextMember()
                    }
                    info = decoded
                } while try c.nextMember()
            }
            guard let info else { throw ConnectorJSONDecline() }
            return info
        }
    }
}
