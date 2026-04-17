import SwiftUI

struct RemindersView: View {
    let channels: [Channel]
    let onPlayReminder: (ProgramReminder) -> Void

    @State private var notificationManager = NotificationManager.shared
    @State private var tick = Date()

    private var upcoming: [ProgramReminder] {
        notificationManager.reminders
            .sorted { $0.notifyAt < $1.notifyAt }
    }

    var body: some View {
        Group {
            if upcoming.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .task {
            // Keep relative times fresh. Cheap 30s tick.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                tick = Date()
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Reminders",
            systemImage: "bell.slash",
            description: Text("Right-click a program in the guide or search results to set a reminder.")
        )
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                sectionHeader
                ForEach(upcoming) { reminder in
                    ReminderRow(
                        reminder: reminder,
                        channel: channels.first { $0.id == reminder.channelID },
                        onPlay: { onPlayReminder(reminder) },
                        onCancel: { notificationManager.cancelReminder(id: reminder.id) }
                    )
                    .id(reminder.id)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(upcoming.count) upcoming")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button {
                cancelAll()
            } label: {
                Label("Clear All", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.bottom, 4)
    }

    private func cancelAll() {
        for reminder in notificationManager.reminders {
            notificationManager.cancelReminder(id: reminder.id)
        }
    }
}

private struct ReminderRow: View {
    let reminder: ProgramReminder
    let channel: Channel?
    let onPlay: () -> Void
    let onCancel: () -> Void

    @State private var hovered = false

    private static let hm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    private var startsWhen: String {
        let now = Date()
        let cal = Calendar.current
        let timeString = Self.hm.string(from: reminder.programStart)
        if cal.isDateInToday(reminder.programStart) {
            return "Today · \(timeString)"
        }
        if cal.isDateInTomorrow(reminder.programStart) {
            return "Tomorrow · \(timeString)"
        }
        let full = DateFormatter()
        full.dateFormat = "EEE d MMM · h:mma"
        full.amSymbol = "am"
        full.pmSymbol = "pm"
        _ = now
        return full.string(from: reminder.programStart)
    }

    private var firesIn: String {
        let interval = reminder.notifyAt.timeIntervalSinceNow
        if interval <= 0 {
            return "firing any moment"
        }
        if interval < 60 {
            return "fires in <1m"
        }
        if interval < 3600 {
            return "fires in \(Int(interval / 60))m"
        }
        if interval < 3600 * 24 {
            let hours = Int(interval / 3600)
            let minutes = (Int(interval) % 3600) / 60
            return minutes == 0 ? "fires in \(hours)h" : "fires in \(hours)h \(minutes)m"
        }
        let days = Int(interval / (3600 * 24))
        return "fires in \(days)d"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let channel {
                ChannelLogoTile(channel: channel)
                    .frame(width: 64, height: 64)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: "tv.slash")
                            .foregroundStyle(.tertiary)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(reminder.programTitle.isEmpty ? "Program" : reminder.programTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(firesIn)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text(reminder.channelName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(Color.secondary.opacity(0.6))
                    Text(startsWhen)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary.opacity(0.9))
                        .monospacedDigit()
                }
                .lineLimit(1)
                if !reminder.programDescription.isEmpty {
                    Text(reminder.programDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary.opacity(0.75))
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovered ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button {
                onPlay()
            } label: {
                Label("Play Channel", systemImage: "play.fill")
            }
            if let channel {
                AddToMultiViewMenuItem(channel: channel)
            }
            if let channel, reminder.programEnd > Date() {
                recordingMenuItems(channel: channel)
            }
            Button(role: .destructive, action: onCancel) {
                Label("Cancel Reminder", systemImage: "bell.slash")
            }
        }
        .onTapGesture {
            onPlay()
        }
    }

    /// Reminder rows carry enough program metadata to build an EPGProgram and
    /// hand it to RecordingManager via the same path the EPG grid uses.
    private func reminderProgram() -> EPGProgram {
        EPGProgram(
            id: reminder.programID,
            channelID: reminder.channelID,
            title: reminder.programTitle,
            description: reminder.programDescription,
            start: reminder.programStart,
            end: reminder.programEnd
        )
    }

    @ViewBuilder
    private func recordingMenuItems(channel: Channel) -> some View {
        let recorder = RecordingManager.shared
        let existing = recorder.recordings.first { rec in
            rec.programID == reminder.programID
                && rec.channelID == channel.id
                && (rec.status == .scheduled || rec.status == .recording)
        }

        if let existing {
            let isRec = existing.status == .recording
            Button {
                recorder.cancel(id: existing.id)
            } label: {
                Label(
                    isRec ? "Stop Recording" : "Cancel Scheduled Recording",
                    systemImage: isRec ? "stop.circle.fill" : "xmark.circle"
                )
            }
        } else if reminder.programStart <= Date() {
            // Program is already airing — kick off a live recording immediately.
            Button {
                let program = reminderProgram()
                Task { @MainActor in
                    _ = await recorder.startLiveRecording(
                        playlistID: reminder.playlistID,
                        channel: channel,
                        program: program
                    )
                }
            } label: {
                Label("Record Now", systemImage: "record.circle")
            }
        } else {
            Button {
                _ = recorder.schedule(
                    playlistID: reminder.playlistID,
                    channel: channel,
                    program: reminderProgram()
                )
            } label: {
                Label("Record This Program", systemImage: "record.circle")
            }
        }
    }
}
