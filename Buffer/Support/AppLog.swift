import OSLog

enum AppLog {
    nonisolated static let subsystem = "com.wattsjs.buffer"

    nonisolated static let app = Logger(subsystem: subsystem, category: "App")
    nonisolated static let playback = Logger(subsystem: subsystem, category: "Playback")
    nonisolated static let sync = Logger(subsystem: subsystem, category: "Sync")
    nonisolated static let sports = Logger(subsystem: subsystem, category: "Sports")
    nonisolated static let recording = Logger(subsystem: subsystem, category: "Recording")
    nonisolated static let notifications = Logger(subsystem: subsystem, category: "Notifications")

    nonisolated static let appSignposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
    nonisolated static let syncSignposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
}
