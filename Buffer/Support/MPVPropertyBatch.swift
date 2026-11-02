/// Flat, allocation-free storage for the mpv property-change hot path.
/// Kept independent of libmpv so the dispatch kernel can be benchmarked and
/// tested standalone (`benchmarks/mpv_property_dispatch_benchmark.swift`).

/// mpv's `mpv_format` ABI codes (client.h). `MPVPlayer` asserts these match
/// the imported constants once at handle setup.
nonisolated enum MPVFormatCode {
    static let string: UInt32 = 1
    static let flag: UInt32 = 3
    static let int64: UInt32 = 4
    static let double: UInt32 = 5
}

/// Every property MPVPlayer observes or reads. The raw value is the mpv
/// `reply_userdata` for observations and the slot index in
/// `MPVPropertyBatch`, so dispatch is a range check plus an array index.
nonisolated enum MPVProperty: UInt8, CaseIterable, Sendable {
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

    static let slotCount = 33

    @inline(__always) var bit: UInt64 { 1 &<< UInt64(rawValue) }
    @inline(__always) var userdata: UInt64 { UInt64(rawValue) }

    /// Properties of the mpv handle rather than of the playlist entry; they
    /// are accepted even while no item is active.
    static let handleMask: UInt64 = MPVProperty.pause.bit | MPVProperty.volume.bit | MPVProperty.mute.bit

    @inline(__always) var isHandleProperty: Bool { Self.handleMask & bit != 0 }

    /// Observation/request userdata → property, without a switch.
    @inline(__always) static func from(userdata: UInt64) -> MPVProperty? {
        guard userdata &- 1 < UInt64(slotCount - 1) else { return nil }
        return MPVProperty(rawValue: UInt8(truncatingIfNeeded: userdata))
    }
}

/// One drain's worth of coalesced property changes, structure-of-arrays:
/// a presence bitmask, a "present but unavailable" bitmask, and one raw
/// 64-bit payload word per property (Double bit pattern, Int64, or 0/1 flag).
/// Strings are the only heap values and only arrive for codec/device names.
///
/// Semantics mirror the former `PendingChanges` optionals exactly:
/// `has(p)` == the old field was non-nil; `isUnavailable(p)` == the old
/// double-optional held `.some(nil)` (or, for single optionals that were
/// assigned a nil observation, the field was cleared).
nonisolated struct MPVPropertyBatch {
    private(set) var present: UInt64 = 0
    private(set) var unavailable: UInt64 = 0
    private var words = InlineArray<33, UInt64>(repeating: 0)
    private(set) var videoCodec = ""
    private(set) var audioCodec = ""
    private(set) var hwdec = ""
    private(set) var audioOutput = ""
    private(set) var lavfProbeInfo = ""

    init() {}

    @inline(__always) var isEmpty: Bool { present == 0 }
    @inline(__always) func has(_ property: MPVProperty) -> Bool { present & property.bit != 0 }
    @inline(__always) func hasAny(_ mask: UInt64) -> Bool { present & mask != 0 }
    @inline(__always) func isUnavailable(_ property: MPVProperty) -> Bool { unavailable & property.bit != 0 }

    @inline(__always) func double(_ property: MPVProperty) -> Double {
        Double(bitPattern: words[Int(property.rawValue)])
    }
    @inline(__always) func int64(_ property: MPVProperty) -> Int64 {
        Int64(bitPattern: words[Int(property.rawValue)])
    }
    @inline(__always) func flag(_ property: MPVProperty) -> Bool { words[Int(property.rawValue)] != 0 }
    /// Present value for a double-optional field; nil means "present, unavailable".
    @inline(__always) func optionalDouble(_ property: MPVProperty) -> Double? {
        isUnavailable(property) ? nil : double(property)
    }

    @inline(__always) mutating func reset() {
        present = 0
        unavailable = 0
    }

    @inline(__always) private mutating func store(_ property: MPVProperty, _ word: UInt64) {
        words[Int(property.rawValue)] = word
        present |= property.bit
        unavailable &= ~property.bit
    }

    @inline(__always) private mutating func storeUnavailable(_ property: MPVProperty) {
        present |= property.bit
        unavailable |= property.bit
    }

    @inline(__always) private mutating func clear(_ property: MPVProperty) {
        present &= ~property.bit
        unavailable &= ~property.bit
    }

    @inline(__always) private mutating func storeDouble(_ property: MPVProperty, _ value: Double) {
        store(property, value.bitPattern)
    }

    @inline(__always) private mutating func storeOptionalDouble(_ property: MPVProperty, _ value: Double?) {
        if let value { storeDouble(property, value) } else { storeUnavailable(property) }
    }

    // MARK: Decoding (mpv_event_property payload)

    @inline(__always) static func flagValue(format: UInt32, data: UnsafeRawPointer?) -> Bool? {
        guard format == MPVFormatCode.flag, let data else { return nil }
        return data.load(as: Int32.self) != 0
    }

    @inline(__always) static func int64Value(format: UInt32, data: UnsafeRawPointer?) -> Int64 {
        guard format == MPVFormatCode.int64, let data else { return 0 }
        return data.load(as: Int64.self)
    }

    @inline(__always) static func doubleValue(format: UInt32, data: UnsafeRawPointer?) -> Double? {
        guard format == MPVFormatCode.double, let data else { return nil }
        return data.load(as: Double.self)
    }

    @inline(__always) static func finiteDouble(format: UInt32, data: UnsafeRawPointer?) -> Double? {
        guard let value = doubleValue(format: format, data: data), value.isFinite else { return nil }
        return value
    }

    static func stringValue(format: UInt32, data: UnsafeRawPointer?) -> String {
        guard format == MPVFormatCode.string, let data,
              let cString = data.load(as: UnsafePointer<CChar>?.self) else { return "" }
        return String(cString: cString)
    }

    /// Records one property payload, overwriting an earlier one from the same
    /// drain. Identical to the former `collectProperty` field assignments.
    mutating func collect(_ property: MPVProperty, format: UInt32, data: UnsafeRawPointer?) {
        switch property {
        case .pause, .pausedForCache, .mute, .seekable:
            if let value = Self.flagValue(format: format, data: data) { store(property, value ? 1 : 0) }
        case .width, .height, .audioChannels:
            store(property, UInt64(bitPattern: Self.int64Value(format: format, data: data)))
        case .audioSampleRate:
            store(property, UInt64(bitPattern: max(0, Self.int64Value(format: format, data: data))))
        case .fps, .estimatedFps:
            storeDouble(property, Self.doubleValue(format: format, data: data) ?? 0)
        case .volume, .duration:
            if let value = Self.doubleValue(format: format, data: data) { storeDouble(property, value) }
        case .videoCodec:
            videoCodec = Self.stringValue(format: format, data: data)
            store(property, 0)
        case .audioCodec:
            audioCodec = Self.stringValue(format: format, data: data)
            store(property, 0)
        case .hwdec:
            hwdec = Self.stringValue(format: format, data: data)
            store(property, 0)
        case .cacheSeconds, .avSync, .demuxerStartTime:
            storeOptionalDouble(property, Self.finiteDouble(format: format, data: data))
        case .timePos:
            // The former `Double?` field was assigned the observation itself,
            // so an unavailable reading cleared an earlier one in the batch.
            if let value = Self.finiteDouble(format: format, data: data) {
                storeDouble(property, value)
            } else {
                clear(property)
            }
        case .videoPTS:
            break // Sampled by the caller; never part of the published state.
        case .videoBitrate, .audioBitrate, .frameDrops, .decoderFrameDrops, .delayedFrames, .mistimedFrames:
            store(property, UInt64(bitPattern: Self.int64Value(format: format, data: data)))
        case .audioOutput:
            let value = Self.stringValue(format: format, data: data)
            if value.isEmpty {
                storeUnavailable(property)
            } else {
                audioOutput = value
                store(property, 0)
            }
        case .cachePauseInitial:
            if let value = Self.flagValue(format: format, data: data) {
                store(property, value ? 1 : 0)
            } else {
                storeUnavailable(property)
            }
        case .cachePauseWait, .lavfAnalyzeDuration:
            storeOptionalDouble(property, Self.finiteDouble(format: format, data: data).flatMap { $0 >= 0 ? $0 : nil })
        case .lavfProbeSize:
            let value = Self.int64Value(format: format, data: data)
            if format == MPVFormatCode.int64, data != nil, value > 0 {
                store(property, UInt64(bitPattern: value))
            } else {
                storeUnavailable(property)
            }
        case .lavfProbeInfo:
            let value = Self.stringValue(format: format, data: data)
            switch value {
            case "auto", "yes", "no", "nostreams":
                lavfProbeInfo = value
                store(property, 0)
            default:
                storeUnavailable(property)
            }
        }
    }

    // Field groups used by the apply step to skip whole sections.
    static let telemetryMask: UInt64 = MPVProperty.pause.bit | MPVProperty.pausedForCache.bit
        | MPVProperty.audioOutput.bit | MPVProperty.avSync.bit | MPVProperty.demuxerStartTime.bit
        | MPVProperty.cachePauseInitial.bit | MPVProperty.cachePauseWait.bit
        | MPVProperty.lavfAnalyzeDuration.bit | MPVProperty.lavfProbeSize.bit | MPVProperty.lavfProbeInfo.bit
    static let mediaInfoMask: UInt64 = MPVProperty.width.bit | MPVProperty.height.bit
        | MPVProperty.videoCodec.bit | MPVProperty.audioCodec.bit | MPVProperty.audioChannels.bit
        | MPVProperty.audioSampleRate.bit | MPVProperty.hwdec.bit
    static let statsMask: UInt64 = MPVProperty.fps.bit | MPVProperty.estimatedFps.bit
        | MPVProperty.videoBitrate.bit | MPVProperty.audioBitrate.bit | MPVProperty.frameDrops.bit
        | MPVProperty.decoderFrameDrops.bit | MPVProperty.delayedFrames.bit | MPVProperty.mistimedFrames.bit
}

/// Outstanding `mpv_get_property_async` reads, replacing a
/// `[UInt64: (generation, item, property)]` dictionary. The request ID keeps
/// its former layout (`1 << 62 | serial`); the slot is `serial & mask`.
/// At most ~26 reads are in flight per load (the FILE_LOADED seed burst plus
/// two coalesced diagnostic clocks) and every load clears the ring, so a
/// 64-slot ring cannot evict a live request. An evicted request (only
/// possible beyond 64 concurrent reads) has its reply ignored.
nonisolated struct MPVPropertyRequestRing {
    struct Request: Equatable {
        let generation: Int
        let item: MPVItemLifecycle.Identity?
        let property: MPVProperty
    }

    static let capacity = 64
    private static let mask: UInt64 = 63
    static let requestTag: UInt64 = 1 << 62

    private var serials = InlineArray<64, UInt64>(repeating: 0)
    private var generations = InlineArray<64, Int>(repeating: 0)
    private var itemGenerations = InlineArray<64, Int>(repeating: 0)
    private var itemEntries = InlineArray<64, Int64>(repeating: 0)
    private var properties = InlineArray<64, UInt8>(repeating: 0)
    private var occupied: UInt64 = 0
    private var hasItem: UInt64 = 0
    private var serial: UInt64 = 0

    init() {}

    var count: Int { occupied.nonzeroBitCount }

    /// Reserves a slot and returns the mpv request ID.
    mutating func insert(generation: Int, item: MPVItemLifecycle.Identity?, property: MPVProperty) -> UInt64 {
        serial &+= 1
        let slot = Int(serial & Self.mask)
        let bit: UInt64 = 1 &<< UInt64(slot)
        serials[slot] = serial
        generations[slot] = generation
        properties[slot] = property.rawValue
        if let item {
            itemGenerations[slot] = item.generation
            itemEntries[slot] = item.playlistEntryID
            hasItem |= bit
        } else {
            hasItem &= ~bit
        }
        occupied |= bit
        return Self.requestTag | serial
    }

    private func slot(for requestID: UInt64) -> Int? {
        guard requestID & Self.requestTag != 0 else { return nil }
        let requestSerial = requestID & ~Self.requestTag
        let slot = Int(requestSerial & Self.mask)
        guard occupied & (1 &<< UInt64(slot)) != 0, serials[slot] == requestSerial else { return nil }
        return slot
    }

    /// Removes and returns the request for a GET_PROPERTY reply.
    mutating func remove(requestID: UInt64) -> Request? {
        guard let slot = slot(for: requestID) else { return nil }
        let bit: UInt64 = 1 &<< UInt64(slot)
        occupied &= ~bit
        guard let property = MPVProperty(rawValue: properties[slot]) else { return nil }
        let item: MPVItemLifecycle.Identity? = hasItem & bit != 0
            ? MPVItemLifecycle.Identity(generation: itemGenerations[slot], playlistEntryID: itemEntries[slot])
            : nil
        return Request(generation: generations[slot], item: item, property: property)
    }

    mutating func cancel(requestID: UInt64) {
        guard let slot = slot(for: requestID) else { return }
        occupied &= ~(1 &<< UInt64(slot))
    }

    mutating func removeAll() {
        occupied = 0
    }

    func containsPending(generation: Int, property: MPVProperty) -> Bool {
        var remaining = occupied
        while remaining != 0 {
            let slot = remaining.trailingZeroBitCount
            remaining &= remaining &- 1
            if generations[slot] == generation, properties[slot] == property.rawValue { return true }
        }
        return false
    }
}
