import AppKit
import ImageIO
import UniformTypeIdentifiers
import Nuke
import Darwin

@MainActor @main struct ImageDecodeBenchmark {
    static func cgImage(_ image: NSImage) -> CGImage {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    static func generateFixture(at url: URL, orientation: UInt32 = 1) throws {
        let context = CGContext(data: nil, width: 4096, height: 3072, bitsPerComponent: 8,
                                bytesPerRow: 4096 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for row in 0..<48 {
            for column in 0..<64 {
                context.setFillColor(CGColor(red: CGFloat(column) / 63,
                                             green: CGFloat(row) / 47,
                                             blue: CGFloat((row + column) % 17) / 16, alpha: 1))
                context.fill(CGRect(x: column * 64, y: row * 64, width: 64, height: 64))
            }
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9, kCGImagePropertyOrientation: orientation] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
    }

    static func generatePDFFixture(at url: URL) throws {
        var bounds = CGRect(x: 0, y: 0, width: 240, height: 360)
        let context = CGContext(url as CFURL, mediaBox: &bounds, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.15, green: 0.55, blue: 0.75, alpha: 1))
        context.fill(bounds)
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 10, y: 15, width: 60, height: 180))
        context.endPDFPage()
        context.closePDF()
    }

    static func decode(_ data: Data, mode: String, scale: CGFloat, fill: Bool) throws -> NSImage {
        let size = CGSize(width: 128, height: 192)
        let contentMode: ImageProcessingOptions.ContentMode = fill ? .aspectFill : .aspectFit
        let request = mode == "thumbnail"
            ? ImageLoader.artworkRequest(for: URL(string: "http://127.0.0.1/artwork.jpg")!, size: size, displayScale: scale, contentMode: contentMode)
            : ImageRequest(url: URL(string: "http://127.0.0.1/artwork.jpg")!)
        let decoder = ImageLoader.makeImageDecoder(for: ImageDecodingContext(request: request, data: data))!
        let image = try decoder.decode(data).image
        if mode == "thumbnail" { return image }
        return ImageProcessors.Resize(size: CGSize(width: size.width * scale, height: size.height * scale), unit: .pixels, contentMode: contentMode).process(image)!
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 16 * 16 * 4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 16, height: 16, bitsPerComponent: 8,
                                    bytesPerRow: 16 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return data
    }

    static func correctness(_ data: Data) throws {
        for fill in [false, true] {
            for scale in [CGFloat(1), CGFloat(2), CGFloat(3)] {
                let old = cgImage(try decode(data, mode: "resize", scale: scale, fill: fill))
                let new = cgImage(try decode(data, mode: "thumbnail", scale: scale, fill: fill))
                precondition(abs(old.width - new.width) <= 1 && abs(old.height - new.height) <= 1, "thumbnail changes fit/fill geometry")
                let a = pixels(old), b = pixels(new)
                let meanDifference = zip(a, b).enumerated().reduce(0.0) { sum, pair in
                    pair.offset % 4 == 3 ? sum : sum + abs(Double(pair.element.0) - Double(pair.element.1))
                } / (16 * 16 * 3)
                precondition(meanDifference < 5, "thumbnail changes sampled artwork colors")
            }
        }
        let url = URL(string: "http://127.0.0.1/artwork.jpg")!
        let size = CGSize(width: 128, height: 192)
        let request = ImageLoader.artworkRequest(for: url, size: size, displayScale: 2, contentMode: .aspectFill)
        let repeated = ImageLoader.artworkRequest(for: url, size: size, displayScale: 2, contentMode: .aspectFill)
        var config = ImagePipeline.Configuration()
        config.imageCache = ImageCache(costLimit: 64 * 1024 * 1024)
        let pipeline = ImagePipeline(configuration: config)
        pipeline.cache[request] = ImageContainer(image: try decode(data, mode: "thumbnail", scale: 2, fill: true))
        precondition(pipeline.cache[repeated] != nil, "same-scale request misses memory cache")
        precondition(pipeline.cache[ImageLoader.artworkRequest(for: url, size: size, displayScale: 1, contentMode: .aspectFill)] == nil, "scale change reuses wrong pixels")
        precondition(pipeline.cache[ImageLoader.artworkRequest(for: url, size: size, displayScale: 2, contentMode: .aspectFit)] == nil, "fit/fill share incorrect cache identity")
        precondition(pipeline.cache[ImageRequest(url: url)] == nil, "thumbnail replaces full-resolution cache entry")
        ImageLoader.markFailed(url, unlessCancelled: CancellationError())
        precondition(!ImageLoader.isFailed(url), "cancelled image was memoized as a failure")
        ImageLoader.markFailed(url, unlessCancelled: URLError(.cancelled))
        precondition(!ImageLoader.isFailed(url), "cancelled URLSession image was memoized as a failure")
        ImageLoader.markFailed(url, unlessCancelled: URLError(.badServerResponse))
        precondition(ImageLoader.isFailed(url), "real image failure was not memoized")
        print("PASS artwork fit/fill geometry and colors at 1x/2x/3x, repeated request cache hit, scale/full-resolution isolation, cancellation memo")
    }

    static func main() throws {
        let mode = CommandLine.arguments[1]
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        if mode == "generate" || mode == "generate-rotated" {
            try generateFixture(at: url, orientation: mode == "generate-rotated" ? 6 : 1)
            return
        }
        if mode == "generate-pdf" { try generatePDFFixture(at: url); return }
        let data = try Data(contentsOf: url)
        if mode == "test" { try correctness(data); return }
        if mode == "inspect" {
            for fill in [false, true] {
                let old = cgImage(try decode(data, mode: "resize", scale: 2, fill: fill))
                let new = cgImage(try decode(data, mode: "thumbnail", scale: 2, fill: fill))
                print("fill=\(fill) resize=\(old.width)x\(old.height) thumbnail=\(new.width)x\(new.height)")
            }
            return
        }
        precondition(mode == "resize" || mode == "thumbnail")
        var samples: [Double] = []
        var width = 0, height = 0
        for iteration in 0..<11 {
            let result = try autoreleasepool { () -> (Double, Int, Int) in
                let start = ContinuousClock.now
                let image = cgImage(try decode(data, mode: mode, scale: 2, fill: true))
                // Materialize the final display surface, including lazy NSImage decode.
                _ = pixels(image)
                let elapsed = start.duration(to: .now).components
                return (Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15, image.width, image.height)
            }
            if iteration > 0 { samples.append(result.0) }
            width = result.1; height = result.2
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let output = try JSONSerialization.data(withJSONObject: ["mode": mode, "samplesMs": samples,
            "peakRSSBytes": usage.ru_maxrss, "inputBytes": data.count, "width": width, "height": height], options: [.sortedKeys])
        print(String(decoding: output, as: UTF8.self))
    }
}
