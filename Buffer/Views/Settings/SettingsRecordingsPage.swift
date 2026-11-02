import AppKit
import SwiftUI

struct RecordingsSettingsPage: View {
    @State private var manager = RecordingManager.shared

    var body: some View {
        SettingsFormPage(title: "Recordings", detail: "Choose where recordings go and how scheduled programmes are captured.") {
            Section {
                LabeledContent("Save recordings to") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(manager.outputDirectory.path).lineLimit(2).truncationMode(.middle)
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Choose Folder…") { chooseFolder() }
                    }
                }
            } header: { Text("Storage") } footer: {
                Text("Recordings are saved as TS files in folders by channel.")
            }

            Section {
                LabeledContent("Start before programme") {
                    HStack {
                        Text("\(manager.preRollSeconds) seconds").monospacedDigit().foregroundStyle(.secondary)
                        Stepper("Start early", value: Binding(get: { manager.preRollSeconds }, set: { manager.preRollSeconds = $0 }),
                            in: 0...300, step: 10).labelsHidden()
                            .accessibilityLabel("Start before programme")
                            .accessibilityValue("\(manager.preRollSeconds) seconds")
                    }
                }
                .accessibilityElement(children: .contain)
                LabeledContent("Continue after programme") {
                    HStack {
                        Text("\(manager.postRollSeconds) seconds").monospacedDigit().foregroundStyle(.secondary)
                        Stepper("Stop late", value: Binding(get: { manager.postRollSeconds }, set: { manager.postRollSeconds = $0 }),
                            in: 0...600, step: 30).labelsHidden()
                            .accessibilityLabel("Continue after programme")
                            .accessibilityValue("\(manager.postRollSeconds) seconds")
                    }
                }
                .accessibilityElement(children: .contain)
            } header: { Text("Schedule padding") } footer: {
                Text("Add time around scheduled recordings for early starts and overruns.")
            }

            Section {
                Toggle("Wake Mac for scheduled recordings", isOn: Binding(
                    get: { manager.wakeMacForRecordings }, set: { manager.wakeMacForRecordings = $0 }))
            } header: { Text("Scheduled recording") } footer: {
                Text("Wakes your Mac about two minutes before recording. Buffer must remain open.")
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = manager.outputDirectory
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            manager.setOutputDirectory(url, fromPicker: true)
        }
    }
}
