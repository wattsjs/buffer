import SwiftUI

struct ChannelSidebarView: View {
    @Bindable var viewModel: EPGViewModel
    @State private var notificationManager = NotificationManager.shared
    @State private var recordingManager = RecordingManager.shared
    @Environment(\.openSettings) private var openSettings
    @AppStorage("hideSport") private var hideSport = false

    private var activeRecordingCount: Int {
        recordingManager.recordings.filter {
            $0.status == .recording || $0.status == .scheduled
        }.count
    }

    private var playlistSelectionBinding: Binding<UUID> {
        Binding(
            get: { viewModel.activePlaylistID ?? viewModel.playlists.first?.id ?? UUID() },
            set: { viewModel.setActivePlaylist(id: $0) }
        )
    }

    @ViewBuilder
    private var playlistPicker: some View {
        if viewModel.playlists.count > 1, let active = viewModel.activePlaylist {
            Menu {
                ForEach(viewModel.playlists) { playlist in
                    Button {
                        playlistSelectionBinding.wrappedValue = playlist.id
                    } label: {
                        if playlist.id == active.id {
                            Label(
                                playlist.name.isEmpty ? "Untitled Playlist" : playlist.name,
                                systemImage: "checkmark"
                            )
                        } else {
                            Text(playlist.name.isEmpty ? "Untitled Playlist" : playlist.name)
                        }
                    }
                }
                Divider()
                Button("Manage Playlists…") { openSettings() }
            } label: {
                PlaylistPickerLabel(
                    name: active.name.isEmpty ? "Playlist" : active.name
                )
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help("Switch playlist")
        }
    }

    @ViewBuilder
    private var remindersRow: some View {
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

    @ViewBuilder
    private var recordingsRow: some View {
        HStack {
            Label("Recordings", systemImage: "record.circle")
            Spacer()
            if activeRecordingCount > 0 {
                Text("\(activeRecordingCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.red)
                    )
            }
        }
        .tag(SidebarSelection.recordings)
    }

    var body: some View {
        List(selection: $viewModel.selection) {
            if viewModel.playlists.count > 1 {
                Section {
                    playlistPicker
                }
            }

            Section {
                Label("Home", systemImage: "house")
                    .tag(SidebarSelection.home)

                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarSelection.search)

                if !hideSport {
                    Label("Sports", systemImage: "sportscourt.fill")
                        .tag(SidebarSelection.sports)
                }

                remindersRow
                recordingsRow
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

private struct PlaylistPickerLabel: View {
    let name: String

    var body: some View {
        HStack {
            Label(name, systemImage: "list.bullet.rectangle")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
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
