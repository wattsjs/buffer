import Foundation
import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: EPGViewModel

    var body: some View {
        TabView {
            GeneralSettingsTab(viewModel: viewModel)
                .tabItem { Label("Account", systemImage: "server.rack") }

            PlaybackSettingsTab()
                .tabItem { Label("Playback", systemImage: "play.rectangle") }

            SyncSettingsTab(viewModel: viewModel)
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }

            GeneralAppSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 520)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Bindable var viewModel: EPGViewModel
    @State private var draft: ServerConfig
    @State private var hasSubmittedFirstAccount = false
    @State private var connectionTestState: ConnectionTestState = .idle
    @State private var statusPreview: ServerAccountStatus?
    private let isCreatingFirstAccount: Bool

    init(viewModel: EPGViewModel) {
        self.viewModel = viewModel
        self._draft = State(initialValue: viewModel.serverConfig ?? ServerConfig())
        self.isCreatingFirstAccount = viewModel.serverConfig == nil
    }

    var body: some View {
        Form {
            if isCreatingFirstAccount {
                Section {
                    SetupFeedbackCard(
                        title: "Add your first account",
                        message: "Choose a provider, enter the details, then click Apply & Sync.",
                        systemImage: "sparkles",
                        tint: .accentColor
                    )
                }
            }

            Section("Server") {
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

            Section("Account") {
                AccountStatusCard(status: displayedStatus, config: displayConfig)
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
                    if let updated = viewModel.lastUpdated {
                        Text("Last sync: \(updated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not synced yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task {
                            await testConnection()
                        }
                    } label: {
                        Label(connectionTestState.buttonTitle, systemImage: connectionTestState.buttonSymbol)
                    }
                    .disabled(!isValid || connectionTestState.isTesting || viewModel.isRefreshing)

                    Button("Apply & Sync") {
                        hasSubmittedFirstAccount = true
                        viewModel.serverConfig = draft
                        viewModel.saveConfig()
                        viewModel.startSyncScheduler()
                        viewModel.sync()
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

    private var firstAccountFeedback: (title: String, message: String, systemImage: String, tint: Color, showsProgress: Bool)? {
        guard isCreatingFirstAccount else { return nil }

        if let error = viewModel.errorMessage, hasSubmittedFirstAccount {
            return (
                title: "Couldn’t add that account",
                message: "\(error) Check the details and try again.",
                systemImage: "exclamationmark.triangle.fill",
                tint: .red,
                showsProgress: false
            )
        }

        if viewModel.isRefreshing, hasSubmittedFirstAccount {
            return (
                title: "Syncing your channels",
                message: viewModel.loadingStage ?? "Connecting and downloading channels.",
                systemImage: "arrow.triangle.2.circlepath",
                tint: .accentColor,
                showsProgress: true
            )
        }

        if hasSubmittedFirstAccount, viewModel.lastUpdated != nil {
            return (
                title: "Account added",
                message: "Sync complete. You can close Settings.",
                systemImage: "checkmark.circle.fill",
                tint: .green,
                showsProgress: false
            )
        }

        if hasSubmittedFirstAccount {
            return (
                title: "Account saved",
                message: "Starting the first sync.",
                systemImage: "clock.badge.checkmark",
                tint: .accentColor,
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
        if let current = viewModel.serverConfig,
           DataCache.cacheKey(for: current) == DataCache.cacheKey(for: draft) {
            return current
        }
        return isValid ? draft : viewModel.serverConfig
    }

    private var displayedStatus: ServerAccountStatus? {
        statusPreview ?? viewModel.serverStatus
    }

    private var shouldRefreshStoredStatus: Bool {
        guard let current = viewModel.serverConfig,
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
        [draftFingerprint, viewModel.serverConfig?.id.uuidString ?? "none"]
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
        if channels.isEmpty {
            throw Error.noChannelsFound
        }

        let epg = await probe(url: config.xtreamEPGURL)
        var status = ServerAccountStatus.initial(for: config, cacheKey: DataCache.cacheKey(for: config))
        status.channelCount = channels.count
        status.guideStatus = epg.message
        status.apply(accountInfo)
        return Result(
            message: "Connected to Xtream. Found \(channels.count) channels. \(epg.message).",
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

        let channels = M3UParser.parse(content)
        guard content.contains("#EXTINF") || content.contains("#EXTM3U") else {
            throw Error.invalidPlaylist
        }
        guard !channels.isEmpty else {
            throw Error.noChannelsFound
        }

        let epg = await probe(url: config.epgSourceURL)
        var status = ServerAccountStatus.initial(for: config, cacheKey: DataCache.cacheKey(for: config))
        status.channelCount = channels.count
        status.guideStatus = epg.message
        status.lastChecked = .now
        return Result(
            message: "Playlist loaded. Found \(channels.count) channels. \(epg.message).",
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
        status?.accountStatus ?? (config?.type == .m3u ? "Playlist" : "Unknown")
    }

    private var lastUpdatedText: String {
        guard let checked = status?.lastChecked else {
            return "No details yet."
        }
        return "Updated \(checked.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(config?.name.isEmpty == false ? config?.name ?? "Account" : "Account")
                    .font(.headline)

                Spacer()

                Text(statusLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    accountField("Channels", channelCountText)
                    accountField("Guide", status?.guideStatus ?? "Unknown")
                }

                GridRow {
                    accountField("Active Connections", activeConnectionsText)
                    accountField("Max Connections", maxConnectionsText)
                }

                GridRow {
                    accountField("Expiry", expiryText)
                    accountField("Username", status?.username ?? (config?.username.isEmpty == false ? config?.username ?? "—" : "—"))
                }
            }

            if status?.isTrial == true {
                Text("Trial account")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if status == nil {
                Text("Use Test Connection or Apply & Sync to load details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(lastUpdatedText)
                .font(.caption)
                .foregroundStyle(.secondary)
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

// MARK: - Playback

private struct GeneralAppSettingsTab: View {
    @AppStorage("hideSport") private var hideSport = false

    var body: some View {
        Form {
            Section("Features") {
                Toggle("Show Live Sport", isOn: Binding(
                    get: { !hideSport },
                    set: { hideSport = !$0 }
                ))
                Text("Shows ESPN live scores on Home and in the sidebar. Turn it off to stop background polling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

private struct PlaybackSettingsTab: View {
    @AppStorage(ExternalPlayer.selectedPlayerKey) private var selectedPlayer: ExternalPlayerKind = .none
    @AppStorage(BufferSetting.appStorageKey) private var bufferSeconds: Int = BufferSetting.default

    var body: some View {
        Form {
            Section("Network Buffer") {
                Stepper(
                    value: $bufferSeconds,
                    in: BufferSetting.range,
                    step: 1
                ) {
                    HStack {
                        Text("Buffer length")
                        Spacer()
                        Text("\(bufferSeconds) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text("How many seconds mpv buffers ahead. Higher values reduce stutter but add more delay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("External Player") {
                Picker("Default player", selection: $selectedPlayer) {
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
        .scrollDisabled(true)
    }

    private var footerText: String {
        switch selectedPlayer {
        case .none:
            return "Channels open in Buffer."
        default:
            return "Selecting a channel opens the stream in \(selectedPlayer.displayName)."
        }
    }
}

// MARK: - Sync

private struct SyncSettingsTab: View {
    @Bindable var viewModel: EPGViewModel
    @AppStorage(SyncInterval.appStorageKey) private var syncIntervalHours: Int = SyncInterval.default.hours

    var body: some View {
        Form {
            Section("Automatic Refresh") {
                Picker("Refresh every", selection: $syncIntervalHours) {
                    ForEach(SyncInterval.allCases) { interval in
                        Text(interval.title).tag(interval.hours)
                    }
                }
                Text("Refreshes in the background while Buffer is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Manual") {
                HStack {
                    if let updated = viewModel.lastUpdated {
                        Text("Last sync: \(updated.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never synced")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh Now") {
                        viewModel.sync()
                    }
                    .disabled(viewModel.isRefreshing || viewModel.serverConfig == nil)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onChange(of: syncIntervalHours) { _, _ in
            viewModel.startSyncScheduler()
        }
    }
}
