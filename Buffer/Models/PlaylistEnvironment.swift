import SwiftUI

extension EnvironmentValues {
    /// The currently-active playlist. Views that schedule or cancel reminders
    /// read this so each reminder is stamped with its owning playlist.
    @Entry var activePlaylistID: UUID? = nil
}
