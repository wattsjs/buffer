import Foundation

private func fixture(_ width: Int = 1920, codec: String = "h264") -> StreamProbe {
    StreamProbe(status: .ok, probedAt: Date(), probeSeconds: 0.1,
                width: width, height: width == 3840 ? 2160 : 1080, fps: 50,
                videoCodec: codec, audioCodec: "aac", audioChannels: 2, sampleRate: 48000,
                bitRate: 0, hasVideo: true, hasAudio: true, errorMessage: nil)
}

/// Controllable real blocking boundary: queue/lifecycle behavior remains in
/// StreamProbeService. No URL leaves the process and no provider IO occurs.
private final class ProbeIO: @unchecked Sendable {
    private let condition = NSCondition()
    private var released: Set<String> = []
    private var calls: [String] = []
    private var live = 0
    private var peakValue = 0
    var peak: Int { condition.lock(); defer { condition.unlock() }; return peakValue }
    private var cache: [String: [String: StreamProbe]] = [:]
    private var heldLoads: Set<String> = []
    private var loadCalls: [String] = []
    private var saves: [(String, [String: StreamProbe])] = []
    private var holdSaves = false
    private var liveSaves = 0
    private var peakSavesValue = 0
    var peakSaves: Int { condition.lock(); defer { condition.unlock() }; return peakSavesValue }

    func probe(_ url: String) -> StreamProbe {
        condition.lock()
        calls.append(url); live += 1; peakValue = max(peakValue, live)
        condition.broadcast()
        while !released.contains(url) { condition.wait() }
        live -= 1
        condition.unlock()
        return fixture()
    }
    func release(_ url: String) { condition.lock(); released.insert(url); condition.broadcast(); condition.unlock() }
    func called(_ url: String) -> Bool { condition.lock(); defer { condition.unlock() }; return calls.contains(url) }
    var count: Int { condition.lock(); defer { condition.unlock() }; return calls.count }
    func holdLoad(_ key: String, value: [String: StreamProbe]) {
        condition.lock(); heldLoads.insert(key); cache[key] = value; condition.unlock()
    }
    func load(_ key: String, _ legacy: [String]) -> [String: StreamProbe]? {
        condition.lock(); defer { condition.unlock() }
        loadCalls.append(key)
        let captured = cache[key]
        condition.broadcast()
        while heldLoads.contains(key) { condition.wait() }
        return captured
    }
    func releaseLoad(_ key: String) { condition.lock(); heldLoads.remove(key); condition.broadcast(); condition.unlock() }
    func loaded(_ key: String) -> Bool { condition.lock(); defer { condition.unlock() }; return loadCalls.contains(key) }
    func save(_ value: [String: StreamProbe], _ key: String) {
        condition.lock(); liveSaves += 1; peakSavesValue = max(peakSavesValue, liveSaves)
        saves.append((key, value)); condition.broadcast()
        while holdSaves { condition.wait() }
        cache[key] = value; liveSaves -= 1; condition.unlock()
    }
    func holdWrites() { condition.lock(); holdSaves = true; condition.unlock() }
    func releaseWrites() { condition.lock(); holdSaves = false; condition.broadcast(); condition.unlock() }
    var saveCount: Int { condition.lock(); defer { condition.unlock() }; return saves.count }
    func lastSave(_ key: String) -> [String: StreamProbe]? {
        condition.lock(); defer { condition.unlock() }; return saves.last { $0.0 == key }?.1
    }
}

@MainActor private final class ProbeGate {
    var enabled = true
    var playing = true
}

@main struct StreamProbeTests {
    @MainActor static func wait(_ message: String, until condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        fatalError("Timed out: \(message)")
    }
    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(35)) }
    static func channel(_ id: String, _ source: String = "a") -> Channel {
        Channel(id: id, name: "Fixture", logoURL: nil, group: "Fixture",
                streamURL: URL(string: "https://fixture.invalid/\(source)/\(id)")!, epgChannelID: nil)
    }
    @MainActor private static func service(_ io: ProbeIO, enabled: @escaping @MainActor () -> Bool = { true },
                                   playing: @escaping @MainActor () -> Bool = { false }) -> StreamProbeService {
        StreamProbeService(isEnabled: enabled, hasPlaybackSessions: playing,
                           runProbe: io.probe, loadCache: io.load, saveCache: io.save,
                           saveDelay: .milliseconds(12), retryDelay: .milliseconds(4))
    }
    @MainActor static func playback(_ service: StreamProbeService, id: String, width: Int = 3840) {
        service.recordPlaybackInfo(channelID: id, width: width, height: width == 3840 ? 2160 : 1080,
                                   fps: 60, videoCodec: "hevc", audioCodec: "", audioChannels: 0,
                                   liveLatencySeconds: nil)
    }
    @MainActor static func main() async {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }

        // Old pending IDs must not prevent the same IDs from being queued in
        // another source; the uncancellable old call retains the only slot.
        do {
            let io = ProbeIO(), s = service(io)
            let old = channel("shared"), abandoned = channel("pending"), new = channel("pending", "b")
            s.setActiveCacheKey("a"); s.requestProbe(for: old)
            await wait("old active", until: { io.called(old.streamURL.absoluteString) })
            s.requestProbe(for: abandoned)
            s.setActiveCacheKey("b"); s.requestProbe(for: new)
            await settle(); check(io.count == 1, "source change launched a second concurrent probe")
            io.release(old.streamURL.absoluteString)
            await wait("new source pending ID", until: { io.called(new.streamURL.absoluteString) })
            check(s.probe(for: "shared") == nil, "retired source published a result")
            check(!io.called(abandoned.streamURL.absoluteString), "abandoned queue opened old source")
            io.release(new.streamURL.absoluteString)
            await wait("new result", until: { s.probe(for: "pending") != nil })
            check(io.peak == 1, "probe concurrency exceeded one")
        }

        // Clear retires both pending and active results, including old cache
        // loads; a new explicit request can use the same ID again.
        do {
            let io = ProbeIO(), s = service(io), c = channel("clear")
            io.holdLoad("a", value: ["cached": fixture()])
            s.setActiveCacheKey("a"); s.requestProbe(for: c)
            await wait("clear active", until: { io.called(c.streamURL.absoluteString) && io.loaded("a") })
            s.requestProbe(for: channel("discarded")); s.clearAll()
            io.release(c.streamURL.absoluteString); io.releaseLoad("a")
            await settle()
            check(s.probe(for: "clear") == nil && s.probe(for: "cached") == nil, "clear was undone by old IO")
            check(io.count == 1, "clear retained pending work")
            s.requestProbe(for: c)
            await wait("re-request after clear", until: { io.count == 2 && s.probe(for: "clear") != nil })
            check(io.peak == 1, "clear released active slot too early")
        }

        // Disabled pending work is dropped at dequeue; disabled active
        // results cannot publish even without a Settings clear callback.
        do {
            let gate = ProbeGate()
            let io = ProbeIO(), s = service(io, enabled: { gate.enabled }, playing: { gate.playing })
            let c = channel("disabled")
            s.setActiveCacheKey("a"); s.requestProbe(for: c)
            await settle(); check(io.count == 0, "probe opened during a player session")
            gate.enabled = false; gate.playing = false
            await settle(); gate.enabled = true
            await settle(); check(io.count == 0, "disabled queued request survived")
            s.requestProbe(for: c)
            await wait("enabled request", until: { io.called(c.streamURL.absoluteString) })
            gate.enabled = false; io.release(c.streamURL.absoluteString)
            await settle(); check(s.probe(for: c.id) == nil, "disabled active result published")
            gate.enabled = true; s.requestProbe(for: c)
            await wait("enabled again", until: { io.count == 2 && s.probe(for: c.id) != nil })
        }

        // Pending probes wait while a player exists and recheck freshness
        // after actual playback has supplied metadata for the same channel.
        do {
            let gate = ProbeGate()
            let io = ProbeIO(), s = service(io, playing: { gate.playing }), c = channel("played")
            s.requestProbe(for: c); await settle()
            check(io.count == 0, "request without a cache scope opened a probe")
            s.setActiveCacheKey("a"); s.requestProbe(for: c); s.requestProbe(for: c)
            playback(s, id: c.id); gate.playing = false
            await settle(); check(io.count == 0, "probe ignored authoritative fresh playback metadata")
            let next = channel("resume")
            gate.playing = true; s.requestProbe(for: next)
            await settle(); check(io.count == 0, "paused/reconnecting session consumed a probe connection")
            gate.playing = false
            await wait("queue resumes when sessions close", until: { io.called(next.streamURL.absoluteString) })
            io.release(next.streamURL.absoluteString)
            await wait("resumed result", until: { s.probe(for: next.id) != nil })
            check(io.count == 1, "duplicate or player-overlap request opened extra connections")
        }

        // Cache publication must merge with live updates already received,
        // and source A -> B -> A must reject the first A generation's load.
        do {
            let io = ProbeIO(), s = service(io)
            io.holdLoad("a", value: ["same": fixture(), "cached": fixture()])
            s.setActiveCacheKey("a")
            await wait("held load", until: { io.loaded("a") })
            playback(s, id: "same"); s.recordStreamHealthEvent(channelID: "same", event: .reconnect)
            io.releaseLoad("a")
            await wait("merged cache", until: { s.probe(for: "cached") != nil })
            check(s.probe(for: "same")?.width == 3840, "disk load overwrote playback metadata")
            check(s.probe(for: "same")?.audioCodec == "aac", "cache missing fields were lost")
            check(s.probe(for: "same")?.streamHealth.reconnectCount == 1, "cache lost playback health")
        }
        do {
            let io = ProbeIO(), s = service(io)
            io.holdLoad("a", value: ["old": fixture()])
            s.setActiveCacheKey("a")
            await wait("first A load", until: { io.loaded("a") })
            s.setActiveCacheKey("b"); playback(s, id: "b")
            s.setActiveCacheKey("a"); s.clearAll(); playback(s, id: "new")
            io.releaseLoad("a"); await settle()
            check(s.probe(for: "old") == nil && s.probe(for: "b") == nil, "ABA source switch accepted old cache generation")
            check(s.probe(for: "new")?.width == 3840, "ABA source switch lost current generation")
        }

        // Actual playback is newer authority than an earlier background probe.
        do {
            let io = ProbeIO(), s = service(io), c = channel("live-update")
            s.setActiveCacheKey("a"); s.requestProbe(for: c)
            await wait("probe before live update", until: { io.called(c.streamURL.absoluteString) })
            playback(s, id: c.id); s.recordStreamHealthEvent(channelID: c.id, event: .http509)
            io.release(c.streamURL.absoluteString); await settle()
            check(s.probe(for: c.id)?.width == 3840 && s.probe(for: c.id)?.fps == 60, "probe overwrote live playback metadata")
            check(s.probe(for: c.id)?.streamHealth.http509Count == 1, "probe erased playback health")
        }

        // Coalesced writes capture the newest state and keep source keys.
        do {
            let io = ProbeIO(), s = service(io)
            s.setActiveCacheKey("a"); playback(s, id: "one", width: 1920); playback(s, id: "one")
            playback(s, id: "two")
            s.setActiveCacheKey("b"); playback(s, id: "b")
            s.setActiveCacheKey("a")
            check(s.probe(for: "one")?.width == 3840, "unsaved source state lost on quick switch")
            await wait("two source saves", until: { io.lastSave("a") != nil && io.lastSave("b") != nil })
            check(io.lastSave("a")?["one"]?.width == 3840 && io.lastSave("a")?["two"] != nil, "coalescing captured first snapshot")
            check(io.lastSave("a")?["b"] == nil && io.lastSave("b")?["one"] == nil, "save crossed source scope")
            s.clearAll()
            await wait("empty newest save", until: { io.lastSave("a")?.isEmpty == true })
            check(io.lastSave("a")?.isEmpty == true, "clear did not persist empty snapshot")
        }

        // Writes already inside IO remain ordered; a mutation during IO is
        // persisted in a second pass, without overwriting a newer snapshot.
        do {
            let io = ProbeIO(), s = service(io)
            io.holdWrites(); s.setActiveCacheKey("a"); playback(s, id: "one", width: 1920)
            await wait("first write started", until: { io.saveCount == 1 })
            playback(s, id: "one"); s.setActiveCacheKey("b"); s.setActiveCacheKey("a")
            check(s.probe(for: "one")?.width == 3840, "switch during write lost dirty newest snapshot")
            io.releaseWrites()
            await wait("second write", until: { io.lastSave("a")?["one"]?.width == 3840 })
            check(io.peakSaves == 1, "cache IO ran concurrently and could reorder snapshots")
        }
        // Ephemeral leases retain user state and badges, keep already-open
        // C work visible until it returns, and gate every subsequent launch.
        do {
            let gate = ProbeGate(); gate.playing = false
            let io = ProbeIO(), s = service(io, enabled: { gate.enabled }, playing: { gate.playing })
            let active = channel("lease-active"), queued = channel("lease-queued")
            s.setActiveCacheKey("a"); playback(s, id: "badge")
            s.requestProbe(for: active)
            await wait("lease existing probe", until: { io.called(active.streamURL.absoluteString) })
            check(s.isProbeRunning && s.probeRunningCount == 1, "running diagnostic did not expose active C work")
            let outer = s.suspendProbing(), inner = s.suspendProbing()
            s.requestProbe(for: queued)
            await settle()
            check(gate.enabled && s.probe(for: "badge")?.width == 3840, "suspension mutated user setting or cleared badges")
            check(s.isProbeRunning && io.count == 1, "suspension hid uncancellable C work or opened another probe")
            io.release(active.streamURL.absoluteString)
            await wait("lease existing probe closes", until: { !s.isProbeRunning })
            check(s.probeRunningCount == 0 && s.probe(for: active.id) != nil, "lease rejected valid completed metadata or retained running count")
            s.resumeProbing(outer); s.resumeProbing(outer)
            await settle(); check(io.count == 1, "duplicate release bypassed nested suspension")
            s.resumeProbing(inner)
            await wait("last lease resumes retained queue", until: { io.called(queued.streamURL.absoluteString) })
            check(s.isProbeRunning && io.peak == 1, "lease resume overlapped connections")
            io.release(queued.streamURL.absoluteString)
            await wait("resumed lease probe closes", until: { !s.isProbeRunning })
            check(s.probe(for: queued.id) != nil && gate.enabled, "lease failed to preserve queue or setting")
        }
        // A lease acquired immediately after a reserved launch still gates
        // the detached pre-IO check, without dropping the request.
        do {
            let io = ProbeIO(), s = service(io), c = channel("lease-reserved")
            s.setActiveCacheKey("a"); s.requestProbe(for: c)
            let lease = s.suspendProbing()
            await wait("reserved launch retires without IO", until: { !s.isProbeRunning })
            check(io.count == 0, "suspension was ignored at detached pre-IO boundary")
            s.resumeProbing(lease)
            await wait("reserved request resumes", until: { io.called(c.streamURL.absoluteString) })
            io.release(c.streamURL.absoluteString)
            await wait("reserved result", until: { !s.isProbeRunning && s.probe(for: c.id) != nil })
            check(io.count == 1, "lease lost or duplicated the reserved request")
        }
        do {
            let sourceA = UUID(), sourceB = UUID()
            func owned(_ source: UUID) -> Channel {
                Channel(id: "same-id", name: "Fixture", logoURL: nil, group: "Tests",
                    streamURL: URL(string: "http://127.0.0.1/\(source)/same-id")!, epgChannelID: "BBCOne.uk",
                    sourceOwnership: ChannelSourceOwnership(channelIdentity: SourceChannelIdentity(sourceID: source, nativeID: "same-id"),
                        accountKey: .unconfiguredSource(source)))
            }
            let a = owned(sourceA), b = owned(sourceB), io = ProbeIO(), s = service(io)
            s.setActiveCacheKey("owned-a", sourceID: sourceA)
            io.holdLoad("owned-b", value: ["untouched": fixture()])
            s.registerSourceCacheKey(sourceID: sourceB, cacheKey: "owned-b")
            await wait("independent owned cache starts", until: { io.loaded("owned-b") })
            s.recordPlaybackInfo(channel: a, width: 1280, height: 720, fps: 50, videoCodec: "h264",
                audioCodec: "aac", audioChannels: 2, liveLatencySeconds: nil)
            s.recordPlaybackInfo(channel: b, width: 3840, height: 2160, fps: 60, videoCodec: "hevc",
                audioCodec: "aac", audioChannels: 2, liveLatencySeconds: nil)
            check(s.probe(for: a)?.width == 1280 && s.probe(for: b)?.width == 3840,
                "native-ID collision crossed source playback observations")
            check(s.probe(for: b)?.metadataProvenance == .passivePlayback && s.probe(for: b)?.metadataObservedAt != nil,
                "passive playback lacks metadata provenance and freshness")
            check(s.probe(for: a)?.endpointFingerprint == StreamProbe.endpointFingerprint(for: a.streamURL) &&
                s.probe(for: b)?.endpointFingerprint == StreamProbe.endpointFingerprint(for: b.streamURL),
                "typed passive metadata is not bound to its actual endpoint revision")
            var health = StreamHealth(); health.record(.http509)
            let metadataDate = s.probe(for: b)?.metadataObservedAt
            s.recordPlaybackHealth(channel: b, health: health, healthySeconds: 8, bufferingSeconds: 2, ordinaryLive: true)
            check(s.probe(for: a)?.streamHealth.http509Count == 0 && s.probe(for: b)?.streamHealth.http509Count == 1,
                "passive health observations crossed native-ID source ownership")
            check(s.probe(for: b)?.passivePlaybackEvidence?.healthySeconds == 8 && s.probe(for: b)?.passivePlaybackEvidence?.bufferingSeconds == 2,
                "passive evidence must retain observed duration rather than inventing reliability")
            check(s.probe(for: b)?.passivePlaybackEvidence?.ordinaryLive == true,
                "new measured health requires explicit ordinary live provenance")
            s.recordPlaybackHealth(channel: b, health: health, healthySeconds: 25, bufferingSeconds: 25)
            check(s.probe(for: b)?.passivePlaybackEvidence?.healthySeconds == 8 && s.probe(for: b)?.passivePlaybackEvidence?.bufferingSeconds == 2,
                "unqualified archive/diagnostic caller cannot alter ordinary live performance evidence")
            let encoded = try! JSONEncoder().encode(s.probe(for: b)!)
            let decoded = try! JSONDecoder().decode(StreamProbe.self, from: encoded)
            check(decoded.endpointFingerprint == StreamProbe.endpointFingerprint(for: b.streamURL) &&
                decoded.passivePlaybackEvidence?.ordinaryLive == true,
                "endpoint and ordinary live provenance must survive persistence")
            var legacy = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            legacy.removeValue(forKey: "endpointFingerprint")
            var legacyEvidence = legacy["passivePlaybackEvidence"] as! [String: Any]
            legacyEvidence.removeValue(forKey: "ordinaryLive")
            legacy["passivePlaybackEvidence"] = legacyEvidence
            let legacyDecoded = try! JSONDecoder().decode(StreamProbe.self, from: JSONSerialization.data(withJSONObject: legacy))
            check(legacyDecoded.endpointFingerprint == nil && legacyDecoded.passivePlaybackEvidence?.ordinaryLive == nil,
                "legacy performance records remain unqualified after decode")
            check(s.probe(for: b)?.metadataObservedAt == metadataDate, "network health activity incorrectly refreshed format evidence age")
            s.recordPlaybackInfo(channel: b, width: 0, height: 0, fps: 0, videoCodec: "", audioCodec: "aac",
                audioChannels: 2, liveLatencySeconds: nil)
            check(s.probe(for: b)?.metadataObservedAt == metadataDate, "partial audio observation refreshed stale video format evidence")
            await settle()
            check(io.lastSave("owned-b") == nil, "early passive observation overwrote a source cache before it loaded")
            io.releaseLoad("owned-b")
            await wait("owned snapshots persisted", until: { io.lastSave("owned-a") != nil && io.lastSave("owned-b") != nil })
            check(io.lastSave("owned-a")?["same-id"]?.width == 1280 && io.lastSave("owned-b")?["same-id"]?.width == 3840,
                "owned playback cache persisted to wrong physical source")
            check(io.lastSave("owned-b")?["untouched"] != nil, "passive source update erased unrelated cached metadata")
            var operationOnly = fixture(); operationOnly.probeSeconds = 2.3
            check(operationOnly.latencyLabel.isEmpty, "probe operation duration was presented as live latency")

            let held = try! AccountCapacityLedger.shared.reserve(for: a, kind: .recording, ownerID: UUID()).get()
            s.invalidate(channelID: a.id)
            s.requestProbe(for: a)
            await settle()
            check(!io.called(a.streamURL.absoluteString), "optional probe ignored an active recording account reservation")
            _ = AccountCapacityLedger.shared.confirmTeardown(lease: held)
            await wait("account capacity resumes queued probe", until: { io.called(a.streamURL.absoluteString) })
            check(AccountCapacityLedger.shared.snapshot(accountKey: .unconfiguredSource(sourceA)).reservationsByKind[.probe] == 1,
                "blocking probe did not reserve account capacity")
            s.clearAll()
            check(AccountCapacityLedger.shared.snapshot(accountKey: .unconfiguredSource(sourceA)).localReservations == 1,
                "probe cancellation released before its blocking IO actually closed")
            io.release(a.streamURL.absoluteString)
            await wait("owned probe closes", until: { !s.isProbeRunning })
            check(AccountCapacityLedger.shared.snapshot(accountKey: .unconfiguredSource(sourceA)).localReservations == 0,
                "completed blocking probe retained its account lease")
        }
        do {
            let source = UUID(), io = ProbeIO(), s = service(io)
            func owned(_ revision: String) -> Channel {
                Channel(id: "stable-native", name: "Revision fixture", logoURL: nil, group: "Tests",
                    streamURL: URL(string: "http://127.0.0.1/\(revision)/stable-native")!, epgChannelID: nil,
                    sourceOwnership: .init(channelIdentity: .init(sourceID: source, nativeID: "stable-native"),
                        accountKey: .unconfiguredSource(source)))
            }
            let first = owned("first"), revised = owned("revised")
            s.setActiveCacheKey("revision-fixture", sourceID: source)
            s.requestProbe(for: first)
            await wait("revision probe starts", until: { io.called(first.streamURL.absoluteString) })
            s.recordPlaybackInfo(channel: revised, width: 1280, height: 720, fps: 50,
                videoCodec: "h264", audioCodec: "aac", audioChannels: 2, liveLatencySeconds: nil)
            io.release(first.streamURL.absoluteString)
            await wait("old revision probe closes", until: { !s.isProbeRunning })
            check(s.probe(for: revised)?.endpointFingerprint == StreamProbe.endpointFingerprint(for: revised.streamURL) &&
                s.probe(for: revised)?.width == 1280,
                "late probe response replaced the current endpoint revision")
            let newer = owned("newer")
            s.recordPlaybackInfo(channel: newer, width: 0, height: 0, fps: 0,
                videoCodec: "", audioCodec: "aac", audioChannels: 2, liveLatencySeconds: nil)
            check(s.probe(for: newer)?.width == 0 && s.probe(for: newer)?.fps == 0 &&
                s.probe(for: newer)?.endpointFingerprint == StreamProbe.endpointFingerprint(for: newer.streamURL),
                "new endpoint inherited video format measurements from an obsolete URL")
            s.invalidate(channelID: newer.id)
            s.requestProbe(for: newer)
            await wait("current revision C probe starts", until: { io.called(newer.streamURL.absoluteString) })
            io.release(newer.streamURL.absoluteString)
            await wait("current revision C probe closes", until: { !s.isProbeRunning })
            check(s.probe(for: newer)?.endpointFingerprint == StreamProbe.endpointFingerprint(for: newer.streamURL) &&
                s.probe(for: newer)?.metadataProvenance == .streamProbe,
                "new C probe lacks endpoint and observation provenance")
            let encoded = try! JSONEncoder().encode(fixture())
            let legacy = try! JSONDecoder().decode(StreamProbe.self, from: encoded)
            check(legacy.endpointFingerprint == nil, "legacy probe unexpectedly acquired current endpoint evidence")
            var oldFailure = fixture(); oldFailure.status = .offline
            oldFailure.probedAt = Date().addingTimeInterval(-16 * 60)
            check(!oldFailure.isFresh, "an old failed probe blocked retry for the format cache’s seven-day lifetime")
            var future = fixture(); future.probedAt = Date().addingTimeInterval(60)
            check(!future.isFresh, "future probe timestamps were accepted as current evidence")
        }
        // Owned probes on different accounts run in parallel (each within
        // its own account lease); another source's result lands only in that
        // source's own cache.
        do {
            let sourceA = UUID(), sourceB = UUID()
            func owned(_ source: UUID, _ id: String) -> Channel {
                Channel(id: id, name: "Fixture", logoURL: nil, group: "Tests",
                    streamURL: URL(string: "http://127.0.0.1/\(source)/\(id)")!, epgChannelID: nil,
                    sourceOwnership: ChannelSourceOwnership(channelIdentity: SourceChannelIdentity(sourceID: source, nativeID: id),
                        accountKey: .unconfiguredSource(source)))
            }
            let io = ProbeIO(), s = service(io)
            s.setActiveCacheKey("parallel-a", sourceID: sourceA)
            s.registerSourceCacheKey(sourceID: sourceB, cacheKey: "parallel-b")
            await wait("other source cache loaded", until: { io.loaded("parallel-b") })
            await settle()
            let a = owned(sourceA, "pa"), b = owned(sourceB, "pb")
            s.requestProbe(for: a); s.requestProbe(for: b)
            await wait("both accounts probing", until: { io.called(a.streamURL.absoluteString) && io.called(b.streamURL.absoluteString) })
            check(io.peak == 2, "independent accounts did not probe in parallel")
            io.release(a.streamURL.absoluteString); io.release(b.streamURL.absoluteString)
            await wait("cross-source result", until: { s.probe(for: b) != nil && s.probe(for: a) != nil })
            await wait("other source persisted", until: { io.lastSave("parallel-b")?["pb"] != nil })
            check(io.lastSave("parallel-a")?["pb"] == nil, "another source's probe was written to the active cache")
        }

        // Player-measured bitrate is smoothed into the endpoint's record and
        // never applied to a different endpoint revision.
        do {
            let source = UUID()
            func owned(_ url: String) -> Channel {
                Channel(id: "br", name: "Fixture", logoURL: nil, group: "Tests",
                    streamURL: URL(string: url)!, epgChannelID: nil,
                    sourceOwnership: ChannelSourceOwnership(channelIdentity: SourceChannelIdentity(sourceID: source, nativeID: "br"),
                        accountKey: .unconfiguredSource(source)))
            }
            let io = ProbeIO(), s = service(io)
            s.setActiveCacheKey("bitrate", sourceID: source)
            let live = owned("http://127.0.0.1/br/a")
            s.recordPlaybackInfo(channel: live, width: 1920, height: 1080, fps: 50, videoCodec: "h264",
                audioCodec: "aac", audioChannels: 2, liveLatencySeconds: nil)
            s.recordPlaybackBitrate(channel: live, bitsPerSecond: 8_000_000)
            check(s.probe(for: live)?.bitRate == 8_000_000, "first bitrate sample not stored")
            s.recordPlaybackBitrate(channel: live, bitsPerSecond: 4_000_000)
            check(s.probe(for: live)?.bitRate == 7_000_000, "bitrate samples not smoothed")
            s.recordPlaybackBitrate(channel: owned("http://127.0.0.1/br/rotated"), bitsPerSecond: 1_000_000)
            check(s.probe(for: live)?.bitRate == 7_000_000, "another endpoint revision changed this bitrate")
        }

        // A known multi-connection account keeps a slot free for playback;
        // an outdated status (ledger assumes one connection) pauses probing.
        do {
            let source = UUID()
            let account = SourceAccountKey(opaqueValue: "probe-headroom-\(source)")
            func owned(_ id: String) -> Channel {
                Channel(id: id, name: "Fixture", logoURL: nil, group: "Tests",
                    streamURL: URL(string: "http://127.0.0.1/hr/\(id)")!, epgChannelID: nil,
                    sourceOwnership: ChannelSourceOwnership(channelIdentity: SourceChannelIdentity(sourceID: source, nativeID: id),
                        accountKey: account))
            }
            let io = ProbeIO(), s = service(io)
            var staleRequests = 0
            s.onCapacityStatusStale = { _ in staleRequests += 1 }
            s.setActiveCacheKey("headroom", sourceID: source)
            AccountCapacityLedger.shared.updateStatus(accountKey: account, maxConnections: 4, activeConnections: nil,
                                                      observedAt: Date().addingTimeInterval(-600))
            s.requestProbe(for: owned("h0"))
            await settle()
            check(io.count == 0 && staleRequests > 0, "stale account status still started a probe")
            AccountCapacityLedger.shared.updateStatus(accountKey: account, maxConnections: 4, activeConnections: nil, observedAt: Date())
            for i in 1...3 { s.requestProbe(for: owned("h\(i)")) }
            s.retryQueuedProbes()
            await wait("fresh account probes", until: { io.count >= 2 })
            await settle()
            check(io.peak == 2, "more than two probes ran on one account")
            check(AccountCapacityLedger.shared.snapshot(accountKey: account).available >= 1, "probes took the last free connection")
            for i in 0...3 { io.release(owned("h\(i)").streamURL.absoluteString) }
            await wait("headroom probes drained", until: { io.count == 4 })
        }

        print("PASS \(checks) real StreamProbeService lifecycle checks: source generations, clear/disable, playback exclusion, cache merging and ordered newest snapshots")
    }
}
