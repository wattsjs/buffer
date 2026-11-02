import SwiftUI

/// Small overlay badge that surfaces what `StreamProbeService` knows about a
/// channel. Renders nothing if probing is disabled or no result has arrived
/// yet, so callers can drop it into any channel cell unconditionally.
struct StreamProbeBadge: View {
    let channelID: String
    var channel: Channel? = nil
    var style: Style = .compact

    init(channelID: String, style: Style = .compact) {
        self.channelID = channelID
        self.style = style
    }

    init(channel: Channel, style: Style = .compact) {
        self.channelID = channel.id
        self.channel = channel
        self.style = style
    }

    enum Style {
        case compact   // res • fps in a single pill
        case compactMetrics
        case detailed  // res, fps, codec stacked
    }

    @State private var service = StreamProbeService.shared
    @Environment(\.epgActionModel) private var actionModel
    @AppStorage(StreamProbeSetting.enabledKey) private var probesEnabled: Bool = StreamProbeSetting.defaultEnabled

    var body: some View {
        // Touch `version` so SwiftUI re-renders when probe state changes.
        let _ = service.version
        if let feedID = channel?.sourceOwnership?.logicalChannelID {
            let _ = PlayerSessionRegistry.shared.allSessions.count
            let _ = RecordingManager.shared.recordings.count
            if let availability = actionModel?.smartSports.aggregateAvailability(for: feedID) {
                logicalStatus(availability)
            } else {
                statusBadge(symbol: "questionmark.circle", tint: .secondary, text: "unmeasured")
            }
        } else if let probe = channel.map({ service.probe(for: $0) }) ?? service.probe(for: channelID),
           probesEnabled || probe.streamHealth.hasEvents {
            content(for: probe)
        }
    }

    @ViewBuilder
    private func logicalStatus(_ availability: SmartSportsAvailability) -> some View {
        Group {
            switch availability.state {
            case .unavailable:
                statusBadge(symbol: "questionmark.circle", tint: .secondary, text: "unavailable")
            case .busy:
                statusBadge(symbol: "clock", tint: .secondary, text: "busy")
            case .observedAvailable:
                statusBadge(symbol: "checkmark.circle", tint: .secondary, text: "\(availability.observedAvailableCount) checked")
            case .uncertain:
                statusBadge(symbol: "questionmark.circle", tint: .secondary, text: "unmeasured")
            case .observedFailures:
                statusBadge(symbol: "exclamationmark.triangle.fill", tint: .orange, text: "sources failed")
            }
        }
        .help(availability.message)
    }

    @ViewBuilder
    private func content(for probe: StreamProbe) -> some View {
        if probe.streamHealth.isUnstable {
            statusBadge(symbol: "exclamationmark.triangle.fill", tint: .orange, text: "unstable")
        } else if probesEnabled {
            switch probe.status {
            case .ok:
                okBadge(probe)
            case .offline, .timedOut, .error:
                statusBadge(symbol: "exclamationmark.triangle.fill", tint: .orange, text: shortStatusText(probe))
            case .unsupported:
                statusBadge(symbol: "questionmark.circle.fill", tint: .secondary, text: "no streams")
            }
        }
    }

    private func shortStatusText(_ probe: StreamProbe) -> String {
        switch probe.status {
        case .timedOut: return "timeout"
        case .offline: return "offline"
        case .error: return "error"
        default: return ""
        }
    }

    @ViewBuilder
    private func okBadge(_ probe: StreamProbe) -> some View {
        switch style {
        case .compact:
            if !compactMetricsLabel(probe).isEmpty {
                compactPill(text: compactMetricsLabel(probe), audioOnly: probe.audioOnly)
            }
        case .compactMetrics:
            if !compactMetricsLabel(probe).isEmpty {
                compactPill(text: compactMetricsLabel(probe), audioOnly: probe.audioOnly)
            }
        case .detailed:
            VStack(alignment: .leading, spacing: 1) {
                if !probe.resolutionLabel.isEmpty {
                    Text(probe.resolutionLabel)
                        .font(BufferFont.microSemibold)
                }
                if !probe.fpsLabel.isEmpty {
                    Text(probe.fpsLabel)
                        .font(BufferFont.tiny)
                        .foregroundStyle(.secondary)
                }
                if !probe.codecLabel.isEmpty {
                    Text(probe.codecLabel)
                        .font(BufferFont.tiny)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func compactMetricsLabel(_ probe: StreamProbe) -> String {
        if probe.audioOnly {
            let codecText = probe.audioCodec.uppercased()
            return codecText.isEmpty ? "AUDIO" : codecText
        }
        var parts: [String] = []
        if !probe.resolutionLabel.isEmpty { parts.append(probe.resolutionLabel) }
        if probe.fps > 0 { parts.append("\(Int(probe.fps.rounded()))") }
        return parts.joined(separator: "•")
    }

    private func compactPill(text: String, audioOnly: Bool) -> some View {
        HStack(spacing: 3) {
            if audioOnly {
                Image(systemName: "speaker.wave.2.fill")
                    .font(BufferFont.hairlineBold)
            }
            Text(text)
                .font(BufferFont.tinyBold)
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(.black.opacity(0.55)))
    }

    @ViewBuilder
    private func statusBadge(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(BufferFont.hairlineBold)
            if !text.isEmpty {
                Text(text)
                    .font(BufferFont.tinyBold)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.85)))
    }
}

/// View modifier that asks the probe service to inspect this channel as soon
/// as the row appears. Cheap when probing is disabled (the service no-ops).
struct StreamProbeRequestModifier: ViewModifier {
    let channel: Channel
    var priority: TaskPriority = .utility

    func body(content: Content) -> some View {
        content.task(id: channel.sourceChannelIdentity?.rawValue ?? channel.id) {
            StreamProbeService.shared.requestProbe(for: channel, priority: priority)
        }
    }
}

extension View {
    func requestStreamProbe(for channel: Channel, priority: TaskPriority = .utility) -> some View {
        modifier(StreamProbeRequestModifier(channel: channel, priority: priority))
    }

    /// Dims the view when the latest probe says the stream is unreachable so
    /// dead channels read as dead at a glance. No-op when probing is off or
    /// the result hasn't arrived yet — we don't want to fade healthy channels
    /// just because we haven't probed them.
    func fadeIfStreamDead(channelID: String) -> some View {
        modifier(FadeIfStreamDeadModifier(channelID: channelID))
    }

    func fadeIfStreamDead(channel: Channel) -> some View {
        modifier(FadeIfStreamDeadModifier(channelID: channel.id, channel: channel))
    }
}

private struct FadeIfStreamDeadModifier: ViewModifier {
    let channelID: String
    var channel: Channel? = nil
    @State private var service = StreamProbeService.shared
    @Environment(\.epgActionModel) private var actionModel
    @AppStorage(StreamProbeSetting.enabledKey) private var probesEnabled: Bool = StreamProbeSetting.defaultEnabled

    func body(content: Content) -> some View {
        let _ = service.version
        let dead = channelIsUnavailable
        content
            .opacity(dead ? 0.35 : 1)
            .saturation(dead ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.25), value: dead)
            // Guide rows reuse this modifier for another channel while
            // scrolling; a new channel must appear at its final opacity rather
            // than cross-fading from the previous row's availability.
            .id(channelID)
    }

    private var channelIsUnavailable: Bool {
        if let feedID = channel?.sourceOwnership?.logicalChannelID {
            // Unknown or failed variants remain actionable: another eligible
            // physical source can still satisfy this stable logical row.
            return actionModel?.smartSports.aggregateAvailability(for: feedID).state == .unavailable
        }
        let probe = channel.map { service.probe(for: $0) } ?? service.probe(for: channelID)
        return probesEnabled && (probe.map(Self.isDead) ?? false)
    }

    nonisolated private static func isDead(_ probe: StreamProbe) -> Bool {
        switch probe.status {
        case .offline, .timedOut, .error: return true
        case .ok, .unsupported: return false
        }
    }
}
