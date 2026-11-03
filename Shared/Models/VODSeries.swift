import Foundation

nonisolated struct VODSeries: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let posterURL: URL?
    let group: String
    var genre: String? = nil
    var rating: String? = nil
    var releaseDate: String? = nil
    var summary: String? = nil
    var director: String? = nil
    var cast: String? = nil
    var episodeCount: Int? = nil

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: VODSeries, rhs: VODSeries) -> Bool {
        lhs.id == rhs.id
    }
}
