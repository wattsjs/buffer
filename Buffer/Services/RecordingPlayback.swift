import Foundation
import Observation

/// Playback controller for a recorded file. Owns the mpv instance for the
/// window and encapsulates the decision of what URL to hand to mpv:
/// - completed recordings → open the `.ts` file directly (fast local path).
/// - in-progress recordings → open the tail-follow HTTP endpoint on
///   `StreamProxy`, which keeps the stream alive as bytes accumulate.
///
/// Lives next to `PlayerSession` as the recording equivalent. The view
/// layer treats either as interchangeable source of an `MPVPlayer` +
/// metadata.
@MainActor
@Observable
final class RecordingPlayback {
    private let recordingID: UUID
    private let original: Recording
    let player: MPVPlayer

    @ObservationIgnored private var tailToken: UUID?
    @ObservationIgnored private var started = false

    init(recording: Recording) {
        self.recordingID = recording.id
        self.original = recording
        self.player = MPVPlayer()
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

        let id = recordingID
        let inProgress = isInProgress
        let playURL: URL
        if inProgress {
            // Hop the tail registration onto a detached task. It's cheap,
            // but `StreamProxy.registerRecordingTail` synchronously calls
            // `start()` on the listener and takes the proxy's state lock.
            // Under load (e.g. a live broadcaster on the same channel is
            // also holding that lock mid-attach), we don't want the main
            // thread waiting on any of that. Capture the two singletons
            // on main before jumping threads — they're both `@MainActor`
            // static properties, so the detached closure can't access
            // them directly without actor-isolation warnings.
            let proxy = StreamProxy.shared
            let manager = RecordingManager.shared
            let reg = await Task.detached(priority: .userInitiated) {
                proxy.registerRecordingTail(
                    fileURL: fileURL,
                    isActive: { manager.isStillRecording(id: id) }
                )
            }.value
            tailToken = reg.token
            playURL = reg.url
        } else {
            playURL = fileURL
        }

        player.loadURL(playURL, autoplay: true, fastProbe: true)
    }

    func stop() {
        player.pause()
        if let token = tailToken {
            StreamProxy.shared.unregisterRecordingTail(token: token)
            tailToken = nil
        }
    }
}
