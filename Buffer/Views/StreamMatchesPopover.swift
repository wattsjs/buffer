import SwiftUI

struct StreamMatchesPopover: View {
    let event: SportEvent
    let matches: [StreamMatch]
    let favoriteIDs: Set<String>
    var reminderHint: String? = nil
    var onPlay: ((Channel) -> Void)? = nil
    var onRemind: ((Channel) -> Void)? = nil
    var onRecord: ((Channel) -> Void)? = nil

    /// ESPN scoreboards only surface a start time. We assume a 3-hour window
    /// so the user can see roughly when the broadcast will wrap.
    private var timeRange: String {
        let end = event.startDate.addingTimeInterval(3 * 3600)
        let cal = Calendar.current
        let timeFmt = DateFormatter()
        timeFmt.amSymbol = "am"
        timeFmt.pmSymbol = "pm"
        timeFmt.dateFormat = "h:mma"

        let dayPrefix: String
        if cal.isDateInToday(event.startDate) {
            dayPrefix = "Today"
        } else if cal.isDateInTomorrow(event.startDate) {
            dayPrefix = "Tomorrow"
        } else {
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "EEE d MMM"
            dayPrefix = dayFmt.string(from: event.startDate)
        }
        return "\(dayPrefix) · \(timeFmt.string(from: event.startDate)) – \(timeFmt.string(from: end))"
    }

    private var visibleMatches: [StreamMatch] {
        matches.filter { !$0.isHidden }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(event.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(event.league.fullName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let reminderHint {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(reminderHint)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(timeRange)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if visibleMatches.isEmpty {
                Text("No matching streams found")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(visibleMatches) { match in
                            StreamMatchPopoverRow(
                                match: match,
                                isFavorite: favoriteIDs.contains(match.channel.id),
                                onPlay: onPlay.map { action in { action(match.channel) } },
                                onRemind: onRemind.map { action in { action(match.channel) } },
                                onRecord: onRecord.map { action in { action(match.channel) } }
                            )
                            .requestStreamProbe(for: match.channel)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 460)
    }
}

private struct StreamMatchPopoverRow: View {
    let match: StreamMatch
    let isFavorite: Bool
    let onPlay: (() -> Void)?
    let onRemind: (() -> Void)?
    let onRecord: (() -> Void)?

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ChannelLogoTile(channel: match.channel, contentInset: 2)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(match.channel.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.pink)
                    }
                    Spacer(minLength: 0)
                    StreamProbeBadge(channelID: match.channel.id, style: .compact)
                }

                if !metaLine.isEmpty {
                    Text(metaLine)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if let title = match.programTitle, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let details = programDetails, !details.isEmpty {
                    Text(details)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                confidenceDots(score: match.score)

                HStack(spacing: 8) {
                    if let onRecord {
                        Button(action: onRecord) {
                            Image(systemName: "record.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(.red)
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.borderless)
                        .help(onPlay != nil ? "Record now" : "Schedule recording")
                    }

                    if let onPlay {
                        Button(action: onPlay) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.borderless)
                        .help("Play now")
                    } else if let onRemind {
                        Button(action: onRemind) {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 12))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.borderless)
                        .help("Set reminder")
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovered ? Color.white.opacity(0.06) : Color.white.opacity(0.025))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            if let onPlay {
                onPlay()
            } else {
                onRemind?()
            }
        }
    }

    private func confidenceDots(score: Double) -> some View {
        let filled = score > 180 ? 3 : (score > 120 ? 2 : 1)
        return HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(i < filled ? Color.green : Color.secondary.opacity(0.2))
                    .frame(width: 5, height: 5)
            }
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if !match.reason.isEmpty { parts.append(match.reason) }
        if let timingLabel { parts.append(timingLabel) }
        return parts.joined(separator: " · ")
    }

    private var programDetails: String? {
        let trimmed = match.programDescription?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var timingLabel: String? {
        guard let start = match.programStart, let end = match.programEnd else { return nil }
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mma"
        timeFmt.amSymbol = "am"
        timeFmt.pmSymbol = "pm"

        let prefix: String
        let now = Date()
        if start <= now && end > now {
            prefix = "Now"
        } else if start > now {
            prefix = "Next"
        } else {
            prefix = "Earlier"
        }
        return "\(prefix) \(timeFmt.string(from: start))-\(timeFmt.string(from: end))"
    }
}
