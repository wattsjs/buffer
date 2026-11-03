import Foundation

/// Carries a catchup-start wall-clock time from an EPG click (in the main
/// window) across the openWindow(value:) boundary to the player window.
///
/// The Window scene takes a bare `Channel` as its value so we can't piggyback
/// the start time on the navigation value. Instead, callers `set` before
/// opening the window and `PlayerView` calls `consume` on first appear — the
/// moment the session starts live playback we immediately replace it with the
/// catchup stream for the selected program.
@MainActor
enum PendingCatchup {
    struct Context {
        let start: Date
        let duration: TimeInterval
    }

    private static var contextByChannel: [String: Context] = [:]

    static func set(channelID: String, start: Date, duration: TimeInterval) {
        contextByChannel[channelID] = Context(start: start, duration: max(duration, 60))
    }

    static func consume(channelID: String) -> Context? {
        contextByChannel.removeValue(forKey: channelID)
    }
}

/// Carries a saved on-demand playhead from Home's Continue Watching shelf into
/// the player window. The window scene only receives a `Channel`, so the
/// timestamp has to be handed off out-of-band like catchup starts.
@MainActor
enum PendingVODResume {
    private static var positionByChannel: [String: Double] = [:]

    static func set(channelID: String, positionSeconds: Double) {
        guard positionSeconds > 0 else { return }
        positionByChannel[channelID] = positionSeconds
    }

    static func consume(channelID: String) -> Double? {
        positionByChannel.removeValue(forKey: channelID)
    }
}
