import Foundation
import UserNotifications
import AppKit
import OSLog
import SwiftUI

/// Bridges EPG program reminders to the macOS notification daemon
/// (`usernoted`). Once a reminder is scheduled via `UNUserNotificationCenter`,
/// the system daemon owns delivery — the notification fires at the scheduled
/// time even if Buffer has quit. No helper LaunchAgent required.
@MainActor
@Observable
final class NotificationManager: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    var reminders: [ProgramReminder] = []
    var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let storageKey = "Buffer_reminders_v1"
    private static let categoryID = "Buffer.program.reminder"
    private static let actionWatchNow = "Buffer.action.watchNow"

    /// Posted when the user activates a reminder notification. `object` is the
    /// stream `URL`.
    static let openStreamNotification = Notification.Name("Buffer.openStreamFromReminder")

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
        loadReminders()
    }

    /// Called at app launch. Requests permission, reconciles persisted state
    /// with whatever the notification daemon still has pending, and removes
    /// reminders whose programs have already aired.
    func bootstrap() async {
        await refreshAuthorizationStatus()
        if authorizationStatus == .notDetermined {
            await requestAuthorization()
        }
        await reconcileWithSystem()
        pruneExpired()
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            AppLog.notifications.error("Notification auth failed error=\(error.localizedDescription, privacy: .public)")
        }
        await refreshAuthorizationStatus()
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        self.authorizationStatus = settings.authorizationStatus
    }

    // MARK: - Queries

    func hasReminder(playlistID: UUID, for program: EPGProgram) -> Bool {
        let id = ProgramReminder.makeID(
            playlistID: playlistID,
            channelID: program.channelID,
            programID: program.id
        )
        return reminders.contains { $0.id == id }
    }

    func reminder(playlistID: UUID, for program: EPGProgram) -> ProgramReminder? {
        let id = ProgramReminder.makeID(
            playlistID: playlistID,
            channelID: program.channelID,
            programID: program.id
        )
        return reminders.first { $0.id == id }
    }

    // MARK: - Scheduling

    @discardableResult
    func scheduleReminder(
        playlistID: UUID,
        program: EPGProgram,
        channel: Channel,
        leadMinutes: Int = 5
    ) async -> Bool {
        if authorizationStatus == .notDetermined {
            await requestAuthorization()
        }
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else {
            presentDeniedAlert()
            return false
        }

        let now = Date()
        // Never schedule for programs that have already finished.
        guard program.end > now else { return false }

        let preferredFire = program.start.addingTimeInterval(-Double(leadMinutes) * 60)
        // If the lead window already passed but the program hasn't started,
        // fire in ~2s. If it's already started, still fire in ~2s so the user
        // gets a "now playing" nudge.
        let fireDate = max(preferredFire, now.addingTimeInterval(2))

        let id = ProgramReminder.makeID(
            playlistID: playlistID,
            channelID: program.channelID,
            programID: program.id
        )

        // Remove any existing request under the same id first.
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id])

        let content = UNMutableNotificationContent()
        content.title = program.title.isEmpty ? "Program starting soon" : program.title
        content.subtitle = channel.name
        content.body = reminderBody(program: program, channel: channel, fireDate: fireDate)
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [
            "playlistID": playlistID.uuidString,
            "channelID": channel.id,
            "programID": program.id
        ]
        content.threadIdentifier = channel.id

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            AppLog.notifications.error("Failed to schedule reminder id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }

        let reminder = ProgramReminder(
            id: id,
            playlistID: playlistID,
            programID: program.id,
            channelID: channel.id,
            channelName: channel.name,
            programTitle: program.title,
            programDescription: program.description,
            programStart: program.start,
            programEnd: program.end,
            notifyAt: fireDate,
            createdAt: now,
            leadMinutes: leadMinutes,
            streamURL: channel.streamURL
        )
        reminders.removeAll { $0.id == id }
        reminders.append(reminder)
        saveReminders()
        return true
    }

    func cancelReminder(playlistID: UUID, for program: EPGProgram) {
        let id = ProgramReminder.makeID(
            playlistID: playlistID,
            channelID: program.channelID,
            programID: program.id
        )
        cancelReminder(id: id)
    }

    func cancelReminder(id: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id])
        reminders.removeAll { $0.id == id }
        saveReminders()
    }

    /// Remove every reminder owned by the given playlist. Called when the
    /// playlist is deleted.
    func cancelReminders(forPlaylistID playlistID: UUID) {
        let doomed = reminders.filter { $0.playlistID == playlistID }
        guard !doomed.isEmpty else { return }
        let ids = doomed.map(\.id)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ids)
        reminders.removeAll { $0.playlistID == playlistID }
        saveReminders()
    }

    // MARK: - Reconciliation

    private func reconcileWithSystem() async {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let pendingIDs = Set(pending.map(\.identifier))
        let before = reminders.count
        reminders.removeAll { !pendingIDs.contains($0.id) && $0.notifyAt < Date() }
        if reminders.count != before {
            saveReminders()
        }
    }

    private func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-60 * 60)
        let expired = reminders.filter { $0.programEnd < cutoff }
        guard !expired.isEmpty else { return }
        let ids = expired.map(\.id)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ids)
        reminders.removeAll { expired.contains($0) }
        saveReminders()
    }

    // MARK: - Persistence

    private func loadReminders() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let list = try? decoder.decode([ProgramReminder].self, from: data) {
            reminders = list
        }
    }

    private func saveReminders() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(reminders) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - Helpers

    private func registerCategories() {
        let watchNow = UNNotificationAction(
            identifier: Self.actionWatchNow,
            title: "Watch Now",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [watchNow],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func reminderBody(program: EPGProgram, channel: Channel, fireDate: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        let startsAt = formatter.string(from: program.start)
        let base = "Starts at \(startsAt) on \(channel.name)"
        if program.description.isEmpty { return base }
        return base + "\n" + program.description
    }

    private func presentDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Notifications are off for Buffer"
        alert.informativeText = "Enable notifications for Buffer in System Settings › Notifications to get program reminders."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = response.notification.request.identifier
        guard let reminder = reminders.first(where: { $0.id == id }) else { return }

        // Consume the reminder now — the system will also clear its pending
        // request by identifier since fire + activate implies completion.
        reminders.removeAll { $0.id == id }
        saveReminders()

        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: Self.openStreamNotification,
            object: reminder
        )
    }
}
