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
    private static var startByChannel: [String: Date] = [:]

    static func set(channelID: String, start: Date) {
        startByChannel[channelID] = start
    }

    static func consume(channelID: String) -> Date? {
        startByChannel.removeValue(forKey: channelID)
    }
}
