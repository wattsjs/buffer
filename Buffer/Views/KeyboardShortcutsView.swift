import SwiftUI

struct KeyboardShortcutsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                shortcutSection(
                    title: "Player",
                    rows: [
                        ("Space", "Play or pause"),
                        ("←", "Seek back 10 seconds"),
                        ("→", "Seek forward 10 seconds"),
                        ("F", "Toggle fullscreen"),
                    ]
                )

                shortcutSection(
                    title: "Library",
                    rows: [
                        ("⌘F", "Search programs"),
                        ("⌘?", "Show this shortcuts window"),
                    ]
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 380, minHeight: 260)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func shortcutSection(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))

            VStack(spacing: 10) {
                ForEach(rows, id: \.0) { row in
                    HStack(spacing: 16) {
                        ShortcutKeyCaps(text: row.0)
                        Text(row.1)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

private struct ShortcutKeyCaps: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}
