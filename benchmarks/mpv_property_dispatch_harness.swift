// Flat dispatch mirror + synthetic streams + harness for
// mpv_property_dispatch_benchmark.swift. Run: scripts/test-mpv-property-dispatch.sh
// SKIP_APPLY=1 times decode/collect only; PROFILE_FLAT=1 loops the flat path for `sample`.
import Darwin
import Foundation
import Observation

// MARK: - Flat dispatch (mirrors MPVPlayer.drainEvents / applyPendingChanges)

@MainActor @Observable
final class FlatPlayer {
    nonisolated(unsafe) static var skipApply = false
    private(set) var mediaInfo = MPVMediaInfo()
    private(set) var playbackStats = MPVPlaybackStats()
    private(set) var isPlaying = false
    private(set) var cacheSeconds: Double = 0
    @ObservationIgnored private var preciseCacheSample = PlaybackCacheSample()
    var telemetryExactCacheSeconds: Double? {
        preciseCacheSample.currentSeconds(generation: loadGeneration, at: ProcessInfo.processInfo.systemUptime)
    }
    @ObservationIgnored private(set) var telemetryCachePauseInitial: Bool?
    @ObservationIgnored private(set) var telemetryCachePauseWaitSeconds: Double?
    @ObservationIgnored private(set) var telemetryLavfAnalyzeDurationSeconds: Double?
    @ObservationIgnored private(set) var telemetryLavfProbeSize: Int64?
    @ObservationIgnored private(set) var telemetryLavfProbeInfo: String?
    @ObservationIgnored private var rawTimeSample = PlaybackClockSample()
    @ObservationIgnored private var videoPTSSample = PlaybackClockSample()
    private(set) var isBuffering = false
    private(set) var isLoading = true
    private(set) var volume: Double = 100
    private(set) var isMuted = false
    private(set) var timePos: Double = 0
    @ObservationIgnored private(set) var telemetryAudioOutput: String?
    @ObservationIgnored private(set) var telemetryDemuxerStartTime: Double?
    @ObservationIgnored private(set) var telemetryAVSyncSeconds: Double?
    @ObservationIgnored private(set) var telemetryPause: Bool?
    @ObservationIgnored private(set) var telemetryPausedForCache: Bool?
    private(set) var duration: Double = 0
    private(set) var isSeekable: Bool = false
    @ObservationIgnored private var containerFps: Double = 0
    @ObservationIgnored private var estimatedFps: Double = 0
    private var bufferSeconds: Int = 5
    @ObservationIgnored var onMediaInfoChanged: ((MPVMediaInfo) -> Void)?
    @ObservationIgnored private var propertyRequests = MPVPropertyRequestRing()
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

    func drain(_ events: UnsafeBufferPointer<SyntheticEvent>, replies: Bool) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { _ = $0.count }
        var batch = MPVPropertyBatch()
        var uptime = Double.nan
        for evt in events {
            if replies {
                if let request = propertyRequests.remove(requestID: evt.userdata),
                   request.generation == loadGeneration,
                   request.property.isHandleProperty || request.item == activeIdentity {
                    acceptedReplies += 1
                    collect(request.property, evt.property, into: &batch, uptime: &uptime)
                }
            } else if let property = MPVProperty.from(userdata: evt.userdata),
                      property.isHandleProperty || activeIdentity != nil {
                collect(property, evt.property, into: &batch, uptime: &uptime)
            }
        }
        if !Self.skipApply { applyPendingChanges(&batch, uptime: &uptime) }
    }

    func requestSeedProperties(into ids: inout [UInt64]) {
        for property in MPVProperty.allCases {
            ids.append(propertyRequests.insert(generation: loadGeneration, item: activeIdentity, property: property))
        }
    }

    func resetRequests() { propertyRequests.removeAll() }

    @inline(__always) private func now(_ uptime: inout Double) -> Double {
        if uptime.isNaN { uptime = ProcessInfo.processInfo.systemUptime }
        return uptime
    }

    @inline(__always)
    private func collect(_ property: MPVProperty, _ prop: mpv_event_property, into batch: inout MPVPropertyBatch,
                         uptime: inout Double) {
        let format = prop.format.rawValue
        let data = UnsafeRawPointer(prop.data)
        switch property {
        case .timePos:
            rawTimeSample.observe(MPVPropertyBatch.finiteDouble(format: format, data: data),
                                  generation: loadGeneration, at: now(&uptime))
        case .videoPTS:
            videoPTSSample.observe(MPVPropertyBatch.finiteDouble(format: format, data: data),
                                   generation: loadGeneration, at: now(&uptime))
        default:
            break
        }
        batch.collect(property, format: format, data: data)
    }

    /// Hot reads use the @Observable backing storage (`_name`): reading a
    /// published value here must not register or pay for observation access.
    /// Writes still go through the setters, and only when the value changed.
    private func applyPendingChanges(_ batch: inout MPVPropertyBatch, uptime: inout Double) {
        guard !batch.isEmpty else { return }

        if batch.has(.pause) {
            let paused = batch.flag(.pause)
            if _isPlaying == paused { isPlaying = !paused }
        }
        if batch.hasAny(MPVPropertyBatch.telemetryMask) {
            // Polled telemetry (not observed): plain stores.
            if batch.has(.pause) { telemetryPause = batch.flag(.pause) }
            if batch.has(.pausedForCache) { telemetryPausedForCache = batch.flag(.pausedForCache) }
            if batch.has(.audioOutput) {
                telemetryAudioOutput = batch.isUnavailable(.audioOutput) ? nil : batch.audioOutput
            }
            if batch.has(.avSync) { telemetryAVSyncSeconds = batch.optionalDouble(.avSync) }
            if batch.has(.demuxerStartTime) { telemetryDemuxerStartTime = batch.optionalDouble(.demuxerStartTime) }
            if batch.has(.cachePauseInitial) {
                telemetryCachePauseInitial = batch.isUnavailable(.cachePauseInitial) ? nil : batch.flag(.cachePauseInitial)
            }
            if batch.has(.cachePauseWait) { telemetryCachePauseWaitSeconds = batch.optionalDouble(.cachePauseWait) }
            if batch.has(.lavfAnalyzeDuration) {
                telemetryLavfAnalyzeDurationSeconds = batch.optionalDouble(.lavfAnalyzeDuration)
            }
            if batch.has(.lavfProbeSize) {
                telemetryLavfProbeSize = batch.isUnavailable(.lavfProbeSize) ? nil : batch.int64(.lavfProbeSize)
            }
            if batch.has(.lavfProbeInfo) {
                telemetryLavfProbeInfo = batch.isUnavailable(.lavfProbeInfo) ? nil : batch.lavfProbeInfo
            }
        }

        let currentDuration = _duration
        let currentTimePos = _timePos
        let currentIsSeekable = _isSeekable
        let nextDuration = batch.has(.duration) ? batch.double(.duration) : currentDuration
        let nextTimePos = batch.has(.timePos) ? batch.double(.timePos) : currentTimePos
        let nextIsSeekable = batch.has(.seekable) ? batch.flag(.seekable) : currentIsSeekable

        // Media info: decide from the stored fields, copy only on change.
        let currentLatency = _mediaInfo.liveLatencySeconds
        var nextLatency = currentLatency
        if nextIsSeekable && nextDuration > 0 && nextDuration.isFinite && nextTimePos.isFinite {
            let targetDelay = min(Double(bufferSeconds), nextDuration)
            let latency = max(0, nextDuration - nextTimePos - targetDelay)
            if abs((currentLatency ?? 0) - latency) >= Tuning.liveLatencyEpsilon { nextLatency = latency }
        } else {
            nextLatency = nil
        }
        let nextContainerFps = batch.has(.fps) ? batch.double(.fps) : containerFps
        let nextEstimatedFps = batch.has(.estimatedFps) ? batch.double(.estimatedFps) : estimatedFps
        if abs(containerFps - nextContainerFps) >= Tuning.stateEpsilon { containerFps = nextContainerFps }
        if abs(estimatedFps - nextEstimatedFps) >= Tuning.stateEpsilon { estimatedFps = nextEstimatedFps }
        let displayFps = max(nextContainerFps, nextEstimatedFps)
        let fpsChanged = abs(_mediaInfo.fps - displayFps) >= Tuning.stateEpsilon
        if nextLatency != currentLatency || fpsChanged || batch.hasAny(MPVPropertyBatch.mediaInfoMask) {
            var info = _mediaInfo
            if batch.has(.width) { info.width = Int(batch.int64(.width)) }
            if batch.has(.height) { info.height = Int(batch.int64(.height)) }
            if batch.has(.videoCodec) { info.videoCodec = batch.videoCodec }
            if batch.has(.audioCodec) { info.audioCodec = batch.audioCodec }
            if batch.has(.audioChannels) { info.audioChannels = Int(batch.int64(.audioChannels)) }
            if batch.has(.audioSampleRate) { info.audioSampleRate = Int(batch.int64(.audioSampleRate)) }
            if batch.has(.hwdec) { info.hwdec = batch.hwdec }
            info.liveLatencySeconds = nextLatency
            if fpsChanged { info.fps = displayFps }
            if info != _mediaInfo {
                mediaInfo = info
                onMediaInfoChanged?(info)
            }
        }

        if batch.has(.cacheSeconds) {
            let at = now(&uptime)
            preciseCacheSample.observe(batch.optionalDouble(.cacheSeconds), generation: loadGeneration, at: at)
            if let seconds = preciseCacheSample.currentSeconds(generation: loadGeneration, at: at),
               abs(_cacheSeconds - seconds) >= Tuning.cacheEpsilon {
                cacheSeconds = seconds
            }
        }
        if batch.has(.pausedForCache) {
            updateBufferingState(telemetryPausedForCache ?? false)
        }
        if batch.has(.volume) {
            let value = batch.double(.volume)
            if abs(_volume - value) >= Tuning.stateEpsilon { volume = value }
        }
        if batch.has(.mute) {
            let value = batch.flag(.mute)
            if _isMuted != value { isMuted = value }
        }
        if batch.has(.timePos) {
            if abs(currentTimePos - nextTimePos) >= Tuning.timePosEpsilon { timePos = nextTimePos }
            if _isLoading, nextTimePos > 0, !startupHoldActive { isLoading = false }
        }
        if batch.has(.duration), abs(currentDuration - nextDuration) >= Tuning.stateEpsilon { duration = nextDuration }
        if batch.has(.seekable), currentIsSeekable != nextIsSeekable { isSeekable = nextIsSeekable }

        if batch.hasAny(MPVPropertyBatch.statsMask) {
            var stats = _playbackStats
            if batch.has(.fps) { stats.containerFps = batch.double(.fps) }
            if batch.has(.estimatedFps) { stats.estimatedFps = batch.double(.estimatedFps) }
            if batch.has(.videoBitrate) { stats.videoBitrateBps = batch.int64(.videoBitrate) }
            if batch.has(.audioBitrate) { stats.audioBitrateBps = batch.int64(.audioBitrate) }
            if batch.has(.frameDrops) { stats.frameDrops = batch.int64(.frameDrops) }
            if batch.has(.decoderFrameDrops) { stats.decoderFrameDrops = batch.int64(.decoderFrameDrops) }
            if batch.has(.delayedFrames) { stats.delayedFrames = batch.int64(.delayedFrames) }
            if batch.has(.mistimedFrames) { stats.mistimedFrames = batch.int64(.mistimedFrames) }
            if stats != _playbackStats { playbackStats = stats }
        }

        if batch.has(.cacheSeconds) {
            startupEvaluations += 1
            if let seconds = preciseCacheSample.currentSeconds(generation: loadGeneration, at: now(&uptime)) {
                maintainLiveCacheFloor(cacheSeconds: seconds)
            }
        }
        updateDisplayPowerAssertion()
    }

    private func updateBufferingState(_ buffering: Bool) {
        guard _isBuffering != buffering else { return }
        isBuffering = buffering
        bufferingTransitions += 1
    }

    private func maintainLiveCacheFloor(cacheSeconds: Double) {
        guard playbackRequested, !startupHoldActive, !_isLoading, _timePos > 0.5,
              cacheSeconds.isFinite, cacheSeconds >= 0 else { return }
        cacheFloorChecks += 1
    }

    private func updateDisplayPowerAssertion() {
        _ = playbackRequested && (_isPlaying || _isLoading || _isBuffering)
    }
}

// MARK: - Synthetic event streams

/// Owns stable payload storage so events can point into it like mpv's.
final class EventArena {
    private let doubles: UnsafeMutablePointer<Double>
    private let ints: UnsafeMutablePointer<Int64>
    private let flags: UnsafeMutablePointer<Int32>
    private let strings: UnsafeMutablePointer<UnsafePointer<CChar>?>
    private let capacity: Int
    private var used = 0
    private(set) var events: [SyntheticEvent] = []

    init(capacity: Int) {
        self.capacity = capacity
        doubles = .allocate(capacity: capacity)
        ints = .allocate(capacity: capacity)
        flags = .allocate(capacity: capacity)
        strings = .allocate(capacity: capacity)
    }

    func add(_ property: MPVProperty, double value: Double) {
        doubles[used] = value
        append(property, MPV_FORMAT_DOUBLE, UnsafeMutableRawPointer(doubles + used))
    }
    func add(_ property: MPVProperty, int value: Int64) {
        ints[used] = value
        append(property, MPV_FORMAT_INT64, UnsafeMutableRawPointer(ints + used))
    }
    func add(_ property: MPVProperty, flag value: Bool) {
        flags[used] = value ? 1 : 0
        append(property, MPV_FORMAT_FLAG, UnsafeMutableRawPointer(flags + used))
    }
    func add(_ property: MPVProperty, string value: String) {
        strings[used] = UnsafePointer(strdup(value)!)
        append(property, MPV_FORMAT_STRING, UnsafeMutableRawPointer(strings + used))
    }
    /// MPV_FORMAT_NONE: property unavailable (mpv reports this on unload).
    func addUnavailable(_ property: MPVProperty) {
        append(property, mpv_format(rawValue: 0), nil)
    }
    private func append(_ property: MPVProperty, _ format: mpv_format, _ data: UnsafeMutableRawPointer?) {
        precondition(used < capacity)
        events.append(SyntheticEvent(userdata: property.userdata,
                                     property: mpv_event_property(name: nil, format: format, data: data)))
        used += 1
    }
}

/// Steady-state live playback: each playloop wakeup delivers the clocks and
/// cache duration; fps/bitrates/drops arrive every ~25 wakeups.
func steadyStateStream(events: Int) -> (EventArena, [Range<Int>]) {
    let arena = EventArena(capacity: events + 64)
    var drains: [Range<Int>] = []
    var t = 100.0
    var wakeup = 0
    while arena.events.count < events {
        let start = arena.events.count
        t += 0.04
        arena.add(.timePos, double: t)
        arena.add(.videoPTS, double: t + 0.001)
        arena.add(.avSync, double: Double(wakeup % 7) * 0.001)
        arena.add(.cacheSeconds, double: 4.5 + Double(wakeup % 11) * 0.1)
        if wakeup % 25 == 0 {
            arena.add(.estimatedFps, double: 24.9 + Double(wakeup % 3) * 0.1)
            arena.add(.videoBitrate, int: 4_000_000 + Int64(wakeup % 5) * 10_000)
            arena.add(.audioBitrate, int: 128_000)
            arena.add(.frameDrops, int: Int64(wakeup / 500))
        }
        drains.append(start..<arena.events.count)
        wakeup += 1
    }
    return (arena, drains)
}

/// Every property, every format (valid, wrong format, unavailable, non-finite).
func randomStream(seed: UInt64, events: Int) -> (EventArena, [Range<Int>]) {
    var rng = SplitMix64(seed: seed)
    let arena = EventArena(capacity: events + 64)
    var drains: [Range<Int>] = []
    let doubles: [Double] = [0, -1, 0.3, 2.5, 25, 30, 120, 3_600, .nan, .infinity, -.infinity]
    let strings = ["", "h264", "hevc", "videotoolbox", "auto", "yes", "no", "nostreams", "coreaudio", "maybe"]
    while arena.events.count < events {
        let start = arena.events.count
        for _ in 0..<(1 + Int(rng.next() % 6)) {
            let property = MPVProperty.allCases[Int(rng.next() % UInt64(MPVProperty.allCases.count))]
            switch rng.next() % 5 {
            case 0: arena.add(property, double: doubles[Int(rng.next() % UInt64(doubles.count))])
            case 1: arena.add(property, int: Int64(rng.next() % 9) - 2)
            case 2: arena.add(property, flag: rng.next() & 1 == 0)
            case 3: arena.add(property, string: strings[Int(rng.next() % UInt64(strings.count))])
            default: arena.addUnavailable(property)
            }
        }
        drains.append(start..<arena.events.count)
    }
    return (arena, drains)
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Harness

func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

@MainActor
func timeDrains(_ drain: (UnsafeBufferPointer<SyntheticEvent>) -> Void, arena: EventArena, drains: [Range<Int>],
                runs: Int = 9) -> Double {
    var samples: [Double] = []
    arena.events.withUnsafeBufferPointer { all in
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            for range in drains { drain(UnsafeBufferPointer(rebasing: all[range])) }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start))
        }
    }
    return median(samples)
}

@MainActor
func runDispatchBenchmark() {
    var checks = 0
    func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !condition { fatalError(message()) }
    }

    // 1. Equivalence on random streams (observation path).
    for seed in 1...UInt64(40) {
        let (arena, drains) = randomStream(seed: seed, events: 2_000)
        let legacy = LegacyPlayer(), flat = FlatPlayer()
        arena.events.withUnsafeBufferPointer { all in
            for range in drains {
                legacy.drain(UnsafeBufferPointer(rebasing: all[range]), replies: false)
                flat.drain(UnsafeBufferPointer(rebasing: all[range]), replies: false)
                let l = legacy.snapshot(), f = flat.snapshot()
                check("\(l)" == "\(f)", "seed \(seed) drain \(range) diverged:\nlegacy \(l)\nflat   \(f)")
            }
        }
    }
    // Reply path: one read per property, replies routed by request ID.
    do {
        let legacy = LegacyPlayer(), flat = FlatPlayer()
        for round in 0..<20 {
            var legacyIDs: [UInt64] = [], flatIDs: [UInt64] = []
            legacy.requestSeedProperties(into: &legacyIDs)
            flat.requestSeedProperties(into: &flatIDs)
            check(legacyIDs == flatIDs, "request IDs must keep the 1<<62|serial layout")
            if round % 5 == 4 { legacy.resetRequests(); flat.resetRequests() }
            let (arena, _) = randomStream(seed: 1_000 + UInt64(round), events: 64)
            var replies = Array(arena.events.prefix(32))
            for index in replies.indices { replies[index].userdata = legacyIDs[index] }
            replies.append(contentsOf: replies.prefix(4)) // duplicate replies must be ignored
            replies.withUnsafeBufferPointer { legacy.drain($0, replies: true); flat.drain($0, replies: true) }
            check("\(legacy.snapshot())" == "\(flat.snapshot())", "reply round \(round) diverged")
        }
    }
    // Ring-specific checks.
    do {
        var ring = MPVPropertyRequestRing()
        let item = MPVItemLifecycle.Identity(generation: 3, playlistEntryID: 9)
        let a = ring.insert(generation: 3, item: item, property: .timePos)
        let b = ring.insert(generation: 3, item: nil, property: .volume)
        check(a & MPVPropertyRequestRing.requestTag != 0, "request tag")
        check(ring.containsPending(generation: 3, property: .timePos), "pending lookup")
        check(!ring.containsPending(generation: 4, property: .timePos), "pending lookup generation")
        check(ring.remove(requestID: a) == .init(generation: 3, item: item, property: .timePos), "remove a")
        check(ring.remove(requestID: a) == nil, "duplicate reply ignored")
        ring.cancel(requestID: b)
        check(ring.remove(requestID: b) == nil, "cancelled request ignored")
        check(ring.remove(requestID: 1 << 63 | 2) == nil, "pause-write ID is not a property request")
        let stale = ring.insert(generation: 3, item: nil, property: .pause)
        ring.removeAll()
        check(ring.remove(requestID: stale) == nil, "cleared request ignored")
        var ids: [UInt64] = []
        for _ in 0..<MPVPropertyRequestRing.capacity { ids.append(ring.insert(generation: 5, item: nil, property: .width)) }
        check(ring.count == MPVPropertyRequestRing.capacity, "ring full")
        let evicting = ring.insert(generation: 5, item: nil, property: .height)
        check(ring.remove(requestID: ids[0]) == nil, "evicted slot is not resurrected")
        check(ring.remove(requestID: evicting)?.property == .height, "newest request wins its slot")
        check(MPVProperty.from(userdata: 0) == nil && MPVProperty.from(userdata: 33) == nil
              && MPVProperty.from(userdata: 1 << 62 | 1) == nil, "userdata range check")
        check(MPVProperty.allCases.allSatisfy { MPVProperty.from(userdata: $0.userdata) == $0 }, "userdata round trip")
        check(MPVProperty.allCases.filter(\.isHandleProperty) == [.pause, .volume, .mute], "handle properties")
    }
    print("equivalence: \(checks) checks passed")
    FlatPlayer.skipApply = ProcessInfo.processInfo.environment["SKIP_APPLY"] != nil

    // 2. Timing: 10k steady-state events.
    let (arena, drains) = steadyStateStream(events: 10_000)
    let eventCount = Double(arena.events.count)
    let legacy = LegacyPlayer(), flat = FlatPlayer()
    _ = timeDrains({ legacy.drain($0, replies: false) }, arena: arena, drains: drains, runs: 2)
    _ = timeDrains({ flat.drain($0, replies: false) }, arena: arena, drains: drains, runs: 2)
    let legacyNs = timeDrains({ legacy.drain($0, replies: false) }, arena: arena, drains: drains)
    if ProcessInfo.processInfo.environment["PROFILE_FLAT"] != nil { _ = timeDrains({ flat.drain($0, replies: false) }, arena: arena, drains: drains, runs: 20_000) }
    let flatNs = timeDrains({ flat.drain($0, replies: false) }, arena: arena, drains: drains)

    // 3. Allocations per event (steady state, after warm-up).
    var legacyAllocs = 0, flatAllocs = 0
    arena.events.withUnsafeBufferPointer { all in
        legacyAllocs = countAllocations { for r in drains { legacy.drain(UnsafeBufferPointer(rebasing: all[r]), replies: false) } }
        flatAllocs = countAllocations { for r in drains { flat.drain(UnsafeBufferPointer(rebasing: all[r]), replies: false) } }
    }

    // 4. Request table: FILE_LOADED seed burst (32 reads) + 32 replies + reset.
    let replyArena = randomStream(seed: 77, events: 64).0
    func requestRoundTrip(seed: (inout [UInt64]) -> Void, drain: (UnsafeBufferPointer<SyntheticEvent>) -> Void,
                          reset: () -> Void) -> Double {
        var samples: [Double] = []
        var ids: [UInt64] = []
        ids.reserveCapacity(64)
        var replies = Array(replyArena.events.prefix(32))
        for _ in 0..<9 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<2_000 {
                ids.removeAll(keepingCapacity: true)
                seed(&ids)
                for index in replies.indices { replies[index].userdata = ids[index] }
                replies.withUnsafeBufferPointer { drain($0) }
                reset()
            }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 2_000)
        }
        return median(samples)
    }
    let lp = LegacyPlayer(), fp = FlatPlayer()
    let legacyBurst = requestRoundTrip(seed: { lp.requestSeedProperties(into: &$0) },
                                       drain: { lp.drain($0, replies: true) }, reset: lp.resetRequests)
    let flatBurst = requestRoundTrip(seed: { fp.requestSeedProperties(into: &$0) },
                                     drain: { fp.drain($0, replies: true) }, reset: fp.resetRequests)
    // Request-table allocations only (seed 32 reads, then clear), 100 loads.
    var tableIDs: [UInt64] = []
    tableIDs.reserveCapacity(64)
    let legacyTableAllocs = countAllocations {
        for _ in 0..<100 { tableIDs.removeAll(keepingCapacity: true); lp.requestSeedProperties(into: &tableIDs); lp.resetRequests() }
    }
    let flatTableAllocs = countAllocations {
        for _ in 0..<100 { tableIDs.removeAll(keepingCapacity: true); fp.requestSeedProperties(into: &tableIDs); fp.resetRequests() }
    }

    // 5. Per-second telemetry sample: PlayerSession.samplePlaybackEvidence +
    //    PlaybackLivenessMonitor.sample reading published player state.
    var monitor = PlaybackLivenessMonitor(position: flat.timePos, now: 0)
    var lastEvidence: (time: Double, position: Double, generation: Int)? = nil
    var healthy = 0.0
    var sampleTimes: [Double] = []
    var second = 0
    for _ in 0..<9 {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10_000 {
            second += 1
            let now = Double(second)
            let position = flat.timePos + now
            if let prior = lastEvidence, prior.generation == flat.loadGeneration, flat.playbackRequested {
                let elapsed = now - prior.time
                if flat.isBuffering { healthy -= 0 }
                if flat.isPlaying || !flat.isLoading, !flat.isBuffering, flat.mediaInfo.width <= 0,
                   position - prior.position >= 0.25 { healthy += elapsed }
            }
            lastEvidence = (now, position, flat.loadGeneration)
            _ = monitor.sample(position: position, now: now, playbackRequested: flat.playbackRequested,
                               isPlaying: flat.isPlaying, isLoading: flat.isLoading, isBuffering: flat.isBuffering)
        }
        sampleTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 10_000)
    }
    var sampleAllocs = 0
    sampleAllocs = countAllocations {
        for _ in 0..<1_000 {
            second += 1
            _ = monitor.sample(position: flat.timePos + Double(second), now: Double(second),
                               playbackRequested: flat.playbackRequested, isPlaying: flat.isPlaying,
                               isLoading: flat.isLoading, isBuffering: flat.isBuffering)
            _ = flat.mediaInfo.width
        }
    }

    func f(_ value: Double) -> String { String(format: "%.1f", value) }
    func g(_ value: Double) -> String { String(format: "%.2f", value) }
    print("dispatch 10k steady-state events (\(drains.count) drains), median of 9:")
    print("  legacy  \(f(legacyNs / 1_000)) us  \(f(legacyNs / eventCount)) ns/event  \(g(Double(legacyAllocs) / eventCount)) allocs/event (\(legacyAllocs) total)")
    print("  flat    \(f(flatNs / 1_000)) us  \(f(flatNs / eventCount)) ns/event  \(g(Double(flatAllocs) / eventCount)) allocs/event (\(flatAllocs) total)")
    print("  speedup \(f(legacyNs / flatNs))x")
    print("property request burst (32 seeds + 32 replies + reset), median of 9:")
    print("  legacy  \(f(legacyBurst)) ns   flat \(f(flatBurst)) ns   speedup \(f(legacyBurst / flatBurst))x")
    print("  request-table allocs per load (32 inserts + clear): legacy \(g(Double(legacyTableAllocs) / 100))  flat \(g(Double(flatTableAllocs) / 100))")
    print("per-second telemetry sample: \(f(median(sampleTimes))) ns/sample, \(sampleAllocs) allocs per 1000 samples (healthy=\(healthy > 0))")
}
