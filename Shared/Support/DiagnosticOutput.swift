import Foundation
import Darwin

/// Bounded, nonblocking transport for diagnostic records. Main-thread callers
/// only encode/reserve memory; they never wait for pipe IO or queue draining.
/// Captures own a duplicate descriptor, so a lost collector cannot stall the
/// ordinary application's stdout after the initial diagnostic handoff.
nonisolated final class DiagnosticOutput: @unchecked Sendable {
    struct Statistics: Sendable {
        let producedRecords: Int
        let writtenRecords: Int
        let droppedRecords: Int
        let queuedRecords: Int
        let queuedBytes: Int
        let peakQueuedBytes: Int
        let closed: Bool
    }
    private struct Counters {
        var accepting = true
        var produced = 0
        var written = 0
        var dropped = 0
        var records = 0
        var bytes = 0
        var peakBytes = 0
        var reason = "capture-backpressure"
        var closed = false
    }
    private struct Record {
        var data: Data
        var offset = 0
        let reservation: Int
        let markerDropCount: Int?
    }
    private nonisolated final class Ownership: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
    private static let stdoutOwnership = Ownership()
    private let lock = NSLock()
    private var counters = Counters()
    private let queue = DispatchQueue(label: "com.wattsjs.buffer.diagnostic-output", qos: .utility)
    private var descriptor: Int32
    private let prefix: Data
    private let maxQueuedBytes: Int
    private let maxQueuedRecords: Int
    private let maxRecordBytes: Int
    private let closeDrainMilliseconds: Int
    private let footprint: Bool
    private var timer: DispatchSourceTimer?
    // The following state is confined to the utility queue.
    private var pending: [Record] = []
    private var active: Record?
    private var closingDeadline: ContinuousClock.Instant?
    private var lastReportedDrops = 0
    private var needsLineBoundary = true
    private var terminated = false

    /// Only one diagnostic recorder may claim stdout per app process. Move
    /// ordinary stdout to /dev/null once at startup, never during close or
    /// while another recorder owns the inherited collector stream.
    static func capturingStdout(prefix: String, footprint: Bool = true) -> DiagnosticOutput? {
        guard stdoutOwnership.claim(), let output = DiagnosticOutput(descriptor: STDOUT_FILENO,
            prefix: prefix, footprint: footprint) else { return nil }
        let sink = Darwin.open("/dev/null", O_WRONLY)
        guard sink >= 0 else { output.close(); return nil }
        let redirected = dup2(sink, STDOUT_FILENO)
        Darwin.close(sink)
        guard redirected >= 0 else { output.close(); return nil }
        return output
    }

    /// An inherited descriptor is duplicated, never closed by this helper.
    /// The injection point also permits real pipe/FIFO integration tests.
    init?(descriptor source: Int32, prefix: String, maxQueuedBytes: Int = 262144,
          maxQueuedRecords: Int = 128, maxRecordBytes: Int = 65536,
          closeDrainMilliseconds: Int = 1000, footprint: Bool = false) {
        let duplicate = dup(source)
        guard duplicate >= 0 else { return nil }
        let flags = fcntl(duplicate, F_GETFL)
        // F_SETNOSIGPIPE is per descriptor: do not change SIGPIPE handling for
        // the application or its other sockets. EPIPE becomes a write error.
        guard flags >= 0, fcntl(duplicate, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(duplicate, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(duplicate, F_SETNOSIGPIPE, 1) == 0 else {
            Darwin.close(duplicate)
            return nil
        }
        self.descriptor = duplicate
        self.prefix = Data(prefix.utf8)
        self.maxQueuedBytes = max(1024, maxQueuedBytes)
        self.maxQueuedRecords = max(1, maxQueuedRecords)
        self.maxRecordBytes = max(256, maxRecordBytes)
        self.closeDrainMilliseconds = max(1, closeDrainMilliseconds)
        self.footprint = footprint
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        // Retain through asynchronous close; terminal cleanup breaks the
        // timer cycle after the deadline, even if the consumer never returns.
        timer.setEventHandler { [self] in drain() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.resume()
    }

    var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        return Statistics(producedRecords: counters.produced, writtenRecords: counters.written,
            droppedRecords: counters.dropped, queuedRecords: counters.records,
            queuedBytes: counters.bytes, peakQueuedBytes: counters.peakBytes, closed: counters.closed)
    }

    @discardableResult
    func append(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard counters.accepting else { return false }
        counters.produced += 1
        guard data.count <= maxRecordBytes else {
            counters.dropped += 1; counters.reason = "record-oversize"; return false
        }
        guard counters.records < maxQueuedRecords, counters.bytes + data.count <= maxQueuedBytes else {
            counters.dropped += 1; counters.reason = "capture-backpressure"; return false
        }
        counters.records += 1
        counters.bytes += data.count
        counters.peakBytes = max(counters.peakBytes, counters.bytes)
        // Reserve before dispatch: producer bursts cannot create an unbounded
        // queue of closures retaining records while a FIFO is full.
        queue.async { [self] in enqueue(data) }
        return true
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard counters.accepting else { return }
        counters.accepting = false
        queue.async { [self] in
            closingDeadline = .now.advanced(by: .milliseconds(closeDrainMilliseconds))
            drain()
        }
    }

    private func enqueue(_ encoded: Data) {
        guard !terminated else { release(reservation: encoded.count, dropped: true); return }
        guard var record = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else {
            release(reservation: encoded.count, dropped: true, reason: "invalid-record"); return
        }
        if footprint, record["event"] as? String == "sample" {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            if result == KERN_SUCCESS { record["physicalFootprintBytes"] = info.phys_footprint }
        }
        guard let body = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              body.count <= maxRecordBytes else {
            release(reservation: encoded.count, dropped: true, reason: "invalid-record"); return
        }
        var line = prefix
        line.append(body); line.append(10)
        pending.append(Record(data: line, reservation: encoded.count, markerDropCount: nil))
        drain()
    }

    private func release(reservation: Int, dropped: Bool, reason: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        counters.records -= 1
        counters.bytes -= reservation
        if dropped { counters.dropped += 1 } else { counters.written += 1 }
        if let reason { counters.reason = reason }
    }

    private func failureMarker() -> Record? {
        lock.lock()
        let state = counters
        lock.unlock()
        guard state.dropped > lastReportedDrops else { return nil }
        let fields: [String: Any] = ["event": "output-failure", "reason": state.reason, "outputHealthy": false,
            "droppedRecords": state.dropped, "writtenRecords": state.written, "producedRecords": state.produced]
        guard let body = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return nil }
        var line = needsLineBoundary ? Data([10]) : Data()
        line.append(prefix); line.append(body); line.append(10)
        needsLineBoundary = false
        return Record(data: line, reservation: 0, markerDropCount: state.dropped)
    }

    private func discardUnwritten(reason: String) {
        if let active {
            if active.offset > 0 { needsLineBoundary = true }
            if active.markerDropCount == nil {
                release(reservation: active.reservation, dropped: true, reason: reason)
            }
        }
        active = nil
        for record in pending { release(reservation: record.reservation, dropped: true, reason: reason) }
        pending.removeAll(keepingCapacity: false)
    }

    private func drain() {
        guard !terminated else { return }
        let expired = closingDeadline.map { ContinuousClock.now >= $0 } ?? false
        if expired { discardUnwritten(reason: "capture-backpressure") }
        // Bound each utility-queue turn as well as buffered memory. There is
        // no blocking syscall, semaphore, or synchronous queue handoff.
        for _ in 0..<32 {
            if active == nil {
                if let marker = failureMarker() { active = marker }
                else if !pending.isEmpty {
                    var record = pending.removeFirst()
                    if needsLineBoundary { record.data.insert(10, at: 0); needsLineBoundary = false }
                    active = record
                }
            }
            guard var current = active else {
                if closingDeadline != nil { terminate() }
                return
            }
            let remaining = current.data.count - current.offset
            let written = current.data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: current.offset), remaining)
            }
            if written > 0 {
                current.offset += written
                if current.offset == current.data.count {
                    if let count = current.markerDropCount { lastReportedDrops = count }
                    else { release(reservation: current.reservation, dropped: false) }
                    active = nil
                } else { active = current }
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                active = current
                if expired { terminate() }
                return
            }
            discardUnwritten(reason: errno == EPIPE ? "consumer-closed" : "write-error")
            terminate()
            return
        }
        if expired { terminate() }
    }

    private func terminate() {
        guard !terminated else { return }
        terminated = true
        lock.lock()
        counters.accepting = false
        counters.closed = true
        lock.unlock()
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }
}
