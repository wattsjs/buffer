import Foundation
import Network

/// In-process HTTP server fronting a pool of `BufferBroadcaster`s — one per
/// distinct upstream URL. mpv connects to `http://127.0.0.1:<port>/s/<token>`
/// and the server attaches the TCP connection as a byte sink on the matching
/// broadcaster. Every consumer (viewer + recording file) shares the SAME
/// upstream HTTP/HLS connection managed inside the broadcaster — that's how
/// single-stream is preserved.
///
/// The broadcaster uses libavformat internally to demux the upstream HLS
/// playlist-and-segments as a unified input (session-consistent, matches
/// mpv's own fetch pattern), then remuxes to MPEG-TS bytes fed to each
/// sink.
/// The whole class is `nonisolated`. The project sets
/// `-default-isolation=MainActor`, which would otherwise make every method
/// here MainActor-isolated and silently hop `Task.detached` bodies back
/// onto main — the HLS + TLS handshake inside `ensureBroadcaster` then
/// blocks the UI for several seconds (trace confirmed:
/// `main → StreamProxy.route → ensureBroadcaster → buffer_broadcaster_create
///  → avformat_open_input → gnutls → gcm_gf_mul`). The class does its own
/// locking (`stateLock`, C-side pthread mutexes) so it's safe to run from
/// any thread.
nonisolated final class StreamProxy: @unchecked Sendable {
    static let shared = StreamProxy()

    // MARK: - Public types

    struct ProxyReference {
        let token: UUID   // unique per mpv-open (viewer sink identifier)
        let url: URL      // localhost URL mpv connects to
    }

    // MARK: - Listener

    private let stateLock = NSLock()
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let readySemaphore = DispatchSemaphore(value: 0)
    private var didSignalReady = false

    // MARK: - Broadcasters

    /// One broadcaster per upstream URL. Created lazily on first viewer
    /// attach, torn down when its last sink goes away.
    private var broadcasters: [String: BroadcasterHandle] = [:]
    /// viewer token → upstream URL (so HTTP route can map `/s/<token>` to
    /// the right broadcaster).
    private var pendingViewerTokens: [UUID: String] = [:]
    /// Recording token → (upstream URL, sink id, file handle) for live
    /// recordings. Active recordings keep the broadcaster alive.
    private var recordings: [UUID: RecordingTap] = [:]

    /// Active tail-replay tokens: the HTTP endpoint `/r/<token>` serves a
    /// local recording file, following EOF while the recording is still
    /// being written. Each registered token carries the URL to read and a
    /// closure the handler polls to know whether the file is still
    /// growing. Populated by `registerRecordingTail` (called from
    /// `RecordingPlayback`) and removed on eviction.
    private struct RecordingTailTicket {
        let fileURL: URL
        /// Returns true while the recording is still writing. When it
        /// flips false, the tail handler flushes remaining bytes and
        /// closes.
        let isActive: @Sendable () -> Bool
    }
    private var recordingTails: [UUID: RecordingTailTicket] = [:]

    private final class BroadcasterHandle: @unchecked Sendable {
        let upstreamURL: String
        let userAgent: String?
        let referer: String?
        var ptr: OpaquePointer?
        var lastError: String = ""
        init(upstreamURL: String, userAgent: String?, referer: String?) {
            self.upstreamURL = upstreamURL
            self.userAgent = userAgent
            self.referer = referer
        }
    }

    private final class RecordingTap {
        let broadcasterKey: String
        let fileURL: URL
        let fileHandle: FileHandle
        var sinkToken: Int32 = 0
        /// Retained closures — must outlive the C callback registration.
        var onBytes: BufferSinkOnBytes?
        var onEOF: BufferSinkOnEOF?
        /// Wait for first video keyframe before writing, so the recording
        /// file is playable from byte 0. MPEG-TS provides enough framing
        /// to detect keyframes via PAT/PMT/adaptation-field scanning — but
        /// a cheap heuristic: wait for the first "PES start + payload_unit
        /// _start + random_access_indicator" pattern. Simpler still:
        /// discard bytes for ~1 s after attach; provider segments are
        /// keyframe-aligned so the next segment boundary (~2 s) will start
        /// cleanly. For now we write everything; future improvement.
        var bytesWritten: Int64 = 0
        init(broadcasterKey: String, fileURL: URL, fileHandle: FileHandle) {
            self.broadcasterKey = broadcasterKey
            self.fileURL = fileURL
            self.fileHandle = fileHandle
        }
    }

    // MARK: - Lifecycle

    private init() {}

    /// Start the listener and block the caller until it's bound and ready
    /// (or 1 s elapses). Called at app init so `proxiedURL` can always return
    /// a valid URL without waiting from the main thread. Loopback binds
    /// typically complete in <50 ms.
    func start() {
        stateLock.lock()
        if listener != nil { stateLock.unlock(); return }
        stateLock.unlock()

        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(connection: conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state, let p = listener.port {
                    self.stateLock.withLock {
                        self.port = p.rawValue
                        if !self.didSignalReady {
                            self.didSignalReady = true
                            self.readySemaphore.signal()
                        }
                    }
                    print("[StreamProxy] listening on 127.0.0.1:\(p.rawValue)")
                } else if case .failed(let err) = state {
                    print("[StreamProxy] listener failed: \(err)")
                    self.stateLock.withLock {
                        if !self.didSignalReady {
                            self.didSignalReady = true
                            self.readySemaphore.signal()
                        }
                    }
                }
            }
            // State callbacks dispatch on a global queue, so waiting on the
            // main thread for `ready` doesn't deadlock.
            listener.start(queue: .global(qos: .userInitiated))
            stateLock.withLock { self.listener = listener }

            _ = readySemaphore.wait(timeout: .now() + .seconds(1))
            readySemaphore.signal()  // keep available for later callers
        } catch {
            print("[StreamProxy] failed to start: \(error)")
        }
    }

    /// Reserve a viewer token for the given upstream URL. The token maps to
    /// a concrete broadcaster when mpv actually connects to the localhost
    /// URL. This lets PlayerSlot.init synchronously hand mpv a URL without
    /// blocking on upstream connect.
    func proxiedURL(for realURL: URL) -> ProxyReference {
        // Listener is expected to already be ready — `start()` is called at
        // app init and blocks briefly until the port is bound.
        start()
        let token = UUID()
        let url = stateLock.withLock { () -> URL in
            pendingViewerTokens[token] = realURL.absoluteString
            return URL(string: "http://127.0.0.1:\(port)/s/\(token.uuidString)")!
        }

        // Prefetch: start opening the upstream HLS session in the
        // background NOW, without waiting for mpv's incoming HTTP request.
        // By the time mpv's TCP connection and HTTP request land on our
        // listener (a few ms later), the broadcaster will typically have
        // already completed its handshake and be ready to stream bytes —
        // eliminating the ~1 s "blank player window while HLS probes" UI
        // hang that otherwise shows as a beach ball.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = try? self?.ensureBroadcaster(
                upstreamURL: realURL,
                userAgent: "Buffer/1.0",
                referer: nil,
                caller: "proxiedURL.prefetch"
            )
        }

        return ProxyReference(token: token, url: url)
    }

    // MARK: - Recording API

    /// Attach a recording sink that writes MPEG-TS bytes from the shared
    /// broadcaster to `fileURL`. Opens (or reuses) a broadcaster for the
    /// channel — the fan-out guarantees at most one upstream connection
    /// regardless of how many viewers + recordings tap in. Returns the
    /// stream characteristics captured from the broadcaster on success,
    /// nil on failure.
    func attachRecording(forChannel realURL: URL, to fileURL: URL, recordingID: UUID,
                         userAgent: String?, referer: String?) -> StreamInfo? {
        let key = realURL.absoluteString
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            print("[StreamProxy] could not open recording file \(fileURL.path)")
            return nil
        }
        try? handle.truncate(atOffset: 0)

        // Ensure a broadcaster exists for this upstream URL. If no viewer is
        // active, we create one (scheduled recording case).
        let broadcaster: BroadcasterHandle
        do {
            broadcaster = try ensureBroadcaster(
                upstreamURL: realURL,
                userAgent: userAgent,
                referer: referer,
                caller: "attachRecording"
            )
        } catch {
            print("[StreamProxy] ensureBroadcaster failed (attachRecording): \(error)")
            try? handle.close()
            return nil
        }

        let tap = RecordingTap(broadcasterKey: key, fileURL: fileURL, fileHandle: handle)
        let ctx = Unmanaged.passUnretained(tap).toOpaque()
        tap.onBytes = { ctx, bytes, len in
            guard let ctx, let bytes else { return }
            let tap = Unmanaged<RecordingTap>.fromOpaque(ctx).takeUnretainedValue()
            let data = Data(bytes: bytes, count: len)
            // FileHandle.write can throw; no cheap way to handle from C callback
            // thread. Swallow errors; a disk-full event will stop growth.
            do {
                try tap.fileHandle.write(contentsOf: data)
                tap.bytesWritten += Int64(len)
            } catch {
                print("[StreamProxy] recording write failed: \(error)")
            }
        }
        tap.onEOF = { ctx in
            guard let ctx else { return }
            let tap = Unmanaged<RecordingTap>.fromOpaque(ctx).takeUnretainedValue()
            try? tap.fileHandle.close()
        }

        let cb = BufferSinkCallbacks(
            on_bytes: tap.onBytes,
            on_eof: tap.onEOF,
            ctx: ctx
        )
        let token = buffer_broadcaster_add_sink(broadcaster.ptr, cb)
        if token <= 0 {
            try? handle.close()
            return nil
        }
        tap.sinkToken = token
        stateLock.withLock {
            recordings[recordingID] = tap
        }
        return Self.streamInfo(from: broadcaster)
    }

    /// Read stream characteristics from the broadcaster's already-probed
    /// input context.
    private static func streamInfo(from broadcaster: BroadcasterHandle) -> StreamInfo {
        var raw = BufferStreamInfo()
        buffer_broadcaster_get_stream_info(broadcaster.ptr, &raw)
        let videoCodec = withUnsafeBytes(of: raw.video_codec) { buf in
            String(cString: buf.bindMemory(to: CChar.self).baseAddress!)
        }
        let audioCodec = withUnsafeBytes(of: raw.audio_codec) { buf in
            String(cString: buf.bindMemory(to: CChar.self).baseAddress!)
        }
        return StreamInfo(
            videoWidth: Int(raw.video_width),
            videoHeight: Int(raw.video_height),
            videoCodec: videoCodec,
            videoFPS: raw.video_fps,
            audioCodec: audioCodec.isEmpty ? nil : audioCodec
        )
    }

    func detachRecording(recordingID: UUID) {
        let tap: RecordingTap? = stateLock.withLock {
            let t = recordings[recordingID]
            recordings[recordingID] = nil
            return t
        }
        guard let tap else { return }
        let broadcaster = stateLock.withLock { broadcasters[tap.broadcasterKey] }
        if let ptr = broadcaster?.ptr {
            buffer_broadcaster_remove_sink(ptr, tap.sinkToken)
        }
        try? tap.fileHandle.close()
        reapIfIdle(key: tap.broadcasterKey)
    }

    func recordingBytesWritten(recordingID: UUID) -> Int64 {
        stateLock.withLock { recordings[recordingID]?.bytesWritten ?? 0 }
    }

    // MARK: - Recording tail playback

    /// Register a recording file for tail-follow playback via the
    /// `/r/<token>` HTTP endpoint. Returns the localhost URL the player
    /// should open. The ticket is kept alive until `unregisterRecordingTail`
    /// is called (typically when the player window closes). `isActive` is
    /// invoked by the handler to decide whether to keep polling for new
    /// bytes after hitting EOF.
    func registerRecordingTail(
        fileURL: URL,
        isActive: @escaping @Sendable () -> Bool
    ) -> (token: UUID, url: URL) {
        start()
        let token = UUID()
        stateLock.withLock {
            recordingTails[token] = RecordingTailTicket(fileURL: fileURL, isActive: isActive)
        }
        let url = URL(string: "http://127.0.0.1:\(port)/r/\(token.uuidString)")!
        return (token, url)
    }

    func unregisterRecordingTail(token: UUID) {
        stateLock.withLock { _ = recordingTails.removeValue(forKey: token) }
    }

    /// True when any recording is currently tapped into the broadcaster for
    /// this upstream URL.
    func hasRecordingFor(channel realURL: URL) -> Bool {
        let key = realURL.absoluteString
        return stateLock.withLock {
            recordings.values.contains { $0.broadcasterKey == key }
        }
    }

    // MARK: - Broadcaster management

    private func ensureBroadcaster(upstreamURL: URL,
                                   userAgent: String?,
                                   referer: String?,
                                   caller: String = #function) throws -> BroadcasterHandle {
        let key = upstreamURL.absoluteString
        if let existing = stateLock.withLock({ broadcasters[key] }),
           existing.ptr != nil {
            print("[StreamProxy] ensureBroadcaster REUSE caller=\(caller) url=\(redact(key))")
            return existing
        }

        // Providers occasionally return a transient error on the first
        // manifest fetch (502 from a CDN edge, a truncated playlist, an
        // empty body). A single retry with a short backoff papers over
        // the vast majority of these without pestering a truly dead
        // stream for long.
        let maxAttempts = 2
        var lastError = "unknown"
        for attempt in 1...maxAttempts {
            print("[StreamProxy] ensureBroadcaster OPEN caller=\(caller) attempt=\(attempt)/\(maxAttempts) url=\(redact(key))")
            let openStart = Date()
            let handle = BroadcasterHandle(upstreamURL: key, userAgent: userAgent, referer: referer)
            var errorBuf = [CChar](repeating: 0, count: 256)
            let ptr: OpaquePointer? = errorBuf.withUnsafeMutableBufferPointer { buf in
                buffer_broadcaster_create(
                    key,
                    userAgent,
                    referer,
                    buf.baseAddress,
                    buf.count
                )
            }
            let elapsedMs = Int(Date().timeIntervalSince(openStart) * 1000)
            if let ptr {
                handle.ptr = ptr
                print("[StreamProxy] ensureBroadcaster OK caller=\(caller) attempt=\(attempt) elapsed=\(elapsedMs)ms url=\(redact(key))")
                stateLock.withLock {
                    // Another caller may have raced — keep the first one.
                    if let existing = broadcasters[key], existing.ptr != nil {
                        buffer_broadcaster_free(ptr)
                        handle.ptr = existing.ptr
                    } else {
                        broadcasters[key] = handle
                    }
                }
                return handle
            }
            lastError = String(cString: errorBuf)
            print("[StreamProxy] ensureBroadcaster FAIL caller=\(caller) attempt=\(attempt) elapsed=\(elapsedMs)ms err=\"\(lastError)\" url=\(redact(key))")
            if attempt < maxAttempts {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }

        throw NSError(domain: "StreamProxy", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: lastError])
    }

    /// Trim the query-string and path of an upstream URL to a short
    /// identifier for logs — providers' URLs include long signed tokens
    /// that spam the console and leak into support pastes.
    private func redact(_ urlString: String) -> String {
        guard let u = URL(string: urlString) else { return urlString }
        let host = u.host ?? "?"
        let lastPath = u.pathComponents.last ?? ""
        return "\(host)/…/\(lastPath)"
    }

    private func reapIfIdle(key: String) {
        let toFree: OpaquePointer? = stateLock.withLock {
            guard let h = broadcasters[key], let ptr = h.ptr else { return nil }
            let count = buffer_broadcaster_sink_count(ptr)
            if count == 0 {
                broadcasters[key] = nil
                return ptr
            }
            return nil
        }
        if let toFree {
            // `buffer_broadcaster_free` joins the worker thread, which
            // can take up to a few seconds when the worker is mid-read
            // on the upstream HLS socket. Detach so the caller (often
            // `detachRecording` from a MainActor-isolated RecordingManager
            // path) doesn't block main.
            DispatchQueue.global(qos: .userInitiated).async {
                buffer_broadcaster_free(toFree)
            }
        }
    }

    // MARK: - HTTP request handling

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        readRequest(connection: connection) { [weak self] result in
            guard let self, let (path, headers) = result else {
                connection.cancel()
                return
            }
            Task.detached { [weak self] in
                await self?.route(path: path, headers: headers, connection: connection)
            }
        }
    }

    private func readRequest(connection: NWConnection, accumulated: Data = Data(),
                             completion: @escaping ((path: String, headers: [String: String])?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
            if error != nil { completion(nil); return }
            var buf = accumulated
            if let data = data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf.subdata(in: 0..<range.lowerBound)
                let headerString = String(data: headerData, encoding: .utf8) ?? ""
                let lines = headerString.components(separatedBy: "\r\n")
                guard let first = lines.first else { completion(nil); return }
                let parts = first.components(separatedBy: " ")
                guard parts.count >= 2 else { completion(nil); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let colon = line.firstIndex(of: ":") {
                        let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                        let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        headers[k] = v
                    }
                }
                completion((parts[1], headers))
                return
            }
            if isComplete || buf.count > 65536 { completion(nil); return }
            self.readRequest(connection: connection, accumulated: buf, completion: completion)
        }
    }

    private func route(path: String, headers: [String: String], connection: NWConnection) async {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // Recording tail-follow endpoint: serves a local .ts file to mpv
        // with Range-request support + poll-for-more-bytes at EOF while the
        // recording is still active. This is the path that makes
        // in-progress recordings behave like a live, scrubbable stream.
        if components.count == 2, components[0] == "r",
           let token = UUID(uuidString: components[1]) {
            await routeRecordingTail(token: token, headers: headers, connection: connection)
            return
        }
        guard components.count == 2, components[0] == "s",
              let token = UUID(uuidString: components[1]) else {
            respond(connection: connection, status: "404 Not Found")
            return
        }
        guard let upstreamURLString = stateLock.withLock({ pendingViewerTokens[token] }),
              let upstreamURL = URL(string: upstreamURLString) else {
            respond(connection: connection, status: "404 Not Found")
            return
        }

        let userAgent = headers["user-agent"]
        let referer = headers["referer"]

        let broadcaster: BroadcasterHandle
        do {
            broadcaster = try ensureBroadcaster(
                upstreamURL: upstreamURL,
                userAgent: userAgent,
                referer: referer,
                caller: "httpRoute.viewer"
            )
        } catch {
            print("[StreamProxy] broadcaster open failed (httpRoute.viewer): \(error)")
            respond(connection: connection, status: "502 Bad Gateway")
            return
        }

        // Send headers immediately; body follows as sink bytes arrive.
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: video/mp2t",
            "Cache-Control: no-cache",
            "Connection: close",
            "", ""
        ].joined(separator: "\r\n")
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })

        let sinkAdapter = ConnectionSinkAdapter(
            connection: connection,
            onClose: { [weak self] _ in
                // Sink closed — clean up and possibly reap broadcaster.
                self?.reapIfIdle(key: upstreamURLString)
                _ = self?.stateLock.withLock {
                    self?.pendingViewerTokens[token] = nil
                }
            }
        )
        sinkAdapter.attach(broadcaster: broadcaster.ptr)
    }

    // MARK: - Recording tail handler

    /// Serve a recording file as a live HTTP stream. While the recording
    /// is still being written, blocks at EOF and polls for more bytes
    /// rather than closing the connection. For Range requests (mpv seeks),
    /// responds with a bounded 206 that claims the current file size as
    /// the advertised end — mpv reconnects with a fresh Range request as
    /// playback advances past it.
    private func routeRecordingTail(
        token: UUID,
        headers: [String: String],
        connection: NWConnection
    ) async {
        guard let ticket = stateLock.withLock({ recordingTails[token] }) else {
            print("[StreamProxy] tail 404 — no ticket for \(token)")
            respond(connection: connection, status: "404 Not Found")
            return
        }
        guard let fh = try? FileHandle(forReadingFrom: ticket.fileURL) else {
            print("[StreamProxy] tail 404 — cannot open \(ticket.fileURL.path)")
            respond(connection: connection, status: "404 Not Found")
            return
        }
        defer { try? fh.close() }

        // Parse Range header (mpv sends `bytes=X-` for open-ended seeks).
        // A bounded `bytes=X-Y` would also be honored but mpv doesn't use
        // it for our use case.
        var startOffset: UInt64 = 0
        var requestedEnd: UInt64? = nil
        var isRange = false
        if let rangeHeader = headers["range"], rangeHeader.hasPrefix("bytes=") {
            let spec = rangeHeader.dropFirst("bytes=".count)
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            if let s = parts.first.flatMap({ UInt64($0) }) {
                startOffset = s
                isRange = true
                if parts.count > 1, !parts[1].isEmpty, let e = UInt64(parts[1]) {
                    requestedEnd = e
                }
            }
        }

        // Determine the advertised response-end: snapshot of file size at
        // this moment (minus 1 to get last byte index). For a Range
        // request we need a concrete end so Content-Range is RFC-valid;
        // `*` in the numerator is non-standard and libavformat rejects it.
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: ticket.fileURL.path)[.size] as? Int64) ?? 0
        let advertisedEnd: UInt64 = {
            if let r = requestedEnd { return r }
            return max(UInt64(fileSize), startOffset + 1) - 1
        }()
        guard startOffset <= advertisedEnd + 1 else {
            print("[StreamProxy] tail 416 — start=\(startOffset) > end=\(advertisedEnd)")
            respond(connection: connection, status: "416 Range Not Satisfiable")
            return
        }

        // For the initial byte-0 load of an active recording, wait briefly
        // for enough data to satisfy mpv's probe. libavformat's mpegts
        // detection needs PAT/PMT + enough packets to confirm the sync
        // pattern — from our side that's ~256 KB of headroom. Without
        // this, a just-started recording with a tiny file serves mpv too
        // few bytes, libavformat bails with "Failed to recognize file
        // format" and never retries. 2.5 s is comfortably more than a
        // typical HLS segment interval for most providers.
        if startOffset == 0 && ticket.isActive() {
            let targetSize: Int64 = 256 * 1024
            let deadline = Date().addingTimeInterval(2.5)
            while Date() < deadline {
                let sz = ((try? FileManager.default.attributesOfItem(atPath: ticket.fileURL.path)[.size]) as? Int64) ?? 0
                if sz >= targetSize { break }
                if !ticket.isActive() { break }
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
            }
        }

        try? fh.seek(toOffset: startOffset)

        // Response headers. We use `Transfer-Encoding: chunked` because
        // FFmpeg's libavformat http protocol treats `s->off >= file_end`
        // as premature EOF for non-chunked streams — and `file_end` is
        // derived from Content-Range's denominator, which can't be `*`
        // (strtoull("*") returns 0, so libavformat thinks the file is 0
        // bytes). With chunked encoding, `s->chunksize != UINT64_MAX`
        // and that EOF check short-circuits to false, letting us stream
        // indefinitely past any advertised range end. For Range
        // responses we still emit a concrete Content-Range so mpv's
        // seek machinery has byte bookkeeping it trusts.
        let statusLine = isRange ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK"
        var headerLines = [
            statusLine,
            "Content-Type: video/mp2t",
            "Accept-Ranges: bytes",
            "Cache-Control: no-cache",
            "Transfer-Encoding: chunked",
            "Connection: close",
        ]
        if isRange {
            // Give libavformat a concrete denominator equal to the
            // advertisedEnd+1 (current file size). This is a snapshot;
            // the chunked body keeps flowing past it for active
            // recordings and mpv re-Ranges when it wants more.
            headerLines.append("Content-Range: bytes \(startOffset)-\(advertisedEnd)/\(advertisedEnd + 1)")
        }
        let header = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        let sent = await sendBytes(connection: connection, data: Data(header.utf8))
        guard sent else {
            print("[StreamProxy] tail header send failed")
            return
        }

        let chunkSize = 256 * 1024
        let pollIntervalNs: UInt64 = 150_000_000  // 150 ms
        var totalSent: UInt64 = 0

        while !Task.isCancelled {
            if let end = requestedEnd, startOffset + totalSent > end { break }

            let data: Data
            do {
                data = try fh.read(upToCount: chunkSize) ?? Data()
            } catch {
                print("[StreamProxy] tail read error: \(error)")
                break
            }

            if !data.isEmpty {
                totalSent += UInt64(data.count)
                // Chunked body: hex-size CRLF, payload, CRLF.
                var chunk = Data()
                chunk.append(Data(String(format: "%x\r\n", data.count).utf8))
                chunk.append(data)
                chunk.append(Data("\r\n".utf8))
                let ok = await sendBytes(connection: connection, data: chunk)
                if !ok { break }
                continue
            }

            // At EOF: if the recording is still being written, wait for
            // more bytes and keep streaming. Otherwise we've finished.
            if !ticket.isActive() { break }
            try? await Task.sleep(nanoseconds: pollIntervalNs)
        }

        // Final chunk + trailing CRLF to signal end of body.
        _ = await sendBytes(connection: connection, data: Data("0\r\n\r\n".utf8))
        connection.cancel()
    }

    /// Awaitable wrapper around `NWConnection.send`. Resolves to false on
    /// any send error so the caller can bail out.
    private func sendBytes(connection: NWConnection, data: Data) async -> Bool {
        await withCheckedContinuation { cont in
            connection.send(content: data, completion: .contentProcessed { err in
                cont.resume(returning: err == nil)
            })
        }
    }

    private func respond(connection: NWConnection, status: String, body: Data = Data()) {
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "", ""
        ].joined(separator: "\r\n")
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - ConnectionSinkAdapter

/// Bridges a broadcaster byte sink to an NWConnection. The broadcaster's
/// thread calls `onBytes`; we queue a non-blocking `send` on the connection.
/// Retained until the connection closes (either side).
private final class ConnectionSinkAdapter: @unchecked Sendable {
    private let connection: NWConnection
    private let onClose: (ConnectionSinkAdapter) -> Void
    private var sinkToken: Int32 = 0
    private var broadcasterPtr: OpaquePointer?
    /// Retained closures keep the C function pointers valid.
    private var onBytes: BufferSinkOnBytes?
    private var onEOF: BufferSinkOnEOF?

    /// Strong self-reference while attached, broken on close so the Swift
    /// object can dealloc. The C callbacks hold an UnsafePointer to self
    /// that only becomes invalid AFTER we've removed the sink from the
    /// broadcaster — broadcaster guarantees no further callbacks after
    /// `remove_sink` returns, so the lifetime is safe.
    private var retainToken: Unmanaged<ConnectionSinkAdapter>?

    init(connection: NWConnection, onClose: @escaping (ConnectionSinkAdapter) -> Void) {
        self.connection = connection
        self.onClose = onClose
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.detach()
            default:
                break
            }
        }
    }

    func attach(broadcaster: OpaquePointer?) {
        guard let broadcaster else { return }
        broadcasterPtr = broadcaster
        retainToken = Unmanaged.passRetained(self)
        let ctx = retainToken!.toOpaque()

        self.onBytes = { ctx, bytes, len in
            guard let ctx, let bytes else { return }
            let me = Unmanaged<ConnectionSinkAdapter>.fromOpaque(ctx).takeUnretainedValue()

            // Fast drop if we've already detached (connection closed, peer
            // disappeared, broadcaster shutting down). The broadcaster may
            // still deliver one or two in-flight chunks between the time
            // we mark detached and `remove_sink` completes on its thread.
            me.detachLock.lock()
            let dead = me.detached
            me.detachLock.unlock()
            if dead { return }

            // If the connection isn't ready anymore, detach NOW so the
            // broadcaster stops calling us. Without this check, a dead
            // peer causes every subsequent chunk to queue an NWConnection
            // send that fails — each failure is logged at the framework
            // level ("nw_write_request_report ... Broken pipe").
            switch me.connection.state {
            case .ready:
                break
            case .cancelled, .failed:
                me.detach()
                return
            default:
                // preparing / setup / waiting — send will queue internally.
                break
            }

            let chunk = Data(bytes: bytes, count: len)
            me.connection.send(content: chunk, completion: .contentProcessed { error in
                if error != nil {
                    me.detach()
                }
            })
        }
        self.onEOF = { ctx in
            guard let ctx else { return }
            let me = Unmanaged<ConnectionSinkAdapter>.fromOpaque(ctx).takeUnretainedValue()
            me.detach()
        }

        var cb = BufferSinkCallbacks(
            on_bytes: self.onBytes,
            on_eof: self.onEOF,
            ctx: ctx
        )
        sinkToken = buffer_broadcaster_add_sink(broadcaster, cb)
        if sinkToken <= 0 {
            detach()
        }
    }

    private var detached = false
    private let detachLock = NSLock()

    func detach() {
        detachLock.lock()
        if detached { detachLock.unlock(); return }
        detached = true
        detachLock.unlock()

        // Remove from broadcaster FIRST so it stops delivering bytes. After
        // this returns, broadcaster guarantees no more on_bytes callbacks
        // for this sink token.
        if sinkToken > 0, let b = broadcasterPtr {
            buffer_broadcaster_remove_sink(b, sinkToken)
        }
        connection.cancel()
        onClose(self)
        retainToken?.release()
        retainToken = nil
    }
}
