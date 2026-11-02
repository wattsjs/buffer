import SwiftUI

struct SettingsSourceEditor: View {
    @Bindable var viewModel: EPGViewModel
    @Bindable var session: SettingsSourceSession
    @State private var testTask: Task<Void, Never>?
    @State private var testID: UUID?
    @State private var feedback: SettingsConnectionFeedback?
    @State private var preview: ServerAccountStatus?
    @State private var didApply = false

    private var isActive: Bool { !session.isNew && viewModel.activePlaylistID == session.id && !viewModel.isSmartSportsActive }
    private var isTesting: Bool { testID != nil }
    private var fingerprint: [String] { SettingsSourceDraft.fingerprint(session.draft) }
    private var saveTitle: String { session.isNew ? "Add & Refresh" : isActive ? "Save & Refresh" : "Save Changes" }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(title: session.isNew ? "New source" : session.draft.name.isEmpty ? "Source details" : session.draft.name,
                detail: session.hasChanges ? "Unsaved changes stay here when you navigate. Use Save to apply them." :
                    isActive ? "This source is in use. Changes are applied only when you save." : "Edit this source or make it the current playlist.")
            Form {
                Section {
                    TextField("Name", text: $session.draft.name, prompt: Text("My provider"))
                    Picker("Source type", selection: $session.draft.type) {
                        ForEach(ServerType.allCases, id: \.self) { type in Text(type.settingsTitle).tag(type) }
                    }
                } header: { Text("Source") }

                connectionFields

                if let validation = validationMessage {
                    Section { Label(validation, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
                }

                if let feedback {
                    Section {
                        SettingsConnectionFeedbackView(feedback: feedback, isTesting: isTesting)
                    } header: { Text("Connection test") }
                }

                if isActive || preview != nil {
                    Section {
                        SettingsAccountDetails(status: accountStatus, config: session.draft)
                        if isActive {
                            Button("Refresh Account Details") {
                                Task { await viewModel.refreshServerStatus() }
                            }
                            .disabled(isTesting || viewModel.isRefreshing || viewModel.isLoadingSourceCredentials)
                        }
                    } header: { Text("Account and guide") }
                }

                if didApply {
                    Section {
                        if let error = viewModel.errorMessage, isActive {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        } else if isActive && viewModel.isRefreshing {
                            HStack { ProgressView().controlSize(.small); Text(viewModel.loadingStage ?? "Refreshing source…") }
                        } else {
                            Label("Source details applied", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    HStack {
                        if session.hasChanges && !session.isNew {
                            Button("Revert Changes") { session.revert() }
                        }
                        Spacer()
                        Text("Changes save only when you choose Save.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    startTest()
                } label: {
                    Label(isTesting ? "Testing…" : "Test Connection", systemImage: "network")
                }
                .disabled(validationMessage != nil || isTesting || viewModel.isRefreshing)
                if !isActive && !session.isNew {
                    Button("Use Source") { apply(useSource: true) }.disabled(validationMessage != nil)
                }
                saveButton
            }
        }
        .onChange(of: fingerprint) { _, _ in
            cancelTest()
            feedback = nil
            preview = nil
            didApply = false
        }
        .onDisappear { cancelTest() }
    }

    @ViewBuilder
    private var saveButton: some View {
        if #available(macOS 26.0, *) {
            Button(saveTitle) { apply(useSource: session.isNew) }
                .buttonStyle(.glassProminent).keyboardShortcut("s", modifiers: .command)
                .disabled(validationMessage != nil || (!session.hasChanges && !isActive))
        } else {
            Button(saveTitle) { apply(useSource: session.isNew) }
                .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                .disabled(validationMessage != nil || (!session.hasChanges && !isActive))
        }
    }

    @ViewBuilder
    private var connectionFields: some View {
        switch session.draft.type {
        case .xtream:
            Section {
                TextField("Server address", text: $session.draft.serverURL, prompt: Text("https://example.com:8080"))
                TextField("Username", text: $session.draft.username)
                SecureField("Password", text: $session.draft.password)
            } header: { Text("Xtream account") }
        case .stalker:
            Section {
                TextField("Portal address", text: $session.draft.serverURL, prompt: Text("https://example.com/c/"))
                TextField("MAC address", text: $session.draft.username, prompt: Text("00:1A:79:AA:BB:CC"))
                SecureField("Portal password", text: $session.draft.password)
            } header: { Text("Stalker account") } footer: { Text("Enter the portal password if your provider requires one.") }
        case .m3u:
            Section {
                TextField("Playlist URL or file", text: $session.draft.m3uURL, prompt: Text("https://example.com/playlist.m3u"))
                TextField("Guide URL or file", text: $session.draft.epgURL, prompt: Text("Optional XMLTV guide"))
            } header: { Text("Playlist and programme guide") }
        }
    }

    private var validationMessage: String? {
        let draft = session.draft
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a name for this source." }
        switch draft.type {
        case .xtream:
            guard validWebAddress(draft.serverURL) else { return "Enter a complete server address starting with http:// or https://." }
            if draft.username.isEmpty { return "Enter the account username." }
            if draft.password.isEmpty { return viewModel.isLoadingSourceCredentials && viewModel.activePlaylistID == session.id ? "Loading the saved password…" : "Enter the account password." }
        case .stalker:
            guard validWebAddress(draft.serverURL) else { return "Enter a complete portal address starting with http:// or https://." }
            if draft.username.isEmpty { return "Enter the MAC address supplied by your provider." }
        case .m3u:
            if draft.m3uSourceURL == nil { return "Enter a playlist URL or file path." }
        }
        return nil
    }

    private func validWebAddress(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && url.host != nil
    }

    private var accountStatus: ServerAccountStatus? {
        if let preview { return preview }
        guard viewModel.activePlaylistID == session.id, let current = viewModel.activePlaylist,
              DataCache.cacheKey(for: current) == DataCache.cacheKey(for: session.draft) else { return nil }
        return viewModel.serverStatus
    }

    private func apply(useSource: Bool) {
        cancelTest()
        if isActive { viewModel.errorMessage = nil }
        if session.isNew { viewModel.addPlaylist(session.draft, makeActive: true) }
        else { viewModel.updatePlaylist(session.draft) }
        if useSource { viewModel.setActivePlaylist(id: session.id) }
        session.markApplied()
        didApply = true
        viewModel.startSyncScheduler()
        if viewModel.activePlaylistID == session.id { viewModel.sync() }
    }

    private func startTest() {
        cancelTest()
        let snapshot = session.draft
        let id = UUID()
        testID = id
        feedback = .init(title: "Testing connection", message: "Checking this account and programme guide.", kind: .progress)
        let includeVOD = !viewModel.isVODDisabled
        testTask = Task {
            do {
                let result = try await ServerConnectionTester.test(snapshot, includeVOD: includeVOD)
                guard !Task.isCancelled, testID == id, SettingsSourceDraft.fingerprint(snapshot) == fingerprint else { return }
                preview = result.status
                feedback = .init(title: "Connection verified", message: result.message, kind: .success)
            } catch {
                guard !Task.isCancelled, testID == id, SettingsSourceDraft.fingerprint(snapshot) == fingerprint else { return }
                feedback = .init(title: "Connection failed", message: error.localizedDescription, kind: .failure)
            }
            if testID == id { testID = nil; testTask = nil }
        }
    }

    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
        testID = nil
        if feedback?.kind == .progress { feedback = nil }
    }
}

struct SettingsConnectionFeedback {
    enum Kind: Equatable { case progress, success, failure }
    let title: String
    let message: String
    let kind: Kind
}

struct SettingsConnectionFeedbackView: View {
    let feedback: SettingsConnectionFeedback
    let isTesting: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isTesting { ProgressView().controlSize(.small) }
            else { Image(systemName: feedback.kind == .failure ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(feedback.kind == .failure ? Color.red : Color.secondary) }
            VStack(alignment: .leading, spacing: 4) {
                Text(feedback.title).font(.callout.weight(.semibold))
                Text(feedback.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsAccountDetails: View {
    let status: ServerAccountStatus?
    let config: ServerConfig

    var body: some View {
        LabeledContent("Status", value: status?.accountStatus ?? "Not checked")
        LabeledContent("Channels", value: status.map { String($0.channelCount) } ?? "—")
        LabeledContent("Programme guide", value: status?.guideStatus ?? "Not checked")
        if config.type == .xtream {
            LabeledContent("Connections in use", value: status?.activeConnections.map(String.init) ?? "—")
            LabeledContent("Connection limit", value: status?.maxConnections.map(String.init) ?? "—")
        }
        if config.type != .m3u {
            LabeledContent("Expires", value: status?.expiryDate?.formatted(date: .abbreviated, time: .omitted) ?? "—")
        }
        if let isTrial = status?.isTrial { LabeledContent("Account type", value: isTrial ? "Trial" : "Standard") }
        if let checked = status?.lastChecked {
            Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
