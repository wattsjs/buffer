import Foundation

struct StalkerAccountInfo: Codable, Equatable {
    let macAddress: String
    let isAuthenticated: Bool
    let expiryDate: Date?

    var statusLabel: String {
        isAuthenticated ? "Active" : "Unauthorized"
    }
}

nonisolated private struct StalkerFlexibleString: Decodable, Sendable {
    let value: String

    init(value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = ""
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(Int(double))
        } else {
            value = ""
        }
    }
}

actor StalkerClient {
    private static let placeholderScheme = "buffer-stalker"

    private let config: ServerConfig
    private var accessToken: String?
    private let session: URLSession

    init(config: ServerConfig) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 20
        sessionConfig.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: - Response Types

    private struct Envelope<Value: Decodable>: Decodable {
        let js: Value
    }

    private struct Handshake: Decodable {
        let token: String
    }

    private struct MainInfo: Decodable {
        let mac: String?
        let phone: String?
    }

    private struct Category: Decodable {
        let id: String
        let title: String?
        let alias: String?
    }

    private struct OrderedList<Item: Decodable>: Decodable, Sendable where Item: Sendable {
        let totalItems: Int
        let maxPageItems: Int
        let data: [Item]

        init(totalItems: Int, maxPageItems: Int, data: [Item]) {
            self.totalItems = totalItems
            self.maxPageItems = maxPageItems
            self.data = data
        }

        enum CodingKeys: String, CodingKey {
            case totalItems = "total_items"
            case maxPageItems = "max_page_items"
            case data
        }
    }

    private struct StalkerChannel: Decodable, Sendable {
        let id: String
        let number: StalkerFlexibleString?
        let name: String?
        let logo: String?
        let cmd: String?
        let tvGenreID: StalkerFlexibleString?
        let genresString: String?
        let xmltvID: String?
        let enableTVArchive: StalkerFlexibleString?
        let tvArchiveDuration: StalkerFlexibleString?

        enum CodingKeys: String, CodingKey {
            case id, number, name, logo, cmd
            case tvGenreID = "tv_genre_id"
            case genresString = "genres_str"
            case xmltvID = "xmltv_id"
            case enableTVArchive = "enable_tv_archive"
            case tvArchiveDuration = "tv_archive_duration"
        }
    }

    private struct StalkerMediaItem: Decodable, Sendable {
        let id: String
        let name: String?
        let categoryID: StalkerFlexibleString?
        let cmd: String?
        let screenshotURI: String?
        let pic: String?
        let genresString: String?
        let actors: String?
        let director: String?
        let ratingIMDB: StalkerFlexibleString?
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

        /// Row `row` of columns decoded with `StalkerColumnarDecoder.mediaFields`.
        init(columns: ConnectorRecordColumns, row: Int) {
            typealias F = StalkerColumnarDecoder.MediaField
            id = columns.string(row, F.id)!
            name = columns.string(row, F.name)
            categoryID = columns.string(row, F.categoryID).map(StalkerFlexibleString.init(value:))
            cmd = columns.string(row, F.cmd)
            screenshotURI = columns.string(row, F.screenshot)
            pic = columns.string(row, F.pic)
            genresString = columns.string(row, F.genres)
            actors = columns.string(row, F.actors)
            director = columns.string(row, F.director)
            ratingIMDB = columns.string(row, F.rating).map(StalkerFlexibleString.init(value:))
            year = columns.string(row, F.year)
            added = columns.string(row, F.added)
            description = columns.string(row, F.description)
            series = columns.intList(row, F.series)
            path = columns.string(row, F.path)
        }
    }

    private struct LinkResult: Decodable {
        let cmd: String?
        let error: String?
        let type: String?
    }

    private struct EPGInfo: Decodable {
        let data: [String: [EPGEntry]]
    }

    private struct EPGEntry: Decodable {
        let id: StalkerFlexibleString?
        let channelID: StalkerFlexibleString?
        let name: String?
        let description: String?
        let startTimestamp: StalkerFlexibleString?
        let stopTimestamp: StalkerFlexibleString?

        enum CodingKeys: String, CodingKey {
            case id, name
            case channelID = "ch_id"
            case description = "descr"
            case startTimestamp = "start_timestamp"
            case stopTimestamp = "stop_timestamp"
        }
    }

    // MARK: - Public API

    func fetchAccountInfo() async throws -> StalkerAccountInfo {
        _ = try await token()
        let info: MainInfo = try await fetch("account_info", action: "get_main_info")
        return StalkerAccountInfo(
            macAddress: info.mac ?? config.stalkerMACAddress,
            isAuthenticated: true,
            expiryDate: Self.parsePortalDate(info.phone)
        )
    }

    func fetchChannels(sampleOnly: Bool = false) async throws -> [Channel] {
        let categories = (try? await fetchCategories(type: "itv", action: "get_genres")) ?? [:]
        let data: Data
        if sampleOnly {
            data = try await fetchData(
                "itv",
                action: "get_ordered_list",
                extra: [
                    URLQueryItem(name: "genre", value: "*"),
                    URLQueryItem(name: "fav", value: "0"),
                    URLQueryItem(name: "sortby", value: "number"),
                    URLQueryItem(name: "hd", value: "0"),
                    URLQueryItem(name: "p", value: "1")
                ]
            )
        } else {
            data = try await fetchData("itv", action: "get_all_channels")
        }
        return try Self.decodeChannels(data, categories: categories)
    }

    // MARK: - Decoding
    // One-pass columnar decoders; when they decline, the original
    // JSONDecoder path decodes (and reports errors) instead.

    /// `get_all_channels` / `get_ordered_list` (itv) → channels.
    static func decodeChannels(_ data: Data, categories: [String: String]) throws -> [Channel] {
        if let list = try? StalkerColumnarDecoder.orderedList(data, fields: StalkerColumnarDecoder.channelFields) {
            return ConnectorParallel.materialize(list.chunks, rows: \.count) { columns, rows, out in
                appendChannels(columns, rows, categories: categories, to: &out)
            }
        }
        let all = try JSONDecoder().decode(Envelope<OrderedList<StalkerChannel>>.self, from: data).js
        return all.data.compactMap { channel in
            guard let command = channel.cmd,
                  let streamURL = Self.playableURL(fromCommand: command) else {
                return nil
            }
            let genreID = channel.tvGenreID?.value
            let group = Self.nonEmpty(channel.genresString)
                ?? genreID.flatMap { categories[$0] }
                ?? "Uncategorized"
            return Channel(
                id: channel.id,
                name: channel.name ?? "Unknown",
                logoURL: channel.logo.flatMap { URL(string: $0) },
                group: group,
                streamURL: streamURL,
                epgChannelID: Self.nonEmpty(channel.xmltvID) ?? channel.id,
                catchup: makeStalkerCatchup(archive: channel.enableTVArchive?.value, duration: channel.tvArchiveDuration?.value)
            )
        }
    }

    private static func appendChannels(_ columns: ConnectorRecordColumns, _ rows: Range<Int>, categories: [String: String],
                                       to channels: inout [Channel]) {
        typealias F = StalkerColumnarDecoder.ChannelField
        for row in rows {
            guard let command = columns.string(row, F.cmd),
                  let streamURL = playableURL(fromCommand: command) else { continue }
            let id = columns.string(row, F.id)!
            let group = nonEmpty(columns.string(row, F.genres))
                ?? columns.string(row, F.genreID).flatMap { categories[$0] }
                ?? "Uncategorized"
            channels.append(Channel(
                id: id,
                name: columns.string(row, F.name) ?? "Unknown",
                logoURL: columns.string(row, F.logo).flatMap { URL(string: $0) },
                group: group,
                streamURL: streamURL,
                epgChannelID: nonEmpty(columns.string(row, F.xmltv)) ?? id,
                catchup: makeStalkerCatchup(archive: columns.string(row, F.archive), duration: columns.string(row, F.archiveDays))
            ))
        }
    }

    /// One `get_ordered_list` media page.
    private static func decodeMediaPage(_ data: Data) throws -> OrderedList<StalkerMediaItem> {
        if let list = try? StalkerColumnarDecoder.orderedList(data, fields: StalkerColumnarDecoder.mediaFields, workers: 1) {
            var items: [StalkerMediaItem] = []
            items.reserveCapacity(list.count)
            for columns in list.chunks {
                for row in 0..<columns.count { items.append(StalkerMediaItem(columns: columns, row: row)) }
            }
            return OrderedList(totalItems: list.totalItems, maxPageItems: list.maxPageItems, data: items)
        }
        return try JSONDecoder().decode(Envelope<OrderedList<StalkerMediaItem>>.self, from: data).js
    }

    /// `get_genres` / `get_categories` → ID → title map.
    static func decodeCategories(_ data: Data) throws -> [String: String] {
        if let map = try? StalkerColumnarDecoder.categories(data, nonEmpty: nonEmpty) { return map }
        let categories = try JSONDecoder().decode(Envelope<[Category]>.self, from: data).js
        var map: [String: String] = [:]
        for category in categories where category.id != "*" {
            map[category.id] = Self.nonEmpty(category.title) ?? Self.nonEmpty(category.alias) ?? category.id
        }
        return map
    }

    /// `get_epg_info` → programmes mapped to the channels' guide IDs.
    /// The reference decoder iterates a dictionary (unspecified order); the
    /// fast path keeps response order.
    static func decodeEPG(_ data: Data, channels: [Channel]) throws -> [EPGProgram] {
        let guideIDs = Dictionary(channels.compactMap { channel -> (String, String)? in
            guard let epgID = channel.epgChannelID else { return nil }
            return (channel.id, epgID)
        }, uniquingKeysWith: { first, _ in first })
        if let info = try? StalkerColumnarDecoder.epgInfo(data) {
            typealias F = StalkerColumnarDecoder.EPGField
            let entries = info.entries
            var programs: [EPGProgram] = []
            programs.reserveCapacity(entries.count)
            for (group, channelID) in info.keys.enumerated() {
                for row in info.rows[group] {
                    if let program = makeProgram(channelID: channelID, guideIDs: guideIDs, id: entries.string(row, F.id),
                                                 nativeChannelID: entries.string(row, F.channelID), name: entries.string(row, F.name),
                                                 description: entries.string(row, F.description),
                                                 start: entries.string(row, F.start), stop: entries.string(row, F.stop)) {
                        programs.append(program)
                    }
                }
            }
            return programs
        }
        let epg = try JSONDecoder().decode(Envelope<EPGInfo>.self, from: data).js
        return epg.data.flatMap { channelID, entries in
            entries.compactMap { entry in
                makeProgram(channelID: channelID, guideIDs: guideIDs, id: entry.id?.value, nativeChannelID: entry.channelID?.value,
                            name: entry.name, description: entry.description,
                            start: entry.startTimestamp?.value, stop: entry.stopTimestamp?.value)
            }
        }
    }

    private static func makeProgram(channelID: String, guideIDs: [String: String], id: String?, nativeChannelID: String?,
                                    name: String?, description: String?, start startValue: String?, stop stopValue: String?) -> EPGProgram? {
        let start = TimeInterval(Int(startValue ?? "") ?? 0)
        let stop = TimeInterval(Int(stopValue ?? "") ?? 0)
        guard start > 0, stop > start else { return nil }
        guard let title = Self.nonEmpty(name) else { return nil }
        let nativeChannelID = Self.nonEmpty(nativeChannelID) ?? channelID
        let resolvedChannelID = guideIDs[nativeChannelID] ?? guideIDs[channelID] ?? nativeChannelID
        return EPGProgram(
            id: Self.nonEmpty(id) ?? "\(resolvedChannelID):\(startValue ?? ""):\(stopValue ?? "")",
            channelID: resolvedChannelID,
            title: title,
            description: description ?? "",
            start: Date(timeIntervalSince1970: start),
            end: Date(timeIntervalSince1970: stop)
        )
    }

    func fetchVODItems(sampleOnly: Bool = false) async throws -> [VODItem] {
        let categories = (try? await fetchCategories(type: "vod", action: "get_categories")) ?? [:]
        let items: [StalkerMediaItem] = try await fetchPagedMedia(type: "vod", sampleOnly: sampleOnly)
        return Self.vodItems(items, categories: categories)
    }

    private static func vodItems(_ items: [StalkerMediaItem], categories: [String: String]) -> [VODItem] {
        items.compactMap { item in
            guard let command = item.cmd,
                  let streamURL = Self.placeholderURL(type: "vod", command: command) else {
                return nil
            }
            let group = item.categoryID.flatMap { categories[$0.value] } ?? "Movies"
            return VODItem(
                id: "stalker:vod:\(item.id)",
                name: item.name ?? "Unknown",
                posterURL: Self.firstURL(item.screenshotURI, item.pic),
                group: group,
                streamURL: streamURL,
                kind: .movie,
                genre: Self.nonEmpty(item.genresString) ?? group,
                rating: Self.nonEmpty(item.ratingIMDB?.value),
                releaseDate: Self.firstNonEmpty(item.year, item.added),
                containerExtension: nil,
                summary: item.description,
                director: item.director,
                cast: item.actors
            )
        }
    }

    private static func series(_ items: [StalkerMediaItem], categories: [String: String]) -> [VODSeries] {
        items.map { item in
            let group = item.categoryID.flatMap { categories[$0.value] } ?? "Series"
            return VODSeries(
                id: "stalker:series:\(item.id)",
                name: item.name ?? "Unknown",
                posterURL: Self.firstURL(item.screenshotURI, item.pic),
                group: group,
                genre: Self.nonEmpty(item.genresString) ?? group,
                rating: Self.nonEmpty(item.ratingIMDB?.value),
                releaseDate: Self.firstNonEmpty(item.year, item.added),
                summary: item.description,
                director: item.director,
                cast: item.actors
            )
        }
    }

    /// One media page → (total, page size, VOD items, series), without the network.
    static func decodeMediaPage(_ data: Data, categories: [String: String]) throws -> (total: Int, pageSize: Int, vod: [VODItem], series: [VODSeries]) {
        let page = try decodeMediaPage(data)
        return (page.totalItems, page.maxPageItems, vodItems(page.data, categories: categories), series(page.data, categories: categories))
    }

    func fetchSeries(sampleOnly: Bool = false) async throws -> [VODSeries] {
        let categories = (try? await fetchCategories(type: "series", action: "get_categories")) ?? [:]
        let items: [StalkerMediaItem] = try await fetchPagedMedia(type: "series", sampleOnly: sampleOnly)
        return Self.series(items, categories: categories)
    }

    func fetchSeriesEpisodes(series: VODSeries) async throws -> [VODItem] {
        let rawSeriesID = Self.rawStalkerID(from: series.id)
        let seasons = try Self.decodeMediaPage(try await fetchData(
            "series",
            action: "get_ordered_list",
            extra: [
                URLQueryItem(name: "movie_id", value: rawSeriesID),
                URLQueryItem(name: "season_id", value: "0"),
                URLQueryItem(name: "episode_id", value: "0"),
                URLQueryItem(name: "category", value: "*"),
                URLQueryItem(name: "sortby", value: "added"),
                URLQueryItem(name: "not_ended", value: "0"),
                URLQueryItem(name: "p", value: "1")
            ]
        ))

        var episodes: [VODItem] = []
        for season in seasons.data {
            guard let command = season.cmd else { continue }
            let seasonNumber = Self.seasonNumber(from: season)
            let episodeNumbers = season.series?.isEmpty == false ? season.series ?? [] : [1]
            for episodeNumber in episodeNumbers {
                guard let streamURL = Self.placeholderURL(type: "series", command: command, episode: episodeNumber) else {
                    continue
                }
                episodes.append(VODItem(
                    id: "\(series.id):s\(seasonNumber):e\(episodeNumber)",
                    name: Self.formattedEpisodeTitle(seriesName: series.name, season: seasonNumber, episode: episodeNumber),
                    posterURL: Self.firstURL(season.screenshotURI, season.pic) ?? series.posterURL,
                    group: series.name,
                    streamURL: streamURL,
                    kind: .seriesEpisode,
                    genre: series.genre,
                    rating: series.rating,
                    releaseDate: series.releaseDate,
                    containerExtension: nil,
                    summary: series.summary,
                    director: series.director,
                    cast: series.cast,
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber
                ))
            }
        }
        return episodes
    }

    func fetchEPG(periodHours: Int, channels: [Channel] = []) async throws -> [EPGProgram] {
        let data = try await fetchData(
            "itv",
            action: "get_epg_info",
            extra: [URLQueryItem(name: "period", value: "\(periodHours)")]
        )
        return try Self.decodeEPG(data, channels: channels)
    }

    func resolvePlaybackURL(for item: VODItem) async throws -> URL {
        guard item.streamURL.scheme == Self.placeholderScheme else {
            return item.streamURL
        }
        guard let components = URLComponents(url: item.streamURL, resolvingAgainstBaseURL: false),
              let type = components.host,
              let command = components.queryItems?.first(where: { $0.name == "cmd" })?.value else {
            throw XtreamError.invalidURL
        }
        let episode = components.queryItems?.first(where: { $0.name == "episode" })?.value ?? ""
        return try await createLink(type: type, command: command, episode: episode)
    }

    nonisolated static func isPlaceholderURL(_ url: URL) -> Bool {
        url.scheme == placeholderScheme
    }

    // MARK: - Requests

    private func fetch<Value: Decodable>(
        _ type: String,
        action: String,
        extra: [URLQueryItem] = []
    ) async throws -> Value {
        let data = try await fetchData(type, action: action, extra: extra)
        return try JSONDecoder().decode(Envelope<Value>.self, from: data).js
    }

    private func fetchData(
        _ type: String,
        action: String,
        extra: [URLQueryItem] = [],
        includeAuth: Bool = true
    ) async throws -> Data {
        let request = try await makeRequest(type, action: action, extra: extra, includeAuth: includeAuth)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return data
    }

    private func makeRequest(
        _ type: String,
        action: String,
        extra: [URLQueryItem] = [],
        includeAuth: Bool = true
    ) async throws -> URLRequest {
        guard let apiURL = config.stalkerAPIURL,
              var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            throw XtreamError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "action", value: action)
        ] + extra + [URLQueryItem(name: "JsHttpRequest", value: "1-xml")]
        guard let url = components.url else { throw XtreamError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        applyMAGHeaders(to: &request)
        if includeAuth {
            request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func token() async throws -> String {
        if let accessToken { return accessToken }
        let data = try await fetchData("stb", action: "handshake", includeAuth: false)
        let handshake = try JSONDecoder().decode(Envelope<Handshake>.self, from: data).js
        accessToken = handshake.token
        return handshake.token
    }

    private func fetchCategories(type: String, action: String) async throws -> [String: String] {
        try Self.decodeCategories(try await fetchData(type, action: action))
    }

    private func fetchPagedMedia(type: String, sampleOnly: Bool) async throws -> [StalkerMediaItem] {
        let firstPage = try Self.decodeMediaPage(try await fetchData(
            type,
            action: "get_ordered_list",
            extra: mediaPageQuery(page: 1)
        ))
        guard !sampleOnly else { return firstPage.data }

        let pageSize = max(firstPage.maxPageItems, max(firstPage.data.count, 1))
        let totalPages = max(1, Int(ceil(Double(firstPage.totalItems) / Double(pageSize))))
        guard totalPages > 1 else { return firstPage.data }

        let remainingPages = Array(2...totalPages)
        var requests: [Int: URLRequest] = [:]
        requests.reserveCapacity(remainingPages.count)
        for page in remainingPages {
            requests[page] = try await makeRequest(
                type,
                action: "get_ordered_list",
                extra: mediaPageQuery(page: page)
            )
        }
        var pages: [Int: [StalkerMediaItem]] = [1: firstPage.data]
        pages.reserveCapacity(totalPages)

        var nextIndex = 0
        let maxConcurrentRequests = 4
        let session = session
        await withTaskGroup(of: (Int, [StalkerMediaItem]).self) { group in
            func enqueueNextPage() {
                guard nextIndex < remainingPages.count else { return }
                let page = remainingPages[nextIndex]
                nextIndex += 1
                guard let request = requests[page] else { return }
                group.addTask {
                    for attempt in 0..<2 {
                        do {
                            let (data, response) = try await session.data(for: request)
                            try Self.validate(response)
                            let next = try Self.decodeMediaPage(data)
                            return (page, next.data)
                        } catch {
                            if attempt == 0 {
                                try? await Task.sleep(for: .milliseconds(500))
                            }
                        }
                    }
                    return (page, [])
                }
            }

            for _ in 0..<min(maxConcurrentRequests, remainingPages.count) {
                enqueueNextPage()
            }

            while let (page, data) = await group.next() {
                pages[page] = data
                enqueueNextPage()
            }
        }

        var all: [StalkerMediaItem] = []
        all.reserveCapacity(firstPage.totalItems)
        for page in 1...totalPages {
            all.append(contentsOf: pages[page] ?? [])
        }
        return all
    }

    private func mediaPageQuery(page: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "category", value: "*"),
            URLQueryItem(name: "sortby", value: "added"),
            URLQueryItem(name: "not_ended", value: "0"),
            URLQueryItem(name: "p", value: "\(page)")
        ]
    }

    private func createLink(type: String, command: String, episode: String) async throws -> URL {
        let data = try await fetchData(
            type,
            action: "create_link",
            extra: [
                URLQueryItem(name: "cmd", value: command),
                URLQueryItem(name: "series", value: episode),
                URLQueryItem(name: "forced_storage", value: ""),
                URLQueryItem(name: "disable_ad", value: "false"),
                URLQueryItem(name: "download", value: "false"),
                URLQueryItem(name: "force_ch_link_check", value: "false")
            ]
        )
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(Envelope<LinkResult>.self, from: data) {
            return try Self.url(from: envelope.js)
        }
        if let envelope = try? decoder.decode(Envelope<[LinkResult]>.self, from: data),
           let link = envelope.js.first(where: { $0.type != "ad" && Self.nonEmpty($0.cmd) != nil }) {
            return try Self.url(from: link)
        }
        throw XtreamError.decodingFailed
    }

    nonisolated private static func firstURL(_ values: String?...) -> URL? {
        for value in values {
            if let raw = Self.nonEmpty(value), let url = URL(string: raw) {
                return url
            }
        }
        return nil
    }

    nonisolated private static func makeStalkerCatchup(archive: String?, duration: String?) -> CatchupInfo? {
        let isArchived = (Int(archive ?? "") ?? 0) > 0
        guard isArchived else { return nil }
        let providerDays = Int(duration ?? "") ?? 0
        let days = max(providerDays, 1)
        // Stalker/Ministra catchup works by appending ?utcstart=&utcend= query
        // parameters to the live stream URL, matching the .shift kind.
        return CatchupInfo(kind: .shift, days: days, source: nil)
    }

    private func applyMAGHeaders(to request: inout URLRequest) {
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if let portal = config.stalkerPortalURL?.absoluteString {
            request.setValue(portal, forHTTPHeaderField: "Referer")
        }
    }

    private var cookieHeader: String {
        let timezone = TimeZone.current.identifier
        return "mac=\(config.stalkerMACAddress); stb_lang=en; timezone=\(timezone)"
    }

    private static let userAgent = "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG250 stbapp ver: 2 rev: 250 Safari/533.3"

    // MARK: - Helpers

    nonisolated private static func validate(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse,
           !(200..<400).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }

    nonisolated private static func placeholderURL(type: String, command: String, episode: Int? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = placeholderScheme
        components.host = type
        var queryItems = [URLQueryItem(name: "cmd", value: command)]
        if let episode {
            queryItems.append(URLQueryItem(name: "episode", value: "\(episode)"))
        }
        components.queryItems = queryItems
        return components.url
    }

    nonisolated private static func url(from link: LinkResult) throws -> URL {
        if let error = nonEmpty(link.error) {
            throw NSError(domain: "StalkerClient", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
        guard let command = link.cmd,
              let url = playableURL(fromCommand: command) else {
            throw XtreamError.invalidURL
        }
        return url
    }

    nonisolated private static func playableURL(fromCommand command: String) -> URL? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let token: String
        if trimmed.hasPrefix("ffmpeg ") {
            token = String(trimmed.dropFirst("ffmpeg ".count))
        } else if let last = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).last {
            token = String(last)
        } else {
            token = trimmed
        }
        return URL(string: token)
    }

    nonisolated private static func rawStalkerID(from id: String) -> String {
        let stripped = id
            .replacingOccurrences(of: "stalker:series:", with: "")
            .replacingOccurrences(of: "stalker:vod:", with: "")
        return stripped.split(separator: ":").first.map(String.init) ?? stripped
    }

    nonisolated private static func seasonNumber(from item: StalkerMediaItem) -> Int {
        if let tail = item.id.split(separator: ":").last, let parsed = Int(tail) {
            return max(parsed, 1)
        }
        if let match = item.name?.split(separator: " ").last, let parsed = Int(match) {
            return max(parsed, 1)
        }
        return 1
    }

    nonisolated private static func formattedEpisodeTitle(seriesName: String, season: Int, episode: Int) -> String {
        "\(seriesName) S\(String(format: "%02d", season))E\(String(format: "%02d", episode))"
    }

    nonisolated private static func parsePortalDate(_ raw: String?) -> Date? {
        guard let raw = nonEmpty(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy, h:mm a"
        return formatter.date(from: raw.uppercased())
    }

    nonisolated private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let normalized = nonEmpty(value) {
                return normalized
            }
        }
        return nil
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed.uppercased() == "N/A" ? nil : trimmed
    }
}
