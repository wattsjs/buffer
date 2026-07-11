import SwiftUI

struct ChannelSidebarView: View {
    @Bindable var viewModel: EPGViewModel
    @State private var notificationManager = NotificationManager.shared
    @State private var recordingManager = RecordingManager.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hideSport") private var hideSport = false
    @AppStorage(EPGViewModel.disableVODKey) private var disableVOD = false
    @AppStorage("sidebarLiveExpanded") private var liveExpanded = true
    @AppStorage("sidebarMoviesExpanded") private var moviesExpanded = true
    @AppStorage("sidebarTVExpanded") private var tvExpanded = true
    @AppStorage("sidebarHiddenExpanded") private var hiddenExpanded = false

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
                Button("Manage Sources…") { openWindow(id: "settings") }
            } label: {
                PlaylistPickerLabel(
                    name: active.name.isEmpty ? "Source" : active.name
                )
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help("Switch source")
        }
    }

    @ViewBuilder
    private var remindersRow: some View {
        HStack {
            Label("Reminders", systemImage: "bell")
            Spacer()
            if !notificationManager.reminders.isEmpty {
                SidebarCountBadge(count: notificationManager.reminders.count)
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
                SidebarCountBadge(count: activeRecordingCount, emphasized: true)
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

            Section {
                if liveExpanded {
                    liveRows
                }
            } header: {
                SidebarSectionHeader(title: "Live", isExpanded: $liveExpanded)
            }

            if !disableVOD, !viewModel.movieItems.isEmpty {
                Section {
                    if moviesExpanded {
                        moviesRows
                    }
                } header: {
                    SidebarSectionHeader(title: "Movies", isExpanded: $moviesExpanded)
                }
            }

            if !disableVOD, !viewModel.vodSeries.isEmpty {
                Section {
                    if tvExpanded {
                        tvRows
                    }
                } header: {
                    SidebarSectionHeader(title: "TV", isExpanded: $tvExpanded)
                }
            }

            if !viewModel.hiddenGroups.isEmpty {
                Section {
                    if hiddenExpanded {
                        hiddenRows
                    }
                } header: {
                    SidebarSectionHeader(title: "Hidden", isExpanded: $hiddenExpanded)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var liveRows: some View {
        if !viewModel.favoriteChannelIDs.isEmpty {
            HStack {
                Label("Favorites", systemImage: "star.fill")
                Spacer()
                SidebarCountBadge(count: viewModel.favoriteChannelIDs.count)
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

    @ViewBuilder
    private var moviesRows: some View {
        HStack {
            Label("Movies", systemImage: "film")
            Spacer()
            SidebarCountBadge(count: viewModel.movieItems.count)
        }
        .tag(SidebarSelection.movies)

        ForEach(viewModel.movieGroups, id: \.self) { group in
            Label(group, systemImage: "folder")
                .tag(SidebarSelection.movieGroup(group))
        }
    }

    @ViewBuilder
    private var tvRows: some View {
        HStack {
            Label("TV Shows", systemImage: "rectangle.stack")
            Spacer()
            SidebarCountBadge(count: viewModel.vodSeries.count)
        }
        .tag(SidebarSelection.series)

        ForEach(viewModel.seriesGroups, id: \.self) { group in
            Label(group, systemImage: "folder")
                .tag(SidebarSelection.seriesGroup(group))
        }
    }

    @ViewBuilder
    private var hiddenRows: some View {
        ForEach(viewModel.hiddenGroups, id: \.self) { group in
            HiddenFolderRow(name: group) {
                viewModel.showGroup(group)
            }
        }
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(BufferMotion.focus) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(BufferFont.tinySemibold)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                    .animation(BufferMotion.focus, value: isExpanded)
                Text(title)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                .font(BufferFont.microSemibold)
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
