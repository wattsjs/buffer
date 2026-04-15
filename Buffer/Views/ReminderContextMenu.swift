import AppKit
import SwiftUI

/// Transparent overlay that lets all regular events pass through but grabs
/// right-clicks (secondary button) and reports their local coordinates. Used
/// to add a contextual menu to the Canvas-rendered EPG grid where SwiftUI's
/// per-item `.contextMenu` modifier can't reach.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: (CGPoint, NSEvent, NSView) -> Void

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: Catcher, context: Context) {
        nsView.onRightClick = onRightClick
    }

    final class Catcher: NSView {
        var onRightClick: ((CGPoint, NSEvent, NSView) -> Void)?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only claim the click when the current event is a secondary
            // click; otherwise return nil so left-clicks, hovers and gestures
            // flow through to the SwiftUI views below.
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return self
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            onRightClick?(local, event, self)
        }
    }
}

/// NSMenuItem variant that fires a Swift closure when chosen. Avoids the
/// target/selector dance for one-off contextual menus.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem does not support NSCoder")
    }

    @objc private func fire() {
        handler()
    }
}

@MainActor
enum ReminderMenuBuilder {
    /// Builds a contextual menu for a program and pops it up at `event`'s
    /// location relative to `view`. Shared by the EPG grid (native right-click
    /// path) and anywhere else an NSMenu is appropriate.
    static func present(
        program: EPGProgram,
        channel: Channel,
        event: NSEvent,
        in view: NSView,
        onPlay: @escaping () -> Void
    ) {
        let menu = buildMenu(program: program, channel: channel, onPlay: onPlay)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    static func buildMenu(
        program: EPGProgram,
        channel: Channel,
        onPlay: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem()
        header.title = program.title.isEmpty ? "Program" : program.title
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let manager = NotificationManager.shared
        let existing = manager.reminder(for: program)

        if let existing {
            let title = "Cancel Reminder (" + leadDescription(minutes: existing.leadMinutes) + ")"
            menu.addItem(ClosureMenuItem(title: title) {
                manager.cancelReminder(for: program)
            })
        } else if program.end <= Date() {
            let past = NSMenuItem(title: "Already aired", action: nil, keyEquivalent: "")
            past.isEnabled = false
            menu.addItem(past)
        } else {
            menu.addItem(makeRemindItem(title: "Remind Me at Start", lead: 0, program: program, channel: channel))
            menu.addItem(makeRemindItem(title: "Remind Me 5 min Before", lead: 5, program: program, channel: channel))
            menu.addItem(makeRemindItem(title: "Remind Me 15 min Before", lead: 15, program: program, channel: channel))
            menu.addItem(makeRemindItem(title: "Remind Me 1 hour Before", lead: 60, program: program, channel: channel))
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Play Channel", handler: onPlay))
        return menu
    }

    private static func makeRemindItem(
        title: String,
        lead: Int,
        program: EPGProgram,
        channel: Channel
    ) -> ClosureMenuItem {
        ClosureMenuItem(title: title) {
            Task { @MainActor in
                let scheduled = await NotificationManager.shared.scheduleReminder(
                    program: program,
                    channel: channel,
                    leadMinutes: lead
                )
                AppFeedbackCenter.shared.showReminderResult(
                    program: program,
                    channel: channel,
                    leadMinutes: lead,
                    scheduled: scheduled
                )
            }
        }
    }

    private static func leadDescription(minutes: Int) -> String {
        switch minutes {
        case 0: return "at start"
        case 1..<60: return "\(minutes) min before"
        default:
            let hours = minutes / 60
            return hours == 1 ? "1 hour before" : "\(hours) hours before"
        }
    }
}
