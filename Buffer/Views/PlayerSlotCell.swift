import SwiftUI

/// One slot in the grid. Mounts the slot's `CAMetalLayer` (via
/// `MPVLayerView`) at the back, and optionally overlays per-cell chrome
/// (focus ring, label, close button, tap-to-focus) on top.
///
/// `showCellChrome` is `false` in single mode (the surrounding `PlayerView`
/// has its own chrome and tap-to-pause), and `true` in multi-view.
struct PlayerSlotCell: View {
    let slot: PlayerSlot
    let isFocused: Bool
    let canRemove: Bool
    let showCellChrome: Bool
    let onFocus: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.black

            MPVLayerView(player: slot.player)

            if showCellChrome {
                // Tap-to-focus layer for multi-view. In single mode this
                // would steal taps from PlayerView's tap-to-pause overlay.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onFocus)
            }

            if let error = slot.player.errorMessage {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .padding(10)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .overlay(alignment: .topLeading) {
            if showCellChrome && (isHovering || isFocused) {
                slotLabel
                    .padding(8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showCellChrome && canRemove && isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Remove from multi-view")
                .transition(.opacity)
            }
        }
        .overlay {
            if showCellChrome {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        isFocused ? Color.accentColor : Color.white.opacity(0.08),
                        lineWidth: isFocused ? 2 : 1
                    )
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }

    @ViewBuilder
    private var slotLabel: some View {
        HStack(spacing: 6) {
            if slot.channel.logoURL != nil {
                ChannelLogoView(url: slot.channel.logoURL, contentInset: 2)
                    .frame(width: 18, height: 18)
            }
            Text(slot.channel.name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.white)
            if isFocused {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.55), in: Capsule())
    }
}
