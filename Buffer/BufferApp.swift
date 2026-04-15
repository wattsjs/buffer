//
//  BufferApp.swift
//  Buffer
//
//  Created by Jamie Watts on 14/4/2026.
//

import AppKit
import Sparkle
import SwiftUI

@MainActor
private enum SparkleConfiguration {
    private static func stringValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    static var isConfigured: Bool {
        stringValue(for: "SUFeedURL") != nil && stringValue(for: "SUPublicEDKey") != nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var updaterController: SPUStandardUpdaterController? = {
        guard SparkleConfiguration.isConfigured else {
            return nil
        }

        return SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }()

    var canCheckForUpdates: Bool {
        updaterController != nil
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}

@main
struct BufferApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = EPGViewModel()
    @State private var notificationManager = NotificationManager.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        ImageLoader.configure()
        // Touch the shared NotificationManager so its init runs — this sets
        // the UNUserNotificationCenter delegate and registers categories.
        // Actual permission + reconciliation happens in `.task` below.
        _ = NotificationManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 800, minHeight: 500)
                .task {
                    await notificationManager.bootstrap()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NotificationManager.openStreamNotification
                    )
                ) { note in
                    handleReminderOpen(note)
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()
                Button("Check for Updates…") {
                    appDelegate.checkForUpdates()
                }
                .disabled(!appDelegate.canCheckForUpdates)
            }

            CommandGroup(after: .help) {
                Button("Keyboard Shortcuts") {
                    openWindow(id: "keyboard-shortcuts")
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            }
        }

        WindowGroup("Player", for: Channel.self) { $channel in
            if let channel {
                PlayerView(
                    channel: channel,
                    currentProgram: viewModel.currentProgram(for: channel),
                    viewModel: viewModel
                )
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 854, height: 480)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(viewModel: viewModel)
        }

        Window("Keyboard Shortcuts", id: "keyboard-shortcuts") {
            KeyboardShortcutsView()
        }
        .defaultSize(width: 420, height: 320)
        .restorationBehavior(.disabled)
    }

    private func handleReminderOpen(_ note: Notification) {
        guard let info = note.userInfo,
              let channelID = info["channelID"] as? String,
              let channel = viewModel.channels.first(where: { $0.id == channelID })
        else { return }
        viewModel.addRecent(channel)
        if ExternalPlayer.isEnabled {
            ExternalPlayer.launch(streamURL: channel.streamURL)
        } else {
            openWindow(value: channel)
        }
    }
}
