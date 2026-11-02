import AppKit
import AVFoundation
import AVKit

final class NativeProbePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// Standalone architecture experiment, not an app engine replacement.
// Uses the same generated HLS server and sample schema as Buffer validation.
@MainActor
final class NativePlayerProbe: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var player: AVPlayer!
    private var item: AVPlayerItem!
    private var videoLayer: AVPlayerLayer!
    private var timer: Timer?
    private var start = ContinuousClock.now
    private var didStart = false
    private var firstVideoMs: Int?
    private var seconds = 30
    private var forwardBuffer = 5.0

    private func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    private func emit(_ fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(Data("BUFFER_PLAYBACK_JSON ".utf8))
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let raw = argument("--validate-url"), let url = URL(string: raw) else { exit(1) }
        seconds = Int(argument("--validate-seconds") ?? "30") ?? 30
        forwardBuffer = Double(argument("--validate-buffer") ?? "5") ?? 5
        window = NativeProbePanel(contentRect: NSRect(x: 0, y: 0, width: 854, height: 480),
                          styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        (window as? NSPanel)?.hidesOnDeactivate = false
        window.title = "Buffer Native Playback Probe"
        window.center()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 854, height: 480))
        view.wantsLayer = true
        window.contentView = view
        item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = forwardBuffer
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        videoLayer = AVPlayerLayer(player: player)
        videoLayer.videoGravity = .resizeAspect
        videoLayer.frame = view.bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(videoLayer)
        window.orderFrontRegardless()
        start = .now
        emit(["event": "start", "seconds": seconds, "bufferSeconds": forwardBuffer, "engine": "avplayer"])
        player.play()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    private func sample() {
        let elapsed = start.duration(to: .now).components
        let ms = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        let position = player.currentTime().seconds
        let ready = videoLayer.isReadyForDisplay
        if ready && firstVideoMs == nil { firstVideoMs = ms }
        if player.timeControlStatus == .playing { didStart = true }
        var cache = 0.0
        for range in item.loadedTimeRanges {
            let timeRange = range.timeRangeValue
            if timeRange.start.seconds <= position && CMTimeRangeGetEnd(timeRange).seconds >= position {
                cache = max(cache, CMTimeRangeGetEnd(timeRange).seconds - position)
            }
        }
        let logs = item.accessLog()?.events ?? []
        let drops = logs.reduce(0) { $0 + max(0, $1.numberOfDroppedVideoFrames) }
        let stalls = logs.reduce(0) { $0 + max(0, $1.numberOfStalls) }
        let size = item.presentationSize
        emit([
            "event": "sample", "engine": "avplayer", "elapsedMs": ms, "generation": 1,
            "time": position.isFinite ? position : 0, "cache": cache,
            "rendered": ready, "loading": !ready,
            "buffering": didStart && player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
            "playing": player.timeControlStatus == .playing,
            "frameDrops": drops, "decoderDrops": 0, "mistimed": 0, "delayed": 0,
            "dropMetricsAvailable": !logs.isEmpty,
            "decoderDropsAvailable": false, "avSyncAvailable": false,
            "reportedStalls": stalls, "cacheFloorPauses": 0,
            "startupMs": firstVideoMs ?? -1, "recoveryReloads": 0,
            "playlistFails": item.errorLog()?.events.count ?? 0,
            "http509": 0, "width": Int(size.width), "height": Int(size.height),
            "audioOutput": "avplayer", "avSyncSeconds": NSNull(),
            "liveLatencySeconds": item.currentDate().map { Date().timeIntervalSince($0) } as Any? ?? NSNull(),
            "error": item.error?.localizedDescription ?? ""
        ])
        if ms >= seconds * 1000 {
            emit(["event": "end", "elapsedMs": ms])
            timer?.invalidate()
            player.pause()
            NSApplication.shared.terminate(nil)
        }
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let probe = NativePlayerProbe()
    application.setActivationPolicy(.accessory)
    application.delegate = probe
    application.run()
}
