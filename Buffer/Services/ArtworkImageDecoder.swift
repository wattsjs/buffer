import Foundation
import ImageIO
import Nuke

/// Selects the displayed pixel size after applying EXIF orientation. Nuke's
/// flexible thumbnail options use the encoded width/height on macOS, which
/// under-samples rotated fit images and over-samples rotated fill images.
nonisolated struct ArtworkImageDecoder: ImageDecoding {
    private struct Target: Sendable {
        let pixels: CGSize
        let contentMode: ImageProcessingOptions.ContentMode
    }
    private static let targetKey: ImageRequest.UserInfoKey = "com.buffer.artwork-target"
    private let context: ImageDecodingContext
    private let target: Target
    private let preferredDecoder: (any ImageDecoding)?

    var isAsynchronous: Bool { true }

    static func request(
        for url: URL,
        size: CGSize,
        displayScale: CGFloat,
        contentMode: ImageProcessingOptions.ContentMode
    ) -> ImageRequest {
        var request = ImageRequest(url: url)
        let pixels = CGSize(width: size.width * displayScale, height: size.height * displayScale)
        // Standard thumbnail options remain in the request so Nuke's image
        // and encoded-data cache keys distinguish dimensions and fit/fill.
        request.userInfo[.thumbnailKey] = ImageRequest.ThumbnailOptions(size: pixels, unit: .pixels, contentMode: contentMode)
        request.userInfo[targetKey] = Target(pixels: pixels, contentMode: contentMode)
        return request
    }

    init?(context: ImageDecodingContext) {
        guard let target = context.request.userInfo[Self.targetKey] as? Target else { return nil }
        self.context = context
        self.target = target
        var correctedContext = context
        if let maxPixelSize = Self.maxPixelSize(data: context.data, target: target) {
            correctedContext.request.userInfo[.thumbnailKey] = ImageRequest.ThumbnailOptions(maxPixelSize: maxPixelSize)
            preferredDecoder = ImageDecoders.Default(context: correctedContext)
        } else {
            preferredDecoder = nil
        }
    }

    func decode(_ data: Data) throws -> ImageContainer {
        if let preferredDecoder, let image = try? preferredDecoder.decode(data) { return image }
        // NSImage supports formats (for example PDF) that ImageIO's bitmap
        // thumbnail decoder does not. Preserve the existing resize fallback.
        var fallbackContext = context
        fallbackContext.request.userInfo[.thumbnailKey] = nil
        fallbackContext.request.userInfo[Self.targetKey] = nil
        guard let decoder = ImageDecoderRegistry.shared.decoder(for: fallbackContext) else { throw ImageDecodingError.unknown }
        var container = try decoder.decode(data)
        let resize = ImageProcessors.Resize(size: target.pixels, unit: .pixels, contentMode: target.contentMode)
        guard let image = resize.process(container.image) else { throw ImageDecodingError.unknown }
        container.image = image
        return container
    }

    private static func maxPixelSize(data: Data, target: Target) -> Float? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0, target.pixels.width > 0, target.pixels.height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        let displayedWidth = swapsAxes ? height : width
        let displayedHeight = swapsAxes ? width : height
        let widthScale = target.pixels.width / displayedWidth
        let heightScale = target.pixels.height / displayedHeight
        let scale = target.contentMode == .aspectFill ? max(widthScale, heightScale) : min(widthScale, heightScale)
        let pixels = (max(displayedWidth, displayedHeight) * min(scale, 1)).rounded()
        guard pixels.isFinite, pixels > 0, pixels <= Double(Float.greatestFiniteMagnitude) else { return nil }
        return Float(pixels)
    }
}
