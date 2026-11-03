import AVKit
import SwiftUI

/// Full-screen player for iOS, iPadOS and tvOS. One `PlayerSession` with a
/// single slot, driven the same way as the Mac `PlayerView`: playback
/// ownership is published before loading, Smart recovery is configured per
/// slot, and archive clips continue through `CatchupClipContinuationPolicy`.
struct TouchPlayerView: View {
    let request: PlaybackRequest
    let viewModel: EPGViewModel
    let onClose: () -> Void

    @State private var session: PlayerSession
    @State private var showChrome = true
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var externalRequestTask: Task<Void, Never>?
    @State private var consecutiveInstantCatchupEOFs = 0
    @State private var showChannels = false

    init(request: PlaybackRequest, viewModel: EPGViewModel, onClose: @escaping () -> Void) {
        self.request = request
        self.viewModel = viewModel
        self.onClose = onClose
        _session = State(initialValue: PlayerSession(
            initialChannel: request.channel,
            currentProgram: viewModel.currentProgram(for: request.channel)))
    }

    private var slot: PlayerSlot { session.focusedSlot }
    private var player: MPVPlayer { slot.player }
    private var channel: Channel { slot.channel }
    private var isCatchup: Bool { slot.catchup != nil }
    private var supportsRewind: Bool {
        channel.sourceOwnership?.logicalChannelID == nil && channel.supportsRewind
    }
    private var displayedProgram: EPGProgram? {
        viewModel.program(for: channel, at: slot.catchupWallClock ?? Date()) ?? slot.currentProgram
    }
    private var errorMessage: String? { slot.recoveryErrorMessage ?? player.errorMessage }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVLayerView(player: player)
                .id(ObjectIdentifier(player))
                .ignoresSafeArea()
#if os(iOS)
                .onTapGesture { toggleChrome() }
#endif
            if player.isBuffering || player.isLoading, errorMessage == nil {
                ProgressView().controlSize(.large).tint(.white)
            }
            if let errorMessage {
                ContentUnavailableView("Playback problem", systemImage: "exclamationmark.triangle",
                                       description: Text(errorMessage))
                    .foregroundStyle(.white)
            }
            if showChrome { chrome.transition(.opacity) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player")
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: showChrome)
#if os(iOS)
        .statusBarHidden(!showChrome)
        .persistentSystemOverlays(.hidden)
#endif
#if os(tvOS)
        .focusable(!showChrome)
        .onPlayPauseCommand { player.togglePause(); revealChrome() }
        .onExitCommand {
            if showChrome { showChrome = false } else { onClose() }
        }
        .onMoveCommand { _ in revealChrome() }
#endif
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
        .onChange(of: session.externalRequest) { _, next in
            guard let next else { return }
            session.externalRequest = nil
            apply(next)
        }
        .sheet(isPresented: $showChannels) {
            NavigationStack {
                List(viewModel.filteredChannels) { candidate in
                    Button {
                        showChannels = false
                        guard let resolved = viewModel.resolvePlaybackRequest(.live(candidate)) else { return }
                        apply(resolved)
                        viewModel.addRecent(resolved.channel)
                    } label: {
                        ChannelListRow(channel: candidate, program: viewModel.currentProgram(for: candidate))
                    }
                }
                .navigationTitle("Channels")
            }
        }
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name).font(.title3.weight(.semibold))
                    if let program = displayedProgram {
                        Text(program.title).font(.headline).foregroundStyle(.secondary)
                        Text(EPGClockText.shared.compactRange(start: program.start.timeIntervalSinceReferenceDate,
                                                              end: program.end.timeIntervalSinceReferenceDate))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
#if os(iOS)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.headline).padding(10)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Close player")
#endif
            }
            .padding()
            .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
            Spacer()
            HStack(spacing: 20) {
                Button { player.togglePause(); revealChrome() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 28)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                if isCatchup {
                    Button { slot.returnToLive(); revealChrome() } label: { Label("Live", systemImage: "dot.radiowaves.left.and.right") }
                } else if supportsRewind, let program = displayedProgram, program.start < Date() {
                    Button { startCatchup(at: program.start); revealChrome() } label: {
                        Label("Start Over", systemImage: "backward.end.fill")
                    }
                }
                Spacer()
                Text(isCatchup ? "REPLAY" : (channel.isOnDemand ? "" : "LIVE"))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(isCatchup ? Color.orange : Color.red))
                    .opacity(channel.isOnDemand ? 0 : 1)
                Button { showChannels = true } label: { Label("Channels", systemImage: "list.bullet") }
#if os(iOS)
                AirPlayButton()
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("AirPlay")
#endif
            }
            .labelStyle(.titleAndIcon)
            .padding()
            .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        }
        .foregroundStyle(.white)
    }

    // MARK: - Lifecycle

    private func handleAppear() {
        slot.onCatchupClipEnded = { handleCatchupClipEnded() }
        PlayerSessionRegistry.shared.setActive(session)
        viewModel.configureSmartRecovery(for: slot)
        switch request.intent {
        case .live:
            session.start()
        case .resume(let position):
            if position > 0 { slot.seekOnNextOnDemandLoad(to: position) }
            session.start()
        case .catchup(let start):
            let willCatchup = supportsRewind
            session.start(skipInitialLoad: true)
            if willCatchup { startCatchup(at: start) } else { slot.loadInitialLive() }
        }
        UIApplication.shared.isIdleTimerDisabled = true
        scheduleChromeHide()
    }

    private func handleDisappear() {
        externalRequestTask?.cancel()
        chromeHideTask?.cancel()
        PlayerSessionRegistry.shared.unregister(session)
        for slot in session.slots {
            slot.onCatchupClipEnded = nil
            slot.player.pause()
            slot.unregisterFromRegistry()
        }
        session.recycleAllPlayers()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func apply(_ request: PlaybackRequest) {
        externalRequestTask?.cancel()
        externalRequestTask = Task { @MainActor in
            let changed = slot.channel.sourceChannelIdentity != request.channel.sourceChannelIdentity ||
                slot.channel.streamURL != request.channel.streamURL
            guard await slot.replacePlaybackChannel(request.channel), !Task.isCancelled else { return }
            viewModel.configureSmartRecovery(for: slot)
            switch request.intent {
            case .live:
                if changed { slot.loadInitialLive() } else if isCatchup { slot.returnToLive() }
            case .catchup(let start):
                if supportsRewind { startCatchup(at: start) }
            case .resume(let position):
                slot.resumeOnDemand(to: position, reload: changed)
            }
            revealChrome()
        }
    }

    // MARK: - Catch-up

    private func startCatchup(at start: Date, resetFailureCount: Bool = true) {
        guard supportsRewind else { return }
        if resetFailureCount { consecutiveInstantCatchupEOFs = 0 }
        if let program = viewModel.program(for: channel, at: start) {
            slot.playCatchup(from: start, timeline: DateInterval(start: program.start, end: program.end), programID: program.id)
        } else {
            slot.playCatchup(from: start, timeline: DateInterval(start: start, duration: 2 * 3600), programID: nil)
        }
    }

    private func handleCatchupClipEnded() {
        guard let catchup = slot.catchup else { return }
        let decision = CatchupClipContinuationPolicy.decision(
            previousImmediateEOFs: consecutiveInstantCatchupEOFs,
            positionSeconds: slot.player.timePos, timelineEnd: catchup.timeline.end)
        consecutiveInstantCatchupEOFs = decision.consecutiveImmediateEOFs
        switch decision.action {
        case .replayUnavailable: slot.stopUnavailableReplay()
        case .returnToLive: slot.returnToLive()
        case .continueArchive:
            if let next = viewModel.program(for: channel, at: catchup.timeline.end.addingTimeInterval(60)),
               channel.canReplay(next) {
                slot.playCatchup(from: max(next.start, catchup.timeline.end),
                                 timeline: DateInterval(start: next.start, end: next.end), programID: next.id)
            } else {
                startCatchup(at: catchup.timeline.end, resetFailureCount: false)
            }
        }
    }

    // MARK: - Chrome

    private func toggleChrome() {
        if showChrome { showChrome = false } else { revealChrome() }
    }

    private func revealChrome() {
        showChrome = true
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, errorMessage == nil, !showChannels else { return }
            showChrome = false
        }
    }
}

#if os(iOS)
/// System AirPlay route picker (audio routes and video-capable receivers).
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .white
        picker.activeTintColor = .systemTeal
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
