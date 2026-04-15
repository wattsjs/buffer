import AppKit
import SwiftUI
import NukeUI

enum MediaInfoDisplay: String, CaseIterable {
    case expanded
    case collapsed
    case hidden

    var next: MediaInfoDisplay {
        switch self {
        case .expanded: return .collapsed
        case .collapsed: return .hidden
        case .hidden: return .expanded
        }
    }

    var iconName: String {
        switch self {
        case .expanded: return "info.circle.fill"
        case .collapsed: return "info.circle"
        case .hidden: return "eye.slash"
        }
    }

    var label: String {
        switch self {
        case .expanded: return "Hide media details"
        case .collapsed: return "Expand media details"
        case .hidden: return "Show media details"
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

struct PlayerView: View {
    let viewModel: EPGViewModel

    @Environment(\.dismiss) private var dismiss
    @AppStorage(ExternalPlayer.selectedPlayerKey) private var selectedPlayer: ExternalPlayerKind = .none
    @State private var session: PlayerSession
    @State private var chromeState = PlayerChromeState()
    @State private var showChrome = true
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var showVolumePopover = false
    @State private var showChannelPicker = false
    @State private var scrubPosition: Double? = nil
    @State private var catchupScrubOffset: Double? = nil
    /// Wall-clock start time of the currently loaded catchup clip.
    /// `nil` means we're playing the live source.
    @State private var catchupStartDate: Date? = nil
    /// True between the moment a catchup load is kicked off and the moment
    /// playback of the new clip actually begins. Drives the inline spinner on
    /// the offset pill so users know the step button registered.
    @State private var isSeekingCatchup: Bool = false
    @State private var seekingTimeoutTask: Task<Void, Never>? = nil
    /// Length of the catchup clip currently loaded, in seconds. We request a
    /// window bracketing the user's target time so they can scrub a little.
    private let catchupClipDuration: TimeInterval = 2 * 60 * 60

    init(channel: Channel, currentProgram: EPGProgram?, viewModel: EPGViewModel) {
        self.viewModel = viewModel
        _session = State(initialValue: PlayerSession(initialChannel: channel, currentProgram: currentProgram))
    }

    // The focused slot is the source of truth for all chrome/controls. In
    // single mode this is simply the only slot; in multi mode it's whichever
    // cell the user has tapped most recently.
    private var player: MPVPlayer { session.focusedSlot.player }
    private var channel: Channel { session.focusedSlot.channel }
    private var currentProgram: EPGProgram? { session.focusedSlot.currentProgram }
    private var liveProgram: EPGProgram? { viewModel.currentProgram(for: channel) }

    private var isLive: Bool { catchupStartDate == nil }
    private var supportsRewind: Bool { !session.isMulti && channel.supportsRewind }

    /// Wall-clock time the user is currently watching. In catchup mode, this
    /// advances as the clip plays.
    private var effectiveWallClock: Date {
        if let start = catchupStartDate {
            return start.addingTimeInterval(player.timePos)
        }
        return Date()
    }

    private var isAtDisplayedLiveState: Bool {
        if supportsRewind || player.canReplay {
            return player.isAtPreferredLivePosition && !isSeekingCatchup
        }
        return catchupCurrentOffset >= -30 && !isSeekingCatchup
    }

    private var displayedProgram: EPGProgram? {
        if let program = viewModel.program(for: channel, at: effectiveWallClock) {
            return program
        }
        return currentProgram
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            // Single code path for both single and multi. `PlayerGridView`
            // drives ONE `MPVSessionRenderView` (one NSOpenGLView + one GL
            // context + N mpv render contexts). Using the same view for
            // both layouts avoids the single→multi transition, which used
            // to tear down an old NSOpenGLView while a new one was being
            // created — racing mpv dispatch queues and triggering
            // `mp_dispatch_queue_process: !queue->in_process` asserts.
            PlayerGridView(session: session)
                .padding(session.isMulti ? 8 : 0)
                .ignoresSafeArea()

            // Tap-to-toggle-pause layer. Only the bottom 2/3 receives taps;
            // the top 1/3 is a passthrough drag region for window movement.
            // Disabled in multi-view mode because per-cell taps handle focus.
            if !session.isMulti {
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
            if showChrome && !session.isMulti {
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
            if showChrome && !session.isMulti {
                controlsBar
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showChrome && !session.isMulti && chromeState.mediaInfoDisplay != .hidden {
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
        .onAppear {
            session.start()
            PlayerSessionRegistry.shared.setActive(session)
            // If the user launched this window from a past-program click in
            // the EPG, immediately replace the live feed with the catchup
            // clip for that program's start time.
            if let start = PendingCatchup.consume(channelID: channel.id),
               supportsRewind {
                loadCatchup(startingAt: start)
            }
            scheduleChromeHide()
        }
        .onChange(of: player.timePos) { _, _ in
            endSeekingIfPlaying()
        }
        .onChange(of: player.isBuffering) { _, _ in
            endSeekingIfPlaying()
        }
        .onDisappear {
            PlayerSessionRegistry.shared.unregister(session)
            for slot in session.slots {
                slot.player.pause()
            }
        }
        .background(WindowAccessor(
            showChrome: $showChrome,
            isPinned: chromeState.isPinned,
            videoSize: session.isMulti
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
                PlayerSessionRegistry.shared.setActive(session)
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

    // MARK: - Top-left: channel + EPG

    @ViewBuilder
    private var infoStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            channelAndProgramCard
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var channelAndProgramCard: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            if let program = displayedProgram {
                Divider().overlay(.white.opacity(0.15))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(isLive ? "NOW" : "WATCHING")
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

                if !isLive, let liveProgram, liveProgram.id != program.id {
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

    // MARK: - Top-right: chrome buttons (sized to sit inside the titlebar)

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

            favoriteButton

            if session.isMulti {
                MultiViewLayoutMenu(session: session)
            }

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
            .help(session.isMulti ? "Add channel" : "Open in multi-view")
            .disabled(!session.canAddMoreSlots())
            .popover(isPresented: $showChannelPicker, arrowEdge: .bottom) {
                ChannelPickerPopover(
                    viewModel: viewModel,
                    session: session,
                    onDismiss: { showChannelPicker = false }
                )
            }

            if selectedPlayer != .none {
                Button {
                    ExternalPlayer.launch(streamURL: channel.streamURL, using: selectedPlayer)
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

            pinButton
                .help(chromeState.isPinned ? "Unpin from top" : "Pin to top")
        }
    }

    @ViewBuilder
    private var favoriteButton: some View {
        let isFavorite = viewModel.isFavorite(channel)
        Button {
            viewModel.toggleFavorite(channel)
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

    @ViewBuilder
    private var pinButton: some View {
        let button = Button {
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

        button
    }

    // MARK: - Bottom-left: controls bar

    @ViewBuilder
    private var controlsBar: some View {
        HStack(spacing: 14) {
            playPauseButton
            volumeButton

            if supportsRewind {
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
        HStack(spacing: 8) {
            liveButton
            bufferIndicator
        }
    }

    /// Current playhead expressed as seconds relative to now (≤ 0).
    private var catchupCurrentOffset: Double {
        -max(0, Date().timeIntervalSince(effectiveWallClock))
    }

    /// Full catchup window expressed as a negative-going range.
    private var catchupWindowSeconds: Double {
        Double(max(channel.catchup?.days ?? 0, 1)) * 86400
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

    /// The "LIVE" / "-15m" pill next to the step buttons. Shows an inline
    /// spinner while a catchup load is in flight so step-button presses feel
    /// acknowledged even though the network fetch takes ~half a second.
    @ViewBuilder
    private func catchupStatusPill(offset: Double) -> some View {
        let atLive = isAtDisplayedLiveState
        Button {
            if !atLive {
                returnToLive()
            }
        } label: {
            HStack(spacing: 8) {
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

                bufferIndicator
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

    @ViewBuilder
    private var playPauseButton: some View {
        Button {
            player.togglePause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.title2)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(player.isPlaying ? "Pause" : "Play")
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
        let atLive = player.isAtPreferredLivePosition
        Button {
            if !atLive {
                player.seekToPreferredLivePosition()
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
        if behind < 1 {
            return "live"
        }
        if behind < 60 {
            return String(format: "-%ds", Int(behind))
        }
        let mins = Int(behind / 60)
        return "-\(mins)m"
    }

    @ViewBuilder
    private var bufferIndicator: some View {
        let target = max(player.configuredBufferSeconds, 1)
        let fraction = min(max(player.cacheSeconds / target, 0), 1)

        ZStack {
            Circle()
                .stroke(.white.opacity(0.18), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    player.isBuffering ? Color.yellow : Color.white.opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: fraction)
        }
        .frame(width: 10, height: 10)
        .help(bufferHelpText)
    }

    private var bufferHelpText: String {
        if player.isBuffering { return "Buffering…" }
        if player.cacheSeconds >= 1 {
            return String(format: "Cache: %.0fs", player.cacheSeconds)
        }
        return "Cache"
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
                case .hidden:
                    EmptyView()
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
            Label("Unable to play this channel", systemImage: "exclamationmark.triangle.fill")
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

    // MARK: - Rewind / catchup

    private func commitCatchupScrub(offset: Double) {
        if offset >= -30 {
            returnToLive()
            return
        }
        loadCatchup(startingAt: Date().addingTimeInterval(offset))
    }

    private func returnToLive() {
        guard !isLive else { return }
        beginSeeking()
        catchupStartDate = nil
        player.loadURL(channel.streamURL, autoplay: true)
    }

    private func loadCatchup(startingAt start: Date) {
        // Clamp start into the available catchup window so we never request
        // something the server will reject.
        let maxBack = TimeInterval((channel.catchup?.days ?? 0) * 86400)
        let earliest = Date().addingTimeInterval(-maxBack + 60)
        let clamped = max(start, earliest)

        guard let url = CatchupURLBuilder.url(
            for: channel,
            start: clamped,
            duration: catchupClipDuration
        ) else {
            return
        }

        beginSeeking()
        catchupStartDate = clamped
        player.loadURL(url, autoplay: true)
    }

    /// Kick off the inline spinner and arm a 6-second fallback so the UI
    /// never gets stuck if the clip fails to start or the server stalls.
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
        }
    }

    private func seekByShortcut(_ delta: Double) {
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

private struct ChromeSurfaceModifier<S: Shape>: ViewModifier {
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

private extension View {
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
                    // Trackpad reports precise fractional deltas; mouse wheel
                    // reports ±1 per click. Scale the mouse case up so one
                    // click = ~4% volume.
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

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            updateWindow(view: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateWindow(view: nsView)
    }

    private func updateWindow(view: NSView) {
        guard let window = view.window else { return }

        window.level = isPinned ? .floating : .normal
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        window.backgroundColor = .clear

        installSnapDelegate(on: window)
        applyAspectRatio(window: window)

        let hidden = !showChrome
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

    private func applyAspectRatio(window: NSWindow) {
        guard videoSize.width > 0, videoSize.height > 0 else { return }
        let targetRatio = videoSize.width / videoSize.height
        let currentAspect = window.contentAspectRatio
        let currentRatio = currentAspect.height > 0 ? currentAspect.width / currentAspect.height : 0
        if abs(currentRatio - targetRatio) < 0.001 { return }

        window.contentAspectRatio = NSSize(width: videoSize.width, height: videoSize.height)

        // Fit the current window to the new aspect, anchoring the top-left so
        // the titlebar and chrome don't jump under the cursor.
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
            window.setFrame(newFrame, display: true, animate: true)
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
                // Defer until AppKit finishes routing this mouseUp so the
                // window has settled at its drag-release frame before we snap.
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

        // Only snap when the window is near a corner (close to both an
        // X edge and a Y edge); edge proximity alone doesn't trigger.
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
