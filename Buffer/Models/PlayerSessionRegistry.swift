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

    /// All currently live player sessions (across any number of player
    /// windows). Used by AppLifecycleCoordinator to pause/resume watchdogs
    /// on every open PlayerSlot during sleep/wake. Sessions are added on
    /// setActive and removed on explicit unregister (from onDisappear).
    private(set) var allSessions: [PlayerSession] = []

    private init() {}

    func setActive(_ session: PlayerSession) {
        activeSession = session
        if !allSessions.contains(where: { $0 === session }) {
            allSessions.append(session)
        }
    }

    func unregister(_ session: PlayerSession) {
        if activeSession === session {
            activeSession = nil
        }
        allSessions.removeAll { $0 === session }
    }

    /// Hand `request` to an already-open player session showing the same
    /// channel, raising its window. Returns false when no open window can
    /// take it (the caller should open a new one). Catchup and resume need
    /// the single-view transport, so multi-view sessions only accept live
    /// requests for a slot they already host.
    func deliver(_ request: PlaybackRequest) -> Bool {
        for session in allSessions {
            guard let slot = session.slots.first(where: { $0.channel.id == request.channel.id }) else {
                continue
            }
            if session.isMulti, request.intent != .live {
                continue
            }
            session.focus(slotID: slot.id)
            session.externalRequest = request
            session.hostWindow?.makeKeyAndOrderFront(nil)
            return true
        }
        return false
    }

    // MARK: - Lifecycle passthrough (Agent 09)

    func pauseAllBackgroundWork() {
        for session in allSessions {
            session.pauseAllBackgroundWork()
        }
    }

    func resumeAllBackgroundWork() {
        for session in allSessions {
            session.resumeAllBackgroundWork()
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
