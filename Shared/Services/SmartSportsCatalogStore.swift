import Foundation

/// Serial actor I/O keeps overrides and passive observations ordered without
/// blocking SwiftUI. Atomic replacement preserves the last complete document.
actor SmartSportsCatalogStore {
    static let shared = SmartSportsCatalogStore()

    nonisolated struct State: Codable, Sendable {
        var schemaVersion = 1
        var overrides = SmartSportsOverrides()
        var observations: [String: SmartSportsObservation] = [:]

        var keyedObservations: [SmartSportsEndpointKey: SmartSportsObservation] {
            Dictionary(observations.compactMap { raw, observation in
                SmartSportsCatalog.key(from: raw).map { ($0, observation) }
            }, uniquingKeysWith: { _, latest in latest })
        }
    }

    private let fileURL: URL
    private var state: State?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Buffer", isDirectory: true)
            .appendingPathComponent("smart-sports-state.json")
    }

    func load() throws -> State {
        if let state { return state }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = State(); state = empty; return empty
        }
        let decoded = try JSONDecoder().decode(State.self, from: Data(contentsOf: fileURL))
        guard decoded.schemaVersion == 1, decoded.overrides.schemaVersion == 1 else {
            throw SmartSportsCatalog.LoadError.unsupportedSchema
        }
        state = decoded
        return decoded
    }

    func save(overrides: SmartSportsOverrides) throws {
        var next = try load()
        next.overrides = overrides
        try persist(next)
    }

    func record(_ observation: SmartSportsObservation, for key: SmartSportsEndpointKey) throws {
        var next = try load()
        // A late completion from an old session may never replace a newer fact.
        if let current = next.observations[key.rawValue], current.observedAt > observation.observedAt { return }
        next.observations[key.rawValue] = observation
        // A bounded store is independent of the size of ordinary playlists.
        if next.observations.count > 2_000 {
            let keep = next.observations.sorted { $0.value.observedAt > $1.value.observedAt }.prefix(2_000)
            next.observations = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        try persist(next)
    }

    private func persist(_ next: State) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(next).write(to: fileURL, options: .atomic)
        state = next
    }
}
