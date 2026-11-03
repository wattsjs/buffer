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
            guard let slot = session.slots.first(where: { $0.channel.preferenceIdentity == request.channel.preferenceIdentity }) else {
                continue
            }
            if session.isMulti, request.intent != .live {
                continue
            }
            session.focus(slotID: slot.id)
            session.externalRequest = request
#if os(macOS)
            session.hostWindow?.makeKeyAndOrderFront(nil)
#endif
            return true
        }
        return false
    }

    func channel(matching channel: Channel) -> Channel? {
        allSessions.lazy.flatMap(\.slots).first {
            $0.channel.preferenceIdentity == channel.preferenceIdentity
        }?.channel
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

#if os(macOS)
/// Context-menu item for the main window's channel rows. Shows only when
/// there's an active player session that still has room for more slots.
struct AddToMultiViewMenuItem: View {
    let channel: Channel
    @Environment(\.epgActionModel) private var model

    private var registry: PlayerSessionRegistry { .shared }

    var body: some View {
        if let session = registry.activeSession, session.canAddMoreSlots() {
            Button {
                let resolved: Channel
                if let model {
                    guard let request = model.resolvePlaybackRequest(.live(channel)) else { return }
                    resolved = request.channel
                } else {
                    guard channel.epgChannelID?.hasPrefix("smart-guide:") != true else { return }
                    resolved = channel
                }
                session.addChannel(resolved, currentProgram: model?.currentProgram(for: resolved))
                if let slot = session.slots.first(where: { $0.channel.preferenceIdentity == resolved.preferenceIdentity }) {
                    model?.configureSmartRecovery(for: slot)
                }
            } label: {
                Label("Add to Multi-View", systemImage: "rectangle.split.2x2")
            }
        }
    }
}
#endif
