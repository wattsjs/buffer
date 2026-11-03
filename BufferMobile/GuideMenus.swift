import UIKit

/// Long-press menu for the iOS guide: reminders, replay and play, matching
/// the Mac's `ReminderMenuBuilder` choices.
@MainActor
enum GuideMenus {
    static func elements(model: TouchAppModel, channel: Channel, program: EPGProgram?) -> [UIMenuElement] {
        let viewModel = model.viewModel
        var elements: [UIMenuElement] = []
        if let program {
            elements.append(reminderMenu(model: model, channel: channel, program: program))
            if channel.sourceOwnership?.logicalChannelID == nil, program.start < Date(), channel.canReplay(program) {
                elements.append(UIAction(title: "Play from Start", image: UIImage(systemName: "gobackward")) { _ in
                    model.openCatchup(channel, program: program)
                })
            }
        }
        elements.append(UIAction(title: "Play Channel", image: UIImage(systemName: "play.fill")) { _ in
            model.openChannel(channel)
        })
        let favorite = viewModel.isFavorite(channel)
        elements.append(UIAction(title: favorite ? "Remove from Favorites" : "Add to Favorites",
                                 image: UIImage(systemName: favorite ? "star.slash" : "star")) { _ in
            viewModel.toggleFavorite(channel)
        })
        if channel.sourceOwnership?.logicalChannelID != nil {
            elements.append(UIAction(title: "Open Original Source Guide", image: UIImage(systemName: "list.bullet.rectangle")) { _ in
                viewModel.showOriginalSourceGuide(for: channel)
            })
        }
        return elements
    }

    private static func reminderMenu(model: TouchAppModel, channel: Channel, program: EPGProgram) -> UIMenuElement {
        let viewModel = model.viewModel
        let manager = NotificationManager.shared
        guard let playlistID = viewModel.displayedPlaylistID else {
            return UIAction(title: "No source selected", attributes: .disabled) { _ in }
        }
        if let existing = manager.reminder(playlistID: playlistID, for: program) {
            return UIAction(title: "Cancel Reminder (\(lead(existing.leadMinutes)))", image: UIImage(systemName: "bell.slash"),
                            attributes: .destructive) { _ in
                manager.cancelReminder(playlistID: playlistID, for: program)
            }
        }
        guard program.end > Date() else {
            return UIAction(title: "Already aired", attributes: .disabled) { _ in }
        }
        let action = viewModel.sourceProgramAction(channel: channel, program: program)
            ?? (channel.sourceOwnership?.logicalChannelID == nil ? (channel, program) : nil)
        guard let action else {
            return UIAction(title: "Guide source unavailable", attributes: .disabled) { _ in }
        }
        let leads = [0, 5, 15, 60].map { minutes in
            UIAction(title: minutes == 0 ? "At Start" : lead(minutes)) { _ in
                Task { @MainActor in
                    let scheduled = await manager.scheduleReminder(
                        playlistID: playlistID, program: program, channel: channel, leadMinutes: minutes,
                        sourceChannel: action.channel, sourceProgramID: action.program.id)
                    AppFeedbackCenter.shared.showReminderResult(
                        playlistID: playlistID, program: program, channel: channel,
                        leadMinutes: minutes, scheduled: scheduled)
                }
            }
        }
        return UIMenu(title: "Remind Me", image: UIImage(systemName: "bell"), children: leads)
    }

    static func lead(_ minutes: Int) -> String {
        switch minutes {
        case 0: "at start"
        case 1..<60: "\(minutes) min before"
        default: minutes == 60 ? "1 hour before" : "\(minutes / 60) hours before"
        }
    }
}
