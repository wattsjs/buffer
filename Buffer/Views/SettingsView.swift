import AppKit
import Foundation
import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: EPGViewModel
    @State private var selection: SettingsSection = .sources
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            settingsSidebar
        } detail: {
            SettingsDetail(section: selection, viewModel: viewModel)
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search settings")
        .frame(width: 920, height: 640)
    }

    private var settingsSidebar: some View {
        SettingsSidebar(
            selection: $selection,
            searchText: $searchText
        )
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case sources
    case refresh
    case playback
    case recordings
    case content

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources: return "Sources"
        case .refresh: return "Refresh"
        case .playback: return "Playback"
        case .recordings: return "Recordings"
        case .content: return "Content"
        }
    }

    var systemImage: String {
        switch self {
        case .sources: return "server.rack"
        case .refresh: return "arrow.triangle.2.circlepath"
        case .playback: return "play.rectangle"
        case .recordings: return "record.circle"
        case .content: return "rectangle.stack"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    @Binding var searchText: String

    private var visibleSections: [SettingsSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(visibleSections) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Settings")
    }
}

private struct SettingsDetail: View {
    let section: SettingsSection
    @Bindable var viewModel: EPGViewModel

    var body: some View {
        detailContent
        .navigationTitle(section.title)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch section {
        case .sources:
            SourcesSettingsTab(viewModel: viewModel)
        case .refresh:
            RefreshSettingsTab(viewModel: viewModel)
        case .playback:
            PlaybackSettingsTab()
        case .recordings:
            RecordingsSettingsTab()
        case .content:
            ContentSettingsTab(viewModel: viewModel)
        }
    }
}

// MARK: - Sources

private struct SourcesSettingsTab: View {
    @Bindable var viewModel: EPGViewModel
    @State private var selection: PlaylistEditorSelection = .none

    var body: some View {
        Group {
            if viewModel.playlists.isEmpty && !selection.isNewDraft {
                firstRunView
            } else {
                SourceDetail(
                    viewModel: viewModel,
                    selection: $selection,
                    sourceControls: sourceControls
                )
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { ensureSelectionIsValid() }
        .onChange(of: viewModel.playlists.map(\.id)) { _, _ in ensureSelectionIsValid() }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var firstRunView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv.badge.wifi")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Add a source")
                .font(.title3.weight(.semibold))
            Text("Connect an Xtream Codes account or M3U playlist.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            Button {
                selection = .new(ServerConfig())
            } label: {
                Label("Add Source", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ensureSelectionIsValid() {
        switch selection {
        case .none:
            if viewModel.playlists.isEmpty {
                selection = .new(ServerConfig())
            } else if let active = viewModel.activePlaylist {
                selection = .existing(active.id)
            } else if let first = viewModel.playlists.first {
                selection = .existing(first.id)
            }
        case .existing(let id):
            if !viewModel.playlists.contains(where: { $0.id == id }) {
                if let active = viewModel.activePlaylist {
                    selection = .existing(active.id)
                } else if let first = viewModel.playlists.first {
                    selection = .existing(first.id)
                } else {
                    selection = .new(ServerConfig())
                }
            }
        case .new:
            break
        }
    }

    private var sourcePickerBinding: Binding<SourcePickerSelection> {
        Binding(
            get: {
                switch selection {
                case .existing(let id): return .existing(id)
                case .new: return .new
                case .none:
                    if let active = viewModel.activePlaylist {
                        return .existing(active.id)
                    }
                    if let first = viewModel.playlists.first {
                        return .existing(first.id)
                    }
                    return .new
                }
            },
            set: { pickerSelection in
                switch pickerSelection {
                case .existing(let id): selection = .existing(id)
                case .new:
                    if !selection.isNewDraft {
                        selection = .new(ServerConfig())
                    }
                }
            }
        )
    }

    private var sourceControls: SourceSelectionControls {
        SourceSelectionControls(
            playlists: viewModel.playlists,
            selection: sourcePickerBinding,
            canDelete: selection.existingID != nil,
            add: {
                selection = .new(ServerConfig())
            },
            delete: {
                if let id = selection.existingID {
                    viewModel.removePlaylist(id: id)
                }
            }
        )
    }
}

private enum PlaylistEditorSelection {
    case none
    case existing(UUID)
    case new(ServerConfig)

    var isExistingID: Bool {
        if case .existing = self { return true }
        return false
    }

    var isNewDraft: Bool {
        if case .new = self { return true }
        return false
    }

    var existingID: UUID? {
        if case .existing(let id) = self { return id }
        return nil
    }
}

private enum SourcePickerSelection: Hashable {
    case existing(UUID)
    case new
}

private struct SourceSelectionControls {
    let playlists: [ServerConfig]
    let selection: Binding<SourcePickerSelection>
    let canDelete: Bool
    let add: () -> Void
    let delete: () -> Void
}

// MARK: - Source Detail

private struct SourceDetail: View {
    @Bindable var viewModel: EPGViewModel
    @Binding var selection: PlaylistEditorSelection
    var sourceControls: SourceSelectionControls?

    var body: some View {
        switch selection {
        case .none:
            emptyDetail
        case .existing(let id):
            if let playlist = viewModel.playlists.first(where: { $0.id == id }) {
                PlaylistEditor(
                    viewModel: viewModel,
                    mode: .existing(id: id, original: playlist),
                    sourceControls: sourceControls
                )
                .id(id)
            } else {
                emptyDetail
            }
        case .new(let draft):
            PlaylistEditor(
                viewModel: viewModel,
                mode: .new(initial: draft),
                sourceControls: sourceControls,
                onCreated: { newID in
                    selection = .existing(newID)
                }
            )
            .id("new-editor")
        }
    }

    private var emptyDetail: some View {
        VStack {
            Spacer()
            Text("Select a source to edit it.")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct PlaylistEditor: View {
    enum Mode {
        case new(initial: ServerConfig)
        case existing(id: UUID, original: ServerConfig)

        var initialConfig: ServerConfig {
            switch self {
            case .new(let initial): return initial
            case .existing(_, let original): return original
            }
        }

        var isNew: Bool {
            if case .new = self { return true }
            return false
        }

        var existingID: UUID? {
            if case .existing(let id, _) = self { return id }
            return nil
        }
    }

    @Bindable var viewModel: EPGViewModel
    let mode: Mode
    var sourceControls: SourceSelectionControls? = nil
    var onCreated: ((UUID) -> Void)? = nil

    @State private var draft: ServerConfig
    @State private var connectionTestState: ConnectionTestState = .idle
    @State private var statusPreview: ServerAccountStatus?
    @State private var justApplied = false

    init(
        viewModel: EPGViewModel,
        mode: Mode,
        sourceControls: SourceSelectionControls? = nil,
        onCreated: ((UUID) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.mode = mode
        self.sourceControls = sourceControls
        self.onCreated = onCreated
        self._draft = State(initialValue: mode.initialConfig)
    }

    var body: some View {
        Form {
            if let sourceControls {
                Section("Source") {
                    Picker("Source", selection: sourceControls.selection) {
                        ForEach(sourceControls.playlists) { playlist in
                            Text(playlist.name.isEmpty ? "Untitled Source" : playlist.name)
                                .tag(SourcePickerSelection.existing(playlist.id))
                        }

                        if mode.isNew {
                            Text("New Source").tag(SourcePickerSelection.new)
                        }
                    }

                    HStack {
                        Button {
                            sourceControls.add()
                        } label: {
                            Label("Add Source", systemImage: "plus")
                        }

                        Button {
                            sourceControls.delete()
                        } label: {
                            Label("Delete Source", systemImage: "minus")
                        }
                        .disabled(!sourceControls.canDelete)
                    }
                }
            }

            Section("Connection") {
                TextField("Name", text: $draft.name, prompt: Text("My provider"))
                Picker("Type", selection: $draft.type) {
                    ForEach(ServerType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
            }

            switch draft.type {
            case .xtream:
                Section("Xtream Codes") {
                    TextField("Server URL", text: $draft.serverURL, prompt: Text("https://example.com:8080"))
                    TextField("Username", text: $draft.username)
                    SecureField("Password", text: $draft.password)
                }
            case .m3u:
                Section("M3U Playlist") {
                    TextField("Playlist URL", text: $draft.m3uURL, prompt: Text("https://example.com/playlist.m3u"))
                    TextField("EPG URL", text: $draft.epgURL, prompt: Text("Optional XMLTV URL"))
                }
            }

            if isActive {
                Section("Account") {
                    AccountStatusCard(status: displayedStatus, config: displayConfig)
                }
            }

            Section {
                if let feedback = firstAccountFeedback {
                    SetupFeedbackCard(
                        title: feedback.title,
                        message: feedback.message,
                        systemImage: feedback.systemImage,
                        tint: feedback.tint,
                        showsProgress: feedback.showsProgress
                    )
                    .padding(.bottom, 4)
                }

                if let feedback = connectionTestFeedback {
                    SetupFeedbackCard(
                        title: feedback.title,
                        message: feedback.message,
                        systemImage: feedback.systemImage,
                        tint: feedback.tint,
                        showsProgress: feedback.showsProgress
                    )
                    .padding(.bottom, 4)
                }

                HStack {
                    if isActive, let updated = viewModel.lastUpdated {
                        Text("Last sync: \(updated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if isActive {
                        Text("Not synced yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    Button {
                        Task { await testConnection() }
                    } label: {
                        Label(connectionTestState.buttonTitle, systemImage: connectionTestState.buttonSymbol)
                    }
                    .disabled(!isValid || connectionTestState.isTesting || viewModel.isRefreshing)

                    if !isActive && !mode.isNew {
                        Button("Make Active") {
                            applyEdits()
                            if let id = mode.existingID {
                                viewModel.setActivePlaylist(id: id)
                            }
                        }
                        .disabled(!isValid)
                    }

                    Button(primaryButtonTitle) {
                        justApplied = true
                        if mode.isNew {
                            viewModel.addPlaylist(draft, makeActive: true)
                            viewModel.startSyncScheduler()
                            onCreated?(draft.id)
                        } else {
                            applyEdits()
                            if isActive {
                                viewModel.sync()
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: draftFingerprint) { _, _ in
            if !connectionTestState.isTesting {
                connectionTestState = .idle
            }
            statusPreview = nil
        }
        .task(id: autoRefreshKey) {
            guard shouldRefreshStoredStatus else { return }
            await viewModel.refreshServerStatus()
        }
    }

    private var isActive: Bool {
        mode.existingID != nil && viewModel.activePlaylistID == mode.existingID
    }

    private var primaryButtonTitle: String {
        if mode.isNew {
            return "Add & Sync"
        }
        if isActive {
            return "Apply & Sync"
        }
        return "Save"
    }

    private func applyEdits() {
        viewModel.updatePlaylist(draft)
    }

    private var firstAccountFeedback: (title: String, message: String, systemImage: String, tint: Color, showsProgress: Bool)? {
        guard mode.isNew || (justApplied && isActive) else { return nil }

        if let error = viewModel.errorMessage, justApplied {
            return (
                title: "Couldn’t add that playlist",
                message: "\(error) Check the details and try again.",
                systemImage: "exclamationmark.triangle.fill",
                tint: .red,
                showsProgress: false
            )
        }

        if viewModel.isRefreshing, justApplied {
            return (
                title: "Refreshing source",
                message: viewModel.loadingStage ?? "Connecting and downloading channels.",
                systemImage: "arrow.triangle.2.circlepath",
                tint: .accentColor,
                showsProgress: true
            )
        }

        if justApplied, viewModel.lastUpdated != nil {
            return (
                title: "Source refreshed",
                message: "Channels and guide are up to date.",
                systemImage: "checkmark.circle.fill",
                tint: .green,
                showsProgress: false
            )
        }

        return nil
    }

    private var isValid: Bool {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        switch draft.type {
        case .xtream:
            return !draft.serverURL.isEmpty && !draft.username.isEmpty && !draft.password.isEmpty
        case .m3u:
            return !draft.m3uURL.isEmpty
        }
    }

    private var draftFingerprint: String {
        [
            draft.type.rawValue,
            draft.name,
            draft.serverURL,
            draft.username,
            draft.password,
            draft.m3uURL,
            draft.epgURL,
        ]
        .joined(separator: "|")
    }

    private var displayConfig: ServerConfig? {
        if isActive,
           let current = viewModel.activePlaylist,
           DataCache.cacheKey(for: current) == DataCache.cacheKey(for: draft) {
            return current
        }
        return isValid ? draft : viewModel.activePlaylist
    }

    private var displayedStatus: ServerAccountStatus? {
        statusPreview ?? viewModel.serverStatus
    }

    private var shouldRefreshStoredStatus: Bool {
        guard isActive,
              let current = viewModel.activePlaylist,
              current.type == .xtream,
              DataCache.cacheKey(for: current) == DataCache.cacheKey(for: draft),
              statusPreview == nil,
              viewModel.serverStatus == nil,
              !viewModel.isRefreshing,
              !connectionTestState.isTesting else {
            return false
        }
        return true
    }

    private var autoRefreshKey: String {
        [draftFingerprint, mode.existingID?.uuidString ?? "new"]
            .joined(separator: "|")
    }

    private var connectionTestFeedback: ConnectionFeedback? {
        switch connectionTestState {
        case .idle:
            return nil
        case .testing:
            return ConnectionFeedback(
                title: "Testing connection",
                message: "Checking the account and guide.",
                systemImage: "bolt.horizontal.circle",
                tint: .accentColor,
                showsProgress: true
            )
        case .success(let feedback), .failure(let feedback):
            return feedback
        }
    }

    private func testConnection() async {
        connectionTestState = .testing

        do {
            let result = try await ServerConnectionTester.test(draft)
            statusPreview = result.status
            connectionTestState = .success(
                ConnectionFeedback(
                    title: "Connection looks good",
                    message: result.message,
                    systemImage: "checkmark.circle.fill",
                    tint: .green
                )
            )
        } catch {
            connectionTestState = .failure(
                ConnectionFeedback(
                    title: "Connection failed",
                    message: error.localizedDescription,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red
                )
            )
        }
    }
}

private struct ConnectionFeedback {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    var showsProgress = false
}

private enum ConnectionTestState {
    case idle
    case testing
    case success(ConnectionFeedback)
    case failure(ConnectionFeedback)

    var isTesting: Bool {
        if case .testing = self {
            return true
        }
        return false
    }

    var buttonTitle: String {
        isTesting ? "Testing…" : "Test Connection"
    }

    var buttonSymbol: String {
        isTesting ? "bolt.horizontal.circle.fill" : "network"
    }
}

private enum ServerConnectionTester {
    struct Result {
        let message: String
        let status: ServerAccountStatus
    }

    private enum EPGStatus {
        case reachable
        case unavailable(String)
        case notConfigured

        var message: String {
            switch self {
            case .reachable:
                return "EPG reachable"
            case .unavailable(let detail):
                return "EPG unavailable (\(detail))"
            case .notConfigured:
                return "No EPG URL configured"
            }
        }
    }

    enum Error: LocalizedError {
        case invalidPlaylist
        case noChannelsFound
        case authenticationFailed
        case invalidServerURL(String)

        var errorDescription: String? {
            switch self {
            case .invalidPlaylist:
                return "The playlist responded, but it does not look like a valid M3U file."
            case .noChannelsFound:
                return "The connection worked, but the provider returned no channels."
            case .authenticationFailed:
                return "The server rejected those Xtream credentials."
            case .invalidServerURL(let field):
                return "Enter a valid \(field)."
            }
        }
    }

    static func test(_ config: ServerConfig) async throws -> Result {
        switch config.type {
        case .xtream:
            return try await testXtream(config)
        case .m3u:
            return try await testM3U(config)
        }
    }

    private static func testXtream(_ config: ServerConfig) async throws -> Result {
        guard config.xtreamAPIURL != nil else {
            throw Error.invalidServerURL("server URL")
        }

        let client = XtreamClient(config: config)
        let accountInfo = try await client.fetchAccountInfo()
        let channels = try await client.fetchChannels()
        let vodItems = (try? await client.fetchVODItems()) ?? []
        let series = (try? await client.fetchSeries()) ?? []
        if channels.isEmpty && vodItems.isEmpty && series.isEmpty {
            throw Error.noChannelsFound
        }

        let epg = await probe(url: config.xtreamEPGURL)
        var status = ServerAccountStatus.initial(for: config, cacheKey: DataCache.cacheKey(for: config))
        status.channelCount = channels.count
        status.guideStatus = epg.message
        status.apply(accountInfo)
        return Result(
            message: "Connected to Xtream. Found \(channels.count) channels, \(vodItems.count) movies, and \(series.count) series. \(epg.message).",
            status: status
        )
    }

    private static func testM3U(_ config: ServerConfig) async throws -> Result {
        guard let playlistURL = config.m3uSourceURL else {
            throw Error.invalidServerURL("playlist URL or file path")
        }

        let data = try await fetchData(from: playlistURL)
        guard let content = String(data: data, encoding: .utf8) else {
            throw Error.invalidPlaylist
        }

        let parsed = M3UParser.parseContent(content)
        let channels = parsed.channels
        guard content.contains("#EXTINF") || content.contains("#EXTM3U") else {
            throw Error.invalidPlaylist
        }
        let seriesCount = Set(parsed.vodItems.filter { $0.kind == .seriesEpisode }.map(\.group)).count
        let movieCount = parsed.vodItems.filter { $0.kind != .seriesEpisode }.count
        guard !channels.isEmpty || movieCount > 0 || seriesCount > 0 else {
            throw Error.noChannelsFound
        }

        let epg = await probe(url: config.epgSourceURL)
        var status = ServerAccountStatus.initial(for: config, cacheKey: DataCache.cacheKey(for: config))
        status.channelCount = channels.count
        status.guideStatus = epg.message
        status.lastChecked = .now
        return Result(
            message: "Playlist loaded. Found \(channels.count) channels, \(movieCount) movies, and \(seriesCount) series. \(epg.message).",
            status: status
        )
    }

    private static func fetchData(from url: URL) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }

    private static func probe(url: URL?) async -> EPGStatus {
        guard let url else { return .notConfigured }

        do {
            if url.isFileURL {
                _ = try Data(contentsOf: url)
            } else {
                var request = URLRequest(url: url)
                request.timeoutInterval = 12
                let (_, response) = try await session.bytes(for: request)
                try validate(response)
            }
            return .reachable
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private static func validate(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse,
           !(200..<400).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }

    private static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }
}

private struct AccountStatusCard: View {
    let status: ServerAccountStatus?
    let config: ServerConfig?

    private var channelCountText: String {
        if let count = status?.channelCount {
            return "\(count)"
        }
        return "—"
    }

    private var activeConnectionsText: String {
        if let value = status?.activeConnections {
            return "\(value)"
        }
        return status?.serverType == .xtream ? "—" : "n/a"
    }

    private var maxConnectionsText: String {
        if let value = status?.maxConnections {
            return "\(value)"
        }
        return status?.serverType == .xtream ? "—" : "n/a"
    }

    private var expiryText: String {
        guard let status else { return "—" }
        guard status.serverType == .xtream else { return "n/a" }
        guard let expiryDate = status.expiryDate else { return "—" }
        return expiryDate.formatted(date: .abbreviated, time: .omitted)
    }

    private var statusLabel: String {
        status?.accountStatus ?? (config?.type == .m3u ? "M3U Source" : "Unknown")
    }

    private var lastUpdatedText: String {
        guard let checked = status?.lastChecked else {
            return "No details yet."
        }
        return "Updated \(checked.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(statusLabel)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if status?.isTrial == true {
                    Text("Trial")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    accountField("Channels", channelCountText)
                    accountField("Guide", status?.guideStatus ?? "Unknown")
                }

                GridRow {
                    accountField("Connections", "\(activeConnectionsText) / \(maxConnectionsText)")
                    accountField("Expiry", expiryText)
                }
            }

            if status == nil {
                Text("Use Test Connection or Apply & Sync to load details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(lastUpdatedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func accountField(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .gridCellUnsizedAxes(.vertical)
    }
}

private struct SetupFeedbackCard: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    var showsProgress = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
                    .padding(.top, 2)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Content

private struct ContentSettingsTab: View {
    @Bindable var viewModel: EPGViewModel
    @AppStorage("hideSport") private var hideSport = false
    @AppStorage(EPGViewModel.disableVODKey) private var disableVOD = false

    var body: some View {
        Form {
            Section("Library") {
                Toggle("Show Live Sports", isOn: Binding(
                    get: { !hideSport },
                    set: { hideSport = !$0 }
                ))
                Text("Shows ESPN live scores on Home and in the sidebar. Disabling it stops background sports polling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show Movies and TV", isOn: Binding(
                    get: { !disableVOD },
                    set: { disableVOD = !$0 }
                ))
                    .onChange(of: disableVOD) { _, newValue in
                        viewModel.applyVODPreference(disabled: newValue)
                    }
                Text("Shows Movies and TV in the library and search, and fetches VOD during source refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History") {
                Button("Clear Recently Watched") {
                    viewModel.clearRecentlyWatched()
                }
                .disabled(viewModel.recentChannelIDs.isEmpty)

                Button("Reset Recommendations") {
                    viewModel.resetRecommendations()
                }
                .disabled(
                    viewModel.recentChannelIDs.isEmpty &&
                        viewModel.channelUsageCounts.isEmpty &&
                        viewModel.groupUsageCounts.isEmpty
                )

                Text("Clears Home history and the channel/group ranking used for suggestions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PlaybackSettingsTab: View {
    @AppStorage(ExternalPlayer.selectedPlayerKey) private var selectedPlayer: ExternalPlayerKind = .none
    @AppStorage(BufferSetting.appStorageKey) private var bufferSeconds: Int = BufferSetting.default
    @AppStorage(StreamProbeSetting.enabledKey) private var probeStreams: Bool = StreamProbeSetting.defaultEnabled
    @AppStorage("buffer_media_info_display") private var mediaInfoDisplay: MediaInfoDisplay = .expanded

    var body: some View {
        Form {
            Section("Player") {
                Picker("Media details", selection: $mediaInfoDisplay) {
                    ForEach(MediaInfoDisplay.allCases, id: \.self) { display in
                        Text(display.settingsTitle).tag(display)
                    }
                }
                Text("Choose how much stream information appears in the player overlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Buffering") {
                Stepper(
                    value: $bufferSeconds,
                    in: BufferSetting.range,
                    step: 1
                ) {
                    HStack {
                        Text("Live buffer")
                        Spacer()
                        Text("\(bufferSeconds) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Higher values can smooth unstable streams, with a little more delay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Channel Metadata") {
                Toggle("Show stream technical details", isOn: $probeStreams)
                    .onChange(of: probeStreams) { _, newValue in
                        if !newValue {
                            StreamProbeService.shared.clearAll()
                        }
                    }
                Text("Opens streams briefly to read codec, resolution, and FPS. This can count against provider session limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Clear Metadata Cache") {
                    StreamProbeService.shared.clearAll()
                }
            }

            Section("External Player") {
                Picker("Open channels with", selection: $selectedPlayer) {
                    ForEach(ExternalPlayerKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var footerText: String {
        switch selectedPlayer {
        case .none:
            return "Channels play in Buffer."
        default:
            return "Channel selections open in \(selectedPlayer.displayName)."
        }
    }
}

private extension MediaInfoDisplay {
    var settingsTitle: String {
        switch self {
        case .expanded: return "Expanded"
        case .collapsed: return "Compact"
        }
    }
}

// MARK: - Recordings

private struct RecordingsSettingsTab: View {
    @State private var manager = RecordingManager.shared

    var body: some View {
        Form {
            Section("Output") {
                HStack {
                    Text("Save to")
                    Spacer()
                    Text(manager.outputDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseDirectory() }
                }
                Text("Recordings are saved as .ts files in folders by channel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Padding") {
                Stepper(value: Binding(
                    get: { manager.preRollSeconds },
                    set: { manager.preRollSeconds = $0 }
                ), in: 0...300, step: 10) {
                    HStack {
                        Text("Start early")
                        Spacer()
                        Text("\(manager.preRollSeconds) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: Binding(
                    get: { manager.postRollSeconds },
                    set: { manager.postRollSeconds = $0 }
                ), in: 0...600, step: 30) {
                    HStack {
                        Text("Stop late")
                        Spacer()
                        Text("\(manager.postRollSeconds) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Adds time before and after scheduled recordings to avoid clipped starts or overruns.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Wake") {
                Toggle("Wake Mac for scheduled recordings", isOn: Binding(
                    get: { manager.wakeMacForRecordings },
                    set: { manager.wakeMacForRecordings = $0 }
                ))
                Text("Wakes the Mac about two minutes before recording. Buffer must remain open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = manager.outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            manager.setOutputDirectory(url, fromPicker: true)
        }
    }
}

// MARK: - Refresh

private struct RefreshSettingsTab: View {
    @Bindable var viewModel: EPGViewModel
    @AppStorage(SyncInterval.playlistStorageKey) private var playlistIntervalHours: Int = SyncInterval.playlistDefault.hours
    @AppStorage(SyncInterval.epgStorageKey) private var epgIntervalHours: Int = SyncInterval.epgDefault.hours

    var body: some View {
        Form {
            Section("Automatic Refresh") {
                Picker("Update channels", selection: $playlistIntervalHours) {
                    ForEach(SyncInterval.allCases) { interval in
                        Text(interval.title).tag(interval.hours)
                    }
                }
                Picker("Update guide", selection: $epgIntervalHours) {
                    ForEach(SyncInterval.allCases) { interval in
                        Text(interval.title).tag(interval.hours)
                    }
                }
                Text("Runs while Buffer is open. Choose Never to disable automatic and launch refreshes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Manual Refresh") {
                HStack {
                    if let updated = viewModel.lastUpdated {
                        Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not synced yet")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh Now") {
                        viewModel.sync()
                    }
                    .disabled(viewModel.isRefreshing || viewModel.activePlaylist == nil)
                }
            }

            Section("Guide Organization") {
                Button("Show Hidden Folders") {
                    viewModel.showAllGroups()
                }
                .disabled(viewModel.hiddenGroups.isEmpty)

                Button("Reset Folder Order") {
                    viewModel.resetGroupOrder()
                }
                .disabled(viewModel.storedGroupOrder.isEmpty)

                Text("Restores folders hidden from the sidebar and clears custom folder ordering.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: playlistIntervalHours) { _, _ in
            viewModel.startSyncScheduler()
        }
        .onChange(of: epgIntervalHours) { _, _ in
            viewModel.startSyncScheduler()
        }
    }
}
