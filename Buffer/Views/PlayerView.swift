import AppKit
import SwiftUI
import NukeUI

enum MediaInfoDisplay: String, CaseIterable {
    case expanded
    case collapsed

    var next: MediaInfoDisplay {
        switch self {
        case .expanded: return .collapsed
        case .collapsed: return .expanded
        }
    }

    var iconName: String {
        switch self {
        case .expanded: return "info.circle.fill"
        case .collapsed: return "info.circle"
        }
    }

    var label: String {
        switch self {
        case .expanded: return "Collapse media details"
        case .collapsed: return "Expand media details"
        }
    }
}

@Observable
final class PlayerChromeState {
    var isPinned: Bool = false
    var mediaInfoDisplay: MediaInfoDisplay {
        didSet {
            UserDefaults.standard.set(mediaInfoDisplay.rawValue, forKey: "buffer_media_info_display")
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: "buffer_media_info_display") ?? MediaInfoDisplay.expanded.rawValue
        self.mediaInfoDisplay = MediaInfoDisplay(rawValue: raw) ?? .expanded
    }
}

/// One unified player view for both live channels and recorded files. The
/// two modes share the same chrome layout and live pill semantics —
/// controls that don't apply to a mode are simply hidden. The live state
/// is latched: once the user is "at the live edge" the pill stays red
/// through ordinary cache / frame jitter and only flips when the player
/// drifts past `max(2 × buffer, buffer + 5s)` behind the live reference.
struct PlayerView: View {
    enum Mode {
        case channel
        case recording
    }

    let mode: Mode
    /// Present only in channel mode — recordings don't need EPG lookups.
    let viewModel: EPGViewModel?

    @Environment(\.dismiss) private var dismiss
    @AppStorage(ExternalPlayer.selectedPlayerKey) private var selectedPlayer: ExternalPlayerKind = .none

    // Exactly one of these two is populated, keyed by `mode`.
    @State private var channelSession: PlayerSession?
    @State private var recordingPlayback: RecordingPlayback?

    @State private var chromeState = PlayerChromeState()
    @State private var showChrome = true
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var showVolumePopover = false
    @State private var showChannelPicker = false

    /// Recording-mode primary scrub position override while the user drags
    /// the bottom scrubber. Also reused by channel mode's HLS-seekbar.
    @State private var scrubPosition: Double? = nil

    /// Catchup step-slider scrub override (channel mode only).
    @State private var catchupScrubOffset: Double? = nil
    /// Wall-clock start time of the currently loaded catchup clip. `nil`
    /// means we're on the live source (or it's a recording).
    @State private var catchupStartDate: Date? = nil
    /// True between the moment a catchup load is kicked off and the
    /// moment playback of the new clip actually begins.
    @State private var isSeekingCatchup: Bool = false
    @State private var seekingTimeoutTask: Task<Void, Never>? = nil
    private let catchupClipDuration: TimeInterval = 2 * 60 * 60

    /// Sticky live indicator. Starts true for any source that has a live
    /// concept (channel + in-progress recording) and false for completed
    /// recordings. Flipped to false only when the player has meaningfully
    /// drifted behind the live reference; re-latched by a LIVE button
    /// press or a seek back near the edge.
    @State private var liveLatched: Bool

    // MARK: - Init

    init(channel: Channel, currentProgram: EPGProgram?, viewModel: EPGViewModel) {
        self.mode = .channel
        self.viewModel = viewModel
        _channelSession = State(initialValue: PlayerSession(
            initialChannel: channel,
            currentProgram: currentProgram
        ))
        _recordingPlayback = State(initialValue: nil)
        _liveLatched = State(initialValue: true)
    }

    init(recording: Recording) {
        self.mode = .recording
        self.viewModel = nil
        _channelSession = State(initialValue: nil)
        _recordingPlayback = State(initialValue: RecordingPlayback(recording: recording))
        _liveLatched = State(initialValue: recording.status == .recording)
    }

    // MARK: - Source accessors

    private var isRecordingMode: Bool { mode == .recording }
    private var isChannelMode: Bool { mode == .channel }

    private var session: PlayerSession? { channelSession }
    private var playback: RecordingPlayback? { recordingPlayback }

    private var player: MPVPlayer {
        playback?.player ?? session!.focusedSlot.player
    }

    private var channel: Channel? { session?.focusedSlot.channel }
    private var currentProgram: EPGProgram? { session?.focusedSlot.currentProgram }
    private var liveProgram: EPGProgram? {
        guard let c = channel else { return nil }
        return viewModel?.currentProgram(for: c)
    }

    private var isMulti: Bool { session?.isMulti ?? false }
    private var supportsRewind: Bool {
        guard let s = session else { return false }
        return !s.isMulti && (channel?.supportsRewind ?? false)
    }

    private var isCatchup: Bool { catchupStartDate != nil }

    /// Wall-clock time the user is currently watching in catchup mode. For
    /// live / recording it's just "now".
    private var effectiveWallClock: Date {
        if let start = catchupStartDate {
            return start.addingTimeInterval(player.timePos)
        }
        return Date()
    }

    private var displayedProgram: EPGProgram? {
        guard let c = channel, let vm = viewModel else { return nil }
        return vm.program(for: c, at: effectiveWallClock) ?? currentProgram
    }

    // MARK: - Live reference + latch

    /// Buffer budget used for the latch threshold. Pulled from the shared
    /// mpv setting, never zero.
    private var bufferSeconds: Double {
        max(player.configuredBufferSeconds, 1)
    }

    /// How far behind the live reference the playhead is, in seconds
    /// (always ≥ 0). Nil when the source has no live concept (completed
    /// recording; HLS with no DVR window and no cache insight).
    private var secondsBehindLive: Double? {
        if isRecordingMode {
            guard let p = playback, p.isInProgress else { return nil }
            return max(0, p.totalDuration - player.timePos)
        }
        if isCatchup {
            return max(0, -catchupCurrentOffset)
        }
        if supportsRewind || player.canReplay {
            return max(0, player.duration - player.timePos - player.preferredLiveDelay)
        }
        return nil
    }

    /// Threshold at which the latch flips off. Deliberately larger than
    /// the buffer so a transient cache dip (e.g. mpv's `paused-for-cache`
    /// briefly reporting lower `cacheSeconds`) doesn't churn the pill.
    private var liveUnlockThreshold: Double {
        max(2 * bufferSeconds, bufferSeconds + 5)
    }

    /// Chrome state the LIVE pill renders from: sticky, computed off the
    /// latch instead of off the instantaneous offset.
    private var isDisplayedLive: Bool { liveLatched && !isCatchup && !isSeekingCatchup }

    /// Whether the LIVE button should be actionable (i.e. we're not
    /// already at live). Keeps the button disabled while the latch is
    /// held so the user can only click it once per drift.
    private var canJumpToLive: Bool {
        if isRecordingMode {
            return (playback?.isInProgress ?? false) && !isDisplayedLive
        }
        return !isDisplayedLive
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Render stack differs by mode, but chrome is unified below.
            if let s = session {
                PlayerGridView(session: s)
                    .padding(s.isMulti ? 8 : 0)
                    .ignoresSafeArea()
            } else {
                MPVLayerView(player: player)
                    .ignoresSafeArea()
            }

            // Tap-to-toggle-pause layer. Only the bottom 2/3 receives
            // taps; the top 1/3 is a passthrough drag region for window
            // movement. Disabled in multi-view (per-cell taps handle focus).
            if !isMulti {
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: geo.size.height / 3)
                            .allowsHitTesting(false)
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.togglePause()
                            }
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if showChrome && !isMulti {
                infoStack
                    .padding(16)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showChrome {
                chromeButtons
                    .padding(.top, 4)
                    .padding(.trailing, 8)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if showChrome && !isMulti {
                controlsBar
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showChrome && !isMulti {
                mediaInfoCard
                    .padding(16)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay {
            if let error = player.errorMessage {
                playbackErrorView(error)
                    .padding(24)
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 640, minHeight: 360)
        .onAppear { handleOnAppear() }
        .onDisappear { handleOnDisappear() }
        .onChange(of: player.timePos) { _, _ in
            endSeekingIfPlaying()
            reconcileLiveLatch()
        }
        .onChange(of: player.isBuffering) { _, _ in
            endSeekingIfPlaying()
        }
        .onChange(of: player.duration) { _, _ in
            reconcileLiveLatch()
        }
        .background(WindowAccessor(
            showChrome: $showChrome,
            isPinned: chromeState.isPinned,
            videoSize: isMulti
                ? .zero
                : CGSize(width: player.mediaInfo.width, height: player.mediaInfo.height)
        ))
        .background(
            PlayerKeyboardMonitor { command, window in
                handleKeyboardCommand(command, in: window)
            }
        )
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active:
                if let s = session { PlayerSessionRegistry.shared.setActive(s) }
                revealChrome()
            case .ended:
                scheduleChromeHide()
            }
        }
        .onChange(of: player.errorMessage) { _, error in
            if error == nil {
                scheduleChromeHide()
            } else {
                chromeHideTask?.cancel()
                showChrome = true
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showChrome)
    }

    // MARK: - Lifecycle

    private func handleOnAppear() {
        if let s = session {
            // Consume any pending catchup BEFORE the session issues its
            // default live load. Otherwise mpv briefly opens the live
            // proxy URL, tears it down, then opens the catchup URL —
            // visible as a blank player + a redundant probe on the live
            // connection.
            let pendingStart = channel.flatMap { PendingCatchup.consume(channelID: $0.id) }
            let willCatchup = pendingStart != nil && supportsRewind
            s.start(skipInitialLoad: willCatchup)
            PlayerSessionRegistry.shared.setActive(s)
            if let start = pendingStart, willCatchup {
                loadCatchup(startingAt: start)
            }
        }
        if let p = playback {
            Task { @MainActor in
                await p.start(renderContextReady: { [weak player = p.player] in
                    player?.renderContextHandle != nil
                })
            }
        }
        scheduleChromeHide()
    }

    private func handleOnDisappear() {
        if let s = session {
            PlayerSessionRegistry.shared.unregister(s)
            for slot in s.slots {
                slot.player.pause()
                slot.unregisterFromRegistry()
            }
        }
        if let p = playback {
            p.stop()
        }
    }

    // MARK: - Top-left: info card

    @ViewBuilder
    private var infoStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isRecordingMode {
                recordingInfoCard
            } else {
                channelAndProgramCard
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var channelAndProgramCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let channel {
                HStack(spacing: 12) {
                    if let logo = channel.logoURL {
                        LazyImage(url: logo) { state in
                            if let image = state.image {
                                image.resizable().scaledToFit()
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(channel.name)
                            .font(.headline)
                            .foregroundStyle(.white)
                        if !channel.group.isEmpty {
                            Text(channel.group)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            }

            if let program = displayedProgram {
                Divider().overlay(.white.opacity(0.15))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(isCatchup ? "WATCHING" : "NOW")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.55))
                            .tracking(1.2)
                        Text(timeRangeText(program))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Text(program.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if !program.description.isEmpty {
                        Text(program.description)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(3)
                            .padding(.top, 2)
                    }
                }

                if isCatchup, let liveProgram, liveProgram.id != program.id {
                    Divider().overlay(.white.opacity(0.12))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("LIVE")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.red.opacity(0.9))
                                .tracking(1.2)
                            Text(timeRangeText(liveProgram))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        Text(liveProgram.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .chromeSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var recordingInfoCard: some View {
        if let rec = playback?.recording {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rec.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(rec.channelName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }

                Divider().overlay(.white.opacity(0.15))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(rec.status == .recording ? "RECORDING" : "RECORDED")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(
                                rec.status == .recording
                                    ? Color.red.opacity(0.9)
                                    : .white.opacity(0.55)
                            )
                            .tracking(1.2)
                        Text(recordingTimestamp(rec))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    if !rec.programDescription.isEmpty {
                        Text(rec.programDescription)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(3)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: 420, alignment: .leading)
            .chromeSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func recordingTimestamp(_ rec: Recording) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, h:mma"
        fmt.amSymbol = "am"
        fmt.pmSymbol = "pm"
        return fmt.string(from: rec.actualStart ?? rec.scheduledStart)
    }

    // MARK: - Top-right: chrome buttons

    @ViewBuilder
    private var chromeButtons: some View {
        HStack(spacing: 6) {
            Button {
                chromeState.mediaInfoDisplay = chromeState.mediaInfoDisplay.next
            } label: {
                Image(systemName: chromeState.mediaInfoDisplay.iconName)
                    .font(.callout)
                    .frame(width: 20, height: 20)
                    .frame(width: 30, height: 30)
                    .chromeSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous), fill: Color.black.opacity(0.42))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help(chromeState.mediaInfoDisplay.label)

            if isChannelMode {
                favoriteButton
                recordButton

                if isMulti {
                    if let s = session {
                        MultiViewLayoutMenu(session: s)
                    }
                }

                multiViewToggle

                if selectedPlayer != .none, let c = channel {
                    Button {
                        ExternalPlayer.launch(streamURL: c.streamURL, using: selectedPlayer)
                        dismiss()
                    } label: {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.callout)
                            .frame(width: 20, height: 20)
                            .frame(width: 30, height: 30)
                            .chromeSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous), fill: Color.black.opacity(0.42))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .help("Open in \(selectedPlayer.displayName)")
                }
            }

            pinButton
                .help(chromeState.isPinned ? "Unpin from top" : "Pin to top")
        }
    }

    @ViewBuilder
    private var multiViewToggle: some View {
        if let s = session {
            Button {
                showChannelPicker.toggle()
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .font(.callout)
                    .frame(width: 20, height: 20)
                    .frame(width: 30, height: 30)
                    .chromeSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous), fill: Color.black.opacity(0.42))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help(s.isMulti ? "Add channel" : "Open in multi-view")
            .disabled(!s.canAddMoreSlots())
            .popover(isPresented: $showChannelPicker, arrowEdge: .bottom) {
                if let vm = viewModel {
                    ChannelPickerPopover(
                        viewModel: vm,
                        session: s,
                        onDismiss: { showChannelPicker = false }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        if let c = channel {
            let isRecording = RecordingManager.shared.isLiveRecording(forChannel: c.streamURL)
            Button {
                toggleRecording()
            } label: {
                Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.callout)
                    .frame(width: 20, height: 20)
                    .frame(width: 30, height: 30)
                    .chromeSurface(
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                        fill: isRecording ? Color.red.opacity(0.4) : Color.black.opacity(0.42)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(isRecording ? Color.red : .white)
            .help(isRecording ? "Stop recording" : "Record this channel")
        }
    }

    private func toggleRecording() {
        guard let c = channel, let vm = viewModel else { return }
        let manager = RecordingManager.shared
        if manager.isLiveRecording(forChannel: c.streamURL) {
            if let entry = manager.recordings.first(where: { rec in
                rec.status == .recording && rec.channelID == c.id && rec.source == .live
            }) {
                manager.stopLiveRecording(id: entry.id)
            }
            return
        }
        guard let playlistID = vm.activePlaylistID else { return }
        let capturedChannel = c
        let capturedProgram = displayedProgram
        Task { @MainActor in
            _ = await manager.startLiveRecording(
                playlistID: playlistID,
                channel: capturedChannel,
                program: capturedProgram
            )
        }
    }

    @ViewBuilder
    private var favoriteButton: some View {
        if let c = channel, let vm = viewModel {
            let isFavorite = vm.isFavorite(c)
            Button {
                vm.toggleFavorite(c)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.callout)
                    .frame(width: 20, height: 20)
                    .frame(width: 30, height: 30)
                    .chromeSurface(
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                        fill: isFavorite ? Color.yellow.opacity(0.35) : Color.black.opacity(0.42)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(isFavorite ? Color.yellow : .white)
            .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
    }

    @ViewBuilder
    private var pinButton: some View {
        Button {
            chromeState.isPinned.toggle()
        } label: {
            Image(systemName: chromeState.isPinned ? "pin.fill" : "pin")
                .font(.callout)
                .frame(width: 20, height: 20)
                .frame(width: 30, height: 30)
                .chromeSurface(
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                    fill: chromeState.isPinned ? Color.accentColor.opacity(0.35) : Color.black.opacity(0.42)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    // MARK: - Bottom-left: controls bar

    @ViewBuilder
    private var controlsBar: some View {
        HStack(spacing: 14) {
            playPauseButton
            volumeButton

            // Source-specific middle section. Recording mode always gets
            // a full scrubber. Channel-rewind gets step controls. Plain
            // live gets the compact live-status group with optional
            // HLS-DVR seek bar.
            if isRecordingMode {
                Divider().frame(height: 18)
                recordingTransport
            } else if supportsRewind {
                Divider().frame(height: 18)
                catchupStepControls
            } else {
                Divider().frame(height: 18)
                liveStatusGroup
                if player.canReplay {
                    seekBar
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .chromeSurface(in: Capsule(), fill: Color.black.opacity(0.5))
    }

    @ViewBuilder
    private var liveStatusGroup: some View {
        liveButton
    }

    // MARK: - Catchup (channel-rewind) controls

    private var catchupCurrentOffset: Double {
        -max(0, Date().timeIntervalSince(effectiveWallClock))
    }

    private var catchupWindowSeconds: Double {
        Double(max(channel?.catchup?.days ?? 0, 1)) * 86400
    }

    private static let catchupSeekChunkSeconds: Double = 5 * 60

    @ViewBuilder
    private var catchupStepControls: some View {
        let offset = catchupCurrentOffset
        HStack(spacing: 10) {
            catchupMiniSeekBar
            catchupStatusPill(offset: offset)
        }
    }

    @ViewBuilder
    private var catchupMiniSeekBar: some View {
        let window = catchupWindowSeconds
        let displayedOffset = catchupScrubOffset ?? catchupCurrentOffset
        let segment = catchupSeekSegment(for: displayedOffset)
        let segmentMax = min(Double(segment) * Self.catchupSeekChunkSeconds, window)
        let displayOffset = displayedOffset.clamped(to: -segmentMax...0)

        HStack(spacing: 8) {
            Text(offsetLabel(-segmentMax))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 34, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { displayOffset },
                    set: { catchupScrubOffset = $0 }
                ),
                in: -segmentMax...0,
                onEditingChanged: { editing in
                    if !editing, let offset = catchupScrubOffset {
                        commitCatchupScrub(offset: offset)
                        catchupScrubOffset = nil
                    }
                }
            )
            .tint(.white)
            .controlSize(.mini)
            .frame(width: 90)
        }
        .help("Seek further back in 5 minute steps")
    }

    private func catchupSeekSegment(for offset: Double) -> Int {
        let behind = max(0, -offset)
        let chunk = Self.catchupSeekChunkSeconds
        return max(1, Int(ceil(behind / chunk)) + 1)
    }

    @ViewBuilder
    private func catchupStatusPill(offset: Double) -> some View {
        let atLive = isDisplayedLive
        Button {
            if !atLive {
                returnToLive()
            }
        } label: {
            HStack(spacing: 5) {
                if isSeekingCatchup {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                        .scaleEffect(0.7)
                        .frame(width: 10, height: 10)
                } else {
                    Circle()
                        .fill(atLive ? Color.red : Color.white.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
                Text(offsetLabel(offset))
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(atLive ? Color.red.opacity(0.95) : .white.opacity(0.75))
                    .monospacedDigit()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(atLive ? Color.red.opacity(0.16) : Color.white.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .stroke(atLive ? Color.red.opacity(0.35) : Color.white.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(atLive || isSeekingCatchup)
        .help(atLive ? "Live + buffer" : "Jump to live + buffer")
    }

    private func offsetLabel(_ offset: Double) -> String {
        let behind = max(0, -offset)
        if behind < 30 { return "LIVE" }
        if behind < 3600 { return "-\(Int(behind / 60))m" }
        let hours = Int(behind / 3600)
        let mins = Int(behind.truncatingRemainder(dividingBy: 3600) / 60)
        return mins == 0 ? "-\(hours)h" : "-\(hours)h\(mins)m"
    }

    // MARK: - Recording transport (scrubber + LIVE pill)

    @ViewBuilder
    private var recordingTransport: some View {
        if let rec = playback?.recording {
            let total = playback?.totalDuration ?? 0
            let inProgress = rec.status == .recording
            HStack(spacing: 10) {
                Text(formatHMS(player.timePos))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 52, alignment: .trailing)

                recordingScrubBar(total: total, inProgress: inProgress)
                    .frame(minWidth: 140, idealWidth: 260, maxWidth: 360)

                Text(formatHMS(total))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 52, alignment: .leading)

                recordingLivePill(inProgress: inProgress)
            }
        }
    }

    @ViewBuilder
    private func recordingScrubBar(total: Double, inProgress: Bool) -> some View {
        if total > 0 {
            // When live-latched on an in-progress recording, pin the
            // fill to 100% so the bar visually sits at the edge — the
            // actual playhead is a couple of seconds behind (mpv keeps
            // a small decode buffer) but the UX "LIVE" contract says
            // "this is as new as it gets".
            let raw = scrubPosition ?? min(player.timePos, total)
            let displayed = (isDisplayedLive && inProgress && scrubPosition == nil) ? total : raw
            ScrubBar(
                value: displayed,
                total: total,
                onScrub: { scrubPosition = $0 },
                onCommit: { target in
                    let clamped = min(target, total)
                    player.seek(to: clamped)
                    scrubPosition = nil
                    // User scrubbed; if they landed near the edge we keep
                    // the latch; otherwise drop it so the button becomes
                    // clickable again.
                    let behind = max(0, total - clamped)
                    liveLatched = inProgress && behind < 5
                }
            )
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func recordingLivePill(inProgress: Bool) -> some View {
        let canJump = inProgress && !isDisplayedLive
        let showRed = inProgress && isDisplayedLive
        Button {
            if canJump { jumpToRecordingLive() }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(showRed ? Color.red : Color.white.opacity(inProgress ? 0.35 : 0.18))
                    .frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(
                        showRed
                            ? Color.red.opacity(0.95)
                            : Color.white.opacity(inProgress ? 0.75 : 0.35)
                    )
                    .monospacedDigit()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(showRed ? Color.red.opacity(0.16) : Color.white.opacity(inProgress ? 0.08 : 0.04))
            )
            .overlay(
                Capsule()
                    .stroke(
                        showRed
                            ? Color.red.opacity(0.35)
                            : Color.white.opacity(inProgress ? 0.15 : 0.08),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!canJump)
        .help(inProgress
              ? (isDisplayedLive ? "At live edge" : "Jump to live")
              : "No live — this recording is finished")
    }

    private func jumpToRecordingLive() {
        guard let p = playback, p.isInProgress else { return }
        let total = p.totalDuration
        // Seek a hair back from the absolute end so mpv has a bit of
        // decoded frames to play immediately; the latch logic treats
        // anything under `liveUnlockThreshold` as "live".
        let target = max(0, total - 1)
        player.seek(to: target)
        scrubPosition = nil
        liveLatched = true
    }

    // MARK: - Channel play-controls

    @ViewBuilder
    private var playPauseButton: some View {
        Button {
            player.togglePause()
        } label: {
            ZStack {
                Color.clear.frame(width: 28, height: 28)
                if player.isBuffering || player.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .disabled(player.isBuffering || player.isLoading)
        .help(player.isBuffering || player.isLoading ? "Loading…" : (player.isPlaying ? "Pause" : "Play"))
    }

    @ViewBuilder
    private var volumeButton: some View {
        Button {
            showVolumePopover.toggle()
        } label: {
            Image(systemName: muteIconName)
                .font(.title3)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(player.isMuted ? "Unmute" : "Volume (scroll to adjust)")
        .onScrollWheel { delta in
            let next = (player.volume + delta).clamped(to: 0...100)
            player.setVolume(next)
            if player.isMuted && next > 0 { player.setMute(false) }
        }
        .popover(isPresented: $showVolumePopover, arrowEdge: .top) {
            volumePopoverContent
        }
    }

    @ViewBuilder
    private var volumePopoverContent: some View {
        HStack(spacing: 10) {
            Button {
                player.toggleMute()
            } label: {
                Image(systemName: muteIconName)
                    .font(.body)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)

            Slider(
                value: Binding(
                    get: { player.volume },
                    set: { player.setVolume($0) }
                ),
                in: 0...100
            )
            .frame(width: 140)

            Text("\(Int(player.volume))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
        .padding(12)
    }

    private var muteIconName: String {
        if player.isMuted || player.volume < 1 {
            return "speaker.slash.fill"
        }
        if player.volume < 33 {
            return "speaker.wave.1.fill"
        }
        if player.volume < 66 {
            return "speaker.wave.2.fill"
        }
        return "speaker.wave.3.fill"
    }

    @ViewBuilder
    private var liveButton: some View {
        let atLive = isDisplayedLive
        Button {
            if !atLive {
                player.seekToPreferredLivePosition()
                liveLatched = true
            }
        } label: {
            liveBadgeLabel(isHighlighted: atLive)
        }
        .buttonStyle(.plain)
        .disabled(atLive)
        .help(atLive ? "Live" : "Jump to live + buffer")
    }

    @ViewBuilder
    private func liveBadgeLabel(isHighlighted: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isHighlighted ? Color.red : Color.white.opacity(0.4))
                .frame(width: 6, height: 6)
            Text("LIVE")
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(isHighlighted ? .white : .white.opacity(0.65))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(isHighlighted ? Color.red.opacity(0.25) : Color.white.opacity(0.08))
        )
    }

    @ViewBuilder
    private var seekBar: some View {
        let maxPos = max(player.duration, 1)
        let currentPos = scrubPosition ?? player.timePos

        HStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { min(currentPos, maxPos) },
                    set: { scrubPosition = $0 }
                ),
                in: 0...maxPos,
                onEditingChanged: { editing in
                    if !editing, let pos = scrubPosition {
                        player.seek(to: pos)
                        scrubPosition = nil
                    }
                }
            )
            .tint(.white)
            .controlSize(.mini)
            .frame(width: 140)

            Text(liveOffsetLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var liveOffsetLabel: String {
        let behind = max(0, player.duration - (scrubPosition ?? player.timePos))
        if behind < 1 { return "live" }
        if behind < 60 { return String(format: "-%ds", Int(behind)) }
        let mins = Int(behind / 60)
        return "-\(mins)m"
    }

    // MARK: - Bottom-right: media info

    @ViewBuilder
    private var mediaInfoCard: some View {
        let info = player.mediaInfo
        let hasAny = info.width > 0 || info.fps > 0 || !info.videoCodec.isEmpty

        if hasAny {
            Group {
                switch chromeState.mediaInfoDisplay {
                case .expanded:
                    expandedMediaInfo(info)
                case .collapsed:
                    collapsedMediaInfo(info)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
            .animation(.easeInOut(duration: 0.18), value: chromeState.mediaInfoDisplay)
        }
    }

    @ViewBuilder
    private func expandedMediaInfo(_ info: MPVMediaInfo) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            if !info.resolutionLabel.isEmpty {
                Text(info.resolutionLabel)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            if !info.fpsLabel.isEmpty {
                Text(info.fpsLabel)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            if !info.videoCodec.isEmpty {
                Text(info.videoCodec.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            if !info.audioCodec.isEmpty {
                let audioBits = [info.audioCodec.uppercased(), info.audioChannels > 0 ? "\(info.audioChannels)ch" : ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                Text(audioBits)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }
            if !info.hwdec.isEmpty && info.hwdec != "no" {
                Text("HW: \(info.hwdec)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(12)
        .chromeSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func collapsedMediaInfo(_ info: MPVMediaInfo) -> some View {
        let bits = [
            info.resolutionLabel,
            info.fps > 0 ? "\(Int(info.fps.rounded(.up)))fps" : "",
        ].filter { !$0.isEmpty }

        if !bits.isEmpty {
            Text(bits.joined(separator: " · "))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .chromeSurface(in: Capsule())
        }
    }

    @ViewBuilder
    private func playbackErrorView(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Unable to play this stream", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(error)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
    }

    // MARK: - Chrome auto-hide

    private func revealChrome() {
        showChrome = true
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        guard player.errorMessage == nil else {
            showChrome = true
            return
        }
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            showChrome = false
        }
    }

    // MARK: - Rewind / catchup (channel mode)

    private func commitCatchupScrub(offset: Double) {
        if offset >= -30 {
            returnToLive()
            return
        }
        loadCatchup(startingAt: Date().addingTimeInterval(offset))
    }

    private func returnToLive() {
        guard isCatchup else { return }
        guard let slot = session?.focusedSlot else { return }
        beginSeeking()
        catchupStartDate = nil
        // Live playback now reconnects directly to the provider URL. Active
        // recordings keep running on their own separate stream.
        slot.loadLive()
        liveLatched = true
    }

    private func loadCatchup(startingAt start: Date) {
        guard let c = channel else { return }
        let maxBack = TimeInterval((c.catchup?.days ?? 0) * 86400)
        let earliest = Date().addingTimeInterval(-maxBack + 60)
        let clamped = max(start, earliest)

        guard let url = CatchupURLBuilder.url(
            for: c,
            start: clamped,
            duration: catchupClipDuration
        ) else {
            return
        }

        beginSeeking()
        catchupStartDate = clamped
        session?.focusedSlot.loadCatchup(url)
        liveLatched = false
    }

    private func beginSeeking() {
        isSeekingCatchup = true
        seekingTimeoutTask?.cancel()
        seekingTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            isSeekingCatchup = false
        }
    }

    private func endSeekingIfPlaying() {
        guard isSeekingCatchup else { return }
        guard player.timePos > 0.25 || !player.isBuffering else { return }
        isSeekingCatchup = false
        seekingTimeoutTask?.cancel()
    }

    // MARK: - Live latch reconciliation

    /// Drives the sticky `liveLatched` state from observed offset. Called
    /// whenever `timePos` or `duration` changes. Only flips:
    /// - unlatches when offset exceeds `liveUnlockThreshold`, so normal
    ///   cache jitter doesn't knock the pill off.
    /// - re-latches when offset shrinks back under `min(buffer, 3s)` —
    ///   covers the case where mpv catches up on its own after a
    ///   reconnect / cache-pause recovery.
    private func reconcileLiveLatch() {
        // Catchup mode is a deliberate drift — never treat it as live.
        if isCatchup {
            if liveLatched { liveLatched = false }
            return
        }
        guard let behind = secondsBehindLive else { return }
        if liveLatched {
            if behind > liveUnlockThreshold { liveLatched = false }
        } else {
            if behind < min(bufferSeconds, 3) { liveLatched = true }
        }
    }

    private func handleKeyboardCommand(_ command: PlayerKeyboardCommand, in window: NSWindow) {
        revealChrome()

        switch command {
        case .togglePlayPause:
            player.togglePause()
        case .seekBackward:
            seekByShortcut(-10)
        case .seekForward:
            seekByShortcut(10)
        case .toggleFullScreen:
            window.toggleFullScreen(nil)
        case .dismiss:
            if isRecordingMode { dismiss() }
        }
    }

    private func seekByShortcut(_ delta: Double) {
        if isRecordingMode {
            let total = playback?.totalDuration ?? player.duration
            let target = (player.timePos + delta).clamped(to: 0...max(total, 0))
            player.seek(to: target)
            return
        }
        if supportsRewind {
            let nextOffset = (catchupCurrentOffset + delta).clamped(to: -catchupWindowSeconds...0)
            commitCatchupScrub(offset: nextOffset)
            return
        }

        guard player.canReplay else { return }
        let maxPosition = max(player.duration, 0)
        let target = (player.timePos + delta).clamped(to: 0...maxPosition)
        if target >= maxPosition - 1 {
            player.seekToPreferredLivePosition()
            liveLatched = true
        } else {
            player.seek(to: target)
        }
    }

    // MARK: - Helpers

    private func timeRangeText(_ program: EPGProgram) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mma"
        fmt.amSymbol = "am"
        fmt.pmSymbol = "pm"
        return "\(fmt.string(from: program.start)) – \(fmt.string(from: program.end))"
    }
}

/// Format seconds as `H:MM:SS` or `M:SS`.
fileprivate func formatHMS(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

/// Thumbless scrub bar shared between recording playback and (future)
/// any source needing a full-width drag-to-seek control.
private struct ScrubBar: View {
    let value: Double
    let total: Double
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = total > 0 ? max(0, min(1, value / total)) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: isDragging ? 5 : 3)
                Capsule()
                    .fill(Color.white)
                    .frame(width: width * fraction, height: isDragging ? 5 : 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 16, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        isDragging = true
                        let x = max(0, min(width, g.location.x))
                        let target = total * (x / max(width, 1))
                        onScrub(target)
                    }
                    .onEnded { g in
                        let x = max(0, min(width, g.location.x))
                        let target = total * (x / max(width, 1))
                        onCommit(target)
                        isDragging = false
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isDragging)
        }
        .frame(height: 16)
    }
}

private struct ChannelPickerPopover: View {
    let viewModel: EPGViewModel
    let session: PlayerSession
    let onDismiss: () -> Void

    @State private var query: String = ""

    private var filteredChannels: [Channel] {
        let existing = Set(session.slots.map(\.channel.id))
        let pool = viewModel.channels.filter { !existing.contains($0.id) }
        if query.isEmpty { return pool }
        return pool.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search channels…", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredChannels.prefix(200), id: \.id) { channel in
                        Button {
                            session.addChannel(
                                channel,
                                currentProgram: viewModel.currentProgram(for: channel)
                            )
                            onDismiss()
                        } label: {
                            HStack(spacing: 10) {
                                ChannelLogoView(url: channel.logoURL, contentInset: 2)
                                    .frame(width: 28, height: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(channel.name)
                                        .font(.body)
                                        .lineLimit(1)
                                    if !channel.group.isEmpty {
                                        Text(channel.group)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }

                    if filteredChannels.isEmpty {
                        Text("No channels")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(24)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 320)
    }
}

struct ChromeSurfaceModifier<S: Shape>: ViewModifier {
    let shape: S
    var fill: Color

    func body(content: Content) -> some View {
        content
            .background(fill, in: shape)
            .overlay {
                shape
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
    }
}

extension View {
    func chromeSurface<S: Shape>(in shape: S, fill: Color = Color.black.opacity(0.52)) -> some View {
        modifier(ChromeSurfaceModifier(shape: shape, fill: fill))
    }
}

private struct ScrollWheelModifier: ViewModifier {
    let onScroll: (Double) -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    let raw = event.scrollingDeltaY
                    guard raw != 0 else { return event }
                    let step = event.hasPreciseScrollingDeltas ? raw * 0.5 : raw * 4
                    onScroll(Double(step))
                    return nil
                }
            } else if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }
    }
}

private extension View {
    func onScrollWheel(_ onScroll: @escaping (Double) -> Void) -> some View {
        modifier(ScrollWheelModifier(onScroll: onScroll))
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private var snapDelegateKey: UInt8 = 0

struct WindowAccessor: NSViewRepresentable {
    @Binding var showChrome: Bool
    var isPinned: Bool
    var videoSize: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.scheduleUpdate(
            view: view,
            showChrome: showChrome,
            isPinned: isPinned,
            videoSize: videoSize
        )
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.scheduleUpdate(
            view: nsView,
            showChrome: showChrome,
            isPinned: isPinned,
            videoSize: videoSize
        )
    }

    final class Coordinator {
        private struct PendingState {
            let showChrome: Bool
            let isPinned: Bool
            let videoSize: CGSize
        }

        private var pendingState: PendingState?
        private var updateScheduled = false

        func scheduleUpdate(view: NSView, showChrome: Bool, isPinned: Bool, videoSize: CGSize) {
            pendingState = PendingState(
                showChrome: showChrome,
                isPinned: isPinned,
                videoSize: videoSize
            )
            requestFlush(for: view)
        }

        private func requestFlush(for view: NSView) {
            guard !updateScheduled else { return }
            updateScheduled = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                self.updateScheduled = false
                guard let view else { return }
                self.applyPendingUpdate(to: view)
                if self.pendingState != nil {
                    self.requestFlush(for: view)
                }
            }
        }

        private func applyPendingUpdate(to view: NSView) {
            guard let state = pendingState else { return }
            pendingState = nil
            guard let window = view.window else {
                pendingState = state
                return
            }

            window.level = state.isPinned ? .floating : .normal
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear

            installSnapDelegate(on: window)
            applyAspectRatio(window: window, videoSize: state.videoSize)

            let hidden = !state.showChrome
            window.standardWindowButton(.closeButton)?.isHidden = hidden
            window.standardWindowButton(.miniaturizeButton)?.isHidden = hidden
            window.standardWindowButton(.zoomButton)?.isHidden = hidden
        }

        private func installSnapDelegate(on window: NSWindow) {
            if objc_getAssociatedObject(window, &snapDelegateKey) != nil { return }
            let snap = SnappingWindowDelegate()
            snap.attach(to: window)
            objc_setAssociatedObject(window, &snapDelegateKey, snap, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        private func applyAspectRatio(window: NSWindow, videoSize: CGSize) {
            guard videoSize.width > 0, videoSize.height > 0 else { return }
            let targetRatio = videoSize.width / videoSize.height
            let currentAspect = window.contentAspectRatio
            let currentRatio = currentAspect.height > 0 ? currentAspect.width / currentAspect.height : 0
            if abs(currentRatio - targetRatio) < 0.001 { return }

            window.contentAspectRatio = NSSize(width: videoSize.width, height: videoSize.height)

            let contentRect = window.contentRect(forFrameRect: window.frame)
            let newHeight = contentRect.width / targetRatio
            let newContent = NSRect(
                x: contentRect.minX,
                y: contentRect.maxY - newHeight,
                width: contentRect.width,
                height: newHeight
            )
            let newFrame = window.frameRect(forContentRect: newContent)
            if !newFrame.equalTo(window.frame) {
                window.setFrame(newFrame, display: true, animate: false)
            }
        }
    }
}

final class SnappingWindowDelegate: NSObject {
    private weak var window: NSWindow?
    private var mouseUpMonitor: Any?
    private var moveObserver: NSObjectProtocol?
    private var didMoveWhileDragging = false
    private let snapThreshold: CGFloat = 40

    func attach(to window: NSWindow) {
        self.window = window

        if moveObserver == nil {
            moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.didMoveWhileDragging = true
            }
        }

        if mouseUpMonitor == nil {
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
                DispatchQueue.main.async { self?.handleMouseUp() }
                return event
            }
        }
    }

    deinit {
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func handleMouseUp() {
        guard didMoveWhileDragging, let window else { return }
        didMoveWhileDragging = false
        snapToCorner(window: window)
    }

    private func snapToCorner(window: NSWindow) {
        guard let screen = window.screen else { return }
        let screenFrame = screen.visibleFrame
        var frame = window.frame

        let leftDistance = abs(frame.minX - screenFrame.minX)
        let rightDistance = abs(frame.maxX - screenFrame.maxX)
        let topDistance = abs(frame.maxY - screenFrame.maxY)
        let bottomDistance = abs(frame.minY - screenFrame.minY)

        let snapLeft = leftDistance < snapThreshold
        let snapRight = rightDistance < snapThreshold
        let snapTop = topDistance < snapThreshold
        let snapBottom = bottomDistance < snapThreshold

        guard (snapLeft || snapRight) && (snapTop || snapBottom) else { return }

        if snapLeft {
            frame.origin.x = screenFrame.minX
        } else if snapRight {
            frame.origin.x = screenFrame.maxX - frame.width
        }
        if snapTop {
            frame.origin.y = screenFrame.maxY - frame.height
        } else if snapBottom {
            frame.origin.y = screenFrame.minY
        }

        guard !frame.equalTo(window.frame) else { return }
        window.setFrame(frame, display: true, animate: true)
    }
}

private enum PlayerKeyboardCommand {
    case togglePlayPause
    case seekBackward
    case seekForward
    case toggleFullScreen
    case dismiss
}

private struct PlayerKeyboardMonitor: NSViewRepresentable {
    let onCommand: (PlayerKeyboardCommand, NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommand: onCommand)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCommand = onCommand
        context.coordinator.view = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        weak var view: NSView?
        var onCommand: (PlayerKeyboardCommand, NSWindow) -> Void
        private var monitor: Any?

        init(onCommand: @escaping (PlayerKeyboardCommand, NSWindow) -> Void) {
            self.onCommand = onCommand
        }

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let view,
                  let window = view.window,
                  event.window === window,
                  window.attachedSheet == nil,
                  !Self.isTyping(in: window),
                  let command = Self.command(for: event) else {
                return event
            }

            onCommand(command, window)
            return nil
        }

        private static func isTyping(in window: NSWindow) -> Bool {
            guard let textView = window.firstResponder as? NSTextView else {
                return false
            }
            return textView.isEditable || textView.isSelectable
        }

        private static func command(for event: NSEvent) -> PlayerKeyboardCommand? {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.isEmpty else { return nil }

            switch event.keyCode {
            case 49:
                return .togglePlayPause
            case 123:
                return .seekBackward
            case 124:
                return .seekForward
            case 53:
                return .dismiss
            default:
                break
            }

            if event.charactersIgnoringModifiers?.lowercased() == "f" {
                return .toggleFullScreen
            }

            return nil
        }
    }
}
