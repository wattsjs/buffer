import Foundation

// Frozen copies of the pre-columnar connector decoders (JSONDecoder /
// JSONSerialization into Codable/dictionary intermediates, then mapping to
// the app models). The differential tests compare the production fast path
// against these on synthetic and quirky payloads; the benchmarks time them.
// Compile together with Buffer/Services/XtreamClient.swift (flex helpers).

enum LegacyXtream {
    struct Category: Decodable {
        let category_id: String
        let category_name: String?
        enum CodingKeys: String, CodingKey { case category_id, category_name }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            category_id = try c.flexString(forKey: .category_id)
            category_name = try c.decodeIfPresent(String.self, forKey: .category_name)
        }
    }

    struct Stream: Decodable {
        let name: String
        let stream_id: String
        let stream_icon: String?
        let epg_channel_id: String?
        let category_id: String?
        let tv_archive: String?
        let tv_archive_duration: String?
        enum CodingKeys: String, CodingKey {
            case name, stream_id, stream_icon, epg_channel_id, category_id, tv_archive, tv_archive_duration
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stream_id = try c.flexInt(forKey: .stream_id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
            stream_icon = try c.decodeIfPresent(String.self, forKey: .stream_icon)
            epg_channel_id = try c.decodeIfPresent(String.self, forKey: .epg_channel_id)
            category_id = try c.flexStringIfPresent(forKey: .category_id)
            tv_archive = try c.flexIntIfPresent(forKey: .tv_archive)
            tv_archive_duration = try c.flexIntIfPresent(forKey: .tv_archive_duration)
        }
    }

    struct VODStream: Decodable {
        let name: String
        let stream_id: String
        let stream_icon: String?
        let category_id: String?
        let container_extension: String?
        let rating: String?
        let rating_5based: String?
        let plot: String?
        let year: String?
        let releaseDate: String?
        let added: String?
        let director: String?
        let cast: String?
        let country: String?
        let genre: String?
        let duration_secs: String?
        enum CodingKeys: String, CodingKey {
            case name, stream_id, stream_icon, category_id, container_extension
            case rating, rating_5based, plot, year, added, director, cast, country, genre, duration_secs
            case releaseDate = "release_date"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stream_id = try c.flexInt(forKey: .stream_id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
            stream_icon = try c.decodeIfPresent(String.self, forKey: .stream_icon)
            category_id = try c.flexStringIfPresent(forKey: .category_id)
            container_extension = try c.decodeIfPresent(String.self, forKey: .container_extension)
            rating = try c.flexStringIfPresent(forKey: .rating)
            rating_5based = try c.flexStringIfPresent(forKey: .rating_5based)
            plot = try c.decodeIfPresent(String.self, forKey: .plot)
            year = try c.flexIntIfPresent(forKey: .year)
            releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
            added = try c.flexStringIfPresent(forKey: .added)
            director = try c.decodeIfPresent(String.self, forKey: .director)
            cast = try c.decodeIfPresent(String.self, forKey: .cast)
            country = try c.decodeIfPresent(String.self, forKey: .country)
            genre = try c.decodeIfPresent(String.self, forKey: .genre)
            duration_secs = try c.flexIntIfPresent(forKey: .duration_secs)
        }
    }

    struct Series: Decodable {
        let series_id: String
        let name: String?
        let cover: String?
        let category_id: String?
        let plot: String?
        let cast: String?
        let director: String?
        let genre: String?
        let releaseDate: String?
        let rating: String?
        enum CodingKeys: String, CodingKey {
            case series_id, name, cover, category_id, plot, cast, director, genre, rating
            case releaseDate = "release_date"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            series_id = try c.flexInt(forKey: .series_id)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            cover = try c.decodeIfPresent(String.self, forKey: .cover)
            category_id = try c.flexStringIfPresent(forKey: .category_id)
            plot = try c.decodeIfPresent(String.self, forKey: .plot)
            cast = try c.decodeIfPresent(String.self, forKey: .cast)
            director = try c.decodeIfPresent(String.self, forKey: .director)
            genre = try c.decodeIfPresent(String.self, forKey: .genre)
            releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
            rating = try c.flexStringIfPresent(forKey: .rating)
        }
    }

    struct EPGEnvelope: Decodable {
        let listings: [EPGListing]
        enum CodingKeys: String, CodingKey { case epgListings = "epg_listings" }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            listings = try container.decodeIfPresent([EPGListing].self, forKey: .epgListings) ?? []
        }
    }

    struct EPGListing: Decodable {
        let id: String?
        let title: String?
        let description: String?
        let startTimestamp: String?
        let stopTimestamp: String?
        enum CodingKeys: String, CodingKey {
            case id, title, description
            case startTimestamp = "start_timestamp"
            case stopTimestamp = "stop_timestamp"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.flexStringIfPresent(forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            startTimestamp = try c.flexStringIfPresent(forKey: .startTimestamp)
            stopTimestamp = try c.flexStringIfPresent(forKey: .stopTimestamp)
        }
    }

    static func categories(_ data: Data) throws -> [String: String] {
        let categories = try JSONDecoder().decode([Category].self, from: data)
        var map: [String: String] = [:]
        map.reserveCapacity(categories.count)
        for cat in categories { map[cat.category_id] = cat.category_name ?? "Unknown" }
        return map
    }

    static func channels(_ data: Data, categories cats: [String: String], config: ServerConfig) throws -> [Channel] {
        let streams = try JSONDecoder().decode([Stream].self, from: data)
        var channels: [Channel] = []
        channels.reserveCapacity(streams.count)
        guard let baseURL = config.xtreamStreamBase else { return [] }
        let baseStr = baseURL.absoluteString
        for stream in streams {
            guard let streamURL = URL(string: "\(baseStr)/\(stream.stream_id).m3u8") else { continue }
            let categoryName = stream.category_id.flatMap { cats[$0] } ?? "Uncategorized"
            channels.append(Channel(
                id: stream.stream_id,
                name: stream.name,
                logoURL: stream.stream_icon.flatMap { URL(string: $0) },
                group: categoryName,
                streamURL: streamURL,
                epgChannelID: nonEmpty(stream.epg_channel_id) ?? "xtream-stream-\(stream.stream_id)",
                catchup: catchup(streamID: stream.stream_id, archive: stream, config: config)
            ))
        }
        return channels
    }

    static func catchup(streamID: String, archive: Stream, config: ServerConfig) -> CatchupInfo? {
        guard let tvArchive = archive.tv_archive, tvArchive == "1" else { return nil }
        let days: Int
        if let dur = archive.tv_archive_duration, let d = Int(dur), d > 0 { days = d } else { days = 1 }
        let source = "\(config.xtreamBaseURL)/timeshift/\(config.username)/\(config.password)/${duration}/${Y}-${m}-${d}:${H}-${M}/\(streamID).ts"
        return CatchupInfo(kind: .xc, days: days, source: source)
    }

    static func vodItems(_ data: Data, categories cats: [String: String], config: ServerConfig) throws -> [VODItem] {
        let streams = try JSONDecoder().decode([VODStream].self, from: data)
        return streams.compactMap { stream in
            let ext = normalizedContainerExtension(stream.container_extension)
            guard let streamURL = URL(string: "\(config.xtreamBaseURL)/movie/\(config.username)/\(config.password)/\(stream.stream_id).\(ext)") else {
                return nil
            }
            let categoryName = stream.category_id.flatMap { cats[$0] } ?? "Movies"
            return VODItem(
                id: stream.stream_id,
                name: stream.name,
                posterURL: stream.stream_icon.flatMap { URL(string: $0) },
                group: categoryName,
                streamURL: streamURL,
                kind: .movie,
                genre: nonEmpty(stream.genre) ?? categoryName,
                durationSeconds: Int(stream.duration_secs ?? ""),
                rating: stream.rating?.isEmpty == false ? stream.rating : stream.rating_5based,
                releaseDate: stream.releaseDate ?? stream.year,
                containerExtension: ext,
                summary: stream.plot,
                director: stream.director,
                cast: stream.cast,
                country: stream.country
            )
        }
    }

    static func series(_ data: Data, categories cats: [String: String]) throws -> [VODSeries] {
        let series = try JSONDecoder().decode([Series].self, from: data)
        return series.map { entry in
            VODSeries(
                id: entry.series_id,
                name: entry.name ?? "Unknown",
                posterURL: entry.cover.flatMap { URL(string: $0) },
                group: entry.category_id.flatMap { cats[$0] } ?? "Series",
                genre: entry.genre ?? entry.category_id.flatMap { cats[$0] },
                rating: nonEmpty(entry.rating),
                releaseDate: entry.releaseDate,
                summary: entry.plot,
                director: entry.director,
                cast: entry.cast
            )
        }
    }

    struct CatchupResult {
        var programs: [EPGProgram]
        var receivedListings: Int
        var earliest: Double
        var latest: Double
    }

    static func catchupListings(_ data: Data, channelID: String, epgID: String, minimumStart: Date?) throws -> CatchupResult {
        let envelope = try JSONDecoder().decode(EPGEnvelope.self, from: data)
        var programs: [EPGProgram] = []
        programs.reserveCapacity(envelope.listings.count)
        var earliest = Double.infinity
        var latest = 0.0
        for listing in envelope.listings {
            guard let start = date(fromEpochString: listing.startTimestamp),
                  let end = date(fromEpochString: listing.stopTimestamp),
                  end > start else { continue }
            earliest = min(earliest, start.timeIntervalSince1970)
            latest = max(latest, end.timeIntervalSince1970)
            if let minimumStart, end <= minimumStart { continue }
            guard let title = decodedEPGText(listing.title) else { continue }
            let listingID = listing.id?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = (listingID?.isEmpty == false ? listingID! : nil)
                ?? "\(Int(start.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))"
            programs.append(EPGProgram(
                id: "xtream-simple-\(channelID)-\(id)",
                channelID: epgID,
                title: title,
                description: decodedEPGText(listing.description) ?? "",
                start: start,
                end: end
            ))
        }
        return CatchupResult(programs: programs, receivedListings: envelope.listings.count,
                             earliest: earliest.isFinite ? earliest : 0, latest: latest)
    }

    static func normalizedContainerExtension(_ value: String?) -> String {
        let trimmed = (value ?? "mp4")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? "mp4" : trimmed
    }

    static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func decodedEPGText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if let data = Data(base64Encoded: trimmed),
           let decoded = String(data: data, encoding: .utf8) {
            let clean = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        return trimmed
    }

    static func date(fromEpochString value: String?) -> Date? {
        guard let value, let seconds = TimeInterval(value),
              seconds.isFinite, seconds > 0, seconds < Double(Int.max) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

enum LegacyStalker {
    struct FlexibleString: Decodable, Sendable {
        let value: String
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { value = "" }
            else if let string = try? container.decode(String.self) { value = string }
            else if let int = try? container.decode(Int.self) { value = String(int) }
            else if let double = try? container.decode(Double.self) { value = String(Int(double)) }
            else { value = "" }
        }
    }
    struct Envelope<Value: Decodable>: Decodable { let js: Value }
    struct Category: Decodable { let id: String; let title: String?; let alias: String? }
    struct OrderedList<Item: Decodable>: Decodable {
        let totalItems: Int
        let maxPageItems: Int
        let data: [Item]
        enum CodingKeys: String, CodingKey {
            case totalItems = "total_items"
            case maxPageItems = "max_page_items"
            case data
        }
    }
    struct StalkerChannel: Decodable {
        let id: String
        let number: FlexibleString?
        let name: String?
        let logo: String?
        let cmd: String?
        let tvGenreID: FlexibleString?
        let genresString: String?
        let xmltvID: String?
        let enableTVArchive: FlexibleString?
        let tvArchiveDuration: FlexibleString?
        enum CodingKeys: String, CodingKey {
            case id, number, name, logo, cmd
            case tvGenreID = "tv_genre_id"
            case genresString = "genres_str"
            case xmltvID = "xmltv_id"
            case enableTVArchive = "enable_tv_archive"
            case tvArchiveDuration = "tv_archive_duration"
        }
    }
    struct MediaItem: Decodable {
        let id: String
        let name: String?
        let categoryID: FlexibleString?
        let cmd: String?
        let screenshotURI: String?
        let pic: String?
        let genresString: String?
        let actors: String?
        let director: String?
        let ratingIMDB: FlexibleString?
        let year: String?
        let added: String?
        let description: String?
        let series: [Int]?
        let path: String?
        enum CodingKeys: String, CodingKey {
            case id, name, cmd, pic, actors, director, year, added, description, series, path
            case categoryID = "category_id"
            case screenshotURI = "screenshot_uri"
            case genresString = "genres_str"
            case ratingIMDB = "rating_imdb"
        }
    }
    struct EPGInfo: Decodable { let data: [String: [EPGEntry]] }
    struct EPGEntry: Decodable {
        let id: FlexibleString?
        let channelID: FlexibleString?
        let name: String?
        let description: String?
        let startTimestamp: FlexibleString?
        let stopTimestamp: FlexibleString?
        enum CodingKeys: String, CodingKey {
            case id, name
            case channelID = "ch_id"
            case description = "descr"
            case startTimestamp = "start_timestamp"
            case stopTimestamp = "stop_timestamp"
        }
    }

    static func categories(_ data: Data) throws -> [String: String] {
        let categories = try JSONDecoder().decode(Envelope<[Category]>.self, from: data).js
        var map: [String: String] = [:]
        for category in categories where category.id != "*" {
            map[category.id] = nonEmpty(category.title) ?? nonEmpty(category.alias) ?? category.id
        }
        return map
    }

    static func channels(_ data: Data, categories: [String: String]) throws -> [Channel] {
        let all = try JSONDecoder().decode(Envelope<OrderedList<StalkerChannel>>.self, from: data).js
        return all.data.compactMap { channel in
            guard let command = channel.cmd, let streamURL = playableURL(fromCommand: command) else { return nil }
            let genreID = channel.tvGenreID?.value
            let group = nonEmpty(channel.genresString) ?? genreID.flatMap { categories[$0] } ?? "Uncategorized"
            let isArchived = (Int(channel.enableTVArchive?.value ?? "") ?? 0) > 0
            let catchup: CatchupInfo? = isArchived
                ? CatchupInfo(kind: .shift, days: max(Int(channel.tvArchiveDuration?.value ?? "") ?? 0, 1), source: nil) : nil
            return Channel(id: channel.id, name: channel.name ?? "Unknown", logoURL: channel.logo.flatMap { URL(string: $0) },
                           group: group, streamURL: streamURL, epgChannelID: nonEmpty(channel.xmltvID) ?? channel.id, catchup: catchup)
        }
    }

    static func epg(_ data: Data, channels: [Channel]) throws -> [EPGProgram] {
        let epg = try JSONDecoder().decode(Envelope<EPGInfo>.self, from: data).js
        let guideIDs = Dictionary(channels.compactMap { channel -> (String, String)? in
            guard let epgID = channel.epgChannelID else { return nil }
            return (channel.id, epgID)
        }, uniquingKeysWith: { first, _ in first })
        return epg.data.flatMap { channelID, entries in
            entries.compactMap { entry in
                let start = TimeInterval(Int(entry.startTimestamp?.value ?? "") ?? 0)
                let stop = TimeInterval(Int(entry.stopTimestamp?.value ?? "") ?? 0)
                guard start > 0, stop > start else { return nil }
                guard let title = nonEmpty(entry.name) else { return nil }
                let nativeChannelID = nonEmpty(entry.channelID?.value) ?? channelID
                let resolvedChannelID = guideIDs[nativeChannelID] ?? guideIDs[channelID] ?? nativeChannelID
                return EPGProgram(
                    id: nonEmpty(entry.id?.value) ?? "\(resolvedChannelID):\(entry.startTimestamp?.value ?? ""):\(entry.stopTimestamp?.value ?? "")",
                    channelID: resolvedChannelID, title: title, description: entry.description ?? "",
                    start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: stop))
            }
        }
    }

    static func mediaPage(_ data: Data) throws -> (total: Int, pageSize: Int, items: [MediaItem]) {
        let page = try JSONDecoder().decode(Envelope<OrderedList<MediaItem>>.self, from: data).js
        return (page.totalItems, page.maxPageItems, page.data)
    }

    static func vodItems(_ items: [MediaItem], categories: [String: String]) -> [VODItem] {
        items.compactMap { item in
            guard let command = item.cmd, let streamURL = placeholderURL(type: "vod", command: command) else { return nil }
            let group = item.categoryID.flatMap { categories[$0.value] } ?? "Movies"
            return VODItem(id: "stalker:vod:\(item.id)", name: item.name ?? "Unknown",
                           posterURL: firstURL(item.screenshotURI, item.pic), group: group, streamURL: streamURL,
                           kind: .movie, genre: nonEmpty(item.genresString) ?? group, rating: nonEmpty(item.ratingIMDB?.value),
                           releaseDate: firstNonEmpty(item.year, item.added), containerExtension: nil,
                           summary: item.description, director: item.director, cast: item.actors)
        }
    }

    static func series(_ items: [MediaItem], categories: [String: String]) -> [VODSeries] {
        items.map { item in
            let group = item.categoryID.flatMap { categories[$0.value] } ?? "Series"
            return VODSeries(id: "stalker:series:\(item.id)", name: item.name ?? "Unknown",
                             posterURL: firstURL(item.screenshotURI, item.pic), group: group,
                             genre: nonEmpty(item.genresString) ?? group, rating: nonEmpty(item.ratingIMDB?.value),
                             releaseDate: firstNonEmpty(item.year, item.added), summary: item.description,
                             director: item.director, cast: item.actors)
        }
    }

    static func placeholderURL(type: String, command: String, episode: Int? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "buffer-stalker"
        components.host = type
        var queryItems = [URLQueryItem(name: "cmd", value: command)]
        if let episode { queryItems.append(URLQueryItem(name: "episode", value: "\(episode)")) }
        components.queryItems = queryItems
        return components.url
    }

    static func playableURL(fromCommand command: String) -> URL? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let token: String
        if trimmed.hasPrefix("ffmpeg ") { token = String(trimmed.dropFirst("ffmpeg ".count)) }
        else if let last = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).last { token = String(last) }
        else { token = trimmed }
        return URL(string: token)
    }

    static func firstURL(_ values: String?...) -> URL? {
        for value in values { if let raw = nonEmpty(value), let url = URL(string: raw) { return url } }
        return nil
    }

    static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values { if let normalized = nonEmpty(value) { return normalized } }
        return nil
    }

    static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed.uppercased() == "N/A" ? nil : trimmed
    }
}

/// JSONSerialization-based ESPN scoreboard parsing exactly as shipped before
/// the tape decoder.
final class LegacyESPN {
    static let tournamentSports: Set<Sport> = [.tennis, .golf, .motorsport]

    func scoreboardIsValid(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["events"] is [[String: Any]] else { return false }
        return true
    }

    func eventCount(_ data: Data) -> Int? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["events"] as? [[String: Any]])?.count
    }

    func golfEventIDs(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else { return [] }
        return events.compactMap { $0["id"] as? String }
    }

    func golfRounds(_ data: Data, league: League) -> [SportEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]],
              let ev = events.first else { return [] }
        return buildGolfRounds(from: ev, league: league)
    }

    func parse(data: Data, league: League) -> [SportEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else { return [] }
        return events.flatMap { parseEvent($0, league: league) }
    }

    func parseEvent(_ json: [String: Any], league: League) -> [SportEvent] {
        guard let id = json["id"] as? String, let name = json["name"] as? String,
              let dateString = json["date"] as? String else { return [] }
        let groupings = json["groupings"] as? [[String: Any]]
        if Self.tournamentSports.contains(league.sport), let groupings, !groupings.isEmpty {
            return expandGroupings(groupings, eventID: id, tournamentName: name, league: league)
        }
        let competitions = json["competitions"] as? [[String: Any]]
        if Self.tournamentSports.contains(league.sport), let competitions, competitions.count > 1 {
            return competitions.compactMap { parseSessionCompetition($0, eventID: id, tournamentName: name, league: league) }
        }
        let shortName = (json["shortName"] as? String) ?? name
        let startDate = parseDate(dateString)
        let competition = competitions?.first
        let eventStatusType = (json["status"] as? [String: Any])?["type"] as? [String: Any]
        let compStatusType = (competition?["status"] as? [String: Any])?["type"] as? [String: Any]
        let eventShortDetail = eventStatusType?["shortDetail"] as? String
        let eventDetail = eventStatusType?["detail"] as? String
        let compShortDetail = compStatusType?["shortDetail"] as? String
        let compDetail = compStatusType?["detail"] as? String
        let bestShortDetail = (eventShortDetail?.isEmpty == false ? eventShortDetail : compShortDetail)
        let bestDetail = (eventDetail?.isEmpty == false ? eventDetail : compDetail)
        var mergedStatus: [String: Any] = eventStatusType ?? [:]
        if let bestShortDetail { mergedStatus["shortDetail"] = bestShortDetail }
        if let bestDetail { mergedStatus["detail"] = bestDetail }
        let status = parseStatus(mergedStatus)
        let competitors = competition?["competitors"] as? [[String: Any]]
        let (home, away) = parseTeams(competitors)
        let broadcasts = parseBroadcasts(competition)
        let venueJSON = (competition?["venue"] as? [String: Any]) ?? (json["venue"] as? [String: Any])
        let venue = venueJSON?["fullName"] as? String
        let detail = bestShortDetail ?? bestDetail
        let leader: LeaderInfo? = {
            guard home == nil, away == nil, let comps = competitors, comps.count > 1 else { return nil }
            let sorted = comps.sorted { (a, b) in
                let ao = a["order"] as? Int ?? Int.max
                let bo = b["order"] as? Int ?? Int.max
                return ao < bo
            }
            guard let first = sorted.first, let athlete = first["athlete"] as? [String: Any],
                  let name = (athlete["displayName"] as? String) ?? (athlete["shortName"] as? String),
                  let score = first["score"] as? String, !score.isEmpty else { return nil }
            return LeaderInfo(name: name, score: score)
        }()
        return [SportEvent(id: "\(league.id)_\(id)", sport: league.sport, league: league, title: name, shortTitle: shortName,
                           homeTeam: home, awayTeam: away, startDate: startDate, status: status, broadcast: broadcasts,
                           venue: venue, detail: detail, tournamentName: nil, leader: leader)]
    }

    func expandGroupings(_ groupings: [[String: Any]], eventID: String, tournamentName: String, league: League) -> [SportEvent] {
        guard let primary = groupings.first, let comps = primary["competitions"] as? [[String: Any]] else { return [] }
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return comps.compactMap { comp -> SportEvent? in
            let state = (comp["status"] as? [String: Any])?["type"] as? [String: Any]
            let stateStr = state?["state"] as? String ?? "pre"
            let compDate = (comp["date"] as? String) ?? (comp["startDate"] as? String)
            if stateStr == "post", let compDate {
                let date = parseDate(compDate)
                if date < startOfToday { return nil }
            }
            let competitors = comp["competitors"] as? [[String: Any]] ?? []
            if stateStr == "pre" && competitors.count == 2 {
                let allTBD = competitors.allSatisfy { c in
                    let name = (c["athlete"] as? [String: Any])?["displayName"] as? String
                    return name == nil || name == "TBD"
                }
                if allTBD { return nil }
            }
            return parseTournamentMatch(comp, eventID: eventID, tournamentName: tournamentName, league: league)
        }
    }

    func parseTournamentMatch(_ comp: [String: Any], eventID: String, tournamentName: String, league: League) -> SportEvent? {
        let compID = (comp["id"] as? String) ?? UUID().uuidString
        let statusType = (comp["status"] as? [String: Any])?["type"] as? [String: Any]
        let status = parseStatus(statusType)
        let dateString = (comp["date"] as? String) ?? (comp["startDate"] as? String)
        let startDate = dateString.map(parseDate) ?? .distantPast
        let (home, away) = parseAthletes(comp["competitors"] as? [[String: Any]])
        let title: String
        let shortTitle: String
        if let away, let home {
            title = "\(away.displayName) vs \(home.displayName)"
            shortTitle = "\(away.abbreviation) vs \(home.abbreviation)"
        } else {
            title = tournamentName
            shortTitle = tournamentName
        }
        let venue = (comp["venue"] as? [String: Any])?["fullName"] as? String
        let detail = (statusType?["shortDetail"] as? String) ?? (statusType?["detail"] as? String)
        return SportEvent(id: "\(league.id)_\(eventID)_\(compID)", sport: league.sport, league: league, title: title,
                          shortTitle: shortTitle, homeTeam: home, awayTeam: away, startDate: startDate, status: status,
                          broadcast: parseBroadcasts(comp), venue: venue, detail: detail, tournamentName: tournamentName, leader: nil)
    }

    func buildGolfRounds(from ev: [String: Any], league: League) -> [SportEvent] {
        guard let id = ev["id"] as? String, let name = ev["name"] as? String else { return [] }
        let shortName = (ev["shortName"] as? String) ?? name
        let comp = (ev["competitions"] as? [[String: Any]])?.first
        let competitors = (comp?["competitors"] as? [[String: Any]]) ?? []
        let compStatus = comp?["status"] as? [String: Any]
        let compStatusType = compStatus?["type"] as? [String: Any]
        let compState = (compStatusType?["state"] as? String) ?? "pre"
        let compPeriod = (compStatus?["period"] as? Int) ?? 1
        let broadcasts = parseBroadcasts(comp)
        let courses = ev["courses"] as? [[String: Any]]
        let venue = (courses?.first?["name"] as? String) ?? ((comp?["venue"] as? [String: Any])?["fullName"] as? String)
        struct RoundAgg { var earliestTee: Date?; var scored: Int; var total: Int }
        var byPeriod: [Int: RoundAgg] = [:]
        var maxPeriod = 0
        for c in competitors {
            let ls = c["linescores"] as? [[String: Any]] ?? []
            for line in ls {
                guard let period = line["period"] as? Int else { continue }
                maxPeriod = max(maxPeriod, period)
                var agg = byPeriod[period] ?? RoundAgg(earliestTee: nil, scored: 0, total: 0)
                agg.total += 1
                if line["value"] != nil { agg.scored += 1 }
                if let teeStr = line["teeTime"] as? String {
                    let t = parseDate(teeStr)
                    if let cur = agg.earliestTee { agg.earliestTee = min(cur, t) } else { agg.earliestTee = t }
                }
                byPeriod[period] = agg
            }
        }
        guard maxPeriod > 0 else { return [] }
        let leader = extractGolfLeader(competitors: competitors)
        let fallbackStart = parseDate((ev["date"] as? String) ?? "")
        var out: [SportEvent] = []
        for period in 1...maxPeriod {
            let agg = byPeriod[period] ?? RoundAgg(earliestTee: nil, scored: 0, total: 0)
            let startDate = agg.earliestTee ?? fallbackStart.addingTimeInterval(Double(period - 1) * 86400)
            let status: EventStatus
            let detailText: String
            if period < compPeriod {
                status = .final_(detail: "Round \(period) Complete"); detailText = "Round \(period) Complete"
            } else if period == compPeriod {
                switch compState {
                case "in": status = .live(detail: "R\(period) in progress"); detailText = "Round \(period) in progress"
                case "post": status = .final_(detail: "R\(period) Play Complete"); detailText = "Round \(period) Play Complete"
                default: status = .scheduled; detailText = "Round \(period)"
                }
            } else {
                status = .scheduled; detailText = "Round \(period)"
            }
            let roundLeader: LeaderInfo? = (status.isLive || status.isFinished) ? leader : nil
            out.append(SportEvent(id: "\(league.id)_\(id)_r\(period)", sport: league.sport, league: league,
                                  title: "\(name) — Round \(period)", shortTitle: "R\(period) \(shortName)", homeTeam: nil,
                                  awayTeam: nil, startDate: startDate, status: status, broadcast: broadcasts, venue: venue,
                                  detail: detailText, tournamentName: name, leader: roundLeader))
        }
        return out
    }

    func extractGolfLeader(competitors: [[String: Any]]) -> LeaderInfo? {
        let sorted = competitors.sorted { a, b in
            let ao = (a["sortOrder"] as? Int) ?? (a["order"] as? Int) ?? Int.max
            let bo = (b["sortOrder"] as? Int) ?? (b["order"] as? Int) ?? Int.max
            return ao < bo
        }
        guard let first = sorted.first, let athlete = first["athlete"] as? [String: Any],
              let name = (athlete["displayName"] as? String) ?? (athlete["shortName"] as? String) else { return nil }
        let scoreDisplay: String? = {
            if let dict = first["score"] as? [String: Any], let dv = dict["displayValue"] as? String, !dv.isEmpty { return dv }
            if let str = first["score"] as? String, !str.isEmpty { return str }
            return nil
        }()
        guard let score = scoreDisplay else { return nil }
        return LeaderInfo(name: name, score: score)
    }

    func parseSessionCompetition(_ comp: [String: Any], eventID: String, tournamentName: String, league: League) -> SportEvent? {
        let compID = (comp["id"] as? String) ?? UUID().uuidString
        let sessionAbbr = ((comp["type"] as? [String: Any])?["abbreviation"] as? String) ?? ""
        let statusType = (comp["status"] as? [String: Any])?["type"] as? [String: Any]
        let status = parseStatus(statusType)
        let dateString = (comp["date"] as? String) ?? (comp["startDate"] as? String)
        let startDate = dateString.map(parseDate) ?? .distantPast
        let title = sessionAbbr.isEmpty ? tournamentName : "\(tournamentName) — \(sessionAbbr)"
        let venue = (comp["venue"] as? [String: Any])?["fullName"] as? String
        let detail = (statusType?["shortDetail"] as? String) ?? (statusType?["detail"] as? String)
        return SportEvent(id: "\(league.id)_\(eventID)_\(compID)", sport: league.sport, league: league, title: title,
                          shortTitle: title, homeTeam: nil, awayTeam: nil, startDate: startDate, status: status,
                          broadcast: parseBroadcasts(comp), venue: venue, detail: detail, tournamentName: tournamentName, leader: nil)
    }

    func parseStatus(_ type: [String: Any]?) -> EventStatus {
        guard let state = type?["state"] as? String else { return .scheduled }
        let detail = type?["shortDetail"] as? String
        switch state {
        case "in":
            if let d = detail?.lowercased(), d.contains("halftime") || d.contains("half") { return .halftime }
            return .live(detail: detail)
        case "post": return .final_(detail: detail)
        case "pre":
            if let d = detail?.lowercased() {
                if d.contains("postponed") { return .postponed }
                if d.contains("delayed") { return .delayed }
                if d.contains("canceled") || d.contains("cancelled") { return .canceled }
            }
            return .scheduled
        default: return .scheduled
        }
    }

    func parseTeams(_ competitors: [[String: Any]]?) -> (home: TeamInfo?, away: TeamInfo?) {
        guard let competitors else { return (nil, nil) }
        var home: TeamInfo?
        var away: TeamInfo?
        for competitor in competitors {
            let team = competitor["team"] as? [String: Any]
            let info = TeamInfo(
                name: (team?["shortDisplayName"] as? String) ?? (team?["name"] as? String) ?? "TBD",
                abbreviation: (team?["abbreviation"] as? String) ?? "",
                displayName: (team?["displayName"] as? String) ?? (team?["name"] as? String) ?? "TBD",
                score: competitor["score"] as? String,
                logoURL: (team?["logo"] as? String).flatMap(URL.init(string:)),
                record: parseRecord(competitor))
            if ((competitor["homeAway"] as? String) ?? "") == "home" { home = info } else { away = info }
        }
        return (home, away)
    }

    func parseAthletes(_ competitors: [[String: Any]]?) -> (home: TeamInfo?, away: TeamInfo?) {
        guard let competitors else { return (nil, nil) }
        var home: TeamInfo?
        var away: TeamInfo?
        for competitor in competitors {
            let athlete = competitor["athlete"] as? [String: Any]
            let flag = athlete?["flag"] as? [String: Any]
            let score: String?
            if let linescores = competitor["linescores"] as? [[String: Any]], !linescores.isEmpty {
                score = linescores.map { set in String(Int(set["value"] as? Double ?? 0)) }.joined(separator: " ")
            } else {
                score = competitor["score"] as? String
            }
            let displayName = (athlete?["displayName"] as? String) ?? (athlete?["fullName"] as? String) ?? "TBD"
            let shortName = (athlete?["shortName"] as? String) ?? displayName
            let info = TeamInfo(name: shortName, abbreviation: shortName, displayName: displayName, score: score,
                                logoURL: (flag?["href"] as? String).flatMap(URL.init(string:)), record: nil)
            if ((competitor["homeAway"] as? String) ?? "") == "home" { home = info } else { away = info }
        }
        return (home, away)
    }

    func parseRecord(_ competitor: [String: Any]) -> String? {
        guard let records = competitor["records"] as? [[String: Any]],
              let overall = records.first(where: { ($0["name"] as? String) == "overall" || ($0["type"] as? String) == "total" }),
              let summary = overall["summary"] as? String else { return nil }
        return summary
    }

    func parseBroadcasts(_ competition: [String: Any]?) -> [String] {
        if let geo = competition?["geoBroadcasts"] as? [[String: Any]] {
            let names = geo.compactMap { ($0["media"] as? [String: Any])?["shortName"] as? String }
            if !names.isEmpty { return Array(Set(names)) }
        }
        if let broadcasts = competition?["broadcasts"] as? [[String: Any]] {
            let names = broadcasts.flatMap { ($0["names"] as? [String]) ?? [] }
            if !names.isEmpty { return Array(Set(names)) }
        }
        return []
    }

    let dateFormatters: [ISO8601DateFormatter] = {
        let withSeconds = ISO8601DateFormatter()
        withSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        let noSeconds = ISO8601DateFormatter()
        noSeconds.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate,
                                   .withTime, .withColonSeparatorInTime, .withTimeZone]
        return [withSeconds, standard, noSeconds]
    }()

    func parseDate(_ string: String) -> Date {
        for formatter in dateFormatters { if let date = formatter.date(from: string) { return date } }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mmZ"] {
            df.dateFormat = format
            if let date = df.date(from: string) { return date }
        }
        return .distantPast
    }
}
