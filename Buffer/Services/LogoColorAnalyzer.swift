import Foundation
import CoreGraphics
import AppKit

/// Dominant logo colour. Computed once per logo, off the main thread, when
/// `LogoAtlas` packs the logo into its slot, and stored as packed sRGB RGBA8
/// in the atlas colour column. There is no URL-keyed colour cache: a lookup
/// is the atlas handle plus an array read.
enum LogoColorAnalyzer {
    @MainActor
    static func cachedColor(for url: URL) -> NSColor? {
        cachedColor(for: url, in: LogoAtlas.shared)
    }

    @MainActor
    static func cachedColor(for url: URL, in atlas: LogoAtlas) -> NSColor? {
        color(packed: atlas.packedColor(atlas.handle(for: url)))
    }

    @MainActor
    static func cachedColor(handle: LogoHandle, in atlas: LogoAtlas) -> NSColor? {
        color(packed: atlas.packedColor(handle))
    }

    /// Computes the colour for an image that did not come through the atlas
    /// and records it in the atlas colour column.
    @MainActor
    static func color(
        for url: URL,
        image: CGImage,
        completion: @escaping @MainActor (NSColor) -> Void
    ) {
        let atlas = LogoAtlas.shared
        let handle = atlas.handle(for: url)
        if let cached = color(packed: atlas.packedColor(handle)) {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let packed = packedColor(from: image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    atlas.setPackedColor(packed, for: handle)
                    completion(color(packed: packed)!)
                }
            }
        }
    }

    /// sRGB RGBA8 (`r << 24 | g << 16 | b << 8 | a`). Never 0: alpha is 255.
    nonisolated static func packedColor(from cgImage: CGImage) -> UInt32 {
        pack(extract(from: cgImage))
    }

    nonisolated static func color(packed: UInt32) -> NSColor? {
        guard packed != 0 else { return nil }
        return NSColor(srgbRed: CGFloat(packed >> 24) / 255, green: CGFloat((packed >> 16) & 0xff) / 255,
                       blue: CGFloat((packed >> 8) & 0xff) / 255, alpha: CGFloat(packed & 0xff) / 255)
    }

    nonisolated static func pack(_ color: NSColor) -> UInt32 {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return byte(c.redComponent) << 24 | byte(c.greenComponent) << 16 | byte(c.blueComponent) << 8 | 0xff
    }

    // MARK: - Extraction

    nonisolated private static let fallback = NSColor(srgbRed: 0.14, green: 0.14, blue: 0.15, alpha: 1.0)

    nonisolated static func extract(from cgImage: CGImage) -> NSColor {
        let size = 40
        let bytesPerRow = size * 4
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return fallback }

        context.interpolationQuality = .medium
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let data = context.data else { return fallback }
        let ptr = data.assumingMemoryBound(to: UInt8.self)

        var xSum: Double = 0
        var ySum: Double = 0
        var sSum: Double = 0
        var weightTotal: Double = 0

        let pixelCount = size * size
        for i in 0..<pixelCount {
            let offset = i * 4
            let a = Double(ptr[offset + 3]) / 255.0
            if a < 0.5 { continue }
            let r = Double(ptr[offset + 0]) / 255.0
            let g = Double(ptr[offset + 1]) / 255.0
            let b = Double(ptr[offset + 2]) / 255.0

            let mx = max(r, max(g, b))
            let mn = min(r, min(g, b))
            let delta = mx - mn
            let value = mx
            let saturation = mx == 0 ? 0 : delta / mx

            if value > 0.96 { continue }
            if value < 0.08 { continue }
            if saturation < 0.22 { continue }

            var hue: Double = 0
            if delta > 0 {
                if mx == r {
                    hue = (g - b) / delta + (g < b ? 6 : 0)
                } else if mx == g {
                    hue = (b - r) / delta + 2
                } else {
                    hue = (r - g) / delta + 4
                }
                hue /= 6
            }

            let weight = saturation * value
            let angle = hue * 2 * .pi
            xSum += cos(angle) * weight
            ySum += sin(angle) * weight
            sSum += saturation * weight
            weightTotal += weight
        }

        guard weightTotal > 0.75 else { return fallback }

        var hue = atan2(ySum, xSum) / (2 * .pi)
        if hue < 0 { hue += 1 }
        let avgSat = min(1.0, sSum / weightTotal)

        let tileSat = min(0.62, max(0.38, avgSat * 0.75))
        let tileBrightness = 0.20

        return NSColor(
            calibratedHue: CGFloat(hue),
            saturation: CGFloat(tileSat),
            brightness: CGFloat(tileBrightness),
            alpha: 1.0
        )
    }
}
