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
}

@MainActor
@Observable
final class AppFeedbackCenter {
    static let shared = AppFeedbackCenter()

    var toast: AppFeedbackMessage?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: AppFeedbackMessage, autoDismissAfter duration: Duration = .seconds(5)) {
        dismissTask?.cancel()
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
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
        withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
            toast = nil
        }
    }

    func showReminderResult(
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
        let notifyAt = NotificationManager.shared.reminder(for: program)?.notifyAt
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
}

struct AppFeedbackBanner: View {
    let message: AppFeedbackMessage
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if message.showsActivity {
                    Image(systemName: message.symbol)
                        .symbolEffect(.rotate, options: .repeat(.continuous))
                } else {
                    Image(systemName: message.symbol)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(message.tone.accent)
            .padding(.top, message.title == nil ? 1 : 2)

            if let title = message.title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(message.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(message.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let onDismiss {
                Spacer(minLength: 12)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 520, alignment: .leading)
        .glassEffect(.regular, in: .capsule)
    }
}
