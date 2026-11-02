import SwiftUI

struct PlaybackSettingsPage: View {
    @AppStorage(ExternalPlayer.selectedPlayerKey) private var player: ExternalPlayerKind = .none
    @AppStorage(BufferSetting.appStorageKey) private var bufferSeconds = BufferSetting.default

    var body: some View {
        SettingsFormPage(title: "Playback", detail: "Choose your player and balance live delay with stream stability.") {
            Section {
                Picker("Open videos with", selection: $player) {
                    ForEach(ExternalPlayerKind.allCases) { option in Text(option == .none ? "Buffer" : option.displayName).tag(option) }
                }
            } header: { Text("Default player") } footer: {
                Text(player == .none ? "Videos play in Buffer." : "Original source playlists open in \(player.displayName). Smart Sports uses Buffer for managed connection limits and source recovery.")
            }

            Section {
                LabeledContent("Live buffer") {
                    HStack(spacing: 12) {
                        Text("\(bufferSeconds) seconds").monospacedDigit().foregroundStyle(.secondary)
                        Stepper("Live buffer", value: $bufferSeconds, in: BufferSetting.range).labelsHidden()
                    }
                }
            } header: { Text("Live streaming") } footer: {
                Text("A larger buffer can smooth unreliable streams with more delay. Changes apply to open Buffer players.")
            }
        }
    }
}

struct AppearanceSettingsPage: View {
    @AppStorage("buffer_media_info_display") private var mediaInfo: MediaInfoDisplay = .expanded
    @AppStorage(StreamProbeSetting.enabledKey) private var probeStreams = StreamProbeSetting.defaultEnabled

    var body: some View {
        SettingsFormPage(title: "Appearance", detail: "Control player information and channel details. Buffer follows your Mac’s appearance.") {
            Section {
                Picker("Media information", selection: $mediaInfo) {
                    Text("Expanded").tag(MediaInfoDisplay.expanded)
                    Text("Compact").tag(MediaInfoDisplay.collapsed)
                }
            } header: { Text("Player overlay") } footer: {
                Text("Choose how much stream information appears over the player. Open players update immediately.")
            }

            Section {
                Toggle("Read stream technical details", isOn: $probeStreams)
                Button("Clear Channel Metadata") { StreamProbeService.shared.clearAll() }
            } header: { Text("Channel information") } footer: {
                Text("Reads codec, resolution and frame rate by briefly opening a stream. Buffer defers these checks while players are open and shares provider connection limits.")
            }
        }
        .onChange(of: probeStreams) { _, enabled in
            if !enabled { StreamProbeService.shared.clearAll() }
        }
    }
}
