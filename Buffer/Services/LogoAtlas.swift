import Foundation
import CoreGraphics
import ImageIO
import AppKit
import Nuke

// MARK: - URL interning

/// Interns image URLs into dense `LogoHandle`s. Strings live once in a UTF-8
/// blob with an offsets column; the open-addressing table stores handles and
/// a per-handle hash column, so growth never rehashes strings. Rows that
/// already carry a handle never come here.
nonisolated struct LogoURLTable {
    private var bytes: [UInt8] = []
    private var offsets: [UInt32] = [0]
    private var hashes: [UInt64] = []
    private var buckets: [LogoHandle] = Array(repeating: .max, count: 1024)

    var count: Int { hashes.count }

    mutating func intern(_ url: URL) -> LogoHandle {
        var string = url.absoluteString
        return string.withUTF8 { intern(utf8: $0) }
    }

    func lookup(_ url: URL) -> LogoHandle? {
        var string = url.absoluteString
        return string.withUTF8 { lookup(utf8: $0, hash: Self.hash($0)).handle }
    }

    mutating func intern(utf8: UnsafeBufferPointer<UInt8>) -> LogoHandle {
        let hash = Self.hash(utf8)
        let found = lookup(utf8: utf8, hash: hash)
        if let handle = found.handle { return handle }
        let handle = LogoHandle(hashes.count)
        hashes.append(hash)
        bytes.append(contentsOf: utf8)
        offsets.append(UInt32(bytes.count))
        if hashes.count * 2 > buckets.count {
            grow()
        } else {
            buckets[found.bucket] = handle
        }
        return handle
    }

    func string(_ handle: LogoHandle) -> String {
        let start = Int(offsets[Int(handle)]), end = Int(offsets[Int(handle) + 1])
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    func url(_ handle: LogoHandle) -> URL? { URL(string: string(handle)) }

    private func lookup(utf8: UnsafeBufferPointer<UInt8>, hash: UInt64) -> (handle: LogoHandle?, bucket: Int) {
        let mask = buckets.count - 1
        var bucket = Int(truncatingIfNeeded: hash) & mask
        return bytes.withUnsafeBufferPointer { blob in
            while true {
                let handle = buckets[bucket]
                if handle == .max { return (nil, bucket) }
                if hashes[Int(handle)] == hash {
                    let start = Int(offsets[Int(handle)]), end = Int(offsets[Int(handle) + 1])
                    if end - start == utf8.count,
                       utf8.count == 0 || memcmp(blob.baseAddress! + start, utf8.baseAddress!, utf8.count) == 0 {
                        return (handle, bucket)
                    }
                }
                bucket = (bucket + 1) & mask
            }
        }
    }

    private mutating func grow() {
        buckets = Array(repeating: .max, count: buckets.count * 2)
        let mask = buckets.count - 1
        for (index, hash) in hashes.enumerated() {
            var bucket = Int(truncatingIfNeeded: hash) & mask
            while buckets[bucket] != .max { bucket = (bucket + 1) & mask }
            buckets[bucket] = LogoHandle(index)
        }
    }

    /// 8-bytes-per-step multiply/xor-shift hash (wyhash-style mixing).
    @inline(__always)
    static func hash(_ utf8: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var h: UInt64 = 0x9E37_79B9_7F4A_7C15 ^ UInt64(utf8.count)
        guard let base = UnsafeRawPointer(utf8.baseAddress) else { return h }
        var i = 0
        let n = utf8.count
        while i + 8 <= n {
            let word = base.loadUnaligned(fromByteOffset: i, as: UInt64.self)
            h = (h ^ word) &* 0xBF58_476D_1CE4_E5B9
            h ^= h >> 31
            i += 8
        }
        var tail: UInt64 = 0
        var shift: UInt64 = 0
        while i < n { tail |= UInt64(base.load(fromByteOffset: i, as: UInt8.self)) << shift; shift += 8; i += 1 }
        h = (h ^ tail) &* 0x94D0_49BB_1331_11EB
        return h ^ (h >> 29)
    }
}

// MARK: - Byte source

/// Supplies original logo bytes. Bytes from the network are the app's data:
/// the Nuke implementation reads them from its on-disk `DataCache` and only
/// fetches (and persists) on a disk miss. Completion may run on any thread.
protocol LogoByteSource: Sendable {
    /// Called on the main actor; must return promptly (no I/O on the caller).
    func fetch(_ urlString: String, completion: @escaping @Sendable (Result<Data, Error>) -> Void)
}

nonisolated struct NukeLogoByteSource: LogoByteSource {
    let pipeline: ImagePipeline
    private static let diskQueue = DispatchQueue(label: "com.buffer.logo-bytes", qos: .userInitiated, attributes: .concurrent)

    func fetch(_ urlString: String, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        let pipeline = pipeline
        Self.diskQueue.async {
            guard let url = URL(string: urlString) else {
                completion(.failure(URLError(.badURL)))
                return
            }
            let request = ImageRequest(url: url)
            if let data = pipeline.cache.cachedData(for: request) {
                completion(.success(data))
                return
            }
            // Data tasks skip the memory image cache; Nuke persists the
            // original bytes in its DataCache under the same key.
            pipeline.loadData(with: request, queue: Self.diskQueue, progress: nil) { result in
                completion(result.map(\.data).mapError { $0 as Error })
            }
        }
    }
}

// MARK: - Atlas pages

/// One texture page: `slotsPerPage` fixed-size slots stacked vertically in a
/// single BGRA8 premultiplied sRGB buffer (`slotWidth` x `slotHeight*64`),
/// the native CoreAnimation/Metal layout. Slot memory is written exactly once
/// by the worker that owns it, before its CGImage is published.
nonisolated final class LogoAtlasPage: @unchecked Sendable {
    let base: UnsafeMutableRawPointer
    init() { base = calloc(LogoAtlas.slotsPerPage, LogoAtlas.slotBytes)! }
    deinit { free(base) }
    func slot(_ index: Int) -> UnsafeMutableRawPointer { base + index * LogoAtlas.slotBytes }
}

/// Packed result of rasterising one logo into its slot.
nonisolated struct LogoSlotFill: @unchecked Sendable {
    let image: CGImage
    let size: UInt32   // width << 16 | height, in pixels, top-left of the slot
    let color: UInt32  // sRGB RGBA8, from LogoColorAnalyzer
}

/// Worker -> main hand-off. Workers append; the first append after a drain
/// schedules one main-queue drain, so a burst of N fills costs one hop.
nonisolated final class LogoFillInbox: @unchecked Sendable {
    struct Item { let handle: LogoHandle; let fill: LogoSlotFill?; let error: Error? }
    private let lock = NSLock()
    private var items: [Item] = []
    private let drain: @Sendable ([Item]) -> Void

    init(drain: @escaping @Sendable ([Item]) -> Void) { self.drain = drain }

    func post(_ item: Item) {
        lock.lock()
        let schedule = items.isEmpty
        items.append(item)
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            let batch = items
            items.removeAll(keepingCapacity: true)
            lock.unlock()
            drain(batch)
        }
    }
}

// MARK: - Atlas

/// Channel logos, addressed by integer handle. Each handle owns a fixed slot
/// (`handle / 64` = page, `handle % 64` = slot) plus parallel columns: the
/// published per-slot CGImage, the content size and the dominant colour as
/// packed RGBA. Lookup from a row is an array index; residency, in-flight
/// and failure state are bitsets. Decoding happens once per residency, off
/// the main thread, at the fixed slot size. Pages are freed LRU beyond the
/// page budget (colours stay); bytes are re-read from disk on demand.
@MainActor
final class LogoAtlas {
    nonisolated static let slotWidth = 192
    nonisolated static let slotHeight = 108
    nonisolated static let slotsPerPage = 64
    nonisolated static let slotRowBytes = slotWidth * 4
    nonisolated static let slotBytes = slotRowBytes * slotHeight

    static let shared = LogoAtlas(source: NukeLogoByteSource(pipeline: ImageLoader.pipeline))

    private let source: any LogoByteSource
    private var inbox: LogoFillInbox!
    private let pageBudget: Int
    private var urls = LogoURLTable()

    // Per-handle columns.
    private var images: [CGImage?] = []
    private var colors: [UInt32] = []
    private var sizes: [UInt32] = []
    private var resident = HandleBitset()
    private var inFlight = HandleBitset()
    let failures = RecentImageFailures()

    // Per-page columns.
    private var pages: [LogoAtlasPage?] = []
    private var pageTick: [UInt32] = []
    private var pageInFlight: [UInt16] = []
    private var residentPageCount = 0
    private var tick: UInt32 = 0

    /// Waiters for handles that are in flight (misses only; integer keys).
    private var waiters: [LogoHandle: [(Bool) -> Void]] = [:]

    private nonisolated static let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.buffer.logo-atlas"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        return queue
    }()

    /// `pageBudget` pages of 64 slots (5.3 MB each) may be resident: 8 pages
    /// = 512 logos, about 8 screens of guide rows.
    init(source: any LogoByteSource, pageBudget: Int = 8) {
        precondition(pageBudget > 0)
        self.source = source
        self.pageBudget = pageBudget
        inbox = LogoFillInbox { [weak self] batch in
            MainActor.assumeIsolated {
                guard let self else { return }
                for item in batch { self.finish(item.handle, fill: item.fill, error: item.error) }
            }
        }
    }

    // MARK: Scroll path

    /// Interns the URL once; rows that keep the handle skip this.
    func handle(for url: URL) -> LogoHandle {
        let handle = urls.intern(url)
        let count = urls.count
        if count > images.count {
            let grow = max(count - images.count, images.count)
            images.append(contentsOf: repeatElement(nil, count: grow))
            colors.append(contentsOf: repeatElement(0, count: grow))
            sizes.append(contentsOf: repeatElement(0, count: grow))
        }
        return handle
    }

    @inline(__always)
    func image(_ handle: LogoHandle) -> CGImage? {
        let page = Int(handle) / Self.slotsPerPage
        guard let image = images[Int(handle)] else { return nil }
        pageTick[page] = tick
        return image
    }

    /// Dominant colour as sRGB RGBA8; 0 when not yet computed.
    @inline(__always)
    func packedColor(_ handle: LogoHandle) -> UInt32 { colors[Int(handle)] }

    /// Content size in pixels (`width << 16 | height`); 0 when not resident.
    func contentSize(_ handle: LogoHandle) -> UInt32 { sizes[Int(handle)] }

    func isResident(_ handle: LogoHandle) -> Bool { resident.contains(handle) }

    func isFailed(_ handle: LogoHandle) -> Bool { failures.contains(handle) }

    func markFailed(_ handle: LogoHandle) { failures.insert(handle) }

    func setPackedColor(_ color: UInt32, for handle: LogoHandle) { colors[Int(handle)] = color }

    var residentCount: Int { resident.count }
    var residentPages: Int { residentPageCount }

    // MARK: Miss path

    /// Makes the handle resident. Completion runs on the main actor with
    /// false when the logo failed; concurrent requests share one load.
    func request(_ handle: LogoHandle, completion: @escaping (Bool) -> Void) {
        if images[Int(handle)] != nil { completion(true); return }
        if failures.contains(handle) { completion(false); return }
        waiters[handle, default: []].append(completion)
        guard inFlight.insert(handle) else { return }
        let urlString = urls.string(handle)
        let pageIndex = Int(handle) / Self.slotsPerPage
        let page = ensurePage(pageIndex)
        pageInFlight[pageIndex] += 1
        let slot = Int(handle) % Self.slotsPerPage
        let inbox = inbox!
        source.fetch(urlString) { result in
            switch result {
            case .failure(let error):
                inbox.post(.init(handle: handle, fill: nil, error: error))
            case .success(let data):
                Self.decodeQueue.addOperation {
                    let fill = Self.rasterize(data, page: page, slot: slot)
                    inbox.post(.init(handle: handle, fill: fill, error: fill == nil ? DecodeError() : nil))
                }
            }
        }
    }

    func load(_ handle: LogoHandle) async -> Bool {
        await withCheckedContinuation { continuation in
            request(handle) { continuation.resume(returning: $0) }
        }
    }

    private nonisolated struct DecodeError: Error {}

    private func finish(_ handle: LogoHandle, fill: LogoSlotFill?, error: Error?) {
        inFlight.remove(handle)
        let pageIndex = Int(handle) / Self.slotsPerPage
        if pageIndex < pageInFlight.count, pages[pageIndex] != nil { pageInFlight[pageIndex] -= 1 }
        if let fill {
            images[Int(handle)] = fill.image
            sizes[Int(handle)] = fill.size
            colors[Int(handle)] = fill.color
            resident.insert(handle)
            pageTick[pageIndex] = tick
        } else if let error, !ImageLoader.isCancellation(error) {
            failures.insert(handle)
        }
        let ok = fill != nil
        for waiter in waiters.removeValue(forKey: handle) ?? [] { waiter(ok) }
    }

    private func ensurePage(_ index: Int) -> LogoAtlasPage {
        if index >= pages.count {
            let grow = index + 1 - pages.count
            pages.append(contentsOf: repeatElement(nil, count: grow))
            pageTick.append(contentsOf: repeatElement(0, count: grow))
            pageInFlight.append(contentsOf: repeatElement(0, count: grow))
        }
        tick &+= 1
        pageTick[index] = tick
        if let page = pages[index] { return page }
        if residentPageCount >= pageBudget { evictLeastRecentPage(except: index) }
        let page = LogoAtlasPage()
        pages[index] = page
        residentPageCount += 1
        return page
    }

    private func evictLeastRecentPage(except keep: Int) {
        var victim = -1
        var oldestAge: UInt32 = 0
        for index in pages.indices where index != keep && pages[index] != nil && pageInFlight[index] == 0 {
            let age = tick &- pageTick[index]  // wrapping age relative to now
            if victim < 0 || age > oldestAge { victim = index; oldestAge = age }
        }
        guard victim >= 0 else { return }  // all pages busy: exceed budget briefly
        pages[victim] = nil
        residentPageCount -= 1
        resident.clearWord(victim)
        let start = victim * Self.slotsPerPage
        let end = min(start + Self.slotsPerPage, images.count)
        for handle in start..<end {
            images[handle] = nil
            sizes[handle] = 0
        }
    }

    // MARK: Worker

    /// Decodes `data` at slot size (aspect-fit, EXIF orientation applied)
    /// straight into the slot memory and computes the dominant colour.
    nonisolated static func rasterize(_ data: Data, page: LogoAtlasPage, slot slotIndex: Int) -> LogoSlotFill? {
        let slot = page.slot(slotIndex)
        guard let decoded = decodeThumbnail(data) else { return nil }
        let source = decoded.image
        let fit = min(Double(slotWidth) / decoded.width, Double(slotHeight) / decoded.height)
        let width = max(1, min(slotWidth, Int((decoded.width * fit).rounded())))
        let height = max(1, min(slotHeight, Int((decoded.height * fit).rounded())))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: slot, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: slotRowBytes, space: space, bitmapInfo: info) else { return nil }
        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let retained = Unmanaged.passRetained(page).toOpaque()
        guard let provider = CGDataProvider(dataInfo: retained, data: slot, size: slotRowBytes * height,
                                            releaseData: { info, _, _ in
                                                Unmanaged<LogoAtlasPage>.fromOpaque(info!).release()
                                            }),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: slotRowBytes, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        // Dominant colour once, at pack time, from the decoded thumbnail.
        let color = LogoColorAnalyzer.packedColor(from: source)
        return LogoSlotFill(image: image, size: UInt32(width) << 16 | UInt32(height), color: color)
    }

    /// Display-oriented image no larger than needed for the slot, plus its
    /// displayed size. Falls back to NSImage for formats ImageIO cannot
    /// rasterize (PDF, SVG).
    nonisolated static func decodeThumbnail(_ data: Data) -> (image: CGImage, width: Double, height: Double)? {
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) > 0,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pw = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let ph = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, pw > 0, ph > 0 {
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let (dw, dh) = (5...8).contains(orientation) ? (ph, pw) : (pw, ph)
            let fit = min(Double(slotWidth) / dw, Double(slotHeight) / dh, 1)
            let maxPixel = max(1, (max(dw, dh) * fit).rounded(.up))
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return (image, dw, dh)
            }
        }
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let fit = min(Double(slotWidth) / image.size.width, Double(slotHeight) / image.size.height)
        var rect = CGRect(x: 0, y: 0, width: (image.size.width * fit).rounded(), height: (image.size.height * fit).rounded())
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return (cg, image.size.width, image.size.height)
    }
}
