import Foundation
#if os(macOS)
import AppKit
#endif
import Darwin
import OSLog

/// Opt-in observation of the ordinary app, including its saved library. It
/// records numeric state only: no source names, URLs, credentials or errors.
@MainActor
enum SessionObservation {
    static var audioOutputOverride: String? {
#if DEBUG && os(macOS)
        let arguments = CommandLine.arguments
        guard arguments.contains("--observe-session") || arguments.contains("--saved-playback-scenario"),
              let i = arguments.firstIndex(of: "--observe-session-ao"),
              arguments.indices.contains(i + 1),
              ["avfoundation", "coreaudio"].contains(arguments[i + 1]) else { return nil }
        return arguments[i + 1]
#else
        return nil
#endif
    }
#if DEBUG && os(macOS)
    private static var task: Task<Void, Never>?
    private static var output: DiagnosticOutput?
    private static var didStart = false
    private static var slotNumbers: [UUID: Int] = [:]
    private static var nextSlotNumber = 0
    private static var startTime: ContinuousClock.Instant?

    static func start(viewModel: EPGViewModel) {
        guard !didStart, CommandLine.arguments.contains("--observe-session") else { return }
        didStart = true
        let secondsIndex = CommandLine.arguments.firstIndex(of: "--observe-session-seconds")
        let rawSeconds = secondsIndex.flatMap { i in
            CommandLine.arguments.indices.contains(i + 1) ? Int(CommandLine.arguments[i + 1]) : nil
        } ?? 60
        let seconds = min(3600, max(5, rawSeconds))
        guard let recorder = DiagnosticOutput.capturingStdout(prefix: "BUFFER_SESSION_JSON ") else {
            AppLog.performance.error("Session observation transport unavailable")
            return
        }
        output = recorder
        let start = ContinuousClock.now
        startTime = start
        emit(["event": "start", "schema": 1, "pid": ProcessInfo.processInfo.processIdentifier,
              "seconds": seconds, "buildMetadata": BufferBuildConfiguration.metadataDictionary, "intervalMs": 1000])
        if CommandLine.arguments.contains("--saved-playback-scenario") {
            emit(["event": "failure", "reason": "conflicting-diagnostics", "outputHealthy": false])
            finish(reason: "conflicting-diagnostics")
            return
        }
        AppLog.performance.info("Session observation started seconds=\(seconds, privacy: .public)")
        task = Task { @MainActor in
            var previous = start
            while !Task.isCancelled, start.duration(to: .now) < .seconds(seconds) {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                guard !Task.isCancelled else { break }
                let now = ContinuousClock.now
                let sessions = PlayerSessionRegistry.shared.allSessions
                let slots = sessions.flatMap(\.slots)
                let samples: [[String: Any]] = slots.map { slot in
                    if slotNumbers[slot.id] == nil {
                        nextSlotNumber += 1
                        slotNumbers[slot.id] = nextSlotNumber
                    }
                    let player = slot.player
                    let stats = player.playbackStats
                    let media = player.mediaInfo
                    let health = slot.playbackStreamHealth
                    return [
                        "slot": slotNumbers[slot.id]!, "generation": player.telemetryLoadGeneration,
                        "windowVisible": sessions.first(where: { $0.slots.contains(where: { $0.id == slot.id }) })?
                            .hostWindow?.occlusionState.contains(.visible) ?? false,
                        "time": player.timePos, "cache": player.cacheSeconds,
                        "rendered": player.hasRenderedCurrentLoad,
                        "renderedFrameCount": player.telemetryRenderedFrameCount,
                        "secondsSinceLastRender": player.telemetrySecondsSinceLastRender as Any? ?? NSNull(),
                        "loading": player.isLoading, "buffering": player.isBuffering,
                        "bufferingMs": player.telemetryBufferingMilliseconds,
                        "playing": player.isPlaying, "width": media.width, "height": media.height,
                        "playbackRequested": player.telemetryPlaybackRequested,
                        "pause": player.telemetryPause as Any? ?? NSNull(),
                        "pausedForCache": player.telemetryPausedForCache as Any? ?? NSNull(),
                        "fps": media.fps, "hwdec": media.hwdec,
                        "audioOutput": player.telemetryAudioOutput as Any? ?? NSNull(),
                        "avSyncSeconds": player.telemetryAVSyncSeconds as Any? ?? NSNull(),
                        "frameDrops": stats.frameDrops, "decoderDrops": stats.decoderFrameDrops,
                        "mistimed": stats.mistimedFrames, "delayed": stats.delayedFrames,
                        "startupMs": player.firstFrameElapsedMs as Any? ?? NSNull(),
                        "cacheFloorPauses": player.cacheFloorPauseCount,
                        "recoveryReloads": health.recoveryReloadCount,
                        "playlistFails": health.playlistReloadFailureCount,
                        "http509": health.http509Count
                    ]
                }
                emit(["event": "sample", "elapsedMs": AppLog.elapsedMilliseconds(since: start, now: now),
                      "applicationActive": NSApp.isActive,
                      "tickGapMs": AppLog.elapsedMilliseconds(since: previous, now: now),
                      "sampleWallTime": Date().timeIntervalSince1970,
                      "channels": viewModel.channels.count, "guideKeys": viewModel.programs.count,
                      "sourceType": viewModel.serverConfig?.type.rawValue as Any? ?? NSNull(),
                      "guideVersion": viewModel.guideVersion,
                      "catalogVersion": viewModel.channelCatalogVersion,
                      "searchEntries": viewModel.searchEntries.count,
                      "movies": viewModel.vodItems.count, "series": viewModel.vodSeries.count,
                      "refreshing": viewModel.isRefreshing, "players": samples])
                previous = now
            }
            finish(reason: Task.isCancelled ? "cancelled" : "duration")
        }
    }

    static func stop() {
        task?.cancel()
        finish(reason: "app-terminated")
    }

    private static func emit(_ fields: [String: Any]) {
        // Failed encoding is itself an evidence failure, not a silent gap.
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        output?.append(data)
    }

    private static func finish(reason: String) {
        guard let output else { return }
        emit(["event": "end", "reason": reason,
              "elapsedMs": startTime.map { AppLog.elapsedMilliseconds(since: $0) } ?? 0])
        output.close()
        self.output = nil
        AppLog.performance.info("Session observation finished reason=\(reason, privacy: .public)")
    }
#else
    static func start(viewModel: EPGViewModel) {}
    static func stop() {}
#endif
}

