import Foundation

nonisolated struct EPGProgram: Identifiable, Codable, Sendable {
    let id: String
    let channelID: String
    let title: String
    let description: String
    let start: Date
    let end: Date

    var duration: TimeInterval {
        end.timeIntervalSince(start)
    }

    var isNowPlaying: Bool {
        let now = Date()
        return start <= now && end > now
    }
}
