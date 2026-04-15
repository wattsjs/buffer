import Foundation
import CoreGraphics
import AppKit

enum LogoColorAnalyzer {
    private static let cacheLock = NSLock()
    private static var cache: [URL: NSColor] = [:]
    private static let workQueue = DispatchQueue(
        label: "com.buffer.logo-color",
        qos: .utility,
        attributes: .concurrent
    )
    private static let persistKey = "com.buffer.logoColors.v1"
    private static let persistLock = NSLock()
    private static var persistedLoaded = false
    private static var pendingFlush: DispatchWorkItem?

    static func cachedColor(for url: URL) -> NSColor? {
        ensurePersistedLoaded()
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[url]
    }

    static func color(
        for url: URL,
        image: CGImage,
        completion: @escaping (NSColor) -> Void
    ) {
        if let cached = cachedColor(for: url) {
            completion(cached)
            return
        }
        workQueue.async {
            let color = extract(from: image)
            cacheLock.lock()
            cache[url] = color
            cacheLock.unlock()
            schedulePersist()
            DispatchQueue.main.async { completion(color) }
        }
    }

    // MARK: - Persistence

    private static func ensurePersistedLoaded() {
        persistLock.lock()
        defer { persistLock.unlock() }
        if persistedLoaded { return }
        persistedLoaded = true
        guard let dict = UserDefaults.standard.dictionary(forKey: persistKey) as? [String: String] else { return }
        cacheLock.lock()
        for (key, hex) in dict {
            guard let url = URL(string: key), let color = Self.color(fromHex: hex) else { continue }
            if cache[url] == nil { cache[url] = color }
        }
        cacheLock.unlock()
    }

    private static func schedulePersist() {
        persistLock.lock()
        defer { persistLock.unlock() }
        pendingFlush?.cancel()
        let work = DispatchWorkItem {
            cacheLock.lock()
            let snapshot = cache.reduce(into: [String: String]()) { acc, pair in
                acc[pair.key.absoluteString] = hex(from: pair.value)
            }
            cacheLock.unlock()
            UserDefaults.standard.set(snapshot, forKey: persistKey)
        }
        pendingFlush = work
        workQueue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private static func hex(from color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "%02x%02x%02x", r, g, b)
    }

    private static func color(fromHex hex: String) -> NSColor? {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xff) / 255.0
        let g = CGFloat((value >> 8) & 0xff) / 255.0
        let b = CGFloat(value & 0xff) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    // MARK: - Extraction

    private static let fallback = NSColor(srgbRed: 0.14, green: 0.14, blue: 0.15, alpha: 1.0)

    private static func extract(from cgImage: CGImage) -> NSColor {
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
