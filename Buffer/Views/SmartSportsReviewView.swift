import SwiftUI

struct SmartSportsReviewView: View {
    let coordinator: SmartSportsCoordinator
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var searchText = ""
    @State private var stateFilter = "all"
    @State private var selectedReviewID: String?

    private var reviews: [SmartSportsReviewItem] {
        (coordinator.catalog?.reviewItems ?? []).filter { item in
            let matchesState = stateFilter == "all" || item.state.rawValue == stateFilter
            guard matchesState else { return false }
            guard !searchText.isEmpty else { return true }
            let channel = coordinator.currentChannel(for: item.key)
            let values = [channel?.name ?? "", channel?.group ?? "", sourceName(item.key), item.key.nativeID, item.reason]
            return values.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private var selected: SmartSportsReviewItem? { reviews.first { $0.id == selectedReviewID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Smart Channels membership reviews").font(.title2.weight(.semibold))
                    Text("Held streams stay outside automatic grouping until reviewed.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if coordinator.isLoading { ProgressView().controlSize(.small) }
                Button("Done") { dismissWindow(id: "smart-sports-reviews") }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            HStack(spacing: 12) {
                TextField("Find a source, stream or reason", text: $searchText).textFieldStyle(.roundedBorder)
                Picker("Show", selection: $stateFilter) {
                    Text("All reviews").tag("all")
                    Text("Held").tag(SmartSportsMembershipState.heldForReview.rawValue)
                    Text("Identity changed").tag(SmartSportsMembershipState.changedIdentity.rawValue)
                    Text("Excluded").tag(SmartSportsMembershipState.rejected.rawValue)
                    Text("Unavailable").tag(SmartSportsMembershipState.missing.rawValue)
                    Text("Duplicate IDs").tag(SmartSportsMembershipState.duplicateNativeID.rawValue)
                }.frame(width: 210)
            }.padding(16)
            HSplitView {
                List(selection: $selectedReviewID) {
                    ForEach(reviews) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(coordinator.currentChannel(for: item.key)?.name ?? "Stream \(item.key.nativeID)")
                                .lineLimit(2)
                            Text("\(sourceName(item.key)) · \(item.state.smartSportsLabel)")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3).tag(item.id)
                    }
                }.frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                if let selected {
                    SmartSportsMembershipReviewDetail(item: selected, coordinator: coordinator)
                        .id(selected.id)
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(reviews.isEmpty ? "No matching reviews" : "Select a stream",
                        systemImage: "list.bullet.clipboard",
                        description: Text("Compare its current identity before linking or splitting a feed."))
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text("\(reviews.count) reviews shown").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let error = coordinator.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding(12)
        }
        .frame(minWidth: 760, idealWidth: 880, minHeight: 500, idealHeight: 640)
        .onChange(of: reviews.map(\.id)) { _, ids in
            if let selectedReviewID, !ids.contains(selectedReviewID) { self.selectedReviewID = nil }
        }
    }

    private func sourceName(_ key: SmartSportsEndpointKey) -> String {
        coordinator.config(for: key.sourceID)?.name
            ?? coordinator.catalog?.feeds.flatMap(\.variants).first { $0.key == key }?.sourceName
            ?? "Unavailable source"
    }
}

private struct SmartSportsMembershipReviewDetail: View {
    let item: SmartSportsReviewItem
    let coordinator: SmartSportsCoordinator
    @State private var destinationFeedID = ""
    @State private var splitName = ""
    @State private var splitCountry = "Other"
    @State private var splitLanguage = "en"
    @State private var splitEdition = "reviewed"
    @State private var isSaving = false

    private var current: Channel? { coordinator.currentChannel(for: item.key) }
    private var proposal: SmartSportsVariant? {
        coordinator.catalog?.feeds.flatMap(\.variants).first { $0.key == item.key }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(current?.name ?? proposal?.expectedIdentity.name ?? "Stream \(item.key.nativeID)")
                        .font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text(item.state.smartSportsLabel).font(.callout).foregroundStyle(.secondary)
                    Text(item.reason).font(.callout)
                }
                if let current {
                    GroupBox("Current source identity") {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Name", value: current.name)
                            LabeledContent("Group", value: current.group)
                            LabeledContent("Raw guide", value: current.epgChannelID ?? "None")
                        }.font(.callout).textSelection(.enabled).padding(8)
                    }
                } else {
                    Text("The current source snapshot is unavailable. Refresh its ordinary playlist to review this endpoint.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let proposal {
                    GroupBox("Reviewed or proposed identity") {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Name", value: proposal.expectedIdentity.name)
                            LabeledContent("Group", value: proposal.expectedIdentity.group)
                            LabeledContent("Raw guide", value: proposal.expectedIdentity.epgChannelID ?? "None")
                        }.font(.callout).textSelection(.enabled).padding(8)
                    }
                }
                GroupBox("Link to an existing feed") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Feed", selection: $destinationFeedID) {
                            Text("Choose a feed").tag("")
                            ForEach(coordinator.catalog?.feeds ?? []) { feed in
                                Text("\(feed.name) · \(feed.country) · \(feed.edition)").tag(feed.id)
                            }
                        }
                        Button("Link current identity") {
                            save { await coordinator.link(item.key, to: destinationFeedID) }
                        }.disabled(current == nil || destinationFeedID.isEmpty || isSaving)
                        Text("This is an explicit membership decision. It does not verify identical stream content.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("Keep as a separate feed") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Feed name", text: $splitName).textFieldStyle(.roundedBorder)
                        HStack {
                            TextField("Region", text: $splitCountry).textFieldStyle(.roundedBorder)
                            TextField("Language", text: $splitLanguage).textFieldStyle(.roundedBorder)
                            TextField("Edition", text: $splitEdition).textFieldStyle(.roundedBorder)
                        }
                        Button("Create separate feed") {
                            save {
                                _ = await coordinator.split(item.key, name: splitName.trimmingCharacters(in: .whitespacesAndNewlines),
                                    country: splitCountry.trimmingCharacters(in: .whitespacesAndNewlines),
                                    language: splitLanguage.trimmingCharacters(in: .whitespacesAndNewlines),
                                    edition: splitEdition.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                        }.disabled(current == nil || splitName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || splitCountry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                HStack {
                    if item.state == .changedIdentity, item.feedID != nil {
                        Button("Accept current identity") { save { await coordinator.acceptIdentity(item.key) } }
                            .disabled(current == nil || isSaving)
                    }
                    Button("Exclude from Smart Channels") { save { await coordinator.reject(item.key) } }
                        .disabled(item.state == .rejected || isSaving)
                }
                Button("Restore proposal") { save { await coordinator.restoreProposal(item.key) } }.disabled(isSaving)
                Text("Restoring removes this endpoint’s manual link, split acceptance and exclusion. A changed endpoint will still need review.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Source \(item.key.sourceID.uuidString.lowercased())\nNative stream \(item.key.nativeID)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(20)
        }
        .onAppear {
            destinationFeedID = item.feedID ?? ""
            splitName = current?.name ?? proposal?.expectedIdentity.name ?? ""
            if let feedID = item.feedID, let feed = coordinator.catalog?.feed(id: feedID) {
                splitCountry = feed.country
                splitLanguage = feed.language
                splitEdition = feed.edition
            }
        }
    }

    private func save(_ action: @escaping @MainActor () async -> Void) {
        isSaving = true
        Task {
            await action()
            isSaving = false
        }
    }
}
