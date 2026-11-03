import SwiftUI

/// Window form of the country filter (Sources ▸ Country Filter…).
struct SmartChannelFilterView: View {
    @Bindable var viewModel: EPGViewModel

    var body: some View {
        CountryFilterEditor(viewModel: viewModel)
            .frame(minWidth: 520, minHeight: 560)
    }
}

/// Sidebar row under the source picker: shows which countries are kept and
/// opens the editor in a popover, so the filter is visible where channels are.
struct CountryFilterSidebarRow: View {
    @Bindable var viewModel: EPGViewModel
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: filter.isEnabled ? "globe.americas.fill" : "globe.americas")
                    .foregroundStyle(filter.isEnabled ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(CountryFilterSummary.title(filter))
                        .lineLimit(1)
                    Text(CountryFilterSummary.counts(viewModel.countryFilterCounts, enabled: filter.isEnabled))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose which countries and languages to show")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            CountryFilterEditor(viewModel: viewModel)
                .frame(width: 460, height: 580)
        }
    }

    private var filter: SmartChannelFilter { viewModel.smartSports.filter }
}

/// Toolbar button with the same popover, filled while a filter is active.
struct CountryFilterToolbarButton: View {
    @Bindable var viewModel: EPGViewModel
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label("Countries", systemImage: viewModel.smartSports.filter.isEnabled ? "globe.americas.fill" : "globe.americas")
        }
        .help(CountryFilterSummary.title(viewModel.smartSports.filter))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            CountryFilterEditor(viewModel: viewModel)
                .frame(width: 460, height: 580)
        }
    }
}

enum CountryFilterSummary {
    /// "🇺🇸 🇬🇧 🇦🇺 🇳🇿 + Kids", or "All countries" when off.
    static func title(_ filter: SmartChannelFilter) -> String {
        guard filter.isEnabled else { return "All countries" }
        let regions = filter.regions.keys.sorted()
        guard !regions.isEmpty else { return filter.alwaysInclude.isEmpty ? "Nothing selected" : "Only \(kept(filter))" }
        let shown = regions.prefix(5).map { CountryFilterNames.flag(for: $0) }.joined(separator: " ")
        var text = regions.count > 5 ? "\(shown) +\(regions.count - 5)" : shown
        if !filter.alwaysInclude.isEmpty { text += " + \(kept(filter))" }
        return text
    }

    static func counts(_ counts: (shown: Int, total: Int), enabled: Bool) -> String {
        guard counts.total > 0 else { return enabled ? "Filter on" : "Filter off" }
        return enabled
            ? "\(counts.shown.formatted()) of \(counts.total.formatted()) channels"
            : "\(counts.total.formatted()) channels"
    }

    private static func kept(_ filter: SmartChannelFilter) -> String {
        SmartChannelFilter.categories.filter(filter.alwaysInclude.contains).joined(separator: ", ")
    }
}

enum CountryFilterNames {
    static func isCountryCode(_ region: String) -> Bool {
        region.count <= 3 && region.allSatisfy { $0.isASCII && $0.isUppercase }
    }

    /// "United Kingdom" for "UK"; languages and "Global" stay as they are.
    static func displayName(_ region: String) -> String {
        if region == SmartChannelFilter.unknownRegion { return "No country detected" }
        guard isCountryCode(region) else { return region }
        let code = region == "UK" ? "GB" : region
        return Locale.current.localizedString(forRegionCode: code) ?? region
    }

    static func flag(for region: String) -> String {
        let code = region == "UK" ? "GB" : region
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return region == SmartChannelFilter.unknownRegion ? "🌐" : "🗣"
        }
        return code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
    }
}

/// Chooses which countries, languages and categories every source and Smart
/// Channels show. Changes apply as they are made.
struct CountryFilterEditor: View {
    @Bindable var viewModel: EPGViewModel
    @State private var draft = SmartChannelFilter()
    @State private var loaded = false
    @State private var query = ""
    @State private var showsAllRegions = false
    @State private var applyTask: Task<Void, Never>?

    private var coordinator: SmartSportsCoordinator { viewModel.smartSports }

    /// Every source's regions once Smart Channels has scanned them (the
    /// filter is shared); otherwise the active source's.
    private var inventory: [SmartRegionSummary] {
        coordinator.regionInventory.isEmpty ? viewModel.sourceRegionInventory : coordinator.regionInventory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if inventory.isEmpty {
                ContentUnavailableView("No channels yet",
                    systemImage: "globe.americas",
                    description: Text("Countries appear once a source has loaded its channels."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    regionSection("Countries", regions: matching.filter { CountryFilterNames.isCountryCode($0.region) })
                    regionSection("Languages", regions: matching.filter {
                        !CountryFilterNames.isCountryCode($0.region) && $0.region != SmartChannelFilter.unknownRegion
                    })
                    regionSection("Other", regions: matching.filter { $0.region == SmartChannelFilter.unknownRegion },
                                  footer: "Channels whose name and group don't mention a country or language.")
                    if query.isEmpty, !showsAllRegions, inventory.count > visibleRegions.count {
                        Button("Show all \(inventory.count) countries and languages") { showsAllRegions = true }
                            .buttonStyle(.link)
                    }
                    Section {
                        HStack(spacing: 6) {
                            ForEach(SmartChannelFilter.categories, id: \.self) { category in
                                Toggle(category, isOn: Binding(
                                    get: { draft.alwaysInclude.contains(category) },
                                    set: { on in
                                        if on { draft.alwaysInclude.insert(category) } else { draft.alwaysInclude.remove(category) }
                                    }))
                                .toggleStyle(.button)
                                .controlSize(.small)
                            }
                        }
                    } header: {
                        Text("Always keep, from any country")
                    } footer: {
                        Text("For example Kids, even from countries you otherwise hide.")
                    }
                }
                .disabled(!draft.isEnabled)
            }
            Divider()
            footer
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = coordinator.filter
        }
        .onChange(of: draft) { _, next in scheduleApply(next) }
        .onDisappear {
            // Apply anything still pending when the popover closes.
            applyTask?.cancel()
            viewModel.applySmartChannelFilter(draft)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $draft.isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Filter by country").font(.headline)
                    Text("Applies to every source and to Smart Channels. Favourites are always shown.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            HStack {
                TextField("Search countries and languages", text: $query)
                    .textFieldStyle(.roundedBorder)
                if draft.isEnabled {
                    Text("Showing \(keptCount.formatted()) of \(totalCount.formatted())")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .padding(14)
    }

    private var footer: some View {
        HStack {
            Button("Use suggested") { draft = suggestedFilter() }
                .disabled(suggestion.isEmpty)
                .help("Countries of channels you've watched or favourited.")
            Spacer()
            Button("Show everything") { draft.isEnabled = false }
                .disabled(!draft.isEnabled)
        }
        .padding(12)
    }

    @ViewBuilder
    private func regionSection(_ title: String, regions: [SmartRegionSummary], footer: String? = nil) -> some View {
        if !regions.isEmpty {
            Section {
                ForEach(regions) { summary in
                    RegionRow(summary: summary, scope: binding(for: summary.region),
                              suggested: suggestion[summary.region] != nil)
                }
            } header: {
                Text(title)
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }

    private func scheduleApply(_ filter: SmartChannelFilter) {
        applyTask?.cancel()
        applyTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            viewModel.applySmartChannelFilter(filter)
        }
    }

    /// Search over code and full name; without a query, configured and
    /// suggested regions first, then the largest others.
    private var matching: [SmartRegionSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return visibleRegions }
        return inventory.filter {
            $0.region.localizedCaseInsensitiveContains(needle)
                || CountryFilterNames.displayName($0.region).localizedCaseInsensitiveContains(needle)
        }
    }

    private var visibleRegions: [SmartRegionSummary] {
        guard !showsAllRegions else { return inventory }
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
                Text(CountryFilterNames.flag(for: summary.region)).font(.title3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(CountryFilterNames.displayName(summary.region)).font(.body.weight(.medium))
                    Text("\(summary.region) · \(summary.total.formatted()) channels")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if suggested {
                    Text("Watched").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Spacer()
                Picker("", selection: preset) {
                    Text("Hide").tag(Preset.off)
                    Text("Sports").tag(Preset.sports)
                    Text("All").tag(Preset.everything)
                    Text("Custom").tag(Preset.custom)
                }
                .pickerStyle(.segmented)
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
}
