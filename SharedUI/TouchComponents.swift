import NukeUI
import OSLog
import SwiftUI

// MARK: - Channel rows

struct ChannelLogo: View {
    let channel: Channel
    var size: CGFloat = 36

    var body: some View {
        LazyImage(url: channel.logoURL) { state in
            if let image = state.image {
                image.resizable().scaledToFit()
            } else {
                Text(initials)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size * 1.4, height: size)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var initials: String {
        String(channel.name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

struct ChannelListRow: View {
    let channel: Channel
    let program: EPGProgram?

    var body: some View {
        HStack(spacing: 12) {
            ChannelLogo(channel: channel)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.body.weight(.medium)).lineLimit(1)
                if let program {
                    Text(program.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    ProgressView(value: progress(program)).tint(.accentColor)
                }
            }
        }
    }

    private func progress(_ program: EPGProgram) -> Double {
        let total = program.end.timeIntervalSince(program.start)
        guard total > 0 else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(program.start) / total))
    }
}

// MARK: - Sources

/// Adds or edits one Xtream / Stalker / M3U source. Credentials are saved by
/// `EPGViewModel` into the Keychain, exactly as on the Mac.
struct SourceEditorForm: View {
    let viewModel: EPGViewModel
    let onDone: () -> Void
    private let isNew: Bool
    @State private var draft: ServerConfig
    @State private var status: String?
    @State private var isTesting = false

    init(viewModel: EPGViewModel, existing: ServerConfig? = nil, onDone: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDone = onDone
        isNew = existing == nil
        _draft = State(initialValue: existing ?? Self.prefilledConfig())
    }

    /// UI tests on tvOS cannot type into the system keyboard reliably, so a
    /// DEBUG launch variable can pre-fill a new source ("url|user|password").
    private static func prefilledConfig() -> ServerConfig {
#if DEBUG
        if let raw = ProcessInfo.processInfo.environment["BUFFER_PREFILL_XTREAM"] {
            let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 3 {
                return ServerConfig(name: "Fixture", type: .xtream, serverURL: parts[0], username: parts[1], password: parts[2])
            }
        }
#endif
        return ServerConfig()
    }

    var body: some View {
        Form {
            Section("Source") {
                TextField("Name", text: $draft.name)
                Picker("Type", selection: $draft.type) {
                    ForEach(ServerType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            switch draft.type {
            case .xtream, .stalker:
                Section(draft.type == .xtream ? "Xtream Codes" : "Stalker / MAG") {
                    TextField("Server URL", text: $draft.serverURL)
                        .textContentType(.URL)
                        .modifier(PlainInput())
                    TextField(draft.type == .xtream ? "Username" : "MAC address", text: $draft.username)
                        .modifier(PlainInput())
                    // No password content type: IPTV portals are not website
                    // logins, and AutoFill would offer to save them as one.
                    SecureField("Password", text: $draft.password)
                }
            case .m3u:
                Section("M3U Playlist") {
                    TextField("Playlist URL", text: $draft.m3uURL).modifier(PlainInput())
                    TextField("Guide (XMLTV) URL", text: $draft.epgURL).modifier(PlainInput())
                }
            }
            Section {
                Button(isTesting ? "Testing…" : "Test Connection", action: test)
                    .disabled(isTesting || !isComplete)
                Button("Save and Sync", action: save)
                    .disabled(!isComplete)
                    .accessibilityIdentifier("save-source")
            } footer: {
                if let status { Text(status) }
            }
        }
#if os(iOS)
        .scrollDismissesKeyboard(.interactively)
#endif
        .navigationTitle(isNew ? "Add Source" : draft.name)
    }

    private var isComplete: Bool {
        switch draft.type {
        case .xtream: return !draft.serverURL.isEmpty && !draft.username.isEmpty && !draft.password.isEmpty
        case .stalker: return !draft.serverURL.isEmpty && !draft.username.isEmpty
        case .m3u: return !draft.m3uURL.isEmpty
        }
    }

    private func test() {
        isTesting = true
        status = "Checking this account and programme guide…"
        let snapshot = draft
        let includeVOD = !viewModel.isVODDisabled
        Task {
            do {
                status = try await ServerConnectionTester.test(snapshot, includeVOD: includeVOD).message
            } catch {
                status = error.localizedDescription
            }
            isTesting = false
        }
    }

    private func save() {
        AppLog.app.info("Source editor saving type=\(draft.type.rawValue, privacy: .public) new=\(isNew, privacy: .public)")
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.name = URL(string: draft.serverURL)?.host ?? "Source"
        }
        if isNew { viewModel.addPlaylist(draft, makeActive: true) }
        else { viewModel.updatePlaylist(draft) }
        viewModel.setActivePlaylist(id: draft.id)
        viewModel.startSyncScheduler()
        viewModel.sync()
        onDone()
    }
}

private struct PlainInput: ViewModifier {
    func body(content: Content) -> some View {
        content
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
#if os(iOS)
            .keyboardType(.URL)
#endif
    }
}

/// Lists saved sources plus Smart Channels; choosing one makes it active.
struct SourcesList: View {
    @Bindable var viewModel: EPGViewModel
    var onChoose: () -> Void = {}

    var body: some View {
        Section("Sources") {
            Button {
                viewModel.activateSmartSports()
                onChoose()
            } label: {
                Label("Smart Channels", systemImage: viewModel.isSmartSportsActive ? "checkmark.circle.fill" : "square.stack.3d.up")
            }
            ForEach(viewModel.playlists) { source in
                Button {
                    viewModel.chooseSource(id: source.id)
                    onChoose()
                } label: {
                    Label(source.name.isEmpty ? "Untitled Source" : source.name,
                          systemImage: !viewModel.isSmartSportsActive && source.id == viewModel.activePlaylistID
                            ? "checkmark.circle.fill" : "server.rack")
                }
            }
        }
    }
}

struct SettingsScreen: View {
    let model: TouchAppModel
    @State private var editing: ServerConfig?
    @State private var adding = false

    var body: some View {
        List {
            Section("Sources") {
                ForEach(model.viewModel.playlists) { source in
                    Button {
                        editing = source
                    } label: {
                        LabeledContent(source.name.isEmpty ? "Untitled Source" : source.name, value: source.type.rawValue)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { model.viewModel.removePlaylist(id: model.viewModel.playlists[index].id) }
                }
                Button { adding = true } label: { Label("Add Source", systemImage: "plus") }
                    .accessibilityIdentifier("add-source")
            }
#if os(iOS)
            Section("Reminders") {
                NavigationLink {
                    RemindersScreen(model: model)
                } label: {
                    LabeledContent("Programme Reminders", value: "\(NotificationManager.shared.reminders.count)")
                }
            }
#endif
            Section("Library") {
                Button { model.viewModel.sync() } label: { Label("Refresh Now", systemImage: "arrow.clockwise") }
                Button { model.isEditingCountryFilter = true } label: {
                    LabeledContent("Countries", value: CountryFilterSummary.title(model.viewModel.smartSports.filter))
                }
            }
        }
        .navigationTitle("Settings")
        .navigationDestination(isPresented: $adding) {
            SourceEditorForm(viewModel: model.viewModel) { adding = false }
        }
        .navigationDestination(item: $editing) { source in
            SourceEditorForm(viewModel: model.viewModel, existing: source) { editing = nil }
        }
    }
}

extension ServerConfig: Hashable {
    static func == (lhs: ServerConfig, rhs: ServerConfig) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Welcome

struct WelcomeView: View {
    let onAdd: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to Buffer", systemImage: "tv.badge.wifi")
        } description: {
            Text("Add an IPTV source to load channels, the guide and sports.")
        } actions: {
            Button(action: onAdd) { Label("Add Source", systemImage: "plus.circle.fill") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("welcome-add-source")
            Text("Xtream Codes, Stalker/MAG, and M3U supported")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sports

struct SportsListView: View {
    let model: TouchAppModel
    @State private var selectedEvent: SportEvent?

    private var sports: SportsViewModel { model.sports }

    var body: some View {
        List {
            if !sports.availableSports.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(sports.availableSports, id: \.self) { sport in
                                let selected = sports.selectedSports.contains(sport)
                                Button { sports.toggleSport(sport) } label: {
                                    Label(sport.rawValue, systemImage: selected ? "checkmark.circle.fill" : "circle")
                                }
                                .buttonStyle(.bordered)
                                .tint(selected ? .accentColor : nil)
                            }
                        }
                    }
                }
            }
            ForEach(sports.sections) { section in
                Section(section.group.title) {
                    ForEach(section.events) { event in
                        Button { selectedEvent = event } label: { SportEventRow(event: event) }
                            .accessibilityIdentifier("sport-event")
                    }
                }
            }
        }
        .overlay {
            if sports.sections.isEmpty {
                if sports.isLoading || !sports.hasLoadedOnce {
                    ProgressView("Loading fixtures…")
                } else {
                    ContentUnavailableView {
                        Label("No events", systemImage: "sportscourt")
                    } description: {
                        Text(sports.refreshWarning ?? "Fixtures couldn't be loaded right now.")
                    } actions: {
                        // Also gives the tvOS focus engine a target on this screen.
                        Button("Refresh") { sports.refresh() }
                    }
                }
            }
        }
        .navigationTitle("Sports")
        .refreshable { sports.refresh() }
        .sheet(item: $selectedEvent) { event in
            NavigationStack {
                SportMatchesView(model: model, event: event) { selectedEvent = nil }
            }
        }
    }
}

struct SportEventRow: View {
    let event: SportEvent

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.displayTitle).font(.body.weight(.medium)).lineLimit(2)
                Text([event.league.shortName, event.detail].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if event.status.isLive {
                Text("LIVE").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.red))
            } else {
                Text(event.startDate, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

/// Channels the stream matcher found for one fixture, best first.
struct SportMatchesView: View {
    let model: TouchAppModel
    let event: SportEvent
    let onDone: () -> Void
    @State private var matches: [StreamMatch]?

    var body: some View {
        List {
            if let matches {
                if matches.isEmpty {
                    ContentUnavailableView("No channels found", systemImage: "tv.slash",
                        description: Text(model.sports.streamIndexUnavailableMessage ?? "No channel or guide entry matches this event."))
                }
                ForEach(matches) { match in
                    Button {
                        onDone()
                        model.openChannel(match.channel)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.channel.name).font(.body.weight(.medium))
                            Text(match.programTitle ?? match.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ProgressView("Finding channels…")
            }
        }
        .navigationTitle(event.shortTitle)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done", action: onDone) }
        }
        .task(id: model.sports.searchIndexVersion) {
            matches = await model.sports.matchEvent(event)
        }
    }
}

// MARK: - Search

struct TouchSearchResults: View {
    let model: TouchAppModel

    private var search: ProgramSearchController { model.search }

    var body: some View {
        List {
            if !search.channelResults.isEmpty {
                Section("Channels") {
                    ForEach(search.channelResults.prefix(30)) { result in
                        Button { model.openChannel(result.channel) } label: {
                            ChannelListRow(channel: result.channel, program: model.viewModel.currentProgram(for: result.channel))
                        }
                    }
                }
            }
            if !search.programResults.isEmpty {
                Section("Programmes") {
                    ForEach(search.programResults.prefix(60)) { result in
                        Button {
                            if result.program.end < Date(), result.channel.canReplay(result.program) {
                                model.openCatchup(result.channel, program: result.program)
                            } else {
                                model.openChannel(result.channel)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.program.title).font(.body.weight(.medium)).lineLimit(1)
                                Text("\(result.channel.name) · \(result.program.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if !search.hasQuery {
                ContentUnavailableView("Search", systemImage: "magnifyingglass",
                                       description: Text("Programmes, channels, movies and series."))
            } else if search.totalResultCount == 0, !search.isSearching {
                ContentUnavailableView.search(text: search.query)
            }
        }
    }
}

#if os(iOS)
/// Upcoming programme reminders; tap to play, swipe to cancel.
struct RemindersScreen: View {
    let model: TouchAppModel

    private var reminders: [ProgramReminder] {
        NotificationManager.shared.reminders.sorted { $0.programStart < $1.programStart }
    }

    var body: some View {
        List {
            ForEach(reminders) { reminder in
                Button { model.openReminder(reminder) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(reminder.programTitle).font(.body.weight(.medium))
                        Text("\(reminder.channelName) · \(reminder.programStart.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Notifies \(GuideMenus.lead(reminder.leadMinutes))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { reminders[$0].id }
                ids.forEach { NotificationManager.shared.cancelReminder(id: $0) }
            }
        }
        .overlay {
            if reminders.isEmpty {
                ContentUnavailableView("No reminders", systemImage: "bell",
                    description: Text("Touch and hold a programme in the guide to get a reminder before it starts."))
            }
        }
        .navigationTitle("Reminders")
    }
}
#endif
