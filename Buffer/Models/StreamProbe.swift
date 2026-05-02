import Foundation

nonisolated enum StreamHealthEvent: String, Codable, Sendable {
    case http509
    case playlistReloadFailure
    case reconnect
    case recoveryReload
}

nonisolated struct StreamHealth: Codable, Hashable, Sendable {
    var http509Count: Int = 0
    var playlistReloadFailureCount: Int = 0
    var reconnectCount: Int = 0
    var recoveryReloadCount: Int = 0

    var lastHTTP509At: Date?
    var lastPlaylistReloadFailureAt: Date?
    var lastReconnectAt: Date?
    var lastRecoveryReloadAt: Date?
    var reconnectWindowStart: Date?
    var reconnectsInWindow: Int = 0

    static let unstableWindow: TimeInterval = 15 * 60

    var hasEvents: Bool {
        http509Count > 0 ||
        playlistReloadFailureCount > 0 ||
        reconnectCount > 0 ||
        recoveryReloadCount > 0
    }

    var isUnstable: Bool {
        let now = Date()
        if Self.isRecent(lastHTTP509At, now: now) ||
            Self.isRecent(lastPlaylistReloadFailureAt, now: now) ||
            Self.isRecent(lastRecoveryReloadAt, now: now) {
            return true
        }

        guard reconnectsInWindow >= 2,
              Self.isRecent(reconnectWindowStart, now: now) else {
            return false
        }
        return true
    }

    var statusLabel: String {
        isUnstable ? "unstable" : "ok"
    }

    mutating func record(_ event: StreamHealthEvent, at date: Date = Date()) {
        switch event {
        case .http509:
            http509Count += 1
            lastHTTP509At = date
        case .playlistReloadFailure:
            playlistReloadFailureCount += 1
            lastPlaylistReloadFailureAt = date
        case .reconnect:
            reconnectCount += 1
            lastReconnectAt = date
            if let windowStart = reconnectWindowStart,
               date.timeIntervalSince(windowStart) <= Self.unstableWindow {
                reconnectsInWindow += 1
            } else {
                reconnectWindowStart = date
                reconnectsInWindow = 1
            }
        case .recoveryReload:
            recoveryReloadCount += 1
            lastRecoveryReloadAt = date
        }
    }

    private static func isRecent(_ date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) <= unstableWindow
    }
}

/// Static metadata pulled from a channel's stream by libavformat. Attached to a
/// channel out-of-band (keyed by `Channel.id`) so the Channel cache schema
/// doesn't need to bump every time we adjust probe fields.
nonisolated struct StreamProbe: Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable {
        case ok
        case offline       // probe failed to open (network/auth/404)
        case timedOut
        case unsupported   // opened but no streams we recognise
        case error
    }

    var status: Status
    var probedAt: Date
    var probeSeconds: Double         // how long the probe took (rough latency signal)

    var width: Int
    var height: Int
    var fps: Double
    var videoCodec: String
    var audioCodec: String
    var audioChannels: Int
    var sampleRate: Int
    var bitRate: Int64               // bits/sec; 0 if unknown
    var liveLatencySeconds: Double?
    var hasVideo: Bool
    var hasAudio: Bool
    var errorMessage: String?
    var streamHealth: StreamHealth = StreamHealth()

    var resolutionLabel: String {
        guard width > 0, height > 0 else { return "" }
        if let shorthand = StreamProbe.shorthand(forHeight: height) { return shorthand }
        return "\(width)×\(height)"
    }

    var fpsLabel: String {
        fps > 0 ? "\(Int(fps.rounded()))p" : ""
    }

    var latencyLabel: String {
        let reportedLatency = liveLatencySeconds ?? (probeSeconds > 0 ? probeSeconds : nil)
        guard let reportedLatency,
              reportedLatency > 0,
              reportedLatency.isFinite else {
            return ""
        }
        return "\(Int((reportedLatency * 1000).rounded()))ms"
    }

    var codecLabel: String {
        videoCodec.uppercased()
    }

    var audioOnly: Bool { hasAudio && !hasVideo }

    var isUsable: Bool { status == .ok }

    /// Did the probe come back with the fields we'd actually display? An "ok"
    /// result with no resolution and no codec is functionally useless — the
    /// service should re-probe rather than honour the stale cache forever.
    /// Failure statuses are always considered complete (re-probing on the
    /// freshness window is what brings them back).
    var isComplete: Bool {
        switch status {
        case .ok:
            if audioOnly {
                return !audioCodec.isEmpty
            }
            return hasVideo && width > 0 && height > 0 && !videoCodec.isEmpty
        case .offline, .timedOut, .unsupported, .error:
            return true
        }
    }

    /// Probes older than this are considered stale and re-checked when the
    /// channel re-enters view. Live IPTV codecs/resolutions don't change very
    /// often, so a week-long cache is fine — the user can force a refresh by
    /// playing the channel (playback updates the record from mpv).
    static let freshness: TimeInterval = 7 * 24 * 60 * 60

    var isFresh: Bool {
        Date().timeIntervalSince(probedAt) < Self.freshness
    }

    private static func shorthand(forHeight h: Int) -> String? {
        switch h {
        case 2160...: return "4K"
        case 1440..<2160: return "1440p"
        case 1080..<1440: return "1080p"
        case 720..<1080: return "720p"
        case 576..<720: return "576p"
        case 480..<576: return "480p"
        default: return nil
        }
    }
}

extension StreamProbe {
    private enum CodingKeys: String, CodingKey {
        case status
        case probedAt
        case probeSeconds
        case width
        case height
        case fps
        case videoCodec
        case audioCodec
        case audioChannels
        case sampleRate
        case bitRate
        case liveLatencySeconds
        case hasVideo
        case hasAudio
        case errorMessage
        case streamHealth
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(Status.self, forKey: .status)
        probedAt = try c.decode(Date.self, forKey: .probedAt)
        probeSeconds = try c.decode(Double.self, forKey: .probeSeconds)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        fps = try c.decode(Double.self, forKey: .fps)
        videoCodec = try c.decode(String.self, forKey: .videoCodec)
        audioCodec = try c.decode(String.self, forKey: .audioCodec)
        audioChannels = try c.decode(Int.self, forKey: .audioChannels)
        sampleRate = try c.decode(Int.self, forKey: .sampleRate)
        bitRate = try c.decode(Int64.self, forKey: .bitRate)
        liveLatencySeconds = try c.decodeIfPresent(Double.self, forKey: .liveLatencySeconds)
        hasVideo = try c.decode(Bool.self, forKey: .hasVideo)
        hasAudio = try c.decode(Bool.self, forKey: .hasAudio)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        streamHealth = try c.decodeIfPresent(StreamHealth.self, forKey: .streamHealth) ?? StreamHealth()
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(probedAt, forKey: .probedAt)
        try c.encode(probeSeconds, forKey: .probeSeconds)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(fps, forKey: .fps)
        try c.encode(videoCodec, forKey: .videoCodec)
        try c.encode(audioCodec, forKey: .audioCodec)
        try c.encode(audioChannels, forKey: .audioChannels)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(bitRate, forKey: .bitRate)
        try c.encodeIfPresent(liveLatencySeconds, forKey: .liveLatencySeconds)
        try c.encode(hasVideo, forKey: .hasVideo)
        try c.encode(hasAudio, forKey: .hasAudio)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try c.encode(streamHealth, forKey: .streamHealth)
    }

    /// Map the C result struct into a Swift value. Strings are read up to the
    /// first NUL byte from the fixed-size char arrays.
    nonisolated init(cResult r: BufferProbeResult) {
        let videoCodec = Self.string(fromTuple: r.video_codec)
        let audioCodec = Self.string(fromTuple: r.audio_codec)
        let errorString = Self.string(fromTuple: r.error)

        let status: Status
        if r.status_code == 0 {
            if r.has_video == 0 && r.has_audio == 0 {
                status = .unsupported
            } else {
                status = .ok
            }
        } else if r.status_code == -1000 {
            status = .timedOut
        } else {
            status = .offline
        }

        self.status = status
        self.probedAt = Date()
        self.probeSeconds = r.probe_seconds
        self.width = Int(r.width)
        self.height = Int(r.height)
        self.fps = r.fps
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.audioChannels = Int(r.audio_channels)
        self.sampleRate = Int(r.sample_rate)
        self.bitRate = r.bit_rate
        self.liveLatencySeconds = nil
        self.hasVideo = r.has_video != 0
        self.hasAudio = r.has_audio != 0
        self.errorMessage = errorString.isEmpty ? nil : errorString
    }

    /// The C struct exposes fixed char arrays as Swift tuples (one element per
    /// byte). Walk them to the first NUL and decode as UTF-8.
    nonisolated private static func string<T>(fromTuple tuple: T) -> String {
        withUnsafePointer(to: tuple) { ptr in
            ptr.withMemoryRebound(
                to: CChar.self,
                capacity: MemoryLayout<T>.size
            ) { String(cString: $0) }
        }
    }
}
