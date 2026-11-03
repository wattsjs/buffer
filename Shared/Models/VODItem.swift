import Foundation

nonisolated struct VODItem: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case movie
        case seriesEpisode
        case unknown
    }

    let id: String
    let name: String
    let posterURL: URL?
    let group: String
    let streamURL: URL
    let kind: Kind
    var genre: String? = nil
    var durationSeconds: Int? = nil
    var rating: String? = nil
    var releaseDate: String? = nil
    var containerExtension: String? = nil
    var summary: String? = nil
    var director: String? = nil
    var cast: String? = nil
    var country: String? = nil
    var seasonNumber: Int? = nil
    var episodeNumber: Int? = nil

    var playbackChannel: Channel {
        Channel(
            id: "vod:\(id)",
            name: name,
            logoURL: posterURL,
            group: group,
            streamURL: streamURL,
            epgChannelID: nil,
            catchup: nil,
            contentType: .vod
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: VODItem, rhs: VODItem) -> Bool {
        lhs.id == rhs.id
    }
}
