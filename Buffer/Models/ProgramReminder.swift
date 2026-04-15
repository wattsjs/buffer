import Foundation

struct ProgramReminder: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let programID: String
    let channelID: String
    let channelName: String
    let programTitle: String
    let programDescription: String
    let programStart: Date
    let programEnd: Date
    let notifyAt: Date
    let createdAt: Date
    let leadMinutes: Int
    let streamURL: URL

    static func makeID(channelID: String, programID: String) -> String {
        "buffer.reminder|\(channelID)|\(programID)"
    }
}
