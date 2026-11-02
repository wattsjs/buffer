import SwiftUI

private struct EPGActionModelKey: EnvironmentKey {
    static let defaultValue: EPGViewModel? = nil
}

extension EnvironmentValues {
    var epgActionModel: EPGViewModel? {
        get { self[EPGActionModelKey.self] }
        set { self[EPGActionModelKey.self] = newValue }
    }
}

/// Reuses the existing source inspector from every logical channel surface.
struct SmartSportsSourceMenuItem: View {
    let channel: Channel
    @Environment(\.epgActionModel) private var model

    var body: some View {
        if let feedID = channel.sourceOwnership?.logicalChannelID, let model {
            Button {
                model.smartSportsInspectorFeedID = feedID
            } label: {
                Label("Playback & Guide Sources…", systemImage: "slider.horizontal.3")
            }
            Button {
                model.showOriginalSourceGuide(for: channel)
            } label: {
                Label("Open Original Source Guide", systemImage: "list.bullet.rectangle")
            }
        }
    }
}
