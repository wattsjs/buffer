import Foundation

struct ProgramReminder: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let playlistID: UUID
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

    static func makeID(playlistID: UUID, channelID: String, programID: String) -> String {
        "buffer.reminder|\(playlistID.uuidString)|\(channelID)|\(programID)"
    }
}
