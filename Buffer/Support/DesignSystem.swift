//
//  DesignSystem.swift
//  Buffer
//
//  Shared layout, motion, type, and interaction tokens so Home / Sports /
//  Search / Player chrome feel like one product.
//

import SwiftUI

// MARK: - Layout

enum BufferLayout {
    /// Outer padding for scroll pages (Home, Reminders, empty states).
    static let page: CGFloat = 24
    /// Horizontal inset for filter bars and dense grids (Sports, VOD, Search).
    static let content: CGFloat = 18
    /// Vertical gap between major page sections.
    static let section: CGFloat = 20
    /// Gap between cards in a grid/row.
    static let cardGap: CGFloat = 12
    /// Inner padding for interactive cards.
    static let cardPadding: CGFloat = 14
    /// Standard elevated card radius (Sports, Home live cards).
    static let cardRadius: CGFloat = 12
    /// Compact card radius (search rows, VOD posters, channel tiles).
    static let compactRadius: CGFloat = 10
    /// Small chips / section header pills.
    static let chipRadius: CGFloat = 6
    /// Soft lift under elevated surfaces.
    static let cardShadow = Color.black.opacity(0.06)
    static let cardShadowRadius: CGFloat = 8
    static let cardShadowY: CGFloat = 2
}

// MARK: - Motion

/// Animation presets tuned for frequent desktop UI.
/// Critically damped springs for structural motion; short ease-out for hover/press.
enum BufferMotion {
    /// Hover highlight / border change — seen tens of times per session.
    static let hover = Animation.easeOut(duration: 0.12)
    /// Button press scale — must feel instant.
    static let press = Animation.easeOut(duration: 0.1)
    /// Player chrome show/hide.
    static let chrome = Animation.easeOut(duration: 0.18)
    /// Focus ring / selection chrome.
    static let focus = Animation.easeOut(duration: 0.15)
    /// Toast / sync banner enter — critically damped, no bounce.
    static let bannerIn = Animation.spring(response: 0.32, dampingFraction: 1.0)
    /// Toast / sync banner exit — snappy ease-out (never ease-in).
    static let bannerOut = Animation.easeOut(duration: 0.18)
    /// Expandable panels (stats for nerds).
    static let panel = Animation.spring(response: 0.26, dampingFraction: 0.9)
    /// Multi-view layout reflow.
    static let layout = Animation.spring(response: 0.28, dampingFraction: 0.82)
    /// Color / logo background crossfade.
    static let color = Animation.easeInOut(duration: 0.2)
    /// Decorative live pulse (respect reduced motion at call site).
    static let livePulse = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)
}

// MARK: - Typography

/// Semantic type scale. Prefer these over raw `Font.system(size:)` in views.
enum BufferFont {
    // Page / section
    static let display = Font.system(size: 30, weight: .semibold)
    static let sectionTitle = Font.system(size: 18, weight: .semibold)
    static let emptyIcon = Font.system(size: 32, weight: .light)
    static let emptyTitle = Font.system(size: 14)
    static let emptySubtitle = Font.system(size: 11)

    // Cards / lists
    static let title = Font.system(size: 15, weight: .semibold)
    static let titleMedium = Font.system(size: 15, weight: .medium)
    static let cardTitle = Font.system(size: 13, weight: .semibold)
    static let cardTitleRegular = Font.system(size: 13)
    static let cardTitleMedium = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let cardSubtitle = Font.system(size: 11, weight: .medium)
    static let meta = Font.system(size: 11)
    static let metaMedium = Font.system(size: 11, weight: .medium)
    static let metaSemibold = Font.system(size: 11, weight: .semibold)

    // Compact UI
    static let caption = Font.system(size: 12)
    static let captionMedium = Font.system(size: 12, weight: .medium)
    static let captionSemibold = Font.system(size: 12, weight: .semibold)
    static let badge = Font.system(size: 11, weight: .semibold)
    static let micro = Font.system(size: 10)
    static let microMedium = Font.system(size: 10, weight: .medium)
    static let microSemibold = Font.system(size: 10, weight: .semibold)
    static let microBadge = Font.system(size: 10, weight: .bold)
    static let sectionLabel = Font.system(size: 10, weight: .semibold)
    static let tiny = Font.system(size: 9)
    static let tinySemibold = Font.system(size: 9, weight: .semibold)
    static let tinyBold = Font.system(size: 9, weight: .bold)
    static let tinyHeavy = Font.system(size: 9, weight: .heavy)

    // Specialty
    static let score = Font.system(size: 15, weight: .bold)
    static let control = Font.system(size: 11, weight: .semibold)
    static let icon = Font.system(size: 13, weight: .medium)
    static let iconLarge = Font.system(size: 18, weight: .regular)
    static let posterFallback = Font.system(size: 22, weight: .regular)
    static let heroIcon = Font.system(size: 24)
    static let settingsHero = Font.system(size: 40)
    static let keycap = Font.system(size: 12, weight: .semibold, design: .rounded)
    static let hairline = Font.system(size: 8)
    static let hairlineBold = Font.system(size: 8, weight: .bold)
}

// MARK: - Pressable control style

/// Subtle scale-down on press. Use on cards/chips/buttons that should feel physical.
struct BufferPressStyle: ButtonStyle {
    var scale: CGFloat = 0.98

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(BufferMotion.press, value: configuration.isPressed)
    }
}

// MARK: - Filter bar + section header

/// Shared top chrome used by Sports / VOD / Search filter rows.
struct BufferFilterBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, BufferLayout.content)
            .padding(.vertical, 10)
            .background(.bar)
    }
}

/// Pinned section label used in Sports / Search grids.
struct BufferPinnedSectionHeader: View {
    var icon: String? = nil
    let title: String
    let count: Int
    var accent: Color = .secondary
    var forceUppercase: Bool = true
    var pinnedChrome: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(BufferFont.sectionLabel)
                    .foregroundStyle(accent)
                    .frame(width: 14)
            }
            Text(forceUppercase ? title.uppercased() : title)
                .font(BufferFont.sectionLabel)
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(BufferFont.microMedium)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
        }
        .padding(.vertical, pinnedChrome ? 7 : 0)
        .padding(.horizontal, pinnedChrome ? 8 : 0)
        .background {
            if pinnedChrome {
                RoundedRectangle(cornerRadius: BufferLayout.chipRadius, style: .continuous)
                    .fill(.bar)
            }
        }
    }
}

/// Compact capsule chip used for sport filters and similar toggles.
struct BufferFilterChip: View {
    let title: String
    var systemImage: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(BufferFont.tiny)
                }
                Text(title)
                    .font(BufferFont.metaMedium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                        lineWidth: 0.5
                    )
            )
            .foregroundStyle(isSelected ? .white : .primary)
            .animation(BufferMotion.hover, value: isSelected)
        }
        .buttonStyle(BufferPressStyle(scale: 0.97))
    }
}

// MARK: - Hover + card surfaces

struct BufferHoverHighlight: ViewModifier {
    var isHovering: Bool
    var cornerRadius: CGFloat = BufferLayout.compactRadius
    var idleFill: Color = Color(nsColor: .controlBackgroundColor)
    var hoverFill: Color = Color.accentColor.opacity(0.12)
    var idleStroke: Color = Color.primary.opacity(0.08)
    var hoverStroke: Color = Color.accentColor.opacity(0.35)
    var lineWidth: CGFloat = 0.75
    var elevated: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering ? hoverFill : idleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isHovering ? hoverStroke : idleStroke, lineWidth: lineWidth)
            )
            .shadow(
                color: elevated && isHovering ? BufferLayout.cardShadow : .clear,
                radius: BufferLayout.cardShadowRadius,
                y: BufferLayout.cardShadowY
            )
            .animation(BufferMotion.hover, value: isHovering)
    }
}

struct BufferCardSurface: ViewModifier {
    var isHovering: Bool = false
    var isLive: Bool = false
    var cornerRadius: CGFloat = BufferLayout.cardRadius

    private var fill: Color {
        if isLive {
            return Color.red.opacity(isHovering ? 0.1 : 0.05)
        }
        return Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 1 : 0.72)
    }

    private var stroke: Color {
        if isLive {
            return Color.red.opacity(isHovering ? 0.42 : 0.28)
        }
        return Color(nsColor: .separatorColor).opacity(isHovering ? 0.7 : 0.45)
    }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 0.5)
            )
            .shadow(
                color: isHovering ? BufferLayout.cardShadow : .clear,
                radius: BufferLayout.cardShadowRadius,
                y: BufferLayout.cardShadowY
            )
            .animation(BufferMotion.hover, value: isHovering)
    }
}

// MARK: - Live indicator

/// Pulsing red live dot. Falls back to static when Reduce Motion is on.
struct LiveIndicatorDot: View {
    var size: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: size, height: size)
            .opacity(reduceMotion ? 1 : (pulse ? 1 : 0.45))
            .scaleEffect(reduceMotion ? 1 : (pulse ? 1 : 0.85))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(BufferMotion.livePulse) {
                    pulse = true
                }
            }
    }
}

// MARK: - Sidebar count badge

struct SidebarCountBadge: View {
    let count: Int
    var emphasized: Bool = false

    var body: some View {
        Text("\(count)")
            .font(BufferFont.badge)
            .monospacedDigit()
            .foregroundStyle(emphasized ? .white : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(emphasized ? Color.red : Color.secondary.opacity(0.15))
            )
            .accessibilityLabel("\(count)")
    }
}

// MARK: - View helpers

extension View {
    func bufferPageBackground() -> some View {
        background(Color(nsColor: .textBackgroundColor))
    }

    func bufferHoverHighlight(
        isHovering: Bool,
        cornerRadius: CGFloat = BufferLayout.compactRadius,
        idleFill: Color = Color(nsColor: .controlBackgroundColor),
        hoverFill: Color = Color.accentColor.opacity(0.12),
        idleStroke: Color = Color.primary.opacity(0.08),
        hoverStroke: Color = Color.accentColor.opacity(0.35),
        lineWidth: CGFloat = 0.75,
        elevated: Bool = false
    ) -> some View {
        modifier(
            BufferHoverHighlight(
                isHovering: isHovering,
                cornerRadius: cornerRadius,
                idleFill: idleFill,
                hoverFill: hoverFill,
                idleStroke: idleStroke,
                hoverStroke: hoverStroke,
                lineWidth: lineWidth,
                elevated: elevated
            )
        )
    }

    func bufferCardSurface(
        isHovering: Bool = false,
        isLive: Bool = false,
        cornerRadius: CGFloat = BufferLayout.cardRadius
    ) -> some View {
        modifier(
            BufferCardSurface(
                isHovering: isHovering,
                isLive: isLive,
                cornerRadius: cornerRadius
            )
        )
    }

    /// Tracks hover state with the standard hover animation curve.
    func bufferHoverTracking(_ isHovering: Binding<Bool>) -> some View {
        onHover { hovering in
            withAnimation(BufferMotion.hover) {
                isHovering.wrappedValue = hovering
            }
        }
    }
}
