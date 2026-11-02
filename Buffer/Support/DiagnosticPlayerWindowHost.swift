import AppKit
import SwiftUI

#if DEBUG
/// Presents the production renderer without interrupting another app's typing.
/// SwiftUI scenes do not expose NSPanel's nonactivating window behavior.
@MainActor
enum DiagnosticPlayerWindowHost {
    // The host owns both the panel and its weak AppKit delegate until close.
    private static var hosts: [UUID: Host] = [:]

    static func open(request: PlaybackRequest, viewModel: EPGViewModel) {
        let id = UUID()
        let host = Host(request: request, viewModel: viewModel) {
            hosts.removeValue(forKey: id)
        }
        hosts[id] = host
        host.present()
    }

    private final class NonactivatingPlayerPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    @MainActor
    private final class Host: NSObject, NSWindowDelegate {
        private let panel: NonactivatingPlayerPanel
        private let hostingView: NSHostingView<AnyView>
        private var onClose: (@MainActor @Sendable () -> Void)?

        init(request: PlaybackRequest, viewModel: EPGViewModel, onClose: @escaping @MainActor @Sendable () -> Void) {
            panel = NonactivatingPlayerPanel(
                contentRect: NSRect(x: 0, y: 0, width: 854, height: 480),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            hostingView = NSHostingView(rootView: AnyView(PlayerView(request: request, viewModel: viewModel)))
            self.onClose = onClose
            super.init()
            panel.delegate = self
            panel.contentView = hostingView
            panel.title = "Buffer Playback Validation"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.isRestorable = false
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.minSize = NSSize(width: 640, height: 360)
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: max(visible.minX, visible.maxX - panel.frame.width - 16),
                                             y: max(visible.minY, visible.maxY - panel.frame.height - 16)))
            }
        }

        func present() {
            // Never make key, main, or activate the application. WindowAccessor
            // still receives this panel and registers the session's hostWindow.
            panel.orderFrontRegardless()
        }

        func windowWillClose(_ notification: Notification) {
            guard let onClose else { return }
            self.onClose = nil
            // Removing the SwiftUI tree invokes PlayerView's normal onDisappear
            // cleanup, unregistering the session and recycling its players.
            hostingView.rootView = AnyView(EmptyView())
            panel.contentView = nil
            panel.delegate = nil
            // Release after AppKit finishes its close callback. No synchronous
            // player-destruction wait is introduced on the main thread.
            DispatchQueue.main.async(execute: onClose)
        }
    }
}
#endif
