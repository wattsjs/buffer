#if os(macOS)
import AppKit
#endif
import Foundation

/// Debug-only real-renderer validation. Structured stdout is the evidence
/// channel: it cannot lose samples through unified-log privacy/filtering.
enum PlaybackValidation {
    struct Config {
        let url: URL
        let seconds: Int
        let bufferSeconds: Int?
        let audioOutput: String?
        let httpRetry: Bool
    }
    static let config: Config? = {
#if DEBUG && os(macOS)
        parse(arguments: CommandLine.arguments)
#else
        nil
#endif
    }()
    private static var started = false
    static var isEnabled: Bool { config != nil }

    static func applyLaunchOverrides() {
        guard let seconds = config?.bufferSeconds else { return }
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[BufferSetting.appStorageKey] = min(max(seconds, 1), 30)
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    static func request() -> PlaybackRequest? {
        guard let config else { return nil }
        return .live(Channel(id: "validation", name: "Validation", logoURL: nil,
                             group: "Validation", streamURL: config.url, epgChannelID: nil))
    }

    private static func emit(_ fields: [String: Any], to output: DiagnosticOutput) {
        // Invalid serialization must become explicit transport-loss evidence.
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        output.append(data)
    }

    @MainActor
    static func run(open request: PlaybackRequest) {
#if os(macOS)
        guard let config, !started else { return }
        started = true
        guard let output = DiagnosticOutput.capturingStdout(prefix: "BUFFER_PLAYBACK_JSON ") else {
            NSApplication.shared.terminate(nil)
            return
        }
        let start = ContinuousClock.now
        emit(["event": "start", "seconds": config.seconds, "bufferSeconds": BufferSetting.read(),
              "renderTimingNoBlock": MPVRenderTiming.validationNoBlock,
              "buildMetadata": BufferBuildConfiguration.metadataDictionary], to: output)
        Task { @MainActor in
            var raisedPlayerWindow = false
            while start.duration(to: .now) < .seconds(config.seconds) {
                try? await Task.sleep(for: .milliseconds(500))
                let elapsed = AppLog.elapsedMilliseconds(since: start)
                guard let session = PlayerSessionRegistry.shared.allSessions
                    .first(where: { $0.slots.contains(where: { $0.channel.id == request.channel.id }) }),
                      let slot = session.slots.first(where: { $0.channel.id == request.channel.id }) else {
                    emit(["event": "missing-player", "elapsedMs": elapsed], to: output)
                    continue
                }
                let player = slot.player
                player.refreshDiagnosticPlaybackClocks()
                let stats = player.playbackStats
                let health = slot.playbackStreamHealth
                // Controlled renderer qualification needs a presented window.
                // Core Animation may stop drawing a fully occluded layer.
                if !raisedPlayerWindow, let window = session.hostWindow {
                    NSApp.unhideWithoutActivation()
                    window.orderFrontRegardless()
                    raisedPlayerWindow = true
                }
                emit([
                    "event": "sample", "elapsedMs": elapsed,
                    "sampleWallTime": Date().timeIntervalSince1970,
                    "applicationActive": NSApp.isActive,
                    "renderTimingNoBlock": MPVRenderTiming.validationNoBlock,
                    "windowVisible": session.hostWindow?.occlusionState.contains(.visible) ?? false,
                    "demuxerStartTime": player.telemetryDemuxerStartTime as Any? ?? NSNull(),
                    "generation": player.telemetryLoadGeneration,
                    "time": player.timePos, "cache": player.cacheSeconds,
                    "rawTimePos": player.telemetryRawTimePos as Any? ?? NSNull(),
                    "rawTimePosAgeMs": player.telemetryRawTimePosAgeMilliseconds as Any? ?? NSNull(),
                    "videoPTS": player.telemetryVideoPTS as Any? ?? NSNull(),
                    "videoPTSAgeMs": player.telemetryVideoPTSAgeMilliseconds as Any? ?? NSNull(),
                    "rendered": player.hasRenderedCurrentLoad,
                    "renderedFrameCount": player.telemetryRenderedFrameCount,
                    "secondsSinceLastRender": player.telemetrySecondsSinceLastRender as Any? ?? NSNull(),
                    "playbackRequested": player.telemetryPlaybackRequested,
                    "startupReserveEnabled": player.usesStartupReserve,
                    "liveAnalysisEnabled": player.liveAnalysisEnabled,
                    "liveAnalysisRequestedSeconds": player.liveAnalysisRequestedSeconds as Any? ?? NSNull(),
                    "lavfAnalyzeDurationSeconds": player.telemetryLavfAnalyzeDurationSeconds as Any? ?? NSNull(),
                    "lavfProbeSize": player.telemetryLavfProbeSize as Any? ?? NSNull(),
                    "lavfProbeInfo": player.telemetryLavfProbeInfo as Any? ?? NSNull(),
                    "startupPhaseTimingsMs": player.telemetryStartupPhaseTimingsMilliseconds,
                    "exactCacheSeconds": player.telemetryExactCacheSeconds as Any? ?? NSNull(),
                    "cachePauseInitial": player.telemetryCachePauseInitial as Any? ?? NSNull(),
                    "cachePauseWaitSeconds": player.telemetryCachePauseWaitSeconds as Any? ?? NSNull(),
                    "startupTargetEnabled": player.startupTargetEnabled,
                    "nativeCacheOnlyEnabled": player.nativeCacheOnlyEnabled,
                    "startupHoldActive": player.startupHoldActive,
                    "startupHoldReleasedAtMs": player.startupHoldReleasedAtMs as Any? ?? NSNull(),
                    "startupHoldReleaseCacheSeconds": player.startupHoldReleaseCacheSeconds as Any? ?? NSNull(),
                    "pause": player.telemetryPause as Any? ?? NSNull(),
                    "pausedForCache": player.telemetryPausedForCache as Any? ?? NSNull(),
                    "loading": player.isLoading, "buffering": player.isBuffering,
                    "bufferingMs": player.telemetryBufferingMilliseconds,
                    "playing": player.isPlaying,
                    "frameDrops": stats.frameDrops, "decoderDrops": stats.decoderFrameDrops,
                    "mistimed": stats.mistimedFrames, "delayed": stats.delayedFrames,
                    "cacheFloorPauses": player.cacheFloorPauseCount,
                    "startupMs": player.firstFrameElapsedMs ?? -1,
                    "recoveryReloads": health.recoveryReloadCount,
                    "playlistFails": health.playlistReloadFailureCount,
                    "http509": health.http509Count,
                    "width": player.mediaInfo.width, "height": player.mediaInfo.height,
                    "hwdec": player.mediaInfo.hwdec,
                    "fps": player.mediaInfo.fps,
                    "videoCodec": player.mediaInfo.videoCodec,
                    "audioCodec": player.mediaInfo.audioCodec,
                    "audioChannels": player.mediaInfo.audioChannels,
                    "audioSampleRate": player.mediaInfo.audioSampleRate,
                    "audioOutput": player.telemetryAudioOutput ?? "unavailable",
                    "avSyncSeconds": player.telemetryAVSyncSeconds as Any? ?? NSNull()
                ], to: output)
            }
            emit(["event": "end", "elapsedMs": AppLog.elapsedMilliseconds(since: start)], to: output)
            output.close()
            // Preserve the asynchronous end record before process exit. The
            // helper drains nonblocking IO for at most one second; this wait
            // yields the MainActor and also has its own bounded deadline.
            let closeDeadline = ContinuousClock.now.advanced(by: .milliseconds(1200))
            while !output.statistics.closed, ContinuousClock.now < closeDeadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            NSApplication.shared.terminate(nil)
        }
#endif
    }

    private static func parse(arguments: [String]) -> Config? {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        guard let raw = value("--validate-url"), let url = URL(string: raw),
              ["http", "https"].contains(url.scheme) else { return nil }
        return Config(url: url, seconds: min(3600, max(5, Int(value("--validate-seconds") ?? "30") ?? 30)),
                      bufferSeconds: value("--validate-buffer").flatMap(Int.init),
                      audioOutput: value("--validate-ao"),
                      httpRetry: arguments.contains("--validate-http-retry"))
    }
}
