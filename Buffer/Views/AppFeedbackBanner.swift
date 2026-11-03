import SwiftUI

struct AppFeedbackBanner: View {
    let message: AppFeedbackMessage
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if message.showsActivity {
                    Image(systemName: message.symbol)
                        .symbolEffect(.rotate, options: .repeat(.continuous))
                } else {
                    Image(systemName: message.symbol)
                }
            }
            .font(BufferFont.cardTitle)
            .foregroundStyle(message.tone.accent)
            .padding(.top, message.title == nil ? 1 : 2)

            if let title = message.title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(BufferFont.captionSemibold)
                    Text(message.message)
                        .font(BufferFont.meta)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(message.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let onDismiss {
                Spacer(minLength: 12)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(BufferFont.microSemibold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 520, alignment: .leading)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}
