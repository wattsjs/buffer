import SwiftUI

/// Chooses which regions, languages and categories Smart Channels shows,
/// with live channel counts from every configured source.
struct SmartChannelFilterView: View {
    @Bindable var viewModel: EPGViewModel
    @State private var draft = SmartChannelFilter()
    @State private var loaded = false
    @State private var showsAllRegions = false

    private var coordinator: SmartSportsCoordinator { viewModel.smartSports }
    private var inventory: [SmartRegionSummary] { coordinator.regionInventory }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if inventory.isEmpty {
                ContentUnavailableView("Scanning your sources",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Open Smart Channels from the Sources menu; regions appear once every source has been read."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("Regions and languages") {
                        ForEach(visibleRegions) { summary in
                            RegionRow(summary: summary, scope: binding(for: summary.region),
                                      suggested: suggestion[summary.region] != nil)
                        }
                        if !showsAllRegions, inventory.count > visibleRegions.count {
                            Button("Show all \(inventory.count) regions") { showsAllRegions = true }
                                .buttonStyle(.link)
                        }
                    }
                    Section {
                        ForEach(SmartChannelFilter.categories, id: \.self) { category in
                            Toggle(category, isOn: Binding(
                                get: { draft.alwaysInclude.contains(category) },
                                set: { on in
                                    if on { draft.alwaysInclude.insert(category) } else { draft.alwaysInclude.remove(category) }
                                }))
                        }
                    } header: {
                        Text("Keep from any region")
                    } footer: {
                        Text("For example Kids, even from regions you otherwise hide.")
                    }
                }
                .disabled(!draft.isEnabled)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 520)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = coordinator.filter
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $draft.isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Only show channels I care about").font(.headline)
                    Text("Smart Channels combines every source. Choose regions and categories; channels from any account that match are kept, everything else is hidden.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            if draft.isEnabled {
                Text("Kept: \(keptCount) of \(totalCount) channels")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Use suggested") { draft = suggestedFilter() }
                .disabled(suggestion.isEmpty)
                .help("Based on the regions of channels you've watched or favourited.")
            Spacer()
            Button("Revert") { draft = coordinator.filter }
                .disabled(draft == coordinator.filter)
            Button("Apply") { viewModel.applySmartChannelFilter(draft) }
                .keyboardShortcut(.defaultAction)
                .disabled(draft == coordinator.filter)
        }
        .padding(12)
    }

    private var visibleRegions: [SmartRegionSummary] {
        guard !showsAllRegions else { return inventory }
        // Configured or suggested regions first, then the largest others.
        let pinned = inventory.filter { draft.regions[$0.region] != nil || suggestion[$0.region] != nil }
        let others = inventory.filter { draft.regions[$0.region] == nil && suggestion[$0.region] == nil }
        return pinned + others.prefix(max(0, 12 - pinned.count))
    }

    private var totalCount: Int { inventory.reduce(0) { $0 + $1.total } }

    private var keptCount: Int {
        inventory.reduce(0) { total, summary in
            total + summary.categoryCounts.reduce(0) { sum, entry in
                sum + (draft.allows(region: summary.region, category: entry.key) ? entry.value : 0)
            }
        }
    }

    private func binding(for region: String) -> Binding<SmartChannelFilter.Scope> {
        Binding(get: { draft.regions[region] ?? .off },
                set: { draft.regions[region] = $0 == .off ? nil : $0 })
    }

    /// Regions of watched/favourited channels; sports-only when every such
    /// channel in that region is a sports channel.
    private var suggestion: [String: SmartChannelFilter.Scope] {
        let ids = Set(viewModel.recentChannelIDs).union(viewModel.favoriteChannelIDs)
        let watched = viewModel.recentChannels + viewModel.displayedChannels.filter { ids.contains($0.id) }
        var categories: [String: Set<String>] = [:]
        for channel in watched {
            guard let parsed = AutoChannelGrouper.parse(channel) else { continue }
            let region = AutoChannelGrouper.regionLabel(parsed.identity.country)
            guard region != SmartChannelFilter.unknownRegion else { continue }
            categories[region, default: []].insert(channel.group.lowercased().contains("sport") ? "Sports" : "Other")
        }
        return categories.mapValues { $0 == ["Sports"] ? .sportsOnly : .everything }
    }

    private func suggestedFilter() -> SmartChannelFilter {
        var next = draft
        next.isEnabled = true
        next.regions = suggestion
        return next
    }
}

private struct RegionRow: View {
    let summary: SmartRegionSummary
    @Binding var scope: SmartChannelFilter.Scope
    let suggested: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Self.flag(for: summary.region)).font(.title3)
                Text(summary.region).font(.body.weight(.medium))
                if suggested {
                    Text("Watched").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Text("\(summary.total) channels").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: preset) {
                    Text("Off").tag(Preset.off)
                    Text("Sports only").tag(Preset.sports)
                    Text("Everything").tag(Preset.everything)
                    Text("Custom").tag(Preset.custom)
                }
                .labelsHidden()
                .fixedSize()
            }
            if case .categories(let allowed) = scope, allowed != ["Sports"] {
                HStack(spacing: 6) {
                    ForEach(SmartChannelFilter.categories.filter { summary.categoryCounts[$0] != nil }, id: \.self) { category in
                        Toggle("\(category) \(summary.categoryCounts[category] ?? 0)", isOn: Binding(
                            get: { allowed.contains(category) },
                            set: { on in
                                var next = allowed
                                if on { next.insert(category) } else { next.remove(category) }
                                scope = .categories(next)
                            }))
                        .toggleStyle(.button)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private enum Preset: Hashable { case off, sports, everything, custom }

    private var preset: Binding<Preset> {
        Binding(get: {
            switch scope {
            case .off: .off
            case .everything: .everything
            case .categories(let allowed): allowed == ["Sports"] ? .sports : .custom
            }
        }, set: { next in
            switch next {
            case .off: scope = .off
            case .sports: scope = .sportsOnly
            case .everything: scope = .everything
            case .custom: scope = .categories(Set(summary.categoryCounts.keys))
            }
        })
    }

    static func flag(for region: String) -> String {
        let code = region == "UK" ? "GB" : region
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return "🌐" }
        return code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
    }
}
