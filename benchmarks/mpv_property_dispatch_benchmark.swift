// -O benchmark + equivalence test for the mpv event/property dispatch path.
//
// `Legacy` is a verbatim copy of the former MPVPlayer dispatch (PendingChanges
// optionals, PropID switch, keypath setState, dictionary request table, a
// heap wakeup buffer per drain). `Flat` mirrors the current MPVPlayer apply
// step and uses the real `MPVPropertyBatch` / `MPVPropertyRequestRing` from
// Buffer/Support. Both drive @Observable state classes so registrar costs
// are included. Side effects outside dispatch (cache floor, startup target,
// display assertion) are identical cheap stubs in both.
//
// Run: scripts/test-mpv-property-dispatch.sh
import Darwin
import Foundation
import Observation

// MARK: - Allocation counter (libmalloc's malloc_logger hook)

typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
nonisolated(unsafe) var allocationCount = 0
nonisolated(unsafe) var countingEnabled = false
@main enum MPVPropertyDispatchBenchmark {
    static func main() { MainActor.assumeIsolated { runDispatchBenchmark() } }
}

nonisolated(unsafe) let mallocLoggerSlot: UnsafeMutablePointer<MallocLogger?> = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else {
        fatalError("malloc_logger unavailable")
    }
    return symbol.assumingMemoryBound(to: MallocLogger?.self)
}()
func countAllocations(_ body: () -> Void) -> Int {
    allocationCount = 0
    mallocLoggerSlot.pointee = { type, _, _, _, _, _ in
        // MALLOC_LOG_TYPE_ALLOCATE = 2 (malloc, calloc, realloc's new block).
        if countingEnabled, type & 2 != 0 { allocationCount &+= 1 }
    }
    countingEnabled = true
    body()
    countingEnabled = false
    mallocLoggerSlot.pointee = nil
    return allocationCount
}

// MARK: - libmpv stand-ins (ABI-shaped)

struct mpv_format: Equatable { var rawValue: UInt32 }
let MPV_FORMAT_STRING = mpv_format(rawValue: 1)
let MPV_FORMAT_FLAG = mpv_format(rawValue: 3)
let MPV_FORMAT_INT64 = mpv_format(rawValue: 4)
let MPV_FORMAT_DOUBLE = mpv_format(rawValue: 5)
struct mpv_event_property {
    var name: UnsafePointer<CChar>?
    var format: mpv_format
    var data: UnsafeMutableRawPointer?
}
struct SyntheticEvent {
    var userdata: UInt64
    var property: mpv_event_property
}

struct MPVMediaInfo: Equatable, Sendable {
    var width: Int = 0
    var height: Int = 0
    var fps: Double = 0
    var videoCodec: String = ""
    var audioCodec: String = ""
    var audioChannels: Int = 0
    var audioSampleRate: Int = 0
    var hwdec: String = ""
    var liveLatencySeconds: Double?
}

struct MPVPlaybackStats: Equatable, Sendable {
    var containerFps: Double = 0
    var estimatedFps: Double = 0
    var videoBitrateBps: Int64 = 0
    var audioBitrateBps: Int64 = 0
    var frameDrops: Int64 = 0
    var decoderFrameDrops: Int64 = 0
    var delayedFrames: Int64 = 0
    var mistimedFrames: Int64 = 0
    var configuredBufferSeconds: Int = 5
    var cachePauseFloorSeconds: Double = 0
    var cachePauseResumeSeconds: Double = 0
    var renderProfile: String = "focused"
    var autoPausedForCacheFloor: Bool = false
}

enum Tuning {
    static let stateEpsilon = 0.05
    static let timePosEpsilon = 0.25
    static let cacheEpsilon = 0.5
    static let liveLatencyEpsilon = 0.5
}

/// Published-state snapshot used to prove both paths are equivalent.
struct StateSnapshot: Equatable {
    var mediaInfo: MPVMediaInfo
    var stats: MPVPlaybackStats
    var isPlaying, isBuffering, isLoading, isMuted, isSeekable: Bool
    var cacheSeconds, volume, timePos, duration, containerFps, estimatedFps: Double
    var telemetryPause, telemetryPausedForCache, telemetryCachePauseInitial: Bool?
    var telemetryAudioOutput, telemetryLavfProbeInfo: String?
    var telemetryAVSync, telemetryDemuxerStart, telemetryCachePauseWait, telemetryLavfAnalyze: Double?
    var telemetryLavfProbeSize: Int64?
    var rawTime, videoPTS, exactCache: Double?
    var mediaInfoCallbacks, bufferingTransitions, startupEvaluations, cacheFloorChecks: Int
    var acceptedReplies: Int
}

// MARK: - Legacy dispatch (verbatim former MPVPlayer code)

@MainActor @Observable
final class LegacyPlayer {
    private(set) var mediaInfo = MPVMediaInfo()
    private(set) var playbackStats = MPVPlaybackStats()
    private(set) var isPlaying = false
    private(set) var cacheSeconds: Double = 0
    @ObservationIgnored private var preciseCacheSample = PlaybackCacheSample()
    var telemetryExactCacheSeconds: Double? {
        preciseCacheSample.currentSeconds(generation: loadGeneration, at: ProcessInfo.processInfo.systemUptime)
    }
    private(set) var telemetryCachePauseInitial: Bool?
    private(set) var telemetryCachePauseWaitSeconds: Double?
    private(set) var telemetryLavfAnalyzeDurationSeconds: Double?
    private(set) var telemetryLavfProbeSize: Int64?
    private(set) var telemetryLavfProbeInfo: String?
    @ObservationIgnored private var rawTimeSample = PlaybackClockSample()
    @ObservationIgnored private var videoPTSSample = PlaybackClockSample()
    private(set) var isBuffering = false
    private(set) var isLoading = true
    private(set) var volume: Double = 100
    private(set) var isMuted = false
    private(set) var timePos: Double = 0
    private(set) var telemetryAudioOutput: String?
    private(set) var telemetryDemuxerStartTime: Double?
    private(set) var telemetryAVSyncSeconds: Double?
    private(set) var telemetryPause: Bool?
    private(set) var telemetryPausedForCache: Bool?
    private(set) var duration: Double = 0
    private(set) var isSeekable: Bool = false
    private var containerFps: Double = 0
    private var estimatedFps: Double = 0
    private var bufferSeconds: Int = 5
    @ObservationIgnored var onMediaInfoChanged: ((MPVMediaInfo) -> Void)?
    @ObservationIgnored private var propertyRequestSerial: UInt64 = 0
    @ObservationIgnored private var propertyRequests: [UInt64: (generation: Int, item: MPVItemLifecycle.Identity?, property: PropID)] = [:]
    @ObservationIgnored let loadGeneration = 1
    @ObservationIgnored var activeIdentity: MPVItemLifecycle.Identity? = .init(generation: 1, playlistEntryID: 7)
    @ObservationIgnored var mediaInfoCallbacks = 0
    @ObservationIgnored var bufferingTransitions = 0
    @ObservationIgnored var startupEvaluations = 0
    @ObservationIgnored var cacheFloorChecks = 0
    @ObservationIgnored var acceptedReplies = 0
    @ObservationIgnored var startupHoldActive = false
    @ObservationIgnored var playbackRequested = true

    init() { onMediaInfoChanged = { [unowned self] _ in mediaInfoCallbacks += 1 } }

    func snapshot() -> StateSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        return StateSnapshot(mediaInfo: mediaInfo, stats: playbackStats, isPlaying: isPlaying, isBuffering: isBuffering,
            isLoading: isLoading, isMuted: isMuted, isSeekable: isSeekable, cacheSeconds: cacheSeconds, volume: volume,
            timePos: timePos, duration: duration, containerFps: containerFps, estimatedFps: estimatedFps,
            telemetryPause: telemetryPause, telemetryPausedForCache: telemetryPausedForCache,
            telemetryCachePauseInitial: telemetryCachePauseInitial, telemetryAudioOutput: telemetryAudioOutput,
            telemetryLavfProbeInfo: telemetryLavfProbeInfo, telemetryAVSync: telemetryAVSyncSeconds,
            telemetryDemuxerStart: telemetryDemuxerStartTime, telemetryCachePauseWait: telemetryCachePauseWaitSeconds,
            telemetryLavfAnalyze: telemetryLavfAnalyzeDurationSeconds, telemetryLavfProbeSize: telemetryLavfProbeSize,
            rawTime: rawTimeSample.current(generation: loadGeneration, at: now)?.seconds,
            videoPTS: videoPTSSample.current(generation: loadGeneration, at: now)?.seconds,
            exactCache: telemetryExactCacheSeconds, mediaInfoCallbacks: mediaInfoCallbacks,
            bufferingTransitions: bufferingTransitions, startupEvaluations: startupEvaluations,
            cacheFloorChecks: cacheFloorChecks, acceptedReplies: acceptedReplies)
    }

    /// One wakeup: the former event-source handler plus drainEvents' property arms.
    func drain(_ events: UnsafeBufferPointer<SyntheticEvent>, replies: Bool) {
        var drainBuffer = [UInt8](repeating: 0, count: 64)
        _ = drainBuffer.withUnsafeMutableBufferPointer { $0.count }
        var pending = PendingChanges()
        for evt in events {
            if replies {
                if let request = propertyRequests.removeValue(forKey: evt.userdata),
                   request.generation == loadGeneration,
                   request.property.isHandleProperty || request.item == activeIdentity {
                    acceptedReplies += 1
                    collectProperty(id: request.property.rawValue, prop: evt.property, into: &pending)
                }
            } else if let property = PropID(rawValue: evt.userdata),
                      property.isHandleProperty || activeIdentity != nil {
                collectProperty(id: evt.userdata, prop: evt.property, into: &pending)
            }
        }
        applyPendingChanges(pending)
    }

    func requestSeedProperties(into ids: inout [UInt64]) {
        for id in 1...UInt64(32) {
            propertyRequestSerial &+= 1
            let requestID = (1 << 62) | propertyRequestSerial
            propertyRequests[requestID] = (loadGeneration, activeIdentity, PropID(rawValue: id)!)
            ids.append(requestID)
        }
    }

    func resetRequests() { propertyRequests.removeAll() }

    private enum PropID: UInt64 {
        case pause = 1
        case width
        case height
        case fps
        case estimatedFps
        case videoCodec
        case audioCodec
        case audioChannels
        case audioSampleRate
        case hwdec
        case pausedForCache
        case cacheSeconds
        case volume
        case mute
        case timePos
        case videoPTS
        case duration
        case seekable
        case videoBitrate
        case audioBitrate
        case frameDrops
        case decoderFrameDrops
        case delayedFrames
        case mistimedFrames
        case audioOutput
        case avSync
        case demuxerStartTime
        case cachePauseInitial
        case cachePauseWait
        case lavfAnalyzeDuration
        case lavfProbeSize
        case lavfProbeInfo

        var isHandleProperty: Bool {
            switch self {
            case .pause, .volume, .mute: true
            default: false
            }
        }
    }

    private struct PendingChanges {
        var isPlaying: Bool?
        var paused: Bool?
        var pausedForCache: Bool?
        var width: Int?
        var height: Int?
        var containerFps: Double?
        var estimatedFps: Double?
        var videoCodec: String?
        var audioCodec: String?
        var audioChannels: Int?
        var audioSampleRate: Int?
        var hwdec: String?
        var cacheSeconds: Double??
        var isBuffering: Bool?
        var volume: Double?
        var isMuted: Bool?
        var timePos: Double?
        var duration: Double?
        var isSeekable: Bool?
        var videoBitrateBps: Int64?
        var audioBitrateBps: Int64?
        var frameDrops: Int64?
        var decoderFrameDrops: Int64?
        var delayedFrames: Int64?
        var mistimedFrames: Int64?
        var audioOutput: String??
        var avSync: Double??
        var demuxerStartTime: Double??
        var cachePauseInitial: Bool??
        var cachePauseWaitSeconds: Double??
        var lavfAnalyzeDurationSeconds: Double??
        var lavfProbeSize: Int64??
        var lavfProbeInfo: String??

        var hasChanges: Bool {
            isPlaying != nil ||
            paused != nil ||
            pausedForCache != nil ||
            width != nil ||
            height != nil ||
            containerFps != nil ||
            estimatedFps != nil ||
            videoCodec != nil ||
            audioCodec != nil ||
            audioChannels != nil ||
            audioSampleRate != nil ||
            hwdec != nil ||
            cacheSeconds != nil ||
            isBuffering != nil ||
            volume != nil ||
            isMuted != nil ||
            timePos != nil ||
            duration != nil ||
            isSeekable != nil ||
            videoBitrateBps != nil ||
            audioBitrateBps != nil ||
            frameDrops != nil ||
            decoderFrameDrops != nil ||
            delayedFrames != nil ||
            mistimedFrames != nil ||
            audioOutput != nil ||
            avSync != nil ||
            demuxerStartTime != nil ||
            cachePauseInitial != nil ||
            cachePauseWaitSeconds != nil ||
            lavfAnalyzeDurationSeconds != nil || lavfProbeSize != nil || lavfProbeInfo != nil
        }
    }

    private func collectProperty(id: UInt64, prop: mpv_event_property, into pending: inout PendingChanges) {
        guard let kind = PropID(rawValue: id) else { return }
        switch kind {
        case .pause:
            if prop.format == MPV_FORMAT_FLAG, let data = prop.data {
                let paused = data.assumingMemoryBound(to: Int32.self).pointee != 0
                pending.paused = paused
                pending.isPlaying = !paused
            }
        case .width:
            pending.width = readInt(prop)
        case .height:
            pending.height = readInt(prop)
        case .fps:
            if prop.format == MPV_FORMAT_DOUBLE, let data = prop.data {
                pending.containerFps = data.assumingMemoryBound(to: Double.self).pointee
            } else {
                pending.containerFps = 0
            }
        case .estimatedFps:
            if prop.format == MPV_FORMAT_DOUBLE, let data = prop.data {
                pending.estimatedFps = data.assumingMemoryBound(to: Double.self).pointee
            } else {
                pending.estimatedFps = 0
            }
        case .videoCodec:
            pending.videoCodec = readString(prop)
        case .audioCodec:
            pending.audioCodec = readString(prop)
        case .audioChannels:
            pending.audioChannels = readInt(prop)
        case .audioSampleRate:
            pending.audioSampleRate = max(0, readInt(prop))
        case .hwdec:
            pending.hwdec = readString(prop)
        case .pausedForCache:
            if prop.format == MPV_FORMAT_FLAG, let data = prop.data {
                let paused = data.assumingMemoryBound(to: Int32.self).pointee != 0
                pending.pausedForCache = paused
                pending.isBuffering = paused
            }
        case .cacheSeconds:
            pending.cacheSeconds = .some(readFiniteDouble(prop))
        case .volume:
            if prop.format == MPV_FORMAT_DOUBLE, let data = prop.data {
                pending.volume = data.assumingMemoryBound(to: Double.self).pointee
            }
        case .mute:
            if prop.format == MPV_FORMAT_FLAG, let data = prop.data {
                pending.isMuted = data.assumingMemoryBound(to: Int32.self).pointee != 0
            }
        case .timePos:
            let value = readFiniteDouble(prop)
            rawTimeSample.observe(value, generation: loadGeneration, at: ProcessInfo.processInfo.systemUptime)
            pending.timePos = value
        case .videoPTS:
            videoPTSSample.observe(readFiniteDouble(prop), generation: loadGeneration,
                                   at: ProcessInfo.processInfo.systemUptime)
        case .duration:
            if prop.format == MPV_FORMAT_DOUBLE, let data = prop.data {
                pending.duration = data.assumingMemoryBound(to: Double.self).pointee
            }
        case .seekable:
            if prop.format == MPV_FORMAT_FLAG, let data = prop.data {
                pending.isSeekable = data.assumingMemoryBound(to: Int32.self).pointee != 0
            }
        case .videoBitrate:
            pending.videoBitrateBps = readInt64(prop)
        case .audioBitrate:
            pending.audioBitrateBps = readInt64(prop)
        case .frameDrops:
            pending.frameDrops = readInt64(prop)
        case .decoderFrameDrops:
            pending.decoderFrameDrops = readInt64(prop)
        case .delayedFrames:
            pending.delayedFrames = readInt64(prop)
        case .mistimedFrames:
            pending.mistimedFrames = readInt64(prop)
        case .audioOutput:
            let value = readString(prop)
            pending.audioOutput = .some(value.isEmpty ? nil : value)
        case .avSync:
            pending.avSync = .some(readFiniteDouble(prop))
        case .demuxerStartTime:
            pending.demuxerStartTime = .some(readFiniteDouble(prop))
        case .cachePauseInitial:
            if prop.format == MPV_FORMAT_FLAG, let data = prop.data {
                pending.cachePauseInitial = .some(data.assumingMemoryBound(to: Int32.self).pointee != 0)
            } else { pending.cachePauseInitial = .some(nil) }
        case .cachePauseWait:
            pending.cachePauseWaitSeconds = .some(readFiniteDouble(prop).flatMap { $0 >= 0 ? $0 : nil })
        case .lavfAnalyzeDuration:
            pending.lavfAnalyzeDurationSeconds = .some(readFiniteDouble(prop).flatMap { $0 >= 0 ? $0 : nil })
        case .lavfProbeSize:
            let value = readInt64(prop)
            pending.lavfProbeSize = .some(prop.format == MPV_FORMAT_INT64 && prop.data != nil && value > 0 ? value : nil)
        case .lavfProbeInfo:
            let value = readString(prop)
            pending.lavfProbeInfo = .some(["auto", "yes", "no", "nostreams"].contains(value) ? value : nil)
        }
    }

    private func applyPendingChanges(_ pending: PendingChanges) {
        guard pending.hasChanges else { return }

        if let isPlaying = pending.isPlaying {
            setState(\.isPlaying, isPlaying)
        }
        if let paused = pending.paused { telemetryPause = paused }
        if let pausedForCache = pending.pausedForCache { telemetryPausedForCache = pausedForCache }
        if let audioOutput = pending.audioOutput { telemetryAudioOutput = audioOutput }
        if let avSync = pending.avSync { telemetryAVSyncSeconds = avSync }
        if let demuxerStartTime = pending.demuxerStartTime { telemetryDemuxerStartTime = demuxerStartTime }
        if let initial = pending.cachePauseInitial { telemetryCachePauseInitial = initial }
        if let seconds = pending.cachePauseWaitSeconds { telemetryCachePauseWaitSeconds = seconds }
        if let seconds = pending.lavfAnalyzeDurationSeconds { telemetryLavfAnalyzeDurationSeconds = seconds }
        if let bytes = pending.lavfProbeSize { telemetryLavfProbeSize = bytes }
        if let mode = pending.lavfProbeInfo { telemetryLavfProbeInfo = mode }

        var nextMediaInfo = mediaInfo
        if let width = pending.width {
            nextMediaInfo.width = width
        }
        if let height = pending.height {
            nextMediaInfo.height = height
        }
        if let videoCodec = pending.videoCodec {
            nextMediaInfo.videoCodec = videoCodec
        }
        if let audioCodec = pending.audioCodec {
            nextMediaInfo.audioCodec = audioCodec
        }
        if let audioChannels = pending.audioChannels {
            nextMediaInfo.audioChannels = audioChannels
        }
        if let audioSampleRate = pending.audioSampleRate { nextMediaInfo.audioSampleRate = audioSampleRate }
        if let hwdec = pending.hwdec {
            nextMediaInfo.hwdec = hwdec
        }
        let nextDuration = pending.duration ?? duration
        let nextTimePos = pending.timePos ?? timePos
        let nextIsSeekable = pending.isSeekable ?? isSeekable
        let hasReplayWindow = nextIsSeekable && nextDuration > 0 && nextDuration.isFinite && nextTimePos.isFinite
        if hasReplayWindow {
            let targetDelay = min(Double(bufferSeconds), nextDuration)
            let nextLatency = max(0, nextDuration - nextTimePos - targetDelay)
            let currentLatency = nextMediaInfo.liveLatencySeconds ?? 0
            if abs(currentLatency - nextLatency) >= Tuning.liveLatencyEpsilon {
                nextMediaInfo.liveLatencySeconds = nextLatency
            }
        } else if nextMediaInfo.liveLatencySeconds != nil {
            nextMediaInfo.liveLatencySeconds = nil
        }

        let nextContainerFps = pending.containerFps ?? containerFps
        let nextEstimatedFps = pending.estimatedFps ?? estimatedFps
        if abs(containerFps - nextContainerFps) >= Tuning.stateEpsilon {
            containerFps = nextContainerFps
        }
        if abs(estimatedFps - nextEstimatedFps) >= Tuning.stateEpsilon {
            estimatedFps = nextEstimatedFps
        }

        let displayFps = max(nextContainerFps, nextEstimatedFps)
        if abs(nextMediaInfo.fps - displayFps) >= Tuning.stateEpsilon {
            nextMediaInfo.fps = displayFps
        }
        let didMediaInfoChange = mediaInfo != nextMediaInfo
        if didMediaInfoChange {
            mediaInfo = nextMediaInfo
            onMediaInfoChanged?(nextMediaInfo)
        }

        if let observation = pending.cacheSeconds {
            preciseCacheSample.observe(observation, generation: loadGeneration, at: ProcessInfo.processInfo.systemUptime)
            if let seconds = telemetryExactCacheSeconds {
                setApproxState(\.cacheSeconds, seconds, epsilon: Tuning.cacheEpsilon)
            }
        }
        if pending.isBuffering != nil {
            updateBufferingState(telemetryPausedForCache ?? false)
        }
        if let volume = pending.volume {
            setApproxState(\.volume, volume, epsilon: Tuning.stateEpsilon)
        }
        if let isMuted = pending.isMuted {
            setState(\.isMuted, isMuted)
        }
        if let timePos = pending.timePos {
            setApproxState(\.timePos, timePos, epsilon: Tuning.timePosEpsilon)
            if isLoading, timePos > 0, !startupHoldActive {
                setState(\.isLoading, false)
            }
        }
        if let duration = pending.duration {
            setApproxState(\.duration, duration, epsilon: Tuning.stateEpsilon)
        }
        if let isSeekable = pending.isSeekable {
            setState(\.isSeekable, isSeekable)
        }

        var nextStats = playbackStats
        if let containerFps = pending.containerFps {
            nextStats.containerFps = containerFps
        }
        if let estimatedFps = pending.estimatedFps {
            nextStats.estimatedFps = estimatedFps
        }
        if let videoBitrateBps = pending.videoBitrateBps {
            nextStats.videoBitrateBps = videoBitrateBps
        }
        if let audioBitrateBps = pending.audioBitrateBps {
            nextStats.audioBitrateBps = audioBitrateBps
        }
        if let frameDrops = pending.frameDrops {
            nextStats.frameDrops = frameDrops
        }
        if let decoderFrameDrops = pending.decoderFrameDrops {
            nextStats.decoderFrameDrops = decoderFrameDrops
        }
        if let delayedFrames = pending.delayedFrames {
            nextStats.delayedFrames = delayedFrames
        }
        if let mistimedFrames = pending.mistimedFrames {
            nextStats.mistimedFrames = mistimedFrames
        }
        if nextStats != playbackStats {
            playbackStats = nextStats
        }

        if pending.cacheSeconds != nil { startupEvaluations += 1 }
        if pending.cacheSeconds != nil, let seconds = telemetryExactCacheSeconds {
            maintainLiveCacheFloor(cacheSeconds: seconds)
        }
        updateDisplayPowerAssertion()
    }

    private func updateBufferingState(_ buffering: Bool) {
        guard isBuffering != buffering else { return }
        setState(\.isBuffering, buffering)
        bufferingTransitions += 1
    }

    private func maintainLiveCacheFloor(cacheSeconds: Double) {
        guard playbackRequested, !startupHoldActive, !isLoading, timePos > 0.5,
              cacheSeconds.isFinite, cacheSeconds >= 0 else { return }
        cacheFloorChecks += 1
    }

    private func updateDisplayPowerAssertion() {
        _ = playbackRequested && (isPlaying || isLoading || isBuffering)
    }

    private func setState<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<LegacyPlayer, Value>, _ value: Value) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    private func setApproxState(_ keyPath: ReferenceWritableKeyPath<LegacyPlayer, Double>, _ value: Double, epsilon: Double) {
        guard abs(self[keyPath: keyPath] - value) >= epsilon else { return }
        self[keyPath: keyPath] = value
    }

    private func readInt(_ prop: mpv_event_property) -> Int {
        guard prop.format == MPV_FORMAT_INT64, let data = prop.data else { return 0 }
        return Int(data.assumingMemoryBound(to: Int64.self).pointee)
    }

    private func readInt64(_ prop: mpv_event_property) -> Int64 {
        guard prop.format == MPV_FORMAT_INT64, let data = prop.data else { return 0 }
        return data.assumingMemoryBound(to: Int64.self).pointee
    }

    private func readFiniteDouble(_ prop: mpv_event_property) -> Double? {
        guard prop.format == MPV_FORMAT_DOUBLE, let data = prop.data else { return nil }
        let value = data.assumingMemoryBound(to: Double.self).pointee
        return value.isFinite ? value : nil
    }

    private func readString(_ prop: mpv_event_property) -> String {
        guard prop.format == MPV_FORMAT_STRING, let data = prop.data else { return "" }
        let pp = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
        return pp.map { String(cString: $0) } ?? ""
    }
}
