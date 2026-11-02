import Foundation

/// Probe settings are attached to the actual playlist entry, including the
/// baseline and local recording path, so a retained handle cannot leak a trial.
nonisolated struct MPVLoadProbeOptions: Equatable, Sendable {
    let probeSize: Int
    let analyzeDurationSeconds: Double
    let probeInfo: String
    let liveAnalysisRequestedSeconds: Double?

    static let baseline = MPVLoadProbeOptions(probeSize: 2_097_152,
        analyzeDurationSeconds: 5, probeInfo: "auto", liveAnalysisRequestedSeconds: nil)
    static let localFastProbe = MPVLoadProbeOptions(probeSize: 65_536,
        analyzeDurationSeconds: 0.1, probeInfo: "auto", liveAnalysisRequestedSeconds: nil)

    var perFileOptions: String {
        "demuxer-lavf-probesize=\(probeSize),demuxer-lavf-analyzeduration=\(analyzeDurationSeconds),demuxer-lavf-probe-info=\(probeInfo)"
    }

    static func configuration(url: URL, live: Bool, archive: Bool, fastProbe: Bool,
                              validationActive: Bool, arguments: [String]) -> MPVLoadProbeOptions {
        // Preserve the existing explicit local-recording probe mode. It does
        // not qualify as a live analysis trial even if contradictory flags exist.
        if fastProbe { return .localFastProbe }
#if DEBUG
        let knownContainer = ["m3u8", "m3u", "ts"].contains(url.pathExtension.lowercased())
        let network = url.scheme == "http" || url.scheme == "https"
        let requests = arguments.filter { $0.hasPrefix("--validate-live-analysis=") }
        guard validationActive, live, !archive, network, knownContainer,
              requests.count == 1,
              let value = requests.first.map({ $0.dropFirst("--validate-live-analysis=".count) }),
              value == "1" || value == "2", let seconds = Double(value) else { return .baseline }
        return MPVLoadProbeOptions(probeSize: baseline.probeSize,
            analyzeDurationSeconds: seconds, probeInfo: baseline.probeInfo,
            liveAnalysisRequestedSeconds: seconds)
#else
        return .baseline
#endif
    }
}

/// Coarse receipt times from Buffer's own callbacks. These do not isolate DNS,
/// stream analysis or decoder work. Only fixed numeric milestones are retained.
nonisolated struct MPVStartupPhases: Sendable {
    enum Phase: String, CaseIterable {
        case loadStarted, redirectStarted, redirectCompleted, loadSubmitted
        case startFile, fileLoaded, firstRender
    }

    private var generation: Int?
    private(set) var timingsMilliseconds: [String: Double] = [:]

    mutating func reset(generation: Int, enabled: Bool) {
        self.generation = enabled ? generation : nil
        timingsMilliseconds.removeAll(keepingCapacity: true)
        if enabled { timingsMilliseconds[Phase.loadStarted.rawValue] = 0 }
    }

    mutating func note(_ phase: Phase, generation: Int, elapsedMilliseconds: Double) {
        guard self.generation == generation, elapsedMilliseconds.isFinite,
              elapsedMilliseconds >= 0, elapsedMilliseconds <= 120_000,
              timingsMilliseconds[phase.rawValue] == nil else { return }
        timingsMilliseconds[phase.rawValue] = elapsedMilliseconds
    }
}
