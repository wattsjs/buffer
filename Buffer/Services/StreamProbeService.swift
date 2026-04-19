import Foundation
import Observation

/// Settings backing the on-demand stream probe feature. Off by default — the
/// probe opens a real connection to each channel, which costs bandwidth and
/// can show up as a "viewer" against an Xtream session limit.
nonisolated enum StreamProbeSetting {
    static let enabledKey = "buffer_stream_probe_enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

/// On-demand stream metadata probing. Channels feed in by id+url, the service
/// schedules limited concurrent ffmpeg probes off the main thread and exposes
/// the most recent result via `probe(for:)`.
@MainActor
@Observable
final class StreamProbeService {
    static let shared = StreamProbeService()

    /// Bumped on every result write so SwiftUI views can depend on a single
    /// observable token without subscribing to the whole dictionary.
    private(set) var version: Int = 0

    /// Cache key currently in scope. Probes are scoped per-playlist so
    /// switching playlists doesn't show metadata from a different provider.
    private var activeCacheKey: String?

    private var probes: [String: StreamProbe] = [:]
    private var inFlight: Set<String> = []
    private var pending: [PendingProbe] = []

    /// Serialize probes. IPTV providers usually count each open() against a
    /// session/connection limit, and an in-flight probe on the same channel
    /// the user is about to play can race the player's own open
    /// and trip "Invalid data" / 503s on the upstream. One at a time keeps us
    /// out of trouble at the cost of slower badge fill on big channel lists.
    private let maxConcurrent = 1
    private var running = 0

    private struct PendingProbe {
        let id: String
        let url: URL
        let priority: TaskPriority
    }

    /// Switch the probe scope to a new cache key. Pending probes are dropped
    /// (their results would no longer be relevant) and the on-disk cache for
    /// the new key is loaded.
    func setActiveCacheKey(_ key: String?) {
        guard activeCacheKey != key else { return }
        activeCacheKey = key
        pending.removeAll()
        probes.removeAll()
        version &+= 1
        guard let key else { return }

        Task.detached(priority: .utility) { [weak self] in
            let cached = DataCache.loadProbes(key: key)
            await MainActor.run { [weak self] in
                guard let self, self.activeCacheKey == key, let cached else { return }
                self.probes = cached.probes
                self.version &+= 1
            }
        }
    }

    /// Returns the most recent probe for a channel, if any.
    func probe(for channelID: String) -> StreamProbe? {
        probes[channelID]
    }

    /// Request a probe for the given channel. Cheap to call repeatedly: skips
    /// when we already have a result inside the freshness window (good or bad
    /// — a recent failure shouldn't trigger another open against a flaky
    /// provider just because the user scrolled past). No-ops when disabled.
    func requestProbe(for channel: Channel, priority: TaskPriority = .utility) {
        guard StreamProbeSetting.isEnabled else { return }
        let id = channel.id
        if inFlight.contains(id) { return }
        // Re-probe stale results AND fresh-but-incomplete ones (e.g. a probe
        // that opened the stream but couldn't decode width/height/codec — the
        // freshness window shouldn't trap us with permanently empty badges).
        if let existing = probes[id], existing.isFresh, existing.isComplete {
            return
        }
        inFlight.insert(id)
        pending.append(PendingProbe(id: id, url: channel.streamURL, priority: priority))
        drainQueue()
    }

    /// Update the cached probe with fresh data observed during actual playback
    /// (mpv has already opened the stream — its numbers are authoritative and
    /// arrive without spending an extra session slot on probing). Caller
    /// passes whatever subset of fields it has; we merge into the existing
    /// record so half-loaded mpv state doesn't overwrite a complete probe.
    func recordPlaybackInfo(
        channelID: String,
        width: Int,
        height: Int,
        fps: Double,
        videoCodec: String,
        audioCodec: String,
        audioChannels: Int,
        liveLatencySeconds: Double?
    ) {
        let hasVideo = width > 0 && height > 0
        let hasAudio = !audioCodec.isEmpty || audioChannels > 0
        if !hasVideo && !hasAudio { return }

        var probe = probes[channelID] ?? StreamProbe(
            status: .ok,
            probedAt: Date(),
            probeSeconds: 0,
            width: 0, height: 0, fps: 0,
            videoCodec: "", audioCodec: "",
            audioChannels: 0, sampleRate: 0,
            bitRate: 0, hasVideo: false, hasAudio: false,
            errorMessage: nil
        )

        probe.status = .ok
        probe.probedAt = Date()
        probe.errorMessage = nil
        if hasVideo {
            probe.width = width
            probe.height = height
            probe.hasVideo = true
        }
        if fps > 0 { probe.fps = fps }
        if !videoCodec.isEmpty { probe.videoCodec = videoCodec }
        if !audioCodec.isEmpty { probe.audioCodec = audioCodec; probe.hasAudio = true }
        if audioChannels > 0 { probe.audioChannels = audioChannels; probe.hasAudio = true }
        if let latency = liveLatencySeconds, latency.isFinite {
            probe.liveLatencySeconds = max(0, latency)
        }

        probes[channelID] = probe
        version &+= 1
        if let key = activeCacheKey {
            persist(for: key)
        }
    }

    /// Convenience for batch warming (e.g. all visible favorites). Same dedupe
    /// rules as the single-channel call.
    func requestProbes(for channels: some Sequence<Channel>) {
        for channel in channels {
            requestProbe(for: channel, priority: .utility)
        }
    }

    /// Forget the result for one channel — used when the user manually asks
    /// for a re-probe (Cmd-click "Refresh" in the UI later).
    func invalidate(channelID: String) {
        probes.removeValue(forKey: channelID)
        version &+= 1
    }

    /// Forget every result and persist the empty cache.
    func clearAll() {
        probes.removeAll()
        version &+= 1
        if let key = activeCacheKey {
            persist(for: key)
        }
    }

    private func drainQueue() {
        while running < maxConcurrent, let next = pending.first {
            pending.removeFirst()
            running += 1
            launch(next)
        }
    }

    private func launch(_ pending: PendingProbe) {
        let id = pending.id
        let urlString = pending.url.absoluteString
        let key = activeCacheKey

        Task.detached(priority: pending.priority) { [weak self] in
            let result = StreamProbeService.runBlockingProbe(urlString: urlString)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.running -= 1
                self.inFlight.remove(id)
                // Drop the result if the user switched playlists mid-flight.
                if self.activeCacheKey == key {
                    self.probes[id] = result
                    self.version &+= 1
                    if let key {
                        self.persist(for: key)
                    }
                }
                self.drainQueue()
            }
        }
    }

    /// Runs on a background detached Task. Calls into the C bridge.
    nonisolated private static func runBlockingProbe(urlString: String) -> StreamProbe {
        let cResult = urlString.withCString { ptr in
            // 30s budget — slow IPTV origins can take 10-15s just to start
            // returning bytes after TLS, and avformat_find_stream_info needs
            // a couple of seconds on top to settle on codec params.
            buffer_probe_stream(ptr, 30)
        }
        return StreamProbe(cResult: cResult)
    }

    /// Coalesce save calls so a burst of probe completions doesn't hammer the
    /// disk. We simply mark dirty and write on the next runloop tick.
    private var saveScheduled = false

    private func persist(for key: String) {
        guard !saveScheduled else { return }
        saveScheduled = true
        let snapshot = probes
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run {
                self?.saveScheduled = false
            }
            Task.detached(priority: .utility) {
                DataCache.saveProbes(snapshot, key: key)
            }
        }
    }
}
