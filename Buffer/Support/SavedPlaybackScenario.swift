import AppKit
import Foundation
import Darwin

/// DEBUG-only, opt-in saved-library scenario. It does not export provider
/// URLs, change credentials, or use the synthetic source-bypass launch mode.
@MainActor
enum SavedPlaybackScenario {
    private(set) static var isCapturing = false
    static var isEnabled: Bool {
#if DEBUG
        CommandLine.arguments.contains("--saved-playback-scenario")
#else
        false
#endif
    }

#if DEBUG
    private static var task: Task<Void, Never>?
    private static var output: DiagnosticOutput?
    private static var didStart = false

    static func start(viewModel: EPGViewModel, open: @escaping @MainActor (PlaybackRequest) -> Void) {
        guard isEnabled, !didStart else { return }
        didStart = true
        // The observer emits the explicit conflict evidence. Never dispatch
        // a saved-source scenario while another recorder owns stdout.
        guard !CommandLine.arguments.contains("--observe-session"),
              let recorder = DiagnosticOutput.capturingStdout(prefix: "BUFFER_MATRIX_JSON ") else { return }
        output = recorder
        isCapturing = true
        let emit: ([String: Any]) -> Void = { fields in
            var fields = fields
            if fields["event"] as? String == "start" {
                fields["pid"] = ProcessInfo.processInfo.processIdentifier
                fields["buildMetadata"] = BufferBuildConfiguration.metadataDictionary
            }
            let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
            output?.append(data)
        }
        task = Task { @MainActor in
            defer { isCapturing = false }
            do {
                let arguments = CommandLine.arguments
                guard let index = arguments.firstIndex(of: "--saved-playback-scenario"),
                      arguments.indices.contains(index + 1), arguments[index + 1].utf8.count <= 65536,
                      let data = Data(base64Encoded: arguments[index + 1]) else { throw SavedScenarioFailure.invalidPlan }
                let plan = try SavedPlaybackScenarioPlan.decode(data)
                let backend = SavedScenarioAppBackend(viewModel: viewModel, open: open)
                await SavedPlaybackScenarioCoordinator.run(plan: plan, backend: backend, emit: emit)
            } catch {
                emit(["event": "start", "schema": 1, "cases": 0])
                emit(["event": "failure", "reason": SavedScenarioFailure.invalidPlan.rawValue])
                emit(["event": "end", "completedCases": 0, "restored": false, "teardownConfirmed": true])
            }
            output?.close()
            output = nil
        }
    }

    static func stop() { task?.cancel() }
#else
    static func start(viewModel: EPGViewModel, open: @escaping @MainActor (PlaybackRequest) -> Void) {}
    static func stop() {}
#endif
}

#if DEBUG
@MainActor
private final class SavedScenarioAppBackend: SavedPlaybackScenarioBackend {
    struct PreparedPlayback {
        let request: PlaybackRequest
        let programme: EPGProgram?
    }
    struct OriginalState {
        let sourceID: UUID
        let selection: SidebarSelection
        let revealChannelID: String?
        let searchText: String
    }
    private let viewModel: EPGViewModel
    private let openWindow: @MainActor (PlaybackRequest) -> Void
    private var lastOwnedSourceID: UUID?
    private var requestedChannelID: String?
    private var ownedSession: PlayerSession?
    private var ownedPlayer: MPVPlayer?
    private var openTime: ContinuousClock.Instant?
    private var requestedProgramme: EPGProgram?
    private var catchupRequested = false
    private var vodRequested = false
    private var requestedVODResumeSeconds: Double?
    private var probeSuspension: StreamProbeService.SuspensionLease?

    init(viewModel: EPGViewModel, open: @escaping @MainActor (PlaybackRequest) -> Void) {
        self.viewModel = viewModel
        self.openWindow = open
    }

    var hasUnrelatedPlayers: Bool {
        PlayerSessionRegistry.shared.allSessions.contains { $0 !== ownedSession }
    }

    func captureOriginalState() throws -> OriginalState {
        guard let sourceID = viewModel.activePlaylistID,
              viewModel.playlists.contains(where: { $0.id == sourceID }) else {
            throw SavedScenarioFailure.unsupportedOriginalState
        }
        lastOwnedSourceID = sourceID
        probeSuspension = StreamProbeService.shared.suspendProbing()
        return OriginalState(sourceID: sourceID, selection: viewModel.selection,
                             revealChannelID: viewModel.revealChannelID, searchText: viewModel.searchText)
    }

    func prepare(_ item: SavedPlaybackScenarioPlan.Case, timeoutSeconds: Int) async throws -> PreparedPlayback {
        guard !hasUnrelatedPlayers else { throw SavedScenarioFailure.unrelatedPlayers }
        guard viewModel.activePlaylistID == lastOwnedSourceID else { throw SavedScenarioFailure.sourceChanged }
        let matches = viewModel.playlists.filter { source in
            if let id = item.sourceID { return source.id == id }
            return source.name.caseInsensitiveCompare(item.sourceName ?? "") == .orderedSame
        }
        guard matches.count == 1 else {
            throw matches.isEmpty ? SavedScenarioFailure.sourceMissing : SavedScenarioFailure.sourceAmbiguous
        }
        let sourceID = matches[0].id
        lastOwnedSourceID = sourceID
        viewModel.setActivePlaylist(id: sourceID)
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        var requestedArchiveGuide = false
        var archiveProgrammeMissing = false
        repeat {
            try Task.checkCancellation()
            guard viewModel.activePlaylistID == sourceID else { throw SavedScenarioFailure.sourceChanged }
            guard !hasUnrelatedPlayers else { throw SavedScenarioFailure.unrelatedPlayers }
            // Metadata probes are real provider connections. Keep cached
            // badges/settings intact while letting any existing C call close
            // before this scenario opens its one player connection.
            if StreamProbeService.shared.isProbeRunning {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            if !viewModel.isLoadingSourceCredentials, viewModel.serverConfig != nil {
                if item.requestsVOD {
                    guard !viewModel.isVODDisabled else { throw SavedScenarioFailure.vodDisabled }
                    let catalog = viewModel.vodItems + viewModel.seriesEpisodes.values.flatMap { $0 }
                    var seen = Set<String>()
                    let matches = catalog.filter { candidate in
                        guard seen.insert(candidate.id).inserted else { return false }
                        if let id = item.vodID { return candidate.id == id }
                        return candidate.name.caseInsensitiveCompare(item.vodName ?? "") == .orderedSame
                    }
                    if matches.count > 1 { throw SavedScenarioFailure.vodAmbiguous }
                    if let candidate = matches.first {
                        let channel: Channel
                        do { channel = try await viewModel.resolveVODPlaybackChannel(candidate, sourceID: sourceID).channel }
                        catch { throw SavedScenarioFailure.vodResolutionUnavailable }
                        try Task.checkCancellation()
                        guard viewModel.activePlaylistID == sourceID else { throw SavedScenarioFailure.sourceChanged }
                        let request: PlaybackRequest = if let position = item.vodResumeSeconds {
                            .resume(channel, at: position)
                        } else {
                            .live(channel)
                        }
                        return PreparedPlayback(request: request, programme: nil)
                    }
                    if viewModel.hasLoadedOnce, !viewModel.isRefreshing { throw SavedScenarioFailure.vodMissing }
                    try await Task.sleep(for: .milliseconds(200))
                    continue
                }
                let channels = viewModel.channels.filter { channel in
                    if let id = item.channelID { return channel.id == id }
                    return channel.name.caseInsensitiveCompare(item.channelName ?? "") == .orderedSame
                }
                if let channel = channels.first, channels.count == 1 {
                    if !item.requestsCatchup { return PreparedPlayback(request: .live(channel), programme: nil) }
                    do {
                        let programme = try SavedScenarioArchiveSelection.programme(
                            channel: channel, programmes: viewModel.programsForChannel(channel),
                            offsetMinutes: item.catchupOffsetMinutes ?? 60, minimumDurationSeconds: 75)
                        guard let resolved = viewModel.program(for: channel, at: programme.start),
                              resolved.start == programme.start, resolved.end == programme.end else {
                            throw SavedScenarioFailure.catchupProgrammeUnavailable
                        }
                        guard CatchupURLBuilder.url(for: channel, start: programme.start, duration: programme.duration) != nil else {
                            throw SavedScenarioFailure.catchupURLUnavailable
                        }
                        return PreparedPlayback(request: .catchup(channel, from: programme.start), programme: programme)
                    } catch SavedScenarioFailure.catchupProgrammeUnavailable {
                        archiveProgrammeMissing = true
                        if !requestedArchiveGuide {
                            // Use the same bounded guide path as opening the
                            // channel in the catch-up UI; no direct provider API.
                            viewModel.syncCatchupGuideIfNeeded(for: [channel])
                            requestedArchiveGuide = true
                        }
                    }
                }
                if channels.count > 1 { throw SavedScenarioFailure.channelAmbiguous }
                // A cached catalog is usable; if no refresh is underway, do
                // not manufacture a provider refresh to hide a missing case.
                if channels.isEmpty, viewModel.hasLoadedOnce, !viewModel.isRefreshing { throw SavedScenarioFailure.channelMissing }
            }
            try await Task.sleep(for: .milliseconds(200))
        } while ContinuousClock.now < deadline
        throw archiveProgrammeMissing ? SavedScenarioFailure.catchupProgrammeUnavailable : SavedScenarioFailure.sourceTimedOut
    }

    func open(_ item: PreparedPlayback) async throws {
        guard PlayerSessionRegistry.shared.allSessions.isEmpty else { throw SavedScenarioFailure.unrelatedPlayers }
        let channel = item.request.channel
        requestedChannelID = channel.id
        requestedProgramme = item.programme
        catchupRequested = item.programme != nil
        vodRequested = channel.isOnDemand
        if case .resume(let seconds) = item.request.intent {
            requestedVODResumeSeconds = seconds
        } else {
            requestedVODResumeSeconds = nil
        }
        openTime = .now
        openWindow(item.request)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        repeat {
            try Task.checkCancellation()
            let sessions = PlayerSessionRegistry.shared.allSessions
            guard sessions.count <= 1 else { throw SavedScenarioFailure.unrelatedPlayers }
            if let session = sessions.first {
                guard session.slots.count == 1, session.slots[0].channel.id == channel.id else {
                    throw SavedScenarioFailure.unrelatedPlayers
                }
                ownedSession = session
                ownedPlayer = session.slots[0].player
                if let window = session.hostWindow {
                    NSApp.unhideWithoutActivation()
                    // This DEBUG-only opt-in capture owns the window and
                    // closes it after the case; no user preference is changed.
                    window.level = .floating
                    window.orderFrontRegardless()
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw SavedScenarioFailure.playerWindowTimedOut
    }

    func observe(caseIndex: Int, seconds: Int, emit: @escaping ([String: Any]) -> Void) async throws {
        guard let session = ownedSession, let player = ownedPlayer, let start = openTime else {
            throw SavedScenarioFailure.playerWindowTimedOut
        }
        var previous = start
        let lagProbe = MainQueueLagProbe()
        lagProbe.start()
        // Stress trial: the kind of short main-thread bursts EPG, sync and
        // Smart Channels work produce, so render pacing can be compared under
        // identical load.
        let mainLoad: Task<Void, Never>? = CommandLine.arguments.contains("--validate-main-thread-load")
            ? Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    let busyUntil = ContinuousClock.now.advanced(by: .milliseconds(25))
                    while ContinuousClock.now < busyUntil {}
                }
            } : nil
        defer { lagProbe.stop(); mainLoad?.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            // A one-second sample can miss the short burst of playback before
            // an initial underrun. Capture startup at 4 Hz, then return to the
            // ordinary diagnostic cadence; no provider or render work is added.
            let startup = AppLog.elapsedMilliseconds(since: start) < 15_000
            try await Task.sleep(for: startup ? .milliseconds(250) : .seconds(1))
            guard !hasUnrelatedPlayers else { throw SavedScenarioFailure.unrelatedPlayers }
            guard viewModel.activePlaylistID == lastOwnedSourceID else { throw SavedScenarioFailure.sourceChanged }
            guard PlayerSessionRegistry.shared.allSessions.contains(where: { $0 === session }),
                  session.slots.count == 1, session.slots[0].channel.id == requestedChannelID,
                  session.slots[0].player === player else { throw SavedScenarioFailure.playerChanged }
            player.refreshDiagnosticPlaybackClocks()
            let now = ContinuousClock.now
            let media = player.mediaInfo
            let stats = player.playbackStats
            let health = session.slots[0].playbackStreamHealth
            func number(_ value: Double?) -> Any { value.flatMap { $0.isFinite ? $0 : nil } as Any? ?? NSNull() }
            func code(_ value: String?) -> Any {
                guard let value, !value.isEmpty, value.utf8.count < 100,
                      !value.contains("://"),
                      value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-,./ ()")).contains($0) }) else { return NSNull() }
                return value
            }
            let lag = lagProbe.drain()
            emit(["event": "sample", "case": caseIndex, "elapsedMs": AppLog.elapsedMilliseconds(since: start, now: now),
                  "mainLagMaxMs": lag.maxMilliseconds, "mainLagOver20": lag.over20Milliseconds, "mainLagSamples": lag.samples,
                  "tickGapMs": AppLog.elapsedMilliseconds(since: previous, now: now),
                  "generation": player.telemetryLoadGeneration,
                  "windowVisible": session.hostWindow?.occlusionState.contains(.visible) ?? false,
                  "windowOnActiveSpace": session.hostWindow?.isOnActiveSpace ?? false,
                  "windowMiniaturized": session.hostWindow?.isMiniaturized ?? false,
                  "windowKey": session.hostWindow?.isKeyWindow ?? false,
                  "windowMain": session.hostWindow?.isMainWindow ?? false,
                  "windowLevel": session.hostWindow?.level.rawValue as Any? ?? NSNull(),
                  "applicationHidden": NSApp.isHidden,
                  "applicationActive": NSApp.isActive,
                  "time": number(player.timePos), "cache": number(player.cacheSeconds),
                  "rawTimePos": number(player.telemetryRawTimePos),
                  "rawTimePosAgeMs": number(player.telemetryRawTimePosAgeMilliseconds),
                  "videoPTS": number(player.telemetryVideoPTS),
                  "videoPTSAgeMs": number(player.telemetryVideoPTSAgeMilliseconds),
                  "rendered": player.hasRenderedCurrentLoad, "renderedFrameCount": player.telemetryRenderedFrameCount,
                  "secondsSinceLastRender": number(player.telemetrySecondsSinceLastRender),
                  "playbackRequested": player.telemetryPlaybackRequested, "playing": player.isPlaying,
                  "pause": player.telemetryPause as Any? ?? NSNull(),
                  "pausedForCache": player.telemetryPausedForCache as Any? ?? NSNull(),
                  "loading": player.isLoading, "buffering": player.isBuffering,
                  "bufferingMs": player.telemetryBufferingMilliseconds,
                  "frameDrops": stats.frameDrops, "decoderDrops": stats.decoderFrameDrops,
                  "mistimed": stats.mistimedFrames, "delayed": stats.delayedFrames,
                  "cacheFloorPauses": player.cacheFloorPauseCount, "startupMs": player.firstFrameElapsedMs as Any? ?? NSNull(),
                  "recoveryReloads": health.recoveryReloadCount, "playlistFails": health.playlistReloadFailureCount,
                  "http509": health.http509Count, "width": media.width, "height": media.height,
                  "fps": number(media.fps), "hwdec": code(media.hwdec), "videoCodec": code(media.videoCodec),
                  "audioCodec": code(media.audioCodec), "audioChannels": media.audioChannels,
                  "audioSampleRate": media.audioSampleRate,
                  "audioOutput": code(player.telemetryAudioOutput), "avSyncSeconds": number(player.telemetryAVSyncSeconds),
                  "muted": player.isMuted, "volume": number(player.volume),
                  "playbackMode": session.slots[0].isCatchup ? "catchup" : (session.slots[0].channel.isOnDemand ? "vod" : "live"),
                  "vodRequested": vodRequested, "isSeekable": player.isSeekable, "duration": number(player.duration),
                  "archiveTimestampRecoveryEnabled": player.usesArchiveTimestampRecovery,
                  "renderTimingNoBlock": MPVRenderTiming.validationNoBlock,
                  "startupReserveEnabled": player.usesStartupReserve,
                  "liveAnalysisEnabled": player.liveAnalysisEnabled,
                  "liveAnalysisRequestedSeconds": number(player.liveAnalysisRequestedSeconds),
                  "lavfAnalyzeDurationSeconds": number(player.telemetryLavfAnalyzeDurationSeconds),
                  "lavfProbeSize": player.telemetryLavfProbeSize as Any? ?? NSNull(),
                  "lavfProbeInfo": code(player.telemetryLavfProbeInfo),
                  "startupPhaseTimingsMs": player.telemetryStartupPhaseTimingsMilliseconds,
                  "exactCacheSeconds": number(player.telemetryExactCacheSeconds),
                  "cachePauseInitial": player.telemetryCachePauseInitial as Any? ?? NSNull(),
                  "cachePauseWaitSeconds": number(player.telemetryCachePauseWaitSeconds),
                  "startupTargetEnabled": player.startupTargetEnabled,
                  "nativeCacheOnlyEnabled": player.nativeCacheOnlyEnabled,
                  "startupHoldActive": player.startupHoldActive,
                  "startupHoldReleasedAtMs": player.startupHoldReleasedAtMs as Any? ?? NSNull(),
                  "startupHoldReleaseCacheSeconds": number(player.startupHoldReleaseCacheSeconds),
                  "vodResumeSeconds": number(requestedVODResumeSeconds),
                  "catchupRequested": catchupRequested,
                  "catchupProgrammeStartUnixSeconds": number(requestedProgramme?.start.timeIntervalSince1970),
                  "catchupProgrammeEndUnixSeconds": number(requestedProgramme?.end.timeIntervalSince1970),
                  "catchupLoadedStartUnixSeconds": number(session.slots[0].catchup?.loadedStart.timeIntervalSince1970),
                  "configuredBufferSeconds": stats.configuredBufferSeconds])
            previous = now
        }
    }

    func closeOwnedPlayer(timeoutSeconds: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        // An open failure may occur after the window was dispatched but before
        // its session registered. Only adopt the exact requested single slot.
        while ownedSession == nil, ContinuousClock.now < deadline {
            if let session = PlayerSessionRegistry.shared.allSessions.first(where: {
                $0.slots.count == 1 && $0.slots[0].channel.id == requestedChannelID
            }) {
                ownedSession = session
                ownedPlayer = session.slots[0].player
                break
            }
            await cleanupSleep()
        }
        guard let session = ownedSession, let player = ownedPlayer, let window = session.hostWindow else {
            throw SavedScenarioFailure.stopTimedOut
        }
        for slot in session.slots { slot.unregisterFromRegistry() }
        player.stop()
        window.performClose(nil)
        repeat {
            if !PlayerSessionRegistry.shared.allSessions.contains(where: { $0 === session }),
               player.telemetryBackendItemIdle {
                ownedSession = nil
                ownedPlayer = nil
                requestedChannelID = nil
                requestedProgramme = nil
                catchupRequested = false
                vodRequested = false
                requestedVODResumeSeconds = nil
                return
            }
            await cleanupSleep()
        } while ContinuousClock.now < deadline
        throw SavedScenarioFailure.stopTimedOut
    }

    func restore(_ state: OriginalState, timeoutSeconds: Int) async -> Bool {
        defer {
            if let lease = probeSuspension {
                StreamProbeService.shared.resumeProbing(lease)
                probeSuspension = nil
            }
        }
        guard ownedSession == nil, !hasUnrelatedPlayers, viewModel.activePlaylistID == lastOwnedSourceID,
              viewModel.playlists.contains(where: { $0.id == state.sourceID }) else { return false }
        viewModel.setActivePlaylist(id: state.sourceID)
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while ContinuousClock.now < deadline {
            guard viewModel.activePlaylistID == state.sourceID, !hasUnrelatedPlayers else { return false }
            if !viewModel.isLoadingSourceCredentials, viewModel.hasLoadedOnce {
                viewModel.selection = state.selection
                viewModel.revealChannelID = state.revealChannelID
                viewModel.searchText = state.searchText
                return true
            }
            await cleanupSleep()
        }
        return false
    }

    private func cleanupSleep() async {
        // Cleanup still runs after scenario cancellation without a busy loop.
        await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
    }
}

#endif
