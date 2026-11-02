import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case sources, library, guide, playback, recordings, appearance
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources: "Sources"
        case .library: "Library"
        case .guide: "Guide & Sports"
        case .playback: "Playback"
        case .recordings: "Recordings"
        case .appearance: "Appearance"
        }
    }

    var symbol: String {
        switch self {
        case .sources: "server.rack"
        case .library: "rectangle.stack"
        case .guide: "list.bullet.rectangle"
        case .playback: "play.rectangle"
        case .recordings: "record.circle"
        case .appearance: "paintpalette"
        }
    }

    var summary: String {
        switch self {
        case .sources: "Accounts and playlists"
        case .library: "Movies, TV and history"
        case .guide: "Listings, sports and folders"
        case .playback: "Player and live buffer"
        case .recordings: "Storage and scheduling"
        case .appearance: "Player and channel details"
        }
    }

    func matches(_ text: String) -> Bool {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let terms: String
        switch self {
        case .sources: terms = "account connection server username password Xtream Stalker MAG M3U playlist test source"
        case .library: terms = "movies TV VOD history recently watched recommendations refresh channels automatic update"
        case .guide: terms = "sports scores ESPN EPG guide catchup archive lookback refresh hidden folders order"
        case .playback: terms = "player external IINA VLC mpv buffering live delay playback"
        case .recordings: terms = "recordings save output directory storage folder padding wake schedule"
        case .appearance: terms = "appearance media details overlay compact expanded technical codec resolution FPS metadata cache"
        }
        let searchable = title + " " + summary + " " + terms
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { searchable.localizedCaseInsensitiveContains(String($0)) }
    }
}

struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    let query: String

    var body: some View {
        List(selection: $selection) {
            Section("Buffer") {
                ForEach(SettingsSection.allCases.filter { $0.matches(query) }) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Settings")
    }
}

struct SettingsPageHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title2.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsFormPage<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(title: title, detail: detail)
            Form(content: content).formStyle(.grouped)
        }
    }
}
