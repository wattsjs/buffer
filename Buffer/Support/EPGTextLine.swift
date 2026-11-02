import AppKit
import CoreText

/// A single-line text style for guide labels drawn with CoreText.
///
/// `NSString` drawing runs TextKit layout (and allocates) for every label on
/// every frame. Guide labels are single truncating-tail lines in a fixed line
/// height, so they are shaped once into a `CTLine` (stored with the row's
/// layout) and drawn directly. The baseline matches TextKit's placement in a
/// fixed-height line fragment (the line height minus the font's descent,
/// rounded up to whole points), so untruncated labels render pixel-identically.
@MainActor
final class EPGTextStyle {
    let font: NSFont
    let lineHeight: CGFloat
    /// Baseline offset from the top of the label rectangle.
    let baseline: CGFloat
    private let ellipsis: CTLine

    init(font: NSFont, lineHeight: CGFloat) {
        self.font = font
        self.lineHeight = lineHeight
        baseline = lineHeight - ceil(-font.descender)
        ellipsis = CTLineCreateWithAttributedString(Self.attributed("\u{2026}", font: font))
    }

    static let programmeTitle = EPGTextStyle(font: .systemFont(ofSize: 13, weight: .medium),
                                             lineHeight: EPGStickyLabelMetrics.titleRowHeight)
    static let timeRange = EPGTextStyle(font: .systemFont(ofSize: 10, weight: .regular),
                                        lineHeight: EPGStickyLabelMetrics.topRowHeight)
    static let channelName = EPGTextStyle(font: .systemFont(ofSize: 11, weight: .semibold),
                                          lineHeight: EPGStickyLabelMetrics.topRowHeight)

    private static func attributed(_ string: String, font: NSFont) -> NSAttributedString {
        // Colour comes from the context fill, so one shaped line serves every
        // appearance and state.
        NSAttributedString(string: string, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
    }

    func line(_ string: String) -> EPGTextLine {
        let line = CTLineCreateWithAttributedString(Self.attributed(string, font: font))
        return EPGTextLine(line: line, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    /// Draws `text` left-aligned in `rect` (flipped coordinates), truncating
    /// the tail with an ellipsis when it is wider than the rectangle.
    func draw(_ text: EPGTextLine, in rect: CGRect, color: NSColor, context: CGContext) {
        var drawn = text.line
        if text.width > rect.width {
            guard let truncated = CTLineCreateTruncatedLine(text.line, Double(rect.width), .end, ellipsis) else { return }
            drawn = truncated
        }
        color.setFill()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: rect.minX, y: rect.minY + baseline)
        CTLineDraw(drawn, context)
    }
}

/// A shaped label and its typographic width.
struct EPGTextLine {
    let line: CTLine
    let width: CGFloat
}
