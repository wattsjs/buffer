//
//  BufferApp.swift
//  Buffer
//
//  Created by Jamie Watts on 14/4/2026.
//

import AppKit
import OSLog
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
    // 6 hours between scheduled background checks.
    private static let updateCheckInterval: TimeInterval = 6 * 60 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Silent check on launch — only surfaces UI if an update is available.
        updaterController?.updater.checkForUpdatesInBackground()
    }

    func applicationWillTerminate(_ notification: Notification) {
        RecordingManager.shared.stopAll()
    }

    private(set) lazy var updaterController: SPUStandardUpdaterController? = {
        guard SparkleConfiguration.isConfigured else {
            AppLog.app.info("Sparkle updater is not configured")
            return nil
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.updateCheckInterval = Self.updateCheckInterval
        return controller
    }()

    var canCheckForUpdates: Bool {
        updaterController != nil
    }

    func checkForUpdates() {
        AppLog.app.info("Manual update check requested")
        updaterController?.checkForUpdates(nil)
    }
}

@main
struct BufferApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = EPGViewModel()
    @State private var notificationManager = NotificationManager.shared
    @State private var recordingManager = RecordingManager.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        ImageLoader.configure()
        // Touch the shared NotificationManager so its init runs — this sets
        // the UNUserNotificationCenter delegate and registers categories.
        // Actual permission + reconciliation happens in `.task` below.
        _ = NotificationManager.shared
        RecordingManager.shared.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 800, minHeight: 500)
                .task {
                    AppLog.app.info("Notification bootstrap started")
                    await notificationManager.bootstrap()
                    AppLog.app.info("Notification bootstrap finished")
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

        WindowGroup("Recording", for: Recording.self) { $recording in
            if let recording {
                PlayerView(recording: recording)
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

}
