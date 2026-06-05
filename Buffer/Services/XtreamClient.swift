import Foundation

struct XtreamAccountInfo: Codable, Equatable {
    let isAuthenticated: Bool
    let status: String?
    let expiryDate: Date?
    let activeConnections: Int?
    let maxConnections: Int?
    let username: String?
    let isTrial: Bool?

    var statusLabel: String {
        if let status, !status.isEmpty {
            return status.capitalized
        }
        return isAuthenticated ? "Active" : "Unauthorized"
    }
}

// Xtream APIs return numbers as either strings or ints inconsistently.
// This wrapper handles both.
private struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = ""
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(Int(double))
        } else {
            value = ""
        }
    }
}

private struct FlexibleBool: Decodable {
    let value: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int != 0
        } else if let string = try? container.decode(String.self) {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            value = !(normalized.isEmpty || normalized == "0" || normalized == "false")
        } else {
            value = false
        }
    }
}

// MARK: - Flexible string decoding helpers
// Avoids the per-field struct allocation of FlexibleString by decoding
// directly in the keyed container. Xtream APIs return numbers inconsistently
// as either String or Int; these helpers handle both.

extension KeyedDecodingContainer {
    func flexString(forKey key: Key) throws -> String {
        if let s = try? decode(String.self, forKey: key) { return s }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        return ""
    }
    func flexStringIfPresent(forKey key: Key) throws -> String? {
        if contains(key) {
            if let s = try? decode(String.self, forKey: key) { return s }
            if let i = try? decode(Int.self, forKey: key) { return String(i) }
        }
        return nil
    }
}

actor XtreamClient {
    private let config: ServerConfig

    init(config: ServerConfig) {
        self.config = config
    }

    // MARK: - API Response Types

    private struct XtreamCategory: Decodable {
        let category_id: String
        let category_name: String?

        enum CodingKeys: String, CodingKey {
            case category_id, category_name
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            category_id = try c.flexString(forKey: .category_id)
            category_name = try c.decodeIfPresent(String.self, forKey: .category_name)
        }
    }

    private struct XtreamStream: Decodable {
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
            stream_id = try c.flexString(forKey: .stream_id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
            stream_icon = try c.decodeIfPresent(String.self, forKey: .stream_icon)
            epg_channel_id = try c.decodeIfPresent(String.self, forKey: .epg_channel_id)
            category_id = try c.flexStringIfPresent(forKey: .category_id)
            tv_archive = try c.flexStringIfPresent(forKey: .tv_archive)
            tv_archive_duration = try c.flexStringIfPresent(forKey: .tv_archive_duration)
        }
    }

    private struct XtreamVODStream: Decodable {
        let num: FlexibleString?
        let name: String?
        let stream_id: FlexibleString
        let stream_icon: String?
        let category_id: FlexibleString?
        let container_extension: String?
        let rating: FlexibleString?
        let rating_5based: FlexibleString?
        let plot: String?
        let year: FlexibleString?
        let releaseDate: String?
        let added: FlexibleString?
        let director: String?
        let cast: String?
        let country: String?
        let genre: String?
        let duration_secs: FlexibleString?

        enum CodingKeys: String, CodingKey {
            case num, name, stream_id, stream_icon, category_id, container_extension
            case rating, rating_5based, plot, year, added, director, cast, country, genre, duration_secs
            case releaseDate = "release_date"
        }
    }

    private struct XtreamVODInfoEnvelope: Decodable {
        let info: XtreamVODInfo?
        let movieData: XtreamVODMovieData?

        enum CodingKeys: String, CodingKey {
            case info
            case movieData = "movie_data"
        }
    }

    private struct XtreamVODInfo: Decodable {
        let name: String?
        let movie_image: String?
        let cover_big: String?
        let plot: String?
        let description: String?
        let genre: String?
        let rating: FlexibleString?
        let releasedate: String?
        let releaseDate: String?
        let duration_secs: FlexibleString?
        let duration: FlexibleString?
        let director: String?
        let cast: String?
        let country: String?

        enum CodingKeys: String, CodingKey {
            case name, movie_image, cover_big, plot, description, genre, rating, releasedate, duration_secs, duration, director, cast, country
            case releaseDate = "release_date"
        }
    }

    private struct XtreamVODMovieData: Decodable {
        let stream_id: FlexibleString?
        let name: String?
        let added: FlexibleString?
        let category_id: FlexibleString?
        let container_extension: String?
    }

    private struct XtreamSeries: Decodable {
        let series_id: FlexibleString
        let name: String?
        let cover: String?
        let category_id: FlexibleString?
        let plot: String?
        let cast: String?
        let director: String?
        let genre: String?
        let releaseDate: String?
        let rating: FlexibleString?

        enum CodingKeys: String, CodingKey {
            case series_id, name, cover, category_id, plot, cast, director, genre, rating
            case releaseDate = "release_date"
        }
    }

    private struct XtreamSeriesInfoEnvelope: Decodable {
        let episodes: FlexibleEpisodes
        let info: XtreamSeriesInfo?

        enum CodingKeys: String, CodingKey {
            case episodes, seasons, info
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            episodes = try container.decodeIfPresent(FlexibleEpisodes.self, forKey: .episodes)
                ?? container.decodeIfPresent(FlexibleEpisodes.self, forKey: .seasons)
                ?? FlexibleEpisodes(seasons: [])
            info = try container.decodeIfPresent(XtreamSeriesInfo.self, forKey: .info)
        }
    }

    private struct XtreamSeriesInfo: Decodable {
        let name: String?
        let cover: String?
        let category_id: FlexibleString?
        let plot: String?
        let cast: String?
        let director: String?
        let genre: String?
        let releaseDate: String?
        let rating: FlexibleString?

        enum CodingKeys: String, CodingKey {
            case name, cover, category_id, plot, cast, director, genre, rating
            case releaseDate = "release_date"
        }
    }

    private struct XtreamEpisode: Decodable {
        let id: String
        let episode_num: FlexibleString?
        let title: String?
        let name: String?
        let container_extension: String?
        let season: FlexibleString?
        let plot: String?
        let added: FlexibleString?
        let info: XtreamEpisodeInfo?

        enum CodingKeys: String, CodingKey {
            case id, stream_id, episode_id, episode_num, title, name, container_extension, season, plot, added, info
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (
                try container.decodeIfPresent(FlexibleString.self, forKey: .id)?.value ??
                container.decodeIfPresent(FlexibleString.self, forKey: .stream_id)?.value ??
                container.decodeIfPresent(FlexibleString.self, forKey: .episode_id)?.value ??
                ""
            )
            episode_num = try container.decodeIfPresent(FlexibleString.self, forKey: .episode_num)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            container_extension = try container.decodeIfPresent(String.self, forKey: .container_extension)
            season = try container.decodeIfPresent(FlexibleString.self, forKey: .season)
            plot = try container.decodeIfPresent(String.self, forKey: .plot)
            added = try container.decodeIfPresent(FlexibleString.self, forKey: .added)
            info = try container.decodeIfPresent(XtreamEpisodeInfo.self, forKey: .info)
        }
    }

    private struct XtreamEpisodeInfo: Decodable {
        let plot: String?
        let duration_secs: FlexibleString?
        let duration: FlexibleString?
        let movie_image: String?
        let cover: String?
        let rating: FlexibleString?
        let releasedate: String?
        let releaseDate: String?
        let director: String?
        let cast: String?
        let genre: String?

        enum CodingKeys: String, CodingKey {
            case plot, duration_secs, duration, movie_image, cover, rating, releasedate, director, cast, genre
            case releaseDate = "release_date"
        }
    }

    private struct FlexibleEpisodes: Decodable {
        let seasons: [(String, [XtreamEpisode])]

        init(seasons: [(String, [XtreamEpisode])]) {
            self.seasons = seasons
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let keyedArrays = try? container.decode([String: [XtreamEpisode]].self) {
                seasons = keyedArrays.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                return
            }
            if let nested = try? container.decode([String: [String: XtreamEpisode]].self) {
                seasons = nested
                    .map { season, episodes in
                        let ordered = episodes
                            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                            .map(\.value)
                        return (season, ordered)
                    }
                    .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
                return
            }
            if let keyedEpisodes = try? container.decode([String: XtreamEpisode].self) {
                let ordered = keyedEpisodes
                    .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                    .map(\.value)
                seasons = [("1", ordered)]
                return
            }
            if let flat = try? container.decode([XtreamEpisode].self) {
                seasons = [("1", flat)]
                return
            }
            seasons = []
        }
    }

    private struct XtreamAuthEnvelope: Decodable {
        let userInfo: XtreamUserInfo?

        enum CodingKeys: String, CodingKey {
            case userInfo = "user_info"
        }
    }

    private struct XtreamUserInfo: Decodable {
        let username: String?
        let auth: FlexibleBool?
        let status: String?
        let exp_date: FlexibleString?
        let active_cons: FlexibleString?
        let max_connections: FlexibleString?
        let is_trial: FlexibleBool?
    }

    func fetchAccountInfo() async throws -> XtreamAccountInfo {
        let target = try xtreamURL(with: [
            URLQueryItem(name: "username", value: config.username),
            URLQueryItem(name: "password", value: config.password),
        ])
        let data = try await fetchData(from: target)
        let envelope = try JSONDecoder().decode(XtreamAuthEnvelope.self, from: data)
        guard let userInfo = envelope.userInfo else {
            throw XtreamError.decodingFailed
        }

        let isAuthenticated = userInfo.auth?.value ?? true
        if !isAuthenticated {
            throw XtreamError.authenticationFailed
        }

        return XtreamAccountInfo(
            isAuthenticated: isAuthenticated,
            status: userInfo.status,
            expiryDate: Self.date(fromEpochString: userInfo.exp_date?.value),
            activeConnections: Int(userInfo.active_cons?.value ?? ""),
            maxConnections: Int(userInfo.max_connections?.value ?? ""),
            username: userInfo.username,
            isTrial: userInfo.is_trial?.value
        )
    }

    // MARK: - Fetch Channels

    func fetchChannels() async throws -> [Channel] {
        let target = try xtreamURL(with: [
            URLQueryItem(name: "username", value: config.username),
            URLQueryItem(name: "password", value: config.password),
            URLQueryItem(name: "action", value: "get_live_streams")
        ])

        let categoriesMap = try await fetchCategories()

        let data = try await fetchData(from: target)
        let streams = try JSONDecoder().decode([XtreamStream].self, from: data)

        var channels: [Channel] = []
        channels.reserveCapacity(streams.count)
        guard let baseURL = config.xtreamStreamBase else { return [] }
        let baseStr = baseURL.absoluteString
        for stream in streams {
            guard let streamURL = URL(string: "\(baseStr)/\(stream.stream_id).m3u8") else { continue }
            let categoryName = stream.category_id.flatMap { categoriesMap[$0] } ?? "Uncategorized"

            channels.append(Channel(
                id: stream.stream_id,
                name: stream.name,
                logoURL: stream.stream_icon.flatMap { URL(string: $0) },
                group: categoryName,
                streamURL: streamURL,
                epgChannelID: stream.epg_channel_id,
                catchup: makeXtreamCatchup(streamID: stream.stream_id, archive: stream)
            ))
        }
        return channels
    }

    func fetchVODItems() async throws -> [VODItem] {
        let target = try xtreamURL(with: [
            URLQueryItem(name: "username", value: config.username),
            URLQueryItem(name: "password", value: config.password),
            URLQueryItem(name: "action", value: "get_vod_streams")
        ])

        let categoriesMap = (try? await fetchCategories(action: "get_vod_categories")) ?? [:]
        let data = try await fetchData(from: target)
        let streams = try JSONDecoder().decode([XtreamVODStream].self, from: data)

        return streams.compactMap { stream in
            let ext = normalizedContainerExtension(stream.container_extension)
            guard let streamURL = URL(string: "\(config.xtreamBaseURL)/movie/\(config.username)/\(config.password)/\(stream.stream_id.value).\(ext)") else {
                return nil
            }
            let categoryName = stream.category_id.flatMap { categoriesMap[$0.value] } ?? "Movies"

            return VODItem(
                id: stream.stream_id.value,
                name: stream.name ?? "Unknown",
                posterURL: stream.stream_icon.flatMap { URL(string: $0) },
                group: categoryName,
                streamURL: streamURL,
                kind: .movie,
                genre: nonEmpty(stream.genre) ?? categoryName,
                durationSeconds: Int(stream.duration_secs?.value ?? ""),
                rating: stream.rating?.value.isEmpty == false ? stream.rating?.value : stream.rating_5based?.value,
                releaseDate: stream.releaseDate ?? stream.year?.value,
                containerExtension: ext,
                summary: stream.plot,
                director: stream.director,
                cast: stream.cast,
                country: stream.country
            )
        }
    }

    func fetchVODItemDetails(item: VODItem) async throws -> VODItem {
        let target = try xtreamURL(with: [
            URLQueryItem(name: "username", value: config.username),
            URLQueryItem(name: "password", value: config.password),
            URLQueryItem(name: "action", value: "get_vod_info"),
            URLQueryItem(name: "vod_id", value: item.id)
        ])

        let data = try await fetchData(from: target)
        let envelope = try JSONDecoder().decode(XtreamVODInfoEnvelope.self, from: data)
        guard envelope.info != nil || envelope.movieData != nil else {
            return item
        }

        let info = envelope.info
        let movieData = envelope.movieData
        let posterURL = firstURL(info?.movie_image, info?.cover_big) ?? item.posterURL

        return VODItem(
            id: item.id,
            name: nonEmpty(info?.name) ?? nonEmpty(movieData?.name) ?? item.name,
            posterURL: posterURL,
            group: item.group,
            streamURL: item.streamURL,
            kind: item.kind,
            genre: nonEmpty(info?.genre) ?? item.genre,
            durationSeconds: durationSeconds(seconds: info?.duration_secs?.value, duration: info?.duration) ?? item.durationSeconds,
            rating: nonEmpty(info?.rating?.value) ?? item.rating,
            releaseDate: firstNonEmpty(info?.releaseDate, info?.releasedate, epochDateString(from: movieData?.added?.value), item.releaseDate),
            containerExtension: nonEmpty(movieData?.container_extension) ?? item.containerExtension,
            summary: firstNonEmpty(info?.plot, info?.description, item.summary),
            director: nonEmpty(info?.director) ?? item.director,
            cast: nonEmpty(info?.cast) ?? item.cast,
            country: nonEmpty(info?.country) ?? item.country,
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber
        )
    }

    func fetchSeries() async throws -> [VODSeries] {
        let target = try xtreamURL(with: [
            URLQueryItem(name: "username", value: config.username),
            URLQueryItem(name: "password", value: config.password),
            URLQueryItem(name: "action", value: "get_series")
        ])

        let categoriesMap = (try? await fetchCategories(action: "get_series_categories")) ?? [:]
        let data = try await fetchData(from: target)
        let series = try JSONDecoder().decode([XtreamSeries].self, from: data)

        return series.map { entry in
            VODSeries(
                id: entry.series_id.value,
                name: entry.name ?? "Unknown",
                posterURL: entry.cover.flatMap { URL(string: $0) },
                group: entry.category_id.flatMap { categoriesMap[$0.value] } ?? "Series",
                genre: entry.genre ?? entry.category_id.flatMap { categoriesMap[$0.value] },
                rating: nonEmpty(entry.rating?.value),
                releaseDate: entry.releaseDate,
                summary: entry.plot,
                director: entry.director,
                cast: entry.cast
            )
        }
    }

    func fetchSeriesEpisodes(series: VODSeries) async throws -> [VODItem] {
        let target = try xtreamURL(with: [
            URLQueryItem(name: "username", value: config.username),
            URLQueryItem(name: "password", value: config.password),
            URLQueryItem(name: "action", value: "get_series_info"),
            URLQueryItem(name: "series_id", value: series.id)
        ])

        let data = try await fetchData(from: target)
        let envelope = try JSONDecoder().decode(XtreamSeriesInfoEnvelope.self, from: data)
        let seriesName = envelope.info?.name ?? series.name
        let posterURL = envelope.info?.cover.flatMap { URL(string: $0) } ?? series.posterURL
        let categoryName = envelope.info?.category_id?.value.isEmpty == false ? series.group : series.group

        var items: [VODItem] = []
        for (seasonKey, episodes) in envelope.episodes.seasons {
            let fallbackSeasonNumber = Int(seasonKey) ?? 0
            for episode in episodes {
                guard !episode.id.isEmpty else { continue }
                let ext = normalizedContainerExtension(episode.container_extension)
                guard let streamURL = URL(string: "\(config.xtreamBaseURL)/series/\(config.username)/\(config.password)/\(episode.id).\(ext)") else {
                    continue
                }
                let episodeNumber = Int(episode.episode_num?.value ?? "") ?? 0
                let seasonNumber = Int(episode.season?.value ?? "") ?? fallbackSeasonNumber
                let fallbackTitle = formattedEpisodeTitle(seriesName: seriesName, season: seasonNumber, episode: episodeNumber)
                let imageURL = episode.info?.movie_image.flatMap { URL(string: $0) }
                    ?? episode.info?.cover.flatMap { URL(string: $0) }
                    ?? posterURL
                items.append(VODItem(
                    id: "\(series.id):\(episode.id)",
                    name: nonEmpty(episode.title) ?? nonEmpty(episode.name) ?? fallbackTitle,
                    posterURL: imageURL,
                    group: categoryName,
                    streamURL: streamURL,
                    kind: .seriesEpisode,
                    genre: episode.info?.genre ?? envelope.info?.genre ?? categoryName,
                    durationSeconds: durationSeconds(from: episode.info),
                    rating: episode.info?.rating?.value,
                    releaseDate: episode.info?.releaseDate ?? episode.info?.releasedate ?? epochDateString(from: episode.added?.value),
                    containerExtension: ext,
                    summary: episode.plot ?? episode.info?.plot ?? envelope.info?.plot,
                    director: episode.info?.director ?? envelope.info?.director,
                    cast: episode.info?.cast ?? envelope.info?.cast,
                    seasonNumber: seasonNumber > 0 ? seasonNumber : nil,
                    episodeNumber: episodeNumber > 0 ? episodeNumber : nil
                ))
            }
        }

        return items.sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func makeXtreamCatchup(streamID: String, archive: XtreamStream) -> CatchupInfo? {
        // Fast path: tv_archive is "0" or "1" in Xtream responses
        guard let tvArchive = archive.tv_archive, tvArchive == "1" else { return nil }

        let days: Int
        if let dur = archive.tv_archive_duration, let d = Int(dur), d > 0 {
            days = d
        } else {
            days = 1
        }

        let base = config.xtreamBaseURL
        let user = config.username
        let pass = config.password
        // Xtream timeshift template. Placeholders are substituted by
        // CatchupURLBuilder at playback time:
        //   ${duration} — clip length in minutes
        //   ${Y}-${m}-${d}:${H}-${M} — clip start in UTC
        let source = "\(base)/timeshift/\(user)/\(pass)/${duration}/${Y}-${m}-${d}:${H}-${M}/\(streamID).ts"
        return CatchupInfo(kind: .xc, days: days, source: source)
    }

    private func fetchCategories() async throws -> [String: String] {
        try await fetchCategories(action: "get_live_categories")
    }

    private func fetchCategories(action: String) async throws -> [String: String] {
        let target = try xtreamURL(with: [
            URLQueryItem(name: "username", value: config.username),
            URLQueryItem(name: "password", value: config.password),
            URLQueryItem(name: "action", value: action)
        ])

        let data = try await fetchData(from: target)
        let categories = try JSONDecoder().decode([XtreamCategory].self, from: data)

        var map: [String: String] = [:]
        map.reserveCapacity(categories.count)
        for cat in categories {
            map[cat.category_id] = cat.category_name ?? "Unknown"
        }
        return map
    }

    private func normalizedContainerExtension(_ value: String?) -> String {
        let trimmed = (value ?? "mp4")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? "mp4" : trimmed
    }

    private func formattedEpisodeTitle(seriesName: String, season: Int, episode: Int) -> String {
        guard season > 0 || episode > 0 else { return seriesName }
        return "\(seriesName) S\(String(format: "%02d", max(season, 0)))E\(String(format: "%02d", max(episode, 0)))"
    }

    private func durationSeconds(from info: XtreamEpisodeInfo?) -> Int? {
        guard let info else { return nil }
        return durationSeconds(seconds: info.duration_secs?.value, duration: info.duration)
    }

    private func durationSeconds(seconds rawSeconds: String?, duration: FlexibleString?) -> Int? {
        if let seconds = Int(rawSeconds ?? ""), seconds > 0 {
            return seconds
        }
        guard let raw = duration?.value, !raw.isEmpty else { return nil }
        let pieces = raw.split(separator: ":").compactMap { Int($0) }
        switch pieces.count {
        case 3:
            return pieces[0] * 3600 + pieces[1] * 60 + pieces[2]
        case 2:
            return pieces[0] * 60 + pieces[1]
        default:
            return Int(raw)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy
            .compactMap { self.nonEmpty($0) }
            .first
    }

    private func firstURL(_ values: String?...) -> URL? {
        values.lazy
            .compactMap { self.nonEmpty($0).flatMap(URL.init(string:)) }
            .first
    }

    private func epochDateString(from value: String?) -> String? {
        guard let value,
              let seconds = TimeInterval(value),
              seconds > 0 else {
            return nil
        }
        return Self.shortDateFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    /// Builds a properly guarded Xtream API URL from the configured base + query items.
    /// Replaces all previous force-unwraps on URLComponents(url:)! and .url! (defensive cleanup).
    private func xtreamURL(with queryItems: [URLQueryItem]) throws -> URL {
        guard let apiURL = config.xtreamAPIURL,
              var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            throw XtreamError.invalidURL
        }
        components.queryItems = queryItems
        guard let finalURL = components.url else {
            throw XtreamError.invalidURL
        }
        return finalURL
    }

    private func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<400).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func date(fromEpochString value: String?) -> Date? {
        guard let value,
              let seconds = TimeInterval(value),
              seconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

enum XtreamError: LocalizedError {
    case invalidURL
    case authenticationFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL"
        case .authenticationFailed: return "Authentication failed"
        case .decodingFailed: return "Failed to parse server response"
        }
    }
}
