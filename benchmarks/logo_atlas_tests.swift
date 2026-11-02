import AppKit
import ImageIO
import UniformTypeIdentifiers

/// In-memory byte source: URL string -> bytes, with a fetch counter.
final class FakeLogoSource: LogoByteSource, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [String: Data] = [:]
    private var fetches: [String: Int] = [:]
    var failure: (any Error)?

    func set(_ data: Data, for url: URL) { lock.lock(); bytes[url.absoluteString] = data; lock.unlock() }
    func fetchCount(_ url: URL) -> Int { lock.lock(); defer { lock.unlock() }; return fetches[url.absoluteString, default: 0] }

    func fetch(_ urlString: String, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        lock.lock()
        fetches[urlString, default: 0] += 1
        let data = bytes[urlString]
        let failure = failure
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) {
            if let data { completion(.success(data)) } else { completion(.failure(failure ?? URLError(.fileDoesNotExist))) }
        }
    }
}

@MainActor @main struct LogoAtlasTests {
    static func image(width: Int, height: Int, hue: CGFloat, alpha: Bool = true) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        ctx.setFillColor(NSColor(calibratedHue: hue, saturation: 0.8, brightness: 0.8, alpha: 1).cgColor)
        ctx.fill(CGRect(x: width / 8, y: height / 8, width: width * 3 / 4, height: height * 3 / 4))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: width / 4, y: height / 3, width: width / 5, height: height / 3))
        return ctx.makeImage()!
    }

    static func encode(_ image: CGImage, type: UTType = .png, orientation: Int = 1) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return out as Data
    }

    static func pdf(width: CGFloat, height: CGFloat) -> Data {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let ctx = CGContext(consumer: CGDataConsumer(data: out)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(box.insetBy(dx: 4, dy: 4))
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }

    static func wait(_ atlas: LogoAtlas, _ handle: LogoHandle) -> Bool {
        var result: Bool?
        atlas.request(handle) { result = $0 }
        let deadline = Date().addingTimeInterval(10)
        while result == nil && Date() < deadline { _ = CFRunLoopRunInMode(.defaultMode, 0.01, true) }
        return result ?? false
    }

    static func size(_ atlas: LogoAtlas, _ h: LogoHandle) -> (Int, Int) {
        let packed = atlas.contentSize(h)
        return (Int(packed >> 16), Int(packed & 0xffff))
    }

    static func interning() {
        var table = LogoURLTable()
        var reference: [String: LogoHandle] = [:]
        for i in 0..<100_000 {
            let url = URL(string: "http://logos.example/\(i % 13)/ch-\(i).png?v=\(i % 3)")!
            let h = table.intern(url)
            precondition(h == LogoHandle(i), "handles must be dense in first-seen order")
            reference[url.absoluteString] = h
        }
        for (string, h) in reference {
            precondition(table.intern(URL(string: string)!) == h)
            precondition(table.lookup(URL(string: string)!) == h)
            precondition(table.string(h) == string)
        }
        precondition(table.count == 100_000)
        precondition(table.lookup(URL(string: "http://logos.example/missing.png")!) == nil)
        // Prefix/length collisions must not alias.
        let a = table.intern(URL(string: "http://x/a")!), b = table.intern(URL(string: "http://x/ab")!)
        precondition(a != b && table.string(a) == "http://x/a" && table.string(b) == "http://x/ab")
    }

    static func colorEquivalence() {
        // Old: colour extracted from the full image. New: from the slot-size decode.
        for k in 0..<24 {
            let full = image(width: 800 - k * 13, height: 300 + k * 7, hue: CGFloat(k) / 24)
            let old = LogoColorAnalyzer.pack(LogoColorAnalyzer.extract(from: full))
            let decoded = LogoAtlas.decodeThumbnail(encode(full))!
            let new = LogoColorAnalyzer.packedColor(from: decoded.image)
            for shift in [24, 16, 8] as [UInt32] {
                let d = abs(Int((old >> shift) & 0xff) - Int((new >> shift) & 0xff))
                precondition(d <= 3, "colour channel moved by \(d) for hue \(k)")
            }
            precondition(new & 0xff == 0xff)
        }
        // Low-saturation logo keeps the documented fallback colour.
        let gray = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        gray.setFillColor(CGColor(gray: 0.5, alpha: 1)); gray.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let fallback = LogoColorAnalyzer.packedColor(from: gray.makeImage()!)
        precondition(fallback == LogoColorAnalyzer.pack(NSColor(srgbRed: 0.14, green: 0.14, blue: 0.15, alpha: 1)))
        let round = LogoColorAnalyzer.color(packed: fallback)!.usingColorSpace(.sRGB)!
        precondition(abs(round.redComponent - 0.14) < 0.003 && LogoColorAnalyzer.color(packed: 0) == nil)
    }

    static func atlasBehaviour() {
        let source = FakeLogoSource()
        let atlas = LogoAtlas(source: source, pageBudget: 2)
        let wide = URL(string: "http://l/wide.png")!, square = URL(string: "http://l/square.png")!
        let small = URL(string: "http://l/small.png")!, rotated = URL(string: "http://l/rot.jpg")!
        let vector = URL(string: "http://l/vector.pdf")!, dead = URL(string: "http://l/dead.png")!
        source.set(encode(image(width: 800, height: 200, hue: 0.1)), for: wide)
        source.set(encode(image(width: 300, height: 300, hue: 0.5)), for: square)
        source.set(encode(image(width: 50, height: 25, hue: 0.7)), for: small)
        source.set(encode(image(width: 400, height: 100, hue: 0.3, alpha: false), type: .jpeg, orientation: 6), for: rotated)
        source.set(pdf(width: 120, height: 60), for: vector)

        let hw = atlas.handle(for: wide)
        precondition(atlas.handle(for: URL(string: "http://l/wide.png")!) == hw, "same URL must intern to one handle")
        precondition(atlas.image(hw) == nil && atlas.packedColor(hw) == 0 && LogoColorAnalyzer.cachedColor(for: wide, in: atlas) == nil)
        // Coalesced: two requests, one fetch.
        var second: Bool?
        atlas.request(hw) { second = $0 }
        precondition(wait(atlas, hw) && second == true && source.fetchCount(wide) == 1)
        precondition(size(atlas, hw) == (192, 48), "aspect-fit into 192x108")
        precondition(atlas.image(hw)!.width == 192 && atlas.image(hw)!.height == 48)
        precondition(atlas.packedColor(hw) != 0 && LogoColorAnalyzer.cachedColor(for: wide, in: atlas) != nil)
        precondition(wait(atlas, hw) && source.fetchCount(wide) == 1, "resident logo must not refetch")

        let hs = atlas.handle(for: square), hm = atlas.handle(for: small)
        let hr = atlas.handle(for: rotated), hv = atlas.handle(for: vector)
        precondition(wait(atlas, hs) && size(atlas, hs) == (108, 108))
        precondition(wait(atlas, hm) && size(atlas, hm) == (192, 96), "small logos scale up like .resizable() did")
        precondition(wait(atlas, hr) && size(atlas, hr) == (27, 108), "EXIF orientation must be applied")
        precondition(wait(atlas, hv) && size(atlas, hv) == (192, 96), "PDF logos fall back to NSImage")

        // Pixels: the slot holds the decoded logo (opaque centre, sRGB BGRA).
        let slot = atlas.image(hs)!
        let bytes = CFDataGetBytePtr(slot.dataProvider!.data!)!
        let centre = (54 * LogoAtlas.slotRowBytes) + 80 * 4
        precondition(bytes[centre + 3] == 255, "slot centre must be opaque")
        precondition(slot.bytesPerRow == LogoAtlas.slotRowBytes && slot.bitsPerPixel == 32)

        // Failures: real errors are remembered per handle; cancellation is not.
        let hd = atlas.handle(for: dead)
        precondition(!wait(atlas, hd) && atlas.isFailed(hd))
        precondition(!wait(atlas, hd) && source.fetchCount(dead) == 1, "failed handle must not refetch within TTL")
        source.failure = CancellationError()
        let cancelled = URL(string: "http://l/cancel.png")!
        let hc = atlas.handle(for: cancelled)
        precondition(!wait(atlas, hc) && !atlas.isFailed(hc), "cancellation must not be memoized")

        // Eviction: budget 2 pages. Fill handles on pages 1..3; page 0 is LRU.
        source.failure = nil
        let filler = encode(image(width: 160, height: 90, hue: 0.9))
        var later: [LogoHandle] = []
        while later.count < 3 {
            let url = URL(string: "http://l/filler-\(atlas.residentCount)-\(later.count)-\(Int.random(in: 0..<1_000_000)).png")!
            source.set(filler, for: url)
            let h = atlas.handle(for: url)
            if Int(h) / LogoAtlas.slotsPerPage > later.count { precondition(wait(atlas, h)); later.append(h) }
        }
        precondition(atlas.residentPages <= 2, "page budget exceeded: \(atlas.residentPages)")
        let wideColor = atlas.packedColor(hw)
        precondition(atlas.image(hw) == nil && !atlas.isResident(hw), "LRU page must be evicted")
        precondition(atlas.packedColor(hw) == wideColor, "colour survives eviction")
        precondition(wait(atlas, hw) && source.fetchCount(wide) == 2 && size(atlas, hw) == (192, 48), "evicted logo reloads from bytes")
        precondition(atlas.packedColor(hw) == wideColor, "colour is stable across reloads")
    }

    static func main() {
        interning()
        colorEquivalence()
        atlasBehaviour()
        print("PASS logo URL interning (100k), colour equivalence vs full-image extract, atlas aspect-fit/EXIF/PDF/upscale, coalescing, failure + cancellation, page-LRU eviction with stable colours")
    }
}
