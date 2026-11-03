import SwiftUI

/// Focus-driven guide. Rows are lazy; each row reads its cells from one
/// `EPGRowLayout` and shows only those intersecting the visible time page.
/// Moving focus past the page's edge pages the timeline by half its span.
struct TVGuideGrid: View {
    let model: TouchAppModel
    @State private var timeline = GuideTimelineWindow(pixelsPerMinute: Self.pixelsPerMinute)
    @State private var pageStart = Date()
    @FocusState private var focused: TVGuideFocus?

    static let pixelsPerMinute = 6.0
    static let pageMinutes = 180.0
    static let rowHeight: CGFloat = 96
    static let channelWidth: CGFloat = 360

    private var pageEnd: Date { pageStart.addingTimeInterval(Self.pageMinutes * 60) }

    var body: some View {
        let viewModel = model.viewModel
        let channels = viewModel.filteredChannels
        VStack(alignment: .leading, spacing: 12) {
            timeHeader
            if channels.isEmpty {
                ContentUnavailableView(viewModel.hasLoadedOnce ? "No Channels" : "Loading…", systemImage: "tv")
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                            TVGuideRow(
                                channel: channel, row: index,
                                programs: viewModel.programsForChannel(channel, between: timeline.start, and: timeline.end),
                                timeline: timeline, pageStart: pageStart, pageMinutes: Self.pageMinutes,
                                guideVersion: viewModel.guideVersion, focused: $focused,
                                onPlay: { model.openChannel(channel) },
                                onProgram: { program in
                                    if program.end < Date(), channel.canReplay(program) {
                                        model.openCatchup(channel, program: program)
                                    } else {
                                        model.openChannel(channel)
                                    }
                                })
                            .onAppear { if index % 8 == 0 { viewModel.syncCatchupGuideIfNeeded(for: Array(channels[index..<min(channels.count, index + 12)])) } }
                        }
                    }
                    .padding(.vertical, 20)
                }
                .scrollClipDisabled()
            }
        }
        .onAppear { resetPage() }
        .onMoveCommand { direction in page(direction) }
    }

    private var timeHeader: some View {
        let spec = timeline.timeStrip()
        let first = Int((CGFloat(timeline.x(for: pageStart)) / spec.slotWidth).rounded(.down))
        let count = Int(Self.pageMinutes / 30)
        return HStack(spacing: 0) {
            Text(pageStart, format: .dateTime.weekday(.wide))
                .font(.headline).frame(width: Self.channelWidth + 20, alignment: .leading)
            ForEach(first..<(first + count), id: \.self) { slot in
                Text(spec.title(slot)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: spec.slotWidth, alignment: .leading)
            }
        }
    }

    private func resetPage() {
        let now = Date()
        timeline = GuideTimelineWindow(now: now, pixelsPerMinute: Self.pixelsPerMinute)
        let origin = now.addingTimeInterval(-30 * 60).timeIntervalSinceReferenceDate
        pageStart = Date(timeIntervalSinceReferenceDate: (origin / GuideTimelineWindow.slot).rounded(.down) * GuideTimelineWindow.slot)
    }

    /// Focus engine moves between visible cells; at the page edge, shift the
    /// page so the next programmes come into view.
    private func page(_ direction: MoveCommandDirection) {
        guard case .program(_, let start, let end) = focused else { return }
        let step = Self.pageMinutes / 2 * 60
        switch direction {
        case .right where end >= pageEnd.addingTimeInterval(-60):
            let next = pageStart.addingTimeInterval(step)
            if next.addingTimeInterval(Self.pageMinutes * 60) <= timeline.end.addingTimeInterval(step) { pageStart = next }
        case .left where start <= pageStart.addingTimeInterval(60):
            pageStart = max(timeline.start, pageStart.addingTimeInterval(-step))
        default:
            break
        }
    }
}

enum TVGuideFocus: Hashable {
    case channel(Int)
    case program(row: Int, start: Date, end: Date)
}

private struct TVGuideRow: View {
    let channel: Channel
    let row: Int
    let programs: [EPGProgram]
    let timeline: GuideTimelineWindow
    let pageStart: Date
    let pageMinutes: Double
    let guideVersion: Int
    var focused: FocusState<TVGuideFocus?>.Binding
    let onPlay: () -> Void
    let onProgram: (EPGProgram) -> Void

    @State private var layout = EPGRowLayout()
    @State private var builtKey: [AnyHashable] = []

    var body: some View {
        let pageX = timeline.x(for: pageStart)
        let pageWidth = pageMinutes * timeline.pixelsPerMinute
        HStack(spacing: 20) {
            Button(action: onPlay) {
                HStack(spacing: 14) {
                    ChannelLogo(channel: channel, size: 40)
                    Text(channel.name).font(.callout.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .frame(width: TVGuideGrid.channelWidth - 40, height: TVGuideGrid.rowHeight - 24)
            }
            .focused(focused, equals: .channel(row))
            .accessibilityIdentifier("tv-channel")

            ZStack(alignment: .leading) {
                Color.clear.frame(width: pageWidth, height: TVGuideGrid.rowHeight)
                let cells = visibleCells(minX: pageX, maxX: pageX + pageWidth)
                if cells.isEmpty {
                    Button(action: onPlay) {
                        Text("No guide information").foregroundStyle(.secondary)
                            .frame(width: pageWidth - 40, height: TVGuideGrid.rowHeight - 24, alignment: .leading)
                    }
                    .focused(focused, equals: .program(row: row, start: pageStart, end: pageStart.addingTimeInterval(pageMinutes * 60)))
                } else {
                    ForEach(cells, id: \.self) { cell in
                        programButton(cell, pageX: pageX, pageWidth: pageWidth)
                    }
                }
            }
            .frame(width: pageWidth, alignment: .leading)
        }
        .task(id: [AnyHashable(guideVersion), AnyHashable(channel.id), AnyHashable(timeline.start)]) { rebuild() }
    }

    private func rebuild() {
        let now = Date()
        layout.build(programs: programs, timelineStart: timeline.start, pixelsPerMinute: timeline.pixelsPerMinute,
                     timelineWidth: timeline.width, rowHeight: Double(TVGuideGrid.rowHeight), showGaps: false)
        layout.applyState(now: now, replayStart: channel.archiveWindow(now: now)?.start)
    }

    private func visibleCells(minX: Double, maxX: Double) -> [Int] {
        var cells: [Int] = []
        var cell = layout.firstCell(endingAfter: minX)
        while cell < layout.count, Double(layout.x[cell]) < maxX {
            if !layout.isGap(cell), programs.indices.contains(Int(layout.source[cell])) { cells.append(cell) }
            cell += 1
        }
        return cells
    }

    @ViewBuilder
    private func programButton(_ cell: Int, pageX: Double, pageWidth: Double) -> some View {
        let program = programs[Int(layout.source[cell])]
        let x0 = max(Double(layout.x[cell]), pageX) - pageX
        let x1 = min(Double(layout.maxX(cell)), pageX + pageWidth) - pageX
        let flags = layout.flags[cell]
        let live = flags & EPGCellFlags.live != 0
        let past = flags & EPGCellFlags.past != 0
        Button { onProgram(program) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(program.title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(EPGClockText.shared.compactRange(start: layout.start[cell], end: layout.end[cell]))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 16)
            // The card's width is the cell's span in the page, less a gutter.
            .frame(width: max(24, x1 - x0 - 8), height: TVGuideGrid.rowHeight - 16, alignment: .leading)
            .background(live ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08))
            .opacity(past ? 0.55 : 1)
        }
        .buttonStyle(.card)
        .focused(focused, equals: .program(row: row, start: program.start, end: program.end))
        .padding(.leading, x0)
    }
}

/// Focusable country filter for the Siri Remote: each region is one row
/// that cycles Hide → Sports → All when selected.
struct TVCountryFilterView: View {
    @Bindable var viewModel: EPGViewModel
    @State private var draft = SmartChannelFilter()
    @State private var loaded = false

    private var inventory: [SmartRegionSummary] {
        viewModel.smartSports.regionInventory.isEmpty ? viewModel.sourceRegionInventory : viewModel.smartSports.regionInventory
    }

    var body: some View {
        List {
            Section {
                Toggle("Filter by country", isOn: $draft.isEnabled)
            } footer: {
                Text("Applies to every source and to Smart Channels. Favourites are always shown. "
                     + CountryFilterSummary.counts(viewModel.countryFilterCounts, enabled: draft.isEnabled))
            }
            Section("Countries and languages") {
                ForEach(inventory) { summary in
                    Button { cycle(summary.region) } label: {
                        HStack {
                            Text(CountryFilterNames.flag(for: summary.region))
                            VStack(alignment: .leading) {
                                Text(CountryFilterNames.displayName(summary.region))
                                Text("\(summary.total.formatted()) channels").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(label(for: draft.regions[summary.region] ?? .off)).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!draft.isEnabled)
                }
            }
            Section("Always keep, from any country") {
                ForEach(SmartChannelFilter.categories, id: \.self) { category in
                    Toggle(category, isOn: Binding(
                        get: { draft.alwaysInclude.contains(category) },
                        set: { on in if on { draft.alwaysInclude.insert(category) } else { draft.alwaysInclude.remove(category) } }))
                    .disabled(!draft.isEnabled)
                }
            }
        }
        .navigationTitle(CountryFilterSummary.title(viewModel.smartSports.filter))
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = viewModel.smartSports.filter
        }
        .onChange(of: draft) { _, next in viewModel.applySmartChannelFilter(next) }
    }

    private func cycle(_ region: String) {
        switch draft.regions[region] ?? .off {
        case .off: draft.regions[region] = .sportsOnly
        case .categories: draft.regions[region] = .everything
        case .everything: draft.regions[region] = nil
        }
    }

    private func label(for scope: SmartChannelFilter.Scope) -> String {
        switch scope {
        case .off: "Hidden"
        case .everything: "All"
        case .categories(let allowed): allowed == ["Sports"] ? "Sports" : "Custom"
        }
    }
}
