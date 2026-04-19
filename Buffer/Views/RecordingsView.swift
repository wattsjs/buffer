import AppKit
import SwiftUI

struct RecordingsView: View {
    @State private var manager = RecordingManager.shared
    @State private var selection: Recording.ID?
    let channels: [Channel]
    let onPlayChannel: (Channel) -> Void

    private var groupedRecordings: (active: [Recording], upcoming: [Recording], past: [Recording]) {
        var active: [Recording] = []
        var upcoming: [Recording] = []
        var past: [Recording] = []
        for r in manager.recordings {
            switch r.status {
            case .recording, .startingUp: active.append(r)
            case .scheduled: upcoming.append(r)
            case .completed, .failed, .cancelled: past.append(r)
            }
        }
        upcoming.sort { $0.scheduledStart < $1.scheduledStart }
        past.sort { ($0.actualEnd ?? $0.scheduledEnd) > ($1.actualEnd ?? $1.scheduledEnd) }
        return (active, upcoming, past)
    }

    var body: some View {
        let groups = groupedRecordings

        if manager.recordings.isEmpty {
            ContentUnavailableView(
                "No Recordings",
                systemImage: "record.circle",
                description: Text("Right-click a program in the guide to schedule a recording, or tap the record button while watching a channel.")
            )
        } else {
            List(selection: $selection) {
                if !groups.active.isEmpty {
                    Section("Recording now") {
                        ForEach(groups.active) { recording in
                            RecordingRow(recording: recording, channels: channels, onPlayChannel: onPlayChannel)
                                .tag(recording.id)
                        }
                    }
                }
                if !groups.upcoming.isEmpty {
                    Section("Scheduled") {
                        ForEach(groups.upcoming) { recording in
                            RecordingRow(recording: recording, channels: channels, onPlayChannel: onPlayChannel)
                                .tag(recording.id)
                        }
                    }
                }
                if !groups.past.isEmpty {
                    Section("Past") {
                        ForEach(groups.past) { recording in
                            RecordingRow(recording: recording, channels: channels, onPlayChannel: onPlayChannel)
                                .tag(recording.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording
    let channels: [Channel]
    let onPlayChannel: (Channel) -> Void

    @State private var manager = RecordingManager.shared
    @Environment(\.openWindow) private var openWindow

    private var channel: Channel? {
        channels.first { $0.id == recording.channelID }
    }

    /// The partial .ts file is playable the moment recording starts, so
    /// both in-progress and completed recordings open the local file.
    private var canOpenFile: Bool {
        recording.fileURL != nil
            && (recording.status == .completed || recording.status == .recording)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusDot
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(cleanedTitle)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if recording.status == .recording {
                        liveBadge
                    } else if recording.status == .startingUp {
                        startingBadge
                    }
                }
                HStack(spacing: 6) {
                    Text(recording.channelName)
                    Text("·")
                    Text(timeRange)
                    if let err = recording.errorMessage {
                        Text("·")
                        Text(err).foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                detailsRow
            }

            Spacer(minLength: 0)

            rowActions
                .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // Finder-idiomatic: single click selects (handled by List), double
        // click opens. For in-progress rows, the default open is "watch
        // from the start"; "watch live" is available from the context menu
        // and the inline Live button.
        .onTapGesture(count: 2) {
            if canOpenFile { playFromStart() }
        }
        .contextMenu { contextMenuContents }
    }

    @ViewBuilder
    private var contextMenuContents: some View {
        switch recording.status {
        case .startingUp:
            Button("Cancel", role: .destructive) {
                manager.cancel(id: recording.id)
            }
        case .recording:
            Button("Watch From Start") { playFromStart() }
            if let channel {
                Button("Watch Live") { onPlayChannel(channel) }
            }
            Divider()
            if let url = recording.fileURL {
                Button("Reveal in Finder") { revealInFinder(url) }
                Button("Open in Default Player") { openExternally(url) }
            }
            Divider()
            Button("Stop Recording", role: .destructive) {
                manager.cancel(id: recording.id)
            }
        case .completed:
            Button("Play in Buffer") { playFromStart() }
            if let url = recording.fileURL {
                Button("Reveal in Finder") { revealInFinder(url) }
                Button("Open in Default Player") { openExternally(url) }
            }
            if let channel {
                Divider()
                Button("Go to Channel") { onPlayChannel(channel) }
            }
            Divider()
            Button("Remove from List") { manager.deleteEntry(id: recording.id) }
            if let url = recording.fileURL,
               FileManager.default.fileExists(atPath: url.path) {
                Button("Move File to Trash", role: .destructive) {
                    deleteFile(url)
                    manager.deleteEntry(id: recording.id)
                }
            }
        case .scheduled:
            Button("Cancel", role: .destructive) {
                manager.cancel(id: recording.id)
            }
        case .failed, .cancelled:
            if let channel {
                Button("Go to Channel") { onPlayChannel(channel) }
                Divider()
            }
            Button("Remove from List") { manager.deleteEntry(id: recording.id) }
        }
    }

    /// Some IPTV providers stuff Unicode superscript characters into
    /// program titles ("ᴸⁱᵛᵉ", "ⁿᵉʷ") as decoration. They render as
    /// near-unreadable tiny glyphs, so we fold them back to ASCII and
    /// drop them if they'd just duplicate info we already surface via
    /// the red dot + LIVE badge.
    private var cleanedTitle: String {
        var t = foldSuperscripts(recording.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["Live", "LIVE", "New", "NEW"] {
            if t.hasSuffix(suffix),
               t.dropLast(suffix.count).last?.isWhitespace == true {
                t = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return t
    }

    private func foldSuperscripts(_ s: String) -> String {
        // Handles the unicode super/subscript letters we see most
        // often in EPG junk. Full Unicode folding would be overkill —
        // this table covers the observed cases.
        let map: [Character: Character] = [
            "ᴬ":"A","ᴮ":"B","ᴰ":"D","ᴱ":"E","ᴳ":"G","ᴴ":"H","ᴵ":"I","ᴶ":"J",
            "ᴷ":"K","ᴸ":"L","ᴹ":"M","ᴺ":"N","ᴼ":"O","ᴾ":"P","ᴿ":"R","ᵀ":"T",
            "ᵁ":"U","ⱽ":"V","ᵂ":"W",
            "ᵃ":"a","ᵇ":"b","ᶜ":"c","ᵈ":"d","ᵉ":"e","ᶠ":"f","ᵍ":"g","ʰ":"h",
            "ⁱ":"i","ʲ":"j","ᵏ":"k","ˡ":"l","ᵐ":"m","ⁿ":"n","ᵒ":"o","ᵖ":"p",
            "ʳ":"r","ˢ":"s","ᵗ":"t","ᵘ":"u","ᵛ":"v","ʷ":"w","ˣ":"x","ʸ":"y","ᶻ":"z",
        ]
        return String(s.map { map[$0] ?? $0 })
    }

    /// Small orange pill shown while the recording stream is opening (HLS + TLS
    /// handshake) but bytes haven't started flowing yet. Spinner signals
    /// "work in progress" so the user doesn't think the row is stalled.
    @ViewBuilder
    private var startingBadge: some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 8, height: 8)
            Text("STARTING")
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Color.orange, in: Capsule())
    }

    /// Tiny red "LIVE" pill next to active recording titles. Replaces
    /// the ugly Unicode "ᴸⁱᵛᵉ" tokens that EPG data often carries.
    @ViewBuilder
    private var liveBadge: some View {
        Text("LIVE")
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.red, in: Capsule())
    }

    /// Second line of details: live stats while recording, final stats once
    /// finished. Hidden for scheduled rows (no data to show).
    @ViewBuilder
    private var detailsRow: some View {
        switch recording.status {
        case .startingUp:
            EmptyView()
        case .recording:
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(elapsedString).monospacedDigit()
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: recording.bytesWritten, countStyle: .file))
                        .monospacedDigit()
                    if let bitrate = bitrateString {
                        Text("·")
                        Text(bitrate).monospacedDigit()
                    }
                    if let stream = streamDetailsString {
                        Text("·")
                        Text(stream)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                // Thin Capsule-based bar instead of the default linear
                // ProgressView — slimmer, rounded, and matches the
                // thumbless scrub bar in the in-app recording player.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.18))
                        Capsule()
                            .fill(Color.red)
                            .frame(width: max(2, geo.size.width * progressFraction))
                    }
                }
                .frame(maxWidth: 320, maxHeight: 3)
            }
        case .completed, .failed, .cancelled:
            if hasFinalStats {
                HStack(spacing: 6) {
                    if let duration = recording.mediaDuration {
                        Text(format(duration: duration)).monospacedDigit()
                    }
                    if let size = recording.fileSizeBytes {
                        if recording.mediaDuration != nil { Text("·") }
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .monospacedDigit()
                    }
                    if let stream = streamDetailsString {
                        Text("·")
                        Text(stream)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        case .scheduled:
            EmptyView()
        }
    }

    private var hasFinalStats: Bool {
        recording.mediaDuration != nil
            || recording.fileSizeBytes != nil
            || recording.streamInfo != nil
    }

    private var elapsedString: String {
        format(duration: recording.mediaDuration ?? 0)
    }

    private var progressFraction: Double {
        let start = recording.scheduledStart
        let total = recording.scheduledEnd.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        let elapsed = Date().timeIntervalSince(start)
        return min(1, max(0, elapsed / total))
    }

    private var bitrateString: String? {
        guard let duration = recording.mediaDuration, duration >= 1 else { return nil }
        let bitsPerSecond = Double(recording.bytesWritten * 8) / duration
        if bitsPerSecond <= 0 { return nil }
        let mbps = bitsPerSecond / 1_000_000
        if mbps >= 1 {
            return String(format: "%.1f Mbps", mbps)
        }
        let kbps = bitsPerSecond / 1_000
        return String(format: "%.0f kbps", kbps)
    }

    private var streamDetailsString: String? {
        guard let info = recording.streamInfo else { return nil }
        var parts: [String] = []
        if info.videoWidth > 0 && info.videoHeight > 0 {
            parts.append("\(info.videoWidth)×\(info.videoHeight)")
        }
        if !info.videoCodec.isEmpty {
            parts.append(info.videoCodec.uppercased())
        }
        if info.videoFPS > 0 {
            parts.append(String(format: "%.0f fps", info.videoFPS))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func format(duration: TimeInterval) -> String {
        let total = Int(duration)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    @ViewBuilder
    private var rowActions: some View {
        switch recording.status {
        case .startingUp:
            Button(role: .destructive) {
                manager.cancel(id: recording.id)
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .controlSize(.regular)
            .buttonStyle(.bordered)
        case .recording:
            HStack(spacing: 8) {
                Button {
                    playFromStart()
                } label: {
                    Label("From Start", systemImage: "play.fill")
                }
                .help("Watch from the beginning of the recording")

                if let channel {
                    Button {
                        onPlayChannel(channel)
                    } label: {
                        Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .help("Watch the channel live")
                }

                Button(role: .destructive) {
                    manager.cancel(id: recording.id)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop recording")
            }
            .controlSize(.regular)
            .buttonStyle(.bordered)
        case .scheduled:
            Button(role: .destructive) {
                manager.cancel(id: recording.id)
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .controlSize(.regular)
            .buttonStyle(.bordered)
        case .completed:
            Button {
                playFromStart()
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .controlSize(.regular)
            .buttonStyle(.bordered)
            .help("Play in Buffer")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private func playFromStart() {
        guard recording.fileURL != nil else { return }
        openWindow(value: recording)
    }

    private func openExternally(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func deleteFile(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Open the parent folder in Finder with the recorded file selected.
    /// `activateFileViewerSelecting` crosses the sandbox boundary and the
    /// kernel's first extension-creation attempt frequently fails under the
    /// Movies entitlement — the user then has to click twice. `selectFile`
    /// rooted at the parent directory avoids that race: Finder is opened
    /// directly at the folder we've already got file access to, with the
    /// target item selected.
    private func revealInFinder(_ url: URL) {
        let parent = url.deletingLastPathComponent().path
        if !NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: parent) {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private var color: Color {
        switch recording.status {
        case .recording:  return .red
        case .startingUp: return .orange
        case .scheduled:  return .blue
        case .completed:  return .green
        case .failed:     return .orange
        case .cancelled:  return .gray
        }
    }

    private var timeRange: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, h:mma"
        fmt.amSymbol = "am"
        fmt.pmSymbol = "pm"
        return "\(fmt.string(from: recording.scheduledStart)) – \(DateFormatter.localizedString(from: recording.scheduledEnd, dateStyle: .none, timeStyle: .short))"
    }
}
