import SwiftUI
import AppKit
import OSLog

/// Central coordinator for app lifecycle state (sleep, background, termination).
/// Used to pause long-running Tasks, schedulers, and background work to prevent
/// the progressive resource accumulation and freezes identified by the agents.
@MainActor
@Observable
final class AppLifecycleCoordinator {
    static let shared = AppLifecycleCoordinator()

    private(set) var isActive: Bool = true
    private(set) var isSleeping: Bool = false
    private(set) var isTerminating: Bool = false

    /// Convenience for components that want to pause work when the app is not in the foreground or is sleeping.
    var shouldPauseBackgroundWork: Bool {
        !isActive || isSleeping || isTerminating
    }

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    private init() {
        registerObservers()
    }

    private func registerObservers() {
        // macOS sleep/wake
        sleepObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWillSleep()
            }
        }

        wakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDidWake()
            }
        }

        // App termination
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    private func handleWillSleep() {
        isSleeping = true
        isActive = false
        AppLog.app.info("App will sleep — pausing background work")

        // Central pause for all player watchdogs / reconnect Tasks / cache timers
        // (the primary remaining leak source from Agent 09). EPG schedulers
        // already consult shouldPauseBackgroundWork inside their loops.
        PlayerSessionRegistry.shared.pauseAllBackgroundWork()

        // Listeners (EPGViewModel, RecordingManager, etc.) should react to isSleeping / !isActive
    }

    private func handleDidWake() {
        isSleeping = false
        isActive = true
        AppLog.app.info("App did wake — resuming background work")

        // Resume player watchdogs / reconnects / cache timers for any open sessions.
        PlayerSessionRegistry.shared.resumeAllBackgroundWork()

        // Trigger recording wake reconciliation (Agent 05/09)
        Task { @MainActor in
            RecordingManager.shared.reconcileWakeEvents()
        }
    }

    @objc private func handleWillTerminate() {
        isTerminating = true
        isActive = false
        AppLog.app.info("App will terminate — final cleanup")
        PlayerSessionRegistry.shared.pauseAllBackgroundWork()
    }

    // Observers are intentionally left registered for the lifetime of the app.
    // macOS apps rarely deinit the main App object, and removing them here
    // causes actor isolation issues in deinit. Cleanup on termination is
    // handled by the process exiting.
}
