import Foundation

/// Stream characteristics captured when a recording starts. Video fields are
/// zero / empty when the stream has
/// no video track (unlikely for IPTV), and audioCodec is nil when there's
/// no audio. `videoFPS` is zero when the container didn't carry frame
/// timing.
struct StreamInfo: Codable, Hashable, Sendable {
    var videoWidth: Int
    var videoHeight: Int
    var videoCodec: String
    var videoFPS: Double
    var audioCodec: String?
}

struct Recording: Identifiable, Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable {
        case scheduled
        /// Scheduler fired (or live record button was pressed) and we're
        /// opening the upstream stream — HLS playlist fetch + TLS handshake.
        /// No bytes on disk yet. Flips to `.recording` once the recorder
        /// starts.
        case startingUp
        case recording
        case completed
        case failed
        case cancelled
    }

    enum Source: String, Codable, Sendable {
        /// User-started recording while a channel is being watched.
        case live
        /// Unattended scheduled recording.
        case scheduled
    }

    let id: UUID
    let playlistID: UUID
    let channelID: String
    let channelName: String
    let programID: String?
    let title: String
    let programDescription: String
    let scheduledStart: Date
    let scheduledEnd: Date
    let streamURL: URL
    let source: Source
    let createdAt: Date

    var actualStart: Date?
    var actualEnd: Date?
    var fileURL: URL?
    var status: Status
    var errorMessage: String?
    /// Wall-clock time of the wake-from-sleep event we registered with
    /// `IOPMSchedulePowerEvent` for this recording. Stored so we can cancel
    /// the exact same event later (the API matches on date + id + type).
    var wakeAt: Date?

    /// Captured when the recorder starts. Nil until start succeeds; stays set
    /// once recorded so past-recordings
    /// retain resolution / codec / fps information.
    var streamInfo: StreamInfo?
    /// Live byte count updated ~1 Hz while the recording is active, frozen
    /// on finalize. Always the authoritative in-progress size; equals the
    /// file size until any post-close truncation.
    var bytesWritten: Int64 = 0
    /// File size measured from disk after finalize. Nil while recording.
    var fileSizeBytes: Int64?

    /// Duration of the captured media. For live MPEG-TS recordings, wall-clock
    /// equals media time, so we derive from actualStart/End.
    var mediaDuration: TimeInterval? {
        guard let start = actualStart else { return nil }
        let end = actualEnd ?? Date()
        return max(0, end.timeIntervalSince(start))
    }

    // Custom Codable so recordings persisted before streamInfo /
    // bytesWritten / fileSizeBytes existed still decode cleanly. We only
    // override the decoder; the encoder synthesis is fine.
    private enum CodingKeys: String, CodingKey {
        case id, playlistID, channelID, channelName, programID, title
        case programDescription, scheduledStart, scheduledEnd, streamURL
        case source, createdAt, actualStart, actualEnd, fileURL, status
        case errorMessage, wakeAt
        case streamInfo, bytesWritten, fileSizeBytes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        playlistID = try c.decode(UUID.self, forKey: .playlistID)
        channelID = try c.decode(String.self, forKey: .channelID)
        channelName = try c.decode(String.self, forKey: .channelName)
        programID = try c.decodeIfPresent(String.self, forKey: .programID)
        title = try c.decode(String.self, forKey: .title)
        programDescription = try c.decode(String.self, forKey: .programDescription)
        scheduledStart = try c.decode(Date.self, forKey: .scheduledStart)
        scheduledEnd = try c.decode(Date.self, forKey: .scheduledEnd)
        streamURL = try c.decode(URL.self, forKey: .streamURL)
        source = try c.decode(Source.self, forKey: .source)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        actualStart = try c.decodeIfPresent(Date.self, forKey: .actualStart)
        actualEnd = try c.decodeIfPresent(Date.self, forKey: .actualEnd)
        fileURL = try c.decodeIfPresent(URL.self, forKey: .fileURL)
        status = try c.decode(Status.self, forKey: .status)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        wakeAt = try c.decodeIfPresent(Date.self, forKey: .wakeAt)
        streamInfo = try c.decodeIfPresent(StreamInfo.self, forKey: .streamInfo)
        bytesWritten = try c.decodeIfPresent(Int64.self, forKey: .bytesWritten) ?? 0
        fileSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .fileSizeBytes)
    }

    init(
        id: UUID,
        playlistID: UUID,
        channelID: String,
        channelName: String,
        programID: String?,
        title: String,
        programDescription: String,
        scheduledStart: Date,
        scheduledEnd: Date,
        streamURL: URL,
        source: Source,
        createdAt: Date,
        actualStart: Date?,
        actualEnd: Date?,
        fileURL: URL?,
        status: Status,
        errorMessage: String?
    ) {
        self.id = id
        self.playlistID = playlistID
        self.channelID = channelID
        self.channelName = channelName
        self.programID = programID
        self.title = title
        self.programDescription = programDescription
        self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd
        self.streamURL = streamURL
        self.source = source
        self.createdAt = createdAt
        self.actualStart = actualStart
        self.actualEnd = actualEnd
        self.fileURL = fileURL
        self.status = status
        self.errorMessage = errorMessage
    }

    static func makeID(playlistID: UUID, channelID: String, programID: String?) -> UUID {
        // Deterministic UUID so re-scheduling the same program updates the
        // existing record instead of stacking duplicates.
        let key = "\(playlistID.uuidString)|\(channelID)|\(programID ?? "adhoc")"
        return UUID.fromStableString(key)
    }
}

extension UUID {
    /// Namespaced v5-ish UUID derived from an arbitrary string. We only need
    /// stability across launches, not RFC compliance.
    static func fromStableString(_ string: String) -> UUID {
        var hash: UInt64 = 1469598103934665603
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8((hash >> (8 * i)) & 0xFF)
        }
        var hash2: UInt64 = hash ^ 0x9E3779B97F4A7C15
        for byte in String(string.reversed()).utf8 {
            hash2 ^= UInt64(byte)
            hash2 &*= 1099511628211
        }
        for i in 0..<8 {
            bytes[8 + i] = UInt8((hash2 >> (8 * i)) & 0xFF)
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
