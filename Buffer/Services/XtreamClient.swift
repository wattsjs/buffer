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
        if let str = try? container.decode(String.self) {
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

actor XtreamClient {
    private let config: ServerConfig

    init(config: ServerConfig) {
        self.config = config
    }

    // MARK: - API Response Types

    private struct XtreamCategory: Decodable {
        let category_id: FlexibleString
        let category_name: String?

        enum CodingKeys: String, CodingKey {
            case category_id, category_name
        }
    }

    private struct XtreamStream: Decodable {
        let num: FlexibleString?
        let name: String?
        let stream_id: FlexibleString
        let stream_icon: String?
        let epg_channel_id: String?
        let category_id: FlexibleString?
        let tv_archive: FlexibleString?
        let tv_archive_duration: FlexibleString?

        enum CodingKeys: String, CodingKey {
            case num, name, stream_id, stream_icon, epg_channel_id, category_id, tv_archive, tv_archive_duration
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            num = try container.decodeIfPresent(FlexibleString.self, forKey: .num)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            stream_id = try container.decode(FlexibleString.self, forKey: .stream_id)
            stream_icon = try container.decodeIfPresent(String.self, forKey: .stream_icon)
            epg_channel_id = try container.decodeIfPresent(String.self, forKey: .epg_channel_id)
            category_id = try container.decodeIfPresent(FlexibleString.self, forKey: .category_id)
            tv_archive = try container.decodeIfPresent(FlexibleString.self, forKey: .tv_archive)
            tv_archive_duration = try container.decodeIfPresent(FlexibleString.self, forKey: .tv_archive_duration)
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
        guard let apiURL = config.xtreamAPIURL else {
            throw XtreamError.invalidURL
        }

        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "username", value: config.username),
            URLQueryItem(name: "password", value: config.password),
        ]

        let data = try await fetchData(from: components.url!)
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
        guard let apiURL = config.xtreamAPIURL else {
            throw XtreamError.invalidURL
        }

        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "username", value: config.username),
            URLQueryItem(name: "password", value: config.password),
            URLQueryItem(name: "action", value: "get_live_streams")
        ]

        let categoriesMap = try await fetchCategories()

        let data = try await fetchData(from: components.url!)
        let streams = try JSONDecoder().decode([XtreamStream].self, from: data)

        return streams.compactMap { stream in
            guard let baseURL = config.xtreamStreamBase else { return nil }
            let streamURL = baseURL.appendingPathComponent("\(stream.stream_id.value).m3u8")
            let categoryName = stream.category_id.flatMap { categoriesMap[$0.value] } ?? "Uncategorized"

            return Channel(
                id: stream.stream_id.value,
                name: stream.name ?? "Unknown",
                logoURL: stream.stream_icon.flatMap { URL(string: $0) },
                group: categoryName,
                streamURL: streamURL,
                epgChannelID: stream.epg_channel_id,
                catchup: makeXtreamCatchup(streamID: stream.stream_id.value, archive: stream)
            )
        }
    }

    private func makeXtreamCatchup(streamID: String, archive: XtreamStream) -> CatchupInfo? {
        let isArchived = (Int(archive.tv_archive?.value ?? "") ?? 0) > 0
        let days = Int(archive.tv_archive_duration?.value ?? "") ?? 0
        guard isArchived, days > 0 else { return nil }

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
        guard let apiURL = config.xtreamAPIURL else {
            throw XtreamError.invalidURL
        }

        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "username", value: config.username),
            URLQueryItem(name: "password", value: config.password),
            URLQueryItem(name: "action", value: "get_live_categories")
        ]

        let data = try await fetchData(from: components.url!)
        let categories = try JSONDecoder().decode([XtreamCategory].self, from: data)

        var map: [String: String] = [:]
        for cat in categories {
            map[cat.category_id.value] = cat.category_name ?? "Unknown"
        }
        return map
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
