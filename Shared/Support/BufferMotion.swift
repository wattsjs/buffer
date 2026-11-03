import SwiftUI

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
