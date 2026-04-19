import SwiftUI
import Observation

/// Tracks the currently "active" player session across open player windows
/// so the main window's channel context menus can target it when the user
/// asks to add a channel to multi-view.
@MainActor
@Observable
final class PlayerSessionRegistry {
    static let shared = PlayerSessionRegistry()

    private(set) var activeSession: PlayerSession?

    private init() {}

    func setActive(_ session: PlayerSession) {
        activeSession = session
    }

    func unregister(_ session: PlayerSession) {
        if activeSession === session {
            activeSession = nil
        }
    }
}

// The old proxy registry was removed — player sessions now key off
// the upstream URL directly, so no external lookup table is needed.

/// Context-menu item for the main window's channel rows. Shows only when
/// there's an active player session that still has room for more slots.
struct AddToMultiViewMenuItem: View {
    let channel: Channel

    private var registry: PlayerSessionRegistry { .shared }

    var body: some View {
        if let session = registry.activeSession, session.canAddMoreSlots() {
            Button {
                session.addChannel(channel, currentProgram: nil)
            } label: {
                Label("Add to Multi-View", systemImage: "rectangle.split.2x2")
            }
        }
    }
}
