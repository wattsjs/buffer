import Foundation
import Nuke

enum ImageLoader {
    nonisolated static let pipeline: ImagePipeline = {
        var config = ImagePipeline.Configuration.withDataCache(
            name: "com.buffer.image-cache",
            sizeLimit: 256 * 1024 * 1024
        )
        config.dataLoadingQueue.maxConcurrentOperationCount = 6
        config.imageDecodingQueue.maxConcurrentOperationCount = 2
        config.isProgressiveDecodingEnabled = false
        config.isTaskCoalescingEnabled = true
        config.makeImageDecoder = { context in makeImageDecoder(for: context) }

        let dataLoaderConfig = URLSessionConfiguration.default
        // Nuke's DataCache owns the encoded-image cache. Replacing its
        // configured loader must not re-enable a second URLCache.
        dataLoaderConfig.urlCache = nil
        dataLoaderConfig.timeoutIntervalForRequest = 15
        dataLoaderConfig.httpAdditionalHeaders = [
            "Accept": "image/webp,image/apng,image/*,*/*;q=0.8",
            "User-Agent": "Buffer/1.0"
        ]
        config.dataLoader = DataLoader(configuration: dataLoaderConfig)

        return ImagePipeline(configuration: config)
    }()

    @MainActor
    static func configure() {
        ImagePipeline.shared = pipeline
        ImageDecoderRegistry.shared.register(ImageDecoders.Default.init)
    }

    static func artworkRequest(
        for url: URL,
        size: CGSize,
        displayScale: CGFloat,
        contentMode: ImageProcessingOptions.ContentMode
    ) -> ImageRequest {
        // Decode directly to the displayed pixels. The view supplies scale;
        // Nuke's request/cache identity includes these thumbnail options.
        return ArtworkImageDecoder.request(
            for: url,
            size: size,
            displayScale: displayScale,
            contentMode: contentMode
        )
    }

    nonisolated static func makeImageDecoder(for context: ImageDecodingContext) -> (any ImageDecoding)? {
        if let decoder = ArtworkImageDecoder(context: context) { return decoder }
        return ImageDecoderRegistry.shared.decoder(for: context)
    }

    // MARK: - Failure memo
    //
    // Nuke has no built-in failure caching, so every re-instantiated view for
    // a dead URL would fire another request. Failures are a bitset over image
    // handles (with an expiry column) owned by `LogoAtlas`; callers skip the
    // fetch until the TTL elapses.

    @MainActor
    static func markFailed(_ url: URL) {
        let atlas = LogoAtlas.shared
        atlas.markFailed(atlas.handle(for: url))
    }

    @MainActor
    static func markFailed(_ url: URL, unlessCancelled error: Error) {
        guard !isCancellation(error) else { return }
        markFailed(url)
    }

    @MainActor
    static func isFailed(_ url: URL) -> Bool {
        let atlas = LogoAtlas.shared
        return atlas.isFailed(atlas.handle(for: url))
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        if let pipelineError = error as? ImagePipeline.Error,
           let underlying = pipelineError.dataLoadingError {
            return isCancellation(underlying)
        }

        return false
    }
}
