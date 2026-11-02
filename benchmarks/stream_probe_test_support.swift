import Foundation

nonisolated enum DataCache {
    struct CachedProbes: Sendable { let probes: [String: StreamProbe] }
    static func loadProbes(key: String) -> CachedProbes? { nil }
    static func saveProbes(_ probes: [String: StreamProbe], key: String) {}
}

@MainActor final class PlayerSessionRegistry {
    static let shared = PlayerSessionRegistry()
    var allSessions: [Int] = []
}
