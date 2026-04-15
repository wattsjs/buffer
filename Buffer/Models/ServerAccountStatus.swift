import Foundation

struct ServerAccountStatus: Codable, Equatable {
    let cacheKey: String
    let serverType: ServerType
    var channelCount: Int
    var guideStatus: String
    var lastChecked: Date
    var accountStatus: String?
    var expiryDate: Date?
    var activeConnections: Int?
    var maxConnections: Int?
    var username: String?
    var isTrial: Bool?
    var isAuthenticated: Bool?

    static func initial(for config: ServerConfig, cacheKey: String) -> ServerAccountStatus {
        ServerAccountStatus(
            cacheKey: cacheKey,
            serverType: config.type,
            channelCount: 0,
            guideStatus: config.type == .m3u
                ? (config.epgURL.isEmpty ? "Not configured" : "Configured")
                : "Configured",
            lastChecked: .now,
            accountStatus: nil,
            expiryDate: nil,
            activeConnections: nil,
            maxConnections: nil,
            username: nil,
            isTrial: nil,
            isAuthenticated: nil
        )
    }

    mutating func apply(_ info: XtreamAccountInfo) {
        accountStatus = info.statusLabel
        expiryDate = info.expiryDate
        activeConnections = info.activeConnections
        maxConnections = info.maxConnections
        username = info.username
        isTrial = info.isTrial
        isAuthenticated = info.isAuthenticated
        lastChecked = .now
    }
}
