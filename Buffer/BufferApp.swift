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
final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    // 6 hours between scheduled background checks.
    private static let updateCheckInterval: TimeInterval = 6 * 60 * 60

    private var updaterStarted = false
    private var focusingScheduledUpdate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        startUpdater()
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
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.updateCheckInterval = Self.updateCheckInterval
        return controller
    }()

    var canCheckForUpdates: Bool {
        guard let updaterController else {
            return false
        }

        return !updaterStarted || updaterController.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        AppLog.app.info("Manual update check requested")
        startUpdater()
        updaterController?.checkForUpdates(nil)
    }

    private func startUpdater() {
        guard !updaterStarted, let updaterController else {
            return
        }

        updaterController.updater.automaticallyChecksForUpdates = true
        updaterController.updater.updateCheckInterval = Self.updateCheckInterval

        do {
            try updaterController.updater.start()
            updaterStarted = true
            AppLog.app.info("Sparkle updater started")

            if updaterController.updater.automaticallyChecksForUpdates {
                updaterController.updater.checkForUpdatesInBackground()
            }
        } catch {
            AppLog.app.error("Sparkle updater failed to start error=\(error.localizedDescription, privacy: .public)")
        }
    }

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else {
            AppLog.app.info("Sparkle update shown from manual check")
            return
        }

        if handleShowingUpdate {
            focusApplicationForUpdate()
            AppLog.app.info("Sparkle scheduled update shown in focus")
        } else {
            presentScheduledUpdateInFocus()
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        focusingScheduledUpdate = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        focusingScheduledUpdate = false
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        AppLog.app.info("Sparkle found update version=\(item.versionString, privacy: .public)")
    }

    private func presentScheduledUpdateInFocus() {
        guard !focusingScheduledUpdate else {
            return
        }

        focusingScheduledUpdate = true
        AppLog.app.info("Sparkle scheduled update found; bringing update prompt to front")

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.focusApplicationForUpdate()
            self.updaterController?.checkForUpdates(nil)
        }
    }

    private func focusApplicationForUpdate() {
        NSApp.activate(ignoringOtherApps: true)

        for window in NSApp.windows where window.isVisible {
            window.orderFrontRegardless()
        }
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
