import SwiftUI

struct SmartSportsSourceInspector: View {
    let feedID: String
    let coordinator: SmartSportsCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var feed: SmartSportsFeed? { coordinator.catalog?.feed(id: feedID) }
    private var variants: [SmartSportsVariant] { coordinator.variants(for: feedID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(feed?.name ?? "Smart Sports sources").font(.title2.weight(.semibold))
                    Text("\(variants.filter(\.isPlayable).count) available of \(variants.count) variants")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismissWindow(id: "smart-sports-sources", value: feedID) }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sourceChoices
                    guideChoices
                    selectionEvidence
                    GroupBox("Source details") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(variants) { variant in
                                SmartSportsVariantDetails(variant: variant)
                                if variant.id != variants.last?.id { Divider() }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    HStack {
                        Text("Membership is a metadata proposal. Source variants may carry different live content.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Button("Review memberships…") { openWindow(id: "smart-sports-reviews") }
                    }
                    if let error = coordinator.errorMessage {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }.padding(20)
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 660)
    }

    private var sourceChoices: some View {
        GroupBox("Playback source") {
            Picker("Playback source", selection: Binding(
                get: { coordinator.preferredVariant(for: feedID)?.rawValue ?? "automatic" },
                set: { value in
                    Task { await coordinator.setPreferredVariant(SmartSportsCatalog.key(from: value), for: feedID) }
                })) {
                Text("Automatic · observed reliability, motion, picture, then startup").tag("automatic")
                ForEach(variants) { variant in
                    SmartSportsSourceChoice(variant: variant).tag(variant.id).disabled(!variant.isPlayable)
                }
            }
            .pickerStyle(.radioGroup).labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private var guideChoices: some View {
        GroupBox("Displayed guide") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Displayed guide", selection: Binding(
                    get: { coordinator.preferredGuide(for: feedID)?.rawValue ?? "automatic" },
                    set: { value in
                        Task { await coordinator.setPreferredGuide(SmartSportsCatalog.key(from: value), for: feedID) }
                    })) {
                    Text("Automatic · current programme and schedule coverage").tag("automatic")
                    ForEach(variants.filter { $0.guideBinding != nil }) { variant in
                        Text("\(variant.sourceName) · \(variant.expectedIdentity.name) · stream \(variant.key.nativeID)")
                            .tag(variant.id)
                            .disabled(variant.guideBinding.map { SmartSportsCatalog.isSuspiciousGuideID($0.epgChannelID) } ?? true)
                    }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                Text("Guide and playback source choices are independent. Catchup uses the archive source’s own programme times.")
                    .font(.caption).foregroundStyle(.secondary)
                if feed?.guideStatus == "Timing review" || feed?.guideStatus == "Schedule review" {
                    Label("These source schedules need review. Their raw times are preserved.", systemImage: "clock.badge.exclamationmark")
                        .font(.callout).foregroundStyle(.orange)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    @ViewBuilder
    private var selectionEvidence: some View {
        if let selection = coordinator.selection(for: feedID) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Selected: \(selection.selected.sourceName) · \(selection.selected.expectedIdentity.name)")
                    .font(.callout.weight(.semibold))
                Text(selection.reasons.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                ForEach(selection.uncertainty, id: \.self) { text in
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text("No source is currently eligible. Check source availability, account capacity and membership reviews.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct SmartSportsSourceChoice: View {
    let variant: SmartSportsVariant

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(variant.sourceName) · \(variant.expectedIdentity.name)")
            Text("\(variant.state.smartSportsLabel) · stream \(variant.key.nativeID)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SmartSportsVariantDetails: View {
    let variant: SmartSportsVariant

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(variant.sourceName) · \(variant.expectedIdentity.name)").font(.callout.weight(.medium))
                Spacer(minLength: 12)
                Text(variant.state.smartSportsLabel).font(.caption).foregroundStyle(.secondary)
            }
            if !variant.advertisedFormat.isEmpty {
                Text("Advertised: \(variant.advertisedFormat)\(variant.advertisedFPS.flatMap { $0.isFinite && $0 >= 0 && $0 <= 1_000 ? " · \(Int($0)) fps" : nil } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let observation = variant.observation {
                observationDetails(observation)
            } else {
                Text("Current format and sustained reliability are unmeasured.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let days = variant.physicalChannel?.catchup?.days, days > 0 {
                Text("Advertised archive: \(days) \(days == 1 ? "day" : "days") · availability unverified")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let binding = variant.guideBinding {
                Text("Raw guide: \(binding.epgChannelID)").font(.caption).foregroundStyle(.secondary)
            }
            Text(variant.id).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
        }
    }

    private func observationDetails(_ observation: SmartSportsObservation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(observation.provenance.smartSportsLabel)
                Text("·")
                Text(observation.observedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
            }.font(.caption).foregroundStyle(.secondary)
            if let width = observation.width, let height = observation.height, width > 0, height > 0 {
                Text("Observed: \(width) × \(height)\(observation.fps.flatMap { $0.isFinite && $0 >= 0 && $0 <= 1_000 ? " · \(Int($0.rounded())) fps" : nil } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if observation.provenance == .legacyCachedFormat {
                Text("Endpoint revision and playback mode were not recorded; this format does not influence selection.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if observation.provenance != .formatProbe {
                Text("\(observation.playedSeconds.isFinite && observation.playedSeconds >= 0 && observation.playedSeconds < 100_000_000 ? Int(observation.playedSeconds.rounded()) : 0) seconds observed · \(observation.failures) failures · \(observation.stalledSeconds, specifier: "%.1f") seconds stalled")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension SmartSportsMembershipState {
    var smartSportsLabel: String {
        switch self {
        case .metadataCandidate: "Metadata candidate"
        case .manuallyReviewed: "Manually reviewed"
        case .changedIdentity: "Identity changed"
        case .missing: "Unavailable"
        case .duplicateNativeID: "Duplicate native ID"
        case .rejected: "Excluded by review"
        case .heldForReview: "Held for review"
        }
    }
}

extension SmartSportsObservation.Provenance {
    var smartSportsLabel: String {
        switch self {
        case .passivePlayback: "Passive playback observation"
        case .shortPlayback: "Short playback observation"
        case .formatProbe: "Format probe"
        case .legacyCachedFormat: "Legacy cached format"
        }
    }
}
