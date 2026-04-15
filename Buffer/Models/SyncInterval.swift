import Foundation

enum SyncInterval: Int, CaseIterable, Identifiable {
    case oneHour = 1
    case twoHours = 2
    case sixHours = 6
    case twelveHours = 12
    case oneDay = 24
    case threeDays = 72
    case sevenDays = 168

    static let appStorageKey = "buffer_sync_interval_hours"
    static let `default`: SyncInterval = .oneDay

    var id: Int { rawValue }
    var hours: Int { rawValue }
    var timeInterval: TimeInterval { TimeInterval(rawValue) * 3600 }

    var title: String {
        switch self {
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        case .sixHours: return "6 hours"
        case .twelveHours: return "12 hours"
        case .oneDay: return "24 hours"
        case .threeDays: return "3 days"
        case .sevenDays: return "7 days"
        }
    }
}
