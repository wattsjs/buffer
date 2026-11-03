import Foundation

enum ServerConnectionTester {
    struct Result {
        let message: String
        let status: ServerAccountStatus
    }

    private enum EPGStatus {
        case reachable
        case unavailable(String)
        case notConfigured

        var message: String {
            switch self {
            case .reachable:
                return "EPG reachable"
            case .unavailable(let detail):
                return "EPG unavailable (\(detail))"
            case .notConfigured:
                return "No EPG URL configured"
            }
        }
    }

    enum Error: LocalizedError {
        case invalidPlaylist
        case noChannelsFound
        case authenticationFailed
        case invalidServerURL(String)

        var errorDescription: String? {
            switch self {
            case .invalidPlaylist:
                return "The playlist responded, but it does not look like a valid M3U file."
            case .noChannelsFound:
                return "The connection worked, but the provider returned no channels."
            case .authenticationFailed:
                return "The server rejected those Xtream credentials."
            case .invalidServerURL(let field):
                return "Enter a valid \(field)."
            }
        }
    }

    static func test(_ config: ServerConfig, includeVOD: Bool) async throws -> Result {
        switch config.type {
        case .xtream:
            return try await testXtream(config, includeVOD: includeVOD)
        case .stalker:
            return try await testStalker(config, includeVOD: includeVOD)
        case .m3u:
            return try await testM3U(config, includeVOD: includeVOD)
        }
    }

    private static func testXtream(_ config: ServerConfig, includeVOD: Bool) async throws -> Result {
        guard config.xtreamAPIURL != nil else {
            throw Error.invalidServerURL("server URL")
        }

        let client = XtreamClient(config: config)
        let accountInfo = try await client.fetchAccountInfo()
        let channels = try await client.fetchChannels()
        try Task.checkCancellation()
        let vodItems = includeVOD ? (try? await client.fetchVODItems()) ?? [] : []
        try Task.checkCancellation()
        let series = includeVOD ? (try? await client.fetchSeries()) ?? [] : []
        try Task.checkCancellation()
        if channels.isEmpty && vodItems.isEmpty && series.isEmpty {
            throw Error.noChannelsFound
        }

        let epg = await probe(url: config.xtreamEPGURL)
        var status = ServerAccountStatus.initial(for: config, cacheKey: DataCache.preferenceKey(for: config))
        status.channelCount = channels.count
        status.guideStatus = epg.message
        status.apply(accountInfo)
        return Result(
            message: includeVOD
                ? "Connected to Xtream. Found \(channels.count) channels, \(vodItems.count) movies, and \(series.count) series. \(epg.message)."
                : "Connected to Xtream. Found \(channels.count) channels. Movies and TV are disabled. \(epg.message).",
            status: status
        )
    }

    private static func testM3U(_ config: ServerConfig, includeVOD: Bool) async throws -> Result {
        guard let playlistURL = config.m3uSourceURL else {
            throw Error.invalidServerURL("playlist URL or file path")
        }

        let data = try await fetchData(from: playlistURL)
        guard let content = String(data: data, encoding: .utf8) else {
            throw Error.invalidPlaylist
        }

        let parsed = await Task.detached(priority: .userInitiated) {
            M3UParser.parseContent(content, includeVOD: includeVOD)
        }.value
        try Task.checkCancellation()
        let channels = parsed.channels
        guard content.contains("#EXTINF") || content.contains("#EXTM3U") else {
            throw Error.invalidPlaylist
        }
        let seriesCount = Set(parsed.vodItems.filter { $0.kind == .seriesEpisode }.map(\.group)).count
        let movieCount = parsed.vodItems.filter { $0.kind != .seriesEpisode }.count
        guard !channels.isEmpty || movieCount > 0 || seriesCount > 0 else {
            throw Error.noChannelsFound
        }

        let epg = await probe(url: config.epgSourceURL)
        var status = ServerAccountStatus.initial(for: config, cacheKey: DataCache.preferenceKey(for: config))
        status.channelCount = channels.count
        status.guideStatus = epg.message
        status.lastChecked = .now
        return Result(
            message: "Playlist loaded. Found \(channels.count) channels, \(movieCount) movies, and \(seriesCount) series. \(epg.message).",
            status: status
        )
    }

    private static func testStalker(_ config: ServerConfig, includeVOD: Bool) async throws -> Result {
        guard config.stalkerAPIURL != nil else {
            throw Error.invalidServerURL("portal URL")
        }

        let client = StalkerClient(config: config)
        let accountInfo = try await client.fetchAccountInfo()
        let channels = try await client.fetchChannels(sampleOnly: true)
        try Task.checkCancellation()
        let vodItems = includeVOD ? (try? await client.fetchVODItems(sampleOnly: true)) ?? [] : []
        try Task.checkCancellation()
        let series = includeVOD ? (try? await client.fetchSeries(sampleOnly: true)) ?? [] : []
        try Task.checkCancellation()
        if channels.isEmpty && vodItems.isEmpty && series.isEmpty {
            throw Error.noChannelsFound
        }

        var status = ServerAccountStatus.initial(for: config, cacheKey: DataCache.preferenceKey(for: config))
        status.channelCount = channels.count
        status.guideStatus = "Configured"
        status.apply(accountInfo)
        return Result(
            message: includeVOD
                ? "Connected to Stalker/MAG. Sample loaded \(channels.count) channels, \(vodItems.count) movies, and \(series.count) series."
                : "Connected to Stalker/MAG. Sample loaded \(channels.count) channels. Movies and TV are disabled.",
            status: status
        )
    }

    private static func fetchData(from url: URL) async throws -> Data {
        if url.isFileURL {
            return try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        }

        let connection = session
        defer { connection.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await connection.data(for: request)
        try validate(response)
        return data
    }

    private static func probe(url: URL?) async -> EPGStatus {
        guard let url else { return .notConfigured }

        do {
            if url.isFileURL {
                // Reachability does not require loading a large XMLTV file.
                try await Task.detached(priority: .userInitiated) {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    _ = try handle.read(upToCount: 1)
                }.value
            } else {
                let connection = session
                defer { connection.invalidateAndCancel() }
                var request = URLRequest(url: url)
                request.timeoutInterval = 12
                let (_, response) = try await connection.bytes(for: request)
                try validate(response)
            }
            return .reachable
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private static func validate(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse,
           !(200..<400).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }

    private static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }
}

