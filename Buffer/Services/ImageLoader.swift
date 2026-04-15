import Foundation
import Nuke

enum ImageLoader {
    static let pipeline: ImagePipeline = {
        var config = ImagePipeline.Configuration.withDataCache(
            name: "com.buffer.image-cache",
            sizeLimit: 256 * 1024 * 1024
        )
        config.dataLoadingQueue.maxConcurrentOperationCount = 6
        config.imageDecodingQueue.maxConcurrentOperationCount = 2
        config.isProgressiveDecodingEnabled = false
        config.isTaskCoalescingEnabled = true

        let dataLoaderConfig = URLSessionConfiguration.default
        dataLoaderConfig.timeoutIntervalForRequest = 15
        dataLoaderConfig.httpAdditionalHeaders = [
            "Accept": "image/webp,image/apng,image/*,*/*;q=0.8",
            "User-Agent": "Buffer/1.0"
        ]
        config.dataLoader = DataLoader(configuration: dataLoaderConfig)

        return ImagePipeline(configuration: config)
    }()

    static func configure() {
        ImagePipeline.shared = pipeline
        ImageDecoderRegistry.shared.register(ImageDecoders.Default.init)
    }

    // MARK: - Failure memo
    //
    // Nuke has no built-in failure caching, so every re-instantiated LazyImage
    // for a dead URL fires another request. In a virtualized grid that can
    // cascade into a hot loop. We track recent failures here and let callers
    // skip the fetch entirely until the TTL elapses.

    private static let failureLock = NSLock()
    private static var failures: [URL: Date] = [:]
    private static let failureTTL: TimeInterval = 10 * 60

    static func markFailed(_ url: URL) {
        failureLock.lock()
        failures[url] = Date()
        failureLock.unlock()
    }

    static func isFailed(_ url: URL) -> Bool {
        failureLock.lock()
        defer { failureLock.unlock() }
        guard let when = failures[url] else { return false }
        if Date().timeIntervalSince(when) > failureTTL {
            failures.removeValue(forKey: url)
            return false
        }
        return true
    }
}
