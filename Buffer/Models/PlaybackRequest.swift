import Foundation

/// The value handed to the player window scene: which channel to open and
/// what to do with it. Carrying the intent inside the scene value (instead
/// of a static side-channel consumed on first appear) means every code path
/// that opens a player states its intent explicitly, and an already-open
/// window can have a new intent delivered to it through
/// `PlayerSessionRegistry.deliver(_:)`.
nonisolated struct PlaybackRequest: Hashable, Codable {
    enum Intent: Hashable, Codable {
        /// Tune the live stream (or start an on-demand item from the top).
        case live
        /// Start playback from the channel archive at the given wall-clock
        /// time. The player resolves the matching EPG program for its
        /// timeline; the raw date keeps the payload independent of guide
        /// data freshness.
        case catchup(start: Date)
        /// Resume an on-demand item at a saved position.
        case resume(positionSeconds: Double)
    }

    let channel: Channel
    let intent: Intent

    static func live(_ channel: Channel) -> PlaybackRequest {
        PlaybackRequest(channel: channel, intent: .live)
    }

    static func catchup(_ channel: Channel, from start: Date) -> PlaybackRequest {
        PlaybackRequest(channel: channel, intent: .catchup(start: start))
    }

    static func resume(_ channel: Channel, at positionSeconds: Double) -> PlaybackRequest {
        PlaybackRequest(channel: channel, intent: .resume(positionSeconds: positionSeconds))
    }
}
