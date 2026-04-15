import Foundation

enum ServerType: String, Codable, CaseIterable {
    case xtream = "Xtream Codes"
    case m3u = "M3U Playlist"
}

struct ServerConfig: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var type: ServerType

    // Xtream fields
    var serverURL: String
    var username: String
    var password: String

    // M3U fields
    var m3uURL: String
    var epgURL: String

    init(id: UUID = UUID(), name: String = "", type: ServerType = .xtream,
         serverURL: String = "", username: String = "", password: String = "",
         m3uURL: String = "", epgURL: String = "") {
        self.id = id
        self.name = name
        self.type = type
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.m3uURL = m3uURL
        self.epgURL = epgURL
    }

    nonisolated var xtreamBaseURL: String {
        serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
    }

    nonisolated var xtreamStreamBase: URL? {
        URL(string: "\(xtreamBaseURL)/live/\(username)/\(password)")
    }

    nonisolated var xtreamAPIURL: URL? {
        URL(string: "\(xtreamBaseURL)/player_api.php")
    }

    nonisolated var xtreamEPGURL: URL? {
        URL(string: "\(xtreamBaseURL)/xmltv.php?username=\(username)&password=\(password)")
    }

    nonisolated var m3uSourceURL: URL? {
        Self.resolvedURL(from: m3uURL)
    }

    nonisolated var epgSourceURL: URL? {
        Self.resolvedURL(from: epgURL)
    }

    nonisolated private static func resolvedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }

        if trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        }

        return URL(string: trimmed)
    }
}
