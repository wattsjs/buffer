import SwiftUI

struct ChannelSidebarView: View {
    @Bindable var viewModel: EPGViewModel
    @State private var notificationManager = NotificationManager.shared
    @AppStorage("hideSport") private var hideSport = false

    var body: some View {
        List(selection: $viewModel.selection) {
            Section {
                Label("Home", systemImage: "house")
                    .tag(SidebarSelection.home)

                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarSelection.search)

                if !hideSport {
                    Label("Sports", systemImage: "sportscourt.fill")
                        .tag(SidebarSelection.sports)
                }

                HStack {
                    Label("Reminders", systemImage: "bell")
                    Spacer()
                    if !notificationManager.reminders.isEmpty {
                        Text("\(notificationManager.reminders.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.secondary.opacity(0.15))
                            )
                    }
                }
                .tag(SidebarSelection.reminders)
            }

            Section("Guide") {
                if !viewModel.favoriteChannelIDs.isEmpty {
                    HStack {
                        Label("Favorites", systemImage: "star.fill")
                        Spacer()
                        Text("\(viewModel.favoriteChannelIDs.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.secondary.opacity(0.15))
                            )
                    }
                    .tag(SidebarSelection.favorites)
                }

                Label("All Channels", systemImage: "tv")
                    .tag(SidebarSelection.allChannels)

                ForEach(viewModel.groups, id: \.self) { group in
                    Label(group, systemImage: "folder")
                        .tag(SidebarSelection.group(group))
                        .contextMenu {
                            Button("Hide Folder") {
                                viewModel.hideGroup(group)
                            }
                        }
                }
                .onMove { offsets, destination in
                    viewModel.moveGroups(fromOffsets: offsets, toOffset: destination)
                }
            }

            if !viewModel.hiddenGroups.isEmpty {
                Section("Hidden") {
                    ForEach(viewModel.hiddenGroups, id: \.self) { group in
                        HiddenFolderRow(name: group) {
                            viewModel.showGroup(group)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct HiddenFolderRow: View {
    let name: String
    let onShow: () -> Void

    var body: some View {
        HStack {
            Label(name, systemImage: "folder")
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onShow) {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .help("Show folder")
        }
        .contextMenu {
            Button("Show Folder", action: onShow)
        }
    }
}
