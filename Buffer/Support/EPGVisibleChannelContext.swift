import Foundation

/// Remember IDs without publishing SwiftUI state at every scroll boundary.
/// A catalog revision resolves them against current channel metadata.
@MainActor
final class EPGVisibleChannelContext {
    private var visibleIDs: Set<String>?

    func update(_ channels: [Channel]) {
        visibleIDs = Set(channels.map(\.id))
    }

    func candidates(from channels: [Channel]) -> [Channel] {
        guard let visibleIDs else { return Array(channels.prefix(24)) }
        let visible = channels.filter { visibleIDs.contains($0.id) }
        return visible.isEmpty ? Array(channels.prefix(24)) : visible
    }
}
