import Foundation

enum SyncInterval: Int, CaseIterable, Identifiable {
    case never = 0
    case oneHour = 1
    case twoHours = 2
    case sixHours = 6
    case twelveHours = 12
    case oneDay = 24
    case threeDays = 72
    case sevenDays = 168

    static let playlistStorageKey = "buffer_playlist_sync_interval_hours"
    static let epgStorageKey = "buffer_epg_sync_interval_hours"
    static let playlistDefault: SyncInterval = .oneDay
    static let epgDefault: SyncInterval = .oneHour

    var id: Int { rawValue }
    var hours: Int { rawValue }
    var isAutomatic: Bool { self != .never }
    var timeInterval: TimeInterval? {
        isAutomatic ? TimeInterval(rawValue) * 3600 : nil
    }

    var title: String {
        switch self {
        case .never: return "Never"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        case .sixHours: return "6 hours"
        case .twelveHours: return "12 hours"
        case .oneDay: return "24 hours"
        case .threeDays: return "3 days"
        case .sevenDays: return "7 days"
        }
    }

    static func storedValue(for key: String, default defaultValue: SyncInterval) -> SyncInterval {
        let raw = UserDefaults.standard.object(forKey: key) as? Int ?? defaultValue.hours
        return SyncInterval(rawValue: raw) ?? defaultValue
    }

    static func automaticRefreshEnabled(for key: String, default defaultValue: SyncInterval) -> Bool {
        storedValue(for: key, default: defaultValue).isAutomatic
    }
}
