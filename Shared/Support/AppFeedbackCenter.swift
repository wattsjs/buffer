import SwiftUI

struct AppFeedbackMessage: Identifiable, Equatable {
    enum Tone: Equatable {
        case neutral
        case success
        case warning

        var accent: Color {
            switch self {
            case .neutral: .secondary
            case .success: .green
            case .warning: .orange
            }
        }

    }

    let id = UUID()
    let title: String?
    let message: String
    let symbol: String
    let tone: Tone
    let showsActivity: Bool

    static func sync(stage: String?) -> Self {
        .init(
            title: nil,
            message: stage ?? "Refreshing…",
            symbol: "arrow.triangle.2.circlepath",
            tone: .neutral,
            showsActivity: true
        )
    }

    static func reminderScheduled(programTitle: String, channelName: String, notifyAt: Date, leadMinutes: Int) -> Self {
        let timeText = notifyAt.formatted(.dateTime.hour().minute())
        let leadText: String
        switch leadMinutes {
        case 0:
            leadText = "right when it starts"
        case 1:
            leadText = "1 minute before it starts"
        default:
            leadText = "\(leadMinutes) minutes before it starts"
        }

        return .init(
            title: "Reminder set for \(programTitle)",
            message: "We’ll send a Mac notification at \(timeText), \(leadText) on \(channelName).",
            symbol: "checkmark.circle.fill",
            tone: .success,
            showsActivity: false
        )
    }

    static func reminderFailed(programTitle: String) -> Self {
        .init(
            title: "Couldn’t set reminder",
            message: "Buffer couldn’t schedule a reminder for \(programTitle).",
            symbol: "exclamationmark.triangle.fill",
            tone: .warning,
            showsActivity: false
        )
    }

    static func reminderChannelMissing(playlistName: String, channelName: String) -> Self {
        let where_ = playlistName.isEmpty ? "the selected playlist" : "“\(playlistName)”"
        return .init(
            title: "Channel no longer in \(where_)",
            message: "\(channelName) was removed from the playlist since you set the reminder.",
            symbol: "exclamationmark.triangle.fill",
            tone: .warning,
            showsActivity: false
        )
    }
}

@MainActor
@Observable
final class AppFeedbackCenter {
    static let shared = AppFeedbackCenter()

    var toast: AppFeedbackMessage?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: AppFeedbackMessage, autoDismissAfter duration: Duration = .seconds(5)) {
        dismissTask?.cancel()
        // Critically damped — banners should settle, not bounce.
        withAnimation(BufferMotion.bannerIn) {
            toast = message
        }

        dismissTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                dismiss()
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        withAnimation(BufferMotion.bannerOut) {
            toast = nil
        }
    }
#if os(macOS)
    func showReminderResult(
        playlistID: UUID,
        program: EPGProgram,
        channel: Channel,
        leadMinutes: Int,
        scheduled: Bool
    ) {
        guard scheduled else {
            show(.reminderFailed(programTitle: program.title.isEmpty ? "this program" : program.title))
            return
        }

        let preferredFire = program.start.addingTimeInterval(-Double(leadMinutes) * 60)
        let notifyAt = NotificationManager.shared
            .reminder(playlistID: playlistID, for: program)?.notifyAt
            ?? max(preferredFire, Date().addingTimeInterval(2))

        show(
            .reminderScheduled(
                programTitle: program.title.isEmpty ? "this program" : program.title,
                channelName: channel.name,
                notifyAt: notifyAt,
                leadMinutes: leadMinutes
            )
        )
    }
#endif
}
