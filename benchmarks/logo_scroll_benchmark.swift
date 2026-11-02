// Channel-logo scroll benchmark. Compiled twice by scripts/bench-logo-atlas.sh:
//   * baseline: the pre-atlas ImageLoader/LogoColorAnalyzer sources from a git
//     revision (Nuke memory cache + NSImage + per-URL colour cache).
//   * -D LOGO_ATLAS: the current LogoAtlas sources.
// Both replay the work ChannelLogoTile/ChannelLogoView do on the main thread
// for 60 visible rows per scroll step, against a temporary Nuke DataCache that
// holds 5,000 synthetic PNG logos (the bytes are on disk, as after a first
// launch; no network). "present" rasterises each delivered image into a
// 196x84 px cell (the EPG logo box at 2x) as a CPU proxy for the first frame.
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Nuke
import Darwin

@MainActor
@main struct LogoScrollBenchmark {
    static let logoCount = 5_000
    static let window = 60
    static let distinctImages = 96

    static func threadCPUSeconds() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// A 400x225 transparent logo: a coloured rounded plate, a bar and text-ish
    /// blocks, like a typical IPTV channel PNG.
    static func makeLogo(_ index: Int) -> Data {
        let w = 400, h = 225
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let hue = CGFloat(index) / CGFloat(distinctImages)
        let c = NSColor(calibratedHue: hue, saturation: 0.8, brightness: 0.85, alpha: 1).usingColorSpace(.sRGB)!
        ctx.setFillColor(c.cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 20 + index % 30, y: 30, width: 260, height: 160), cornerWidth: 30, cornerHeight: 30, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        for k in 0..<4 { ctx.fill(CGRect(x: 50 + k * 50, y: 80, width: 34, height: 60)) }
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 0.9))
        ctx.fill(CGRect(x: 300, y: 40 + index % 50, width: 80, height: 120))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(dest))
        return out as Data
    }

    static func url(_ i: Int) -> URL { URL(string: "http://logos.example.invalid/provider/\(i % 7)/channel-\(i).png")! }

    static func makePipeline(cacheDirectory: URL) throws -> (ImagePipeline, DataCache) {
        let dataCache = try DataCache(path: cacheDirectory)
        var config = ImagePipeline.Configuration()
        config.dataCache = dataCache
        config.dataLoadingQueue.maxConcurrentOperationCount = 6
        config.imageDecodingQueue.maxConcurrentOperationCount = 2
        config.isProgressiveDecodingEnabled = false
        config.isTaskCoalescingEnabled = true
        config.makeImageDecoder = { context in ImageLoader.makeImageDecoder(for: context) }
        config.imageCache = ImageCache()
        return (ImagePipeline(configuration: config), dataCache)
    }

    // Presentation proxy: aspect-fit draw into the 2x EPG logo box.
    static let cell = CGContext(data: nil, width: 196, height: 84, bitsPerComponent: 8, bytesPerRow: 196 * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    static var presentSeconds = 0.0
    static let materializeOnly = ProcessInfo.processInfo.environment["LOGO_PRESENT"] == "materialize"
    static func present(_ image: CGImage) {
        let p0 = threadCPUSeconds()
        defer { presentSeconds += threadCPUSeconds() - p0 }
        if materializeOnly {
            // What CoreAnimation needs at commit: the image's pixel bytes.
            // Lazily-decoded images decode here; atlas slots are already raw.
            precondition(CFDataGetLength(image.dataProvider!.data!) > 0)
            return
        }
        let s = min(196 / Double(image.width), 84 / Double(image.height))
        let w = Double(image.width) * s, h = Double(image.height) * s
        cell.clear(CGRect(x: 0, y: 0, width: 196, height: 84))
        cell.draw(image, in: CGRect(x: (196 - w) / 2, y: (84 - h) / 2, width: w, height: h))
    }

    static func spin(until done: () -> Bool) {
        while !done() { _ = CFRunLoopRunInMode(.defaultMode, 1.0, true) }  // blocks until main work arrives
    }

    struct StepSample { var wallMs: Double; var mainMs: Double; var colorMs: Double; var presentMs: Double = 0 }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted(); return s.isEmpty ? .nan : (s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2)
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (pipeline, dataCache) = try makePipeline(cacheDirectory: root)
        let images = (0..<distinctImages).map(makeLogo)
        for i in 0..<logoCount { dataCache.storeData(images[i % distinctImages], for: url(i).absoluteString) }
        dataCache.flush()
        let urls = (0..<logoCount).map(url)
        let windows = stride(from: 0, to: logoCount - window + 1, by: window).map { Array(urls[$0..<($0 + window)]) }
        let footprintBefore = footprint()

        var cold: [StepSample] = []
        var warm: [StepSample] = []
#if LOGO_ATLAS
        let atlas = LogoAtlas(source: NukeLogoByteSource(pipeline: pipeline))
        for rows in windows {
            let t0 = ContinuousClock.now, c0 = threadCPUSeconds(); presentSeconds = 0
            var presented = 0, colored = 0
            var lastPresent = t0, lastColor = t0
            for u in rows {
                _ = LogoColorAnalyzer.cachedColor(for: u, in: atlas)   // tile init
                let h = atlas.handle(for: u)
                if let image = atlas.image(h) { present(image); presented += 1; colored += 1; continue }
                guard !atlas.isFailed(h) else { continue }
                atlas.request(h) { ok in
                    precondition(ok, "logo failed to pack")
                    present(atlas.image(h)!)
                    presented += 1; lastPresent = .now
                    _ = LogoColorAnalyzer.color(packed: atlas.packedColor(h))
                    colored += 1; lastColor = .now
                }
            }
            spin { presented == rows.count && colored == rows.count }
            let c1 = threadCPUSeconds()
            cold.append(StepSample(wallMs: Double((lastPresent - t0) / .milliseconds(1)), mainMs: (c1 - c0) * 1000,
                                   colorMs: Double((lastColor - t0) / .milliseconds(1)), presentMs: presentSeconds * 1000))
        }
        // Behaviour checks: colour column agrees with the analyzer, sizes are aspect-fit.
        for i in (windows.count * window - distinctImages)..<(windows.count * window) {
            let h = atlas.handle(for: urls[i])
            let img = atlas.image(h)!
            precondition(img.width == 192 && img.height == 108, "unexpected slot content size \(img.width)x\(img.height)")
            precondition(atlas.packedColor(h) != 0)
        }
        precondition(atlas.residentPages <= 8 && atlas.residentCount <= 8 * 64, "page budget exceeded")
        let atlasFootprint = footprint() - footprintBefore
#else
        var memo: Set<URL> = []
        for rows in windows {
            let t0 = ContinuousClock.now, c0 = threadCPUSeconds(); presentSeconds = 0
            var presented = 0, colored = 0
            var lastPresent = t0, lastColor = t0
            for u in rows {
                _ = LogoColorAnalyzer.cachedColor(for: u)               // tile init
                if ImageLoader.isFailed(u) { continue }
                if let cached = pipeline.cache[ImageRequest(url: u)] {
                    _ = LogoColorAnalyzer.cachedColor(for: u)
                    present(cached.image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
                    presented += 1; colored += 1; continue
                }
                pipeline.loadImage(with: ImageRequest(url: u)) { result in
                    guard case .success(let response) = result else { fatalError("load failed") }
                    // ChannelLogoView.analyzeColorIfNeeded runs on main.
                    if LogoColorAnalyzer.cachedColor(for: u) == nil,
                       let cg = response.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        LogoColorAnalyzer.color(for: u, image: cg) { _ in colored += 1; lastColor = .now }
                        present(cg)
                    } else {
                        colored += 1; lastColor = .now
                        present(response.image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
                    }
                    presented += 1; lastPresent = .now
                }
            }
            spin { presented == rows.count && colored == rows.count }
            let c1 = threadCPUSeconds()
            memo.formUnion(rows)
            cold.append(StepSample(wallMs: Double((lastPresent - t0) / .milliseconds(1)), mainMs: (c1 - c0) * 1000,
                                   colorMs: Double((lastColor - t0) / .milliseconds(1)), presentMs: presentSeconds * 1000))
        }
        let atlasFootprint = footprint() - footprintBefore
#endif
        // Warm: re-scroll the most recent 6 windows (all resident) 5 times.
        for _ in 0..<5 {
            for rows in windows.suffix(6) {
                let t0 = ContinuousClock.now, c0 = threadCPUSeconds(); presentSeconds = 0
                for u in rows {
#if LOGO_ATLAS
                    _ = LogoColorAnalyzer.cachedColor(for: u, in: atlas)
                    let h = atlas.handle(for: u)
                    if !atlas.isFailed(h), let image = atlas.image(h) { present(image) } else { fatalError("warm miss") }
#else
                    _ = LogoColorAnalyzer.cachedColor(for: u)
                    if !ImageLoader.isFailed(u), let cached = pipeline.cache[ImageRequest(url: u)] {
                        _ = LogoColorAnalyzer.cachedColor(for: u)
                        present(cached.image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
                    } else { fatalError("warm miss") }
#endif
                }
                let c1 = threadCPUSeconds()
                warm.append(StepSample(wallMs: Double((ContinuousClock.now - t0) / .milliseconds(1)), mainMs: (c1 - c0) * 1000, colorMs: 0, presentMs: presentSeconds * 1000))
            }
        }
        // Warm lookup only (no rasterisation): the per-row main-thread cost.
        var lookupNs: [Double] = []
        for _ in 0..<20 {
            let t0 = ContinuousClock.now
            var sink = 0
            for rows in windows.suffix(6) {
                for u in rows {
#if LOGO_ATLAS
                    let h = atlas.handle(for: u)
                    if let c = LogoColorAnalyzer.cachedColor(for: u, in: atlas) { sink &+= Int(c.alphaComponent) }
                    if !atlas.isFailed(h), let image = atlas.image(h) { sink &+= image.width }
#else
                    if let c = LogoColorAnalyzer.cachedColor(for: u) { sink &+= Int(c.alphaComponent) }
                    if !ImageLoader.isFailed(u), let cached = pipeline.cache[ImageRequest(url: u)] { sink &+= Int(cached.image.size.width) }
#endif
                }
            }
            precondition(sink != 0)
            lookupNs.append(Double((ContinuousClock.now - t0) / .nanoseconds(1)) / Double(6 * window))
        }
#if LOGO_ATLAS
        // Rows that already hold a handle (phase 2: Channel.logoHandle).
        let handles = windows.suffix(6).flatMap { $0.map { atlas.handle(for: $0) } }
        var handleNs: [Double] = []
        for _ in 0..<200 {
            let t0 = ContinuousClock.now
            var sink = 0
            for h in handles {
                sink &+= Int(atlas.packedColor(h) & 1)
                if let image = atlas.image(h) { sink &+= image.width }
            }
            precondition(sink != 0)
            handleNs.append(Double((ContinuousClock.now - t0) / .nanoseconds(1)) / Double(handles.count))
        }
        let handleLookup = median(handleNs)
#else
        let handleLookup = -1.0  // no handle API before the atlas
#endif
        let report: [String: Any] = [
            "present": materializeOnly ? "materialize" : "draw",
            "warmHandleLookupNsPerRow": handleLookup,
            "mode": {
#if LOGO_ATLAS
                "atlas"
#else
                "baseline"
#endif
            }(),
            "coldStepWallMsMedian": median(cold.map(\.wallMs)),
            "coldStepColorMsMedian": median(cold.map(\.colorMs)),
            "coldStepMainMsMedian": median(cold.map(\.mainMs)),
            "coldStepMainExclDrawMsMedian": median(cold.map { $0.mainMs - $0.presentMs }),
            "warmStepMainExclDrawMsMedian": median(warm.map { $0.mainMs - $0.presentMs }),
            "warmStepWallMsMedian": median(warm.map(\.wallMs)),
            "warmStepMainMsMedian": median(warm.map(\.mainMs)),
            "warmLookupNsPerRow": median(lookupNs),
            "footprintDeltaBytesFor5000": atlasFootprint,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        try? FileManager.default.removeItem(at: root)
    }
}
