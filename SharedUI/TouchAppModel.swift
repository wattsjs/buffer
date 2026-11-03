import AVFoundation
import Observation
import OSLog
import SwiftUI

/// One full-screen player presentation (iOS / tvOS have no player windows).
struct PlayerPresentation: Identifiable {
    let id = UUID()
    let request: PlaybackRequest
}

/// App-level state shared by the iOS/iPadOS and tvOS roots: the guide view
/// model, Sports, search, and the single player presentation. The Mac keeps
/// the equivalent wiring in `ContentView`.
@MainActor
@Observable
final class TouchAppModel {
    let viewModel = EPGViewModel()
    let sports = SportsViewModel()
    let search = ProgramSearchController()
    var player: PlayerPresentation?
    var isEditingSources = false
    var isEditingCountryFilter = false

    @ObservationIgnored private let sportsContext = SportsMatchingContext()
    @ObservationIgnored private var didLaunch = false

    static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            AppLog.playback.error("Audio session setup failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Playback

    func openChannel(_ channel: Channel) { open(.live(channel)) }

    func openCatchup(_ channel: Channel, program: EPGProgram) { open(.catchup(channel, from: program.start)) }

    func open(_ request: PlaybackRequest) {
        guard let request = viewModel.resolvePlaybackRequest(request) else { return }
        AppLog.playback.info("Opening channel in Buffer name=\(request.channel.name, privacy: .public)")
        if player != nil, PlayerSessionRegistry.shared.deliver(request) {
            // The open player took the request in place.
        } else {
            PlayerSession.noteOpen(channel: request.channel)
            player = PlayerPresentation(request: request)
        }
        Task { @MainActor in
            await Task.yield()
            viewModel.addRecent(request.channel)
            updateSportsPreferences()
        }
    }

    // MARK: - Launch

    func launch() async {
        guard !didLaunch else { return }
        didLaunch = true
#if os(iOS)
        Task { await NotificationManager.shared.bootstrap() }
#endif
        await viewModel.hydrate()
        AppLog.sync.info("Launch hydration finished channels=\(self.viewModel.channels.count, privacy: .public)")
        viewModel.syncOnLaunchIfNeeded()
        viewModel.startSyncScheduler()
        viewModel.restoreSmartChannelsIfPreferred()
        updateSearchIndex()
        Task { @MainActor in
            await Task.yield()
            PlayerSession.prewarmPlayerPool()
        }
        if !UserDefaults.standard.bool(forKey: "hideSport") {
            try? await Task.sleep(for: .milliseconds(500))
            updateSportsContext()
            sports.refresh()
            sports.startAutoRefresh()
        }
    }

    /// A reminder notification was tapped: play its channel when it resolves.
    func openReminder(_ reminder: ProgramReminder) {
        Task { @MainActor in
            if let channel = await viewModel.resolveReminder(reminder) {
                openChannel(channel)
            } else {
                AppFeedbackCenter.shared.show(.reminderChannelMissing(
                    playlistName: viewModel.activePlaylist?.name ?? "", channelName: reminder.channelName))
            }
        }
    }

    // MARK: - Derived indexes

    func updateSportsContext() { sportsContext.updateContext(viewModel: viewModel, sports: sports) }

    func updateSportsPreferences() { sportsContext.updatePreferences(viewModel: viewModel, sports: sports) }

    func updateSearchIndex() {
        let disableVOD = viewModel.isVODDisabled
        let vodItems: [VODItem] = disableVOD ? [] : viewModel.movieItems + viewModel.seriesEpisodes.values.flatMap { $0 }
        search.updateIndex(
            programs: viewModel.searchEntries,
            programStore: viewModel.programSearchStore,
            channels: viewModel.displayedChannels,
            vodItems: vodItems,
            vodSeries: disableVOD ? [] : viewModel.vodSeries
        )
    }
}

/// The change observers `ContentView` installs on the Mac, shared by the
/// iOS and tvOS roots so Sports matching and search stay current.
struct TouchAppObservers: ViewModifier {
    let model: TouchAppModel

    func body(content: Content) -> some View {
        let viewModel = model.viewModel
        content
            .environment(\.activePlaylistID, viewModel.displayedPlaylistID)
            .task { await model.launch() }
            .onChange(of: StreamProbeService.shared.version) { _, _ in model.updateSportsPreferences() }
            .onChange(of: viewModel.smartSports.revision) { _, _ in
                if viewModel.isSmartSportsActive { model.updateSportsContext() }
            }
            .onChange(of: viewModel.smartSports.isLoading) { _, _ in
                if viewModel.isSmartSportsActive { model.updateSportsContext() }
            }
            .onChange(of: viewModel.channelCatalogVersion) { _, _ in model.updateSportsContext() }
            .onChange(of: viewModel.guideVersion) { _, _ in model.updateSportsContext() }
            .onChange(of: viewModel.isGuideEnriching) { _, _ in model.updateSportsContext() }
            .onChange(of: viewModel.favoriteChannelIDs) { _, _ in model.updateSportsPreferences() }
            .onChange(of: viewModel.preferenceScoresVersion) { _, _ in model.updateSportsPreferences() }
            .onChange(of: viewModel.hiddenGroupNames) { _, _ in model.updateSportsContext() }
            .onChange(of: viewModel.searchIndexVersion) { _, _ in
                model.updateSearchIndex()
                model.updateSportsContext()
            }
#if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: NotificationManager.openStreamNotification)) { note in
                if let reminder = note.object as? ProgramReminder { model.openReminder(reminder) }
            }
#endif
            .onChange(of: viewModel.smartSports.errorMessage) { _, message in
                if viewModel.isSmartSportsActive, let message { viewModel.showSmartActionUnavailable(message) }
            }
    }
}
