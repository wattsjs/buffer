import AppKit
import SwiftUI

/// Drawing roles shared by the AppKit timeline, programme canvas and sticky
/// metadata. Resolve against the consuming view's appearance, never NSApp's.
@MainActor
enum EPGGridStyle {
    enum ProgramState { case upcoming, past, replay, live }

    @MainActor struct Palette {
        let page: NSColor
        let header: NSColor
        let primaryText: NSColor
        let metadataText: NSColor
        let upcomingSurface: NSColor
        let pastSurface: NSColor
        let liveSurface: NSColor
        let hoverTint: NSColor
        let border: NSColor
        let hoverBorder: NSColor
        let liveIndicator: NSColor
        let replayIndicator: NSColor

        func surface(for state: ProgramState, hovered: Bool = false) -> NSColor {
            let surface: NSColor
            switch state {
            case .upcoming: surface = upcomingSurface
            case .past, .replay: surface = pastSurface
            case .live: surface = liveSurface
            }
            return hovered ? EPGGridStyle.composite(hoverTint, over: surface) : surface
        }
    }

    static func palette(for appearance: NSAppearance) -> Palette {
        var result: Palette!
        appearance.performAsCurrentDrawingAppearance {
            let page = rgb(.textBackgroundColor)
            let text = rgb(.labelColor)
            let red = rgb(.systemRed)
            let teal = rgb(.systemTeal)
            let accent = rgb(.controlAccentColor)
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let card = composite(text.withAlphaComponent(isDark ? 0.065 : 0.055), over: page)
            let past = composite(text.withAlphaComponent(isDark ? 0.035 : 0.025), over: page)
            result = Palette(
                page: page,
                header: composite(text.withAlphaComponent(isDark ? 0.025 : 0.035), over: page),
                primaryText: text,
                // System secondaryLabelColor is too faint for ten-point
                // programme times on elevated light surfaces. Keep the same
                // semantic neutral hue with enough opacity in both themes.
                metadataText: text.withAlphaComponent(0.68),
                upcomingSurface: card,
                pastSurface: past,
                liveSurface: composite(red.withAlphaComponent(isDark ? 0.055 : 0.035), over: card),
                hoverTint: accent.withAlphaComponent(isDark ? 0.09 : 0.06),
                border: composite(text.withAlphaComponent(isDark ? 0.15 : 0.13), over: card),
                hoverBorder: composite(accent.withAlphaComponent(isDark ? 0.75 : 0.65), over: card),
                liveIndicator: isDark ? red : composite(text.withAlphaComponent(0.12), over: red),
                replayIndicator: isDark ? teal : composite(text.withAlphaComponent(0.25), over: teal)
            )
        }
        return result
    }

    static func applyAppearance(to view: NSView, scheme: ColorScheme, contrast: ColorSchemeContrast) {
        let name: NSAppearance.Name
        switch (scheme, contrast) {
        case (.dark, .increased): name = .accessibilityHighContrastDarkAqua
        case (.light, .increased): name = .accessibilityHighContrastAqua
        case (.dark, _): name = .darkAqua
        default: name = .aqua
        }
        guard view.appearance?.name != name else { return }
        view.appearance = NSAppearance(named: name)
    }

    static func state(for program: EPGProgram, now: Date, replayStart: Date?) -> ProgramState {
        if program.start <= now && program.end > now { return .live }
        if program.end <= now {
            if let replayStart, program.start >= replayStart { return .replay }
            return .past
        }
        return .upcoming
    }

    private static func rgb(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }

    static func composite(_ foreground: NSColor, over background: NSColor) -> NSColor {
        let fg = rgb(foreground)
        let bg = rgb(background)
        let alpha = fg.alphaComponent
        return NSColor(srgbRed: fg.redComponent * alpha + bg.redComponent * (1 - alpha),
                       green: fg.greenComponent * alpha + bg.greenComponent * (1 - alpha),
                       blue: fg.blueComponent * alpha + bg.blueComponent * (1 - alpha), alpha: 1)
    }
}

/// Views with time-dependent drawing can refresh their colors without
/// rebuilding timeline blocks or invalidating the visible-row metadata cache.
@MainActor
protocol EPGTimeSensitiveDrawing: AnyObject {
    func setReferenceDate(_ date: Date)
}

/// Document-coordinate drawing hosted on a horizontally bounded native surface.
protocol EPGViewportDrawing: AnyObject {
    func setTimelineOriginX(_ x: CGFloat)
}
