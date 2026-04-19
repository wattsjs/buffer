import Foundation
import Observation

/// Playback controller for a recorded file. Owns the mpv instance for the
/// window and encapsulates the decision of what URL to hand to mpv:
/// - completed recordings → open the `.ts` file directly (fast local path).
/// - in-progress recordings → also open the `.ts` file directly.
///
/// Lives next to `PlayerSession` as the recording equivalent. The view
/// layer treats either as interchangeable source of an `MPVPlayer` +
/// metadata.
@MainActor
@Observable
final class RecordingPlayback {
    private enum ReloadTuning {
        static let retryDelayNanoseconds: UInt64 = 750_000_000
        static let resumeBackoffSeconds: Double = 1
    }

    private let recordingID: UUID
    private let original: Recording
    let player: MPVPlayer

    @ObservationIgnored private var started = false
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(recording: Recording) {
        self.recordingID = recording.id
        self.original = recording
        self.player = MPVPlayer()
        self.player.onPlaybackEnded = { [weak self] reason in
            self?.handlePlaybackEnded(reason)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            reloadTask?.cancel()
            player.onPlaybackEnded = nil
            player.stop()
        }
    }

    /// Live snapshot from the shared `RecordingManager` store, so observers
    /// see size / duration / status changes automatically (the manager
    /// updates `bytesWritten` at 1 Hz and flips `status` when a recording
    /// finishes).
    var recording: Recording {
        RecordingManager.shared.recordings.first { $0.id == recordingID } ?? original
    }

    var isInProgress: Bool { recording.status == .recording }

    /// Total playable duration. For in-progress recordings we take the max
    /// of `player.duration` (what mpv has probed) and the manager's
    /// wall-clock `mediaDuration` (which ticks every second) — the latter
    /// is authoritative while the file is still growing, the former once
    /// mpv has seen enough bytes to index the full file.
    var totalDuration: Double {
        max(player.duration, recording.mediaDuration ?? 0)
    }

    /// Kick off playback. `renderContextReady` lets the view signal when
    /// the `CAOpenGLLayer` has bound mpv's render context — for local
    /// files mpv's VO gives up if we `loadfile` before the layer has
    /// called `copyCGLContext`, so we wait a few frames (<50 ms typical)
    /// before issuing the load.
    func start(renderContextReady: @MainActor @escaping () -> Bool) async {
        guard !started else { return }
        started = true
        guard let fileURL = original.fileURL else { return }

        // Cap at 2 s so the UI still responds if OpenGL binding is broken
        // for some reason — mpv will then report an error instead of
        // silently never rendering.
        let deadline = Date().addingTimeInterval(2)
        while !renderContextReady(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        player.loadURL(fileURL, autoplay: true, fastProbe: true)
    }

    func stop() {
        reloadTask?.cancel()
        reloadTask = nil
        player.onPlaybackEnded = nil
        player.stop()
    }

    private func handlePlaybackEnded(_ reason: MPVEndReason) {
        switch reason {
        case .eof:
            guard isInProgress else { return }
            scheduleReload()
        case .error(_, let message):
            if isInProgress {
                scheduleReload()
            } else {
                player.setReconnectingErrorMessage("Playback failed: \(message)")
            }
        case .stopped:
            break
        }
    }

    private func scheduleReload() {
        guard let fileURL = recording.fileURL, RecordingManager.shared.isStillRecording(id: recordingID) else { return }
        reloadTask?.cancel()

        let resumeTime = max(player.timePos - ReloadTuning.resumeBackoffSeconds, 0)
        player.setReconnectingErrorMessage("Recording still growing — retrying…")
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: ReloadTuning.retryDelayNanoseconds)
            guard !Task.isCancelled else { return }
            guard RecordingManager.shared.isStillRecording(id: self.recordingID) else { return }

            self.player.loadURL(fileURL, autoplay: true, fastProbe: true)
            if resumeTime > 0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self.player.seek(to: resumeTime)
            }
        }
    }
}
