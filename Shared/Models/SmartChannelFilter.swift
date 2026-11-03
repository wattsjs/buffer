import Foundation

/// Which regions/languages and categories Smart Channels shows. Regions are
/// country codes ("UK") or language groups ("Arabic") detected per channel.
nonisolated struct SmartChannelFilter: Codable, Equatable, Sendable {
    enum Scope: Codable, Equatable, Hashable, Sendable {
        case off
        case everything
        case categories(Set<String>)

        static let sportsOnly = Scope.categories(["Sports"])
    }

    static let categories = ["Sports", "News", "Movies", "Kids", "Documentary", "Music", "Channels"]
    static let unknownRegion = "Global"
    static let storageKey = "buffer_smart_channel_filter_v1"

    var isEnabled = false
    var regions: [String: Scope] = [:]
    /// Kept from any region, e.g. Kids.
    var alwaysInclude: Set<String> = []

    func allows(region: String, category: String) -> Bool {
        guard isEnabled else { return true }
        if alwaysInclude.contains(category) { return true }
        switch regions[region] ?? .off {
        case .off: return false
        case .everything: return true
        case .categories(let allowed): return allowed.contains(category)
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> SmartChannelFilter {
        guard let data = defaults.data(forKey: storageKey),
              let filter = try? JSONDecoder().decode(SmartChannelFilter.self, from: data) else { return .init() }
        return filter
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }
}

/// Channel counts per detected region and category across every source.
nonisolated struct SmartRegionSummary: Identifiable, Equatable, Sendable {
    let region: String
    var categoryCounts: [String: Int]
    var id: String { region }
    var total: Int { categoryCounts.values.reduce(0, +) }
}
