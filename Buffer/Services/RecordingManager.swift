import AppKit
import Foundation
import IOKit.pwr_mgt
import OSLog

/// Owns Buffer's recording subsystem: direct live recordings, scheduled
/// unattended recordings, and persistence of both. Mirrors the pattern used
/// by `NotificationManager`.
@MainActor
@Observable
final class RecordingManager {
    static let shared = RecordingManager()

    private struct DirectRecorderStartResult: Sendable {
        let handleBits: UInt
        let streamInfo: StreamInfo

        var handle: OpaquePointer? { OpaquePointer(bitPattern: handleBits) }
    }

    /// All known recordings — scheduled, in-flight, completed. Most-recent
    /// first when displayed.
    private(set) var recordings: [Recording] = []

    /// Persisted user settings.
    var preRollSeconds: Int {
        didSet { UserDefaults.standard.set(preRollSeconds, forKey: Self.preRollKey) }
    }
    var postRollSeconds: Int {
        didSet { UserDefaults.standard.set(postRollSeconds, forKey: Self.postRollKey) }
    }
    private(set) var outputDirectory: URL

    /// Replace the output directory with a user-selected folder. Persists a
    /// security-scoped bookmark so subsequent app launches can write there
    /// without re-prompting.
    func setOutputDirectory(_ url: URL, fromPicker: Bool) {
        stopAccessingScopedOutput()
        outputDirectory = url
        UserDefaults.standard.set(url.path, forKey: Self.outputDirKey)

        if fromPicker && !url.path.hasPrefix(Self.defaultOutputDirectory().deletingLastPathComponent().path) {
            if let data = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(data, forKey: Self.outputDirBookmarkKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: Self.outputDirBookmarkKey)
        }
        startAccessingScopedOutputIfNeeded()
    }

    // MARK: - Internals

    private static let storageKey = "Buffer_recordings_v1"
    private static let preRollKey = "Buffer_recording_preRoll"
    private static let postRollKey = "Buffer_recording_postRoll"
    private static let outputDirKey = "Buffer_recording_outputDir"
    private static let outputDirBookmarkKey = "Buffer_recording_outputDirBookmark"
    private static let wakeEnabledKey = "Buffer_recording_wakeEnabled"

    /// Security-scoped URL we've started accessing on behalf of a user-picked
    /// output folder. `~/Movies/Buffer Recordings` doesn't need this because
    /// the Movies entitlement covers it unconditionally.
    @ObservationIgnored private var scopedOutputURL: URL?

    /// Seconds before the pre-roll window to ask macOS to wake the Mac. Gives
    /// the kernel room to bring the system back from sleep and spin up wifi
    /// before mpv tries to open the stream. 120 s is the value `pmset`
    /// documentation uses as the minimum reliable lead time.
    private static let wakeLeadSeconds: TimeInterval = 120
    private static let unexpectedStopGraceSeconds: TimeInterval = 30

    /// Whether to ask macOS to wake the Mac for scheduled recordings.
    /// Defaults to true — matches user expectation that "schedule a recording"
    /// actually results in a recording.
    var wakeMacForRecordings: Bool {
        didSet {
            UserDefaults.standard.set(wakeMacForRecordings, forKey: Self.wakeEnabledKey)
            reconcileWakeEvents()
        }
    }

    /// Active direct-recording handles, keyed by recording ID.
    @ObservationIgnored private var liveSessions: [UUID: OpaquePointer] = [:]
    @ObservationIgnored private var liveStopTimers: [UUID: DispatchSourceTimer] = [:]

    // Scheduled recordings use the same direct-recorder path as manual live
    // recordings. No separate session type is needed.
    @ObservationIgnored private var scheduledStartTimers: [UUID: DispatchSourceTimer] = [:]
    @ObservationIgnored private var scheduledStopTimers: [UUID: DispatchSourceTimer] = [:]

    /// Power-management assertion held while any recording is active so the
    /// Mac doesn't idle-sleep mid-capture.
    @ObservationIgnored private var powerAssertion: IOPMAssertionID = IOPMAssertionID(0)
    @ObservationIgnored private var holdsPowerAssertion = false

    private init() {
        self.preRollSeconds = (UserDefaults.standard.object(forKey: Self.preRollKey) as? Int) ?? 30
        self.postRollSeconds = (UserDefaults.standard.object(forKey: Self.postRollKey) as? Int) ?? 60
        if let path = UserDefaults.standard.string(forKey: Self.outputDirKey) {
            self.outputDirectory = URL(fileURLWithPath: path)
        } else {
            self.outputDirectory = Self.defaultOutputDirectory()
        }
        self.wakeMacForRecordings = (UserDefaults.standard.object(forKey: Self.wakeEnabledKey) as? Bool) ?? true
        loadRecordings()
        resolveStoredBookmark()
    }

    private func resolveStoredBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.outputDirBookmarkKey) else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        outputDirectory = url
        startAccessingScopedOutputIfNeeded()
        if isStale,
           let refreshed = try? url.bookmarkData(
               options: .withSecurityScope,
               includingResourceValuesForKeys: nil,
               relativeTo: nil
           ) {
            UserDefaults.standard.set(refreshed, forKey: Self.outputDirBookmarkKey)
        }
    }

    private func startAccessingScopedOutputIfNeeded() {
        // Only needed for user-picked folders outside the Movies entitlement.
        let defaultBase = Self.defaultOutputDirectory().deletingLastPathComponent().path
        guard !outputDirectory.path.hasPrefix(defaultBase) else { return }
        if outputDirectory.startAccessingSecurityScopedResource() {
            scopedOutputURL = outputDirectory
        }
    }

    private func stopAccessingScopedOutput() {
        scopedOutputURL?.stopAccessingSecurityScopedResource()
        scopedOutputURL = nil
    }

    /// Called at app launch. Recovers stale in-flight entries (force-quit
    /// during recording → marked failed) and re-arms timers for any
    /// scheduled recordings whose window is still in the future.
    func bootstrap() {
        let now = Date()
        var mutated = false
        for index in recordings.indices {
            switch recordings[index].status {
            case .recording, .startingUp:
                // Normal quit calls stopAll which closes cleanly; if we see
                // `.recording` at launch, the app was force-quit or crashed.
                // The MPEG-TS bytes already on disk are self-describing and
                // playable, so promote to `.completed` whenever the file has
                // content. Only flag as failed when there's nothing to keep.
                if let url = recordings[index].fileURL,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = (attrs[.size] as? NSNumber)?.int64Value,
                   size > 0 {
                    // Use the file's mtime as actualEnd so mediaDuration
                    // reflects what was actually captured, not wall-clock
                    // time-to-next-launch.
                    let mtime = attrs[.modificationDate] as? Date
                    recordings[index].status = .completed
                    recordings[index].actualStart = recordings[index].actualStart ?? recordings[index].scheduledStart
                    recordings[index].actualEnd = mtime ?? recordings[index].actualEnd ?? now
                    recordings[index].fileSizeBytes = size
                    recordings[index].bytesWritten = size
                    recordings[index].errorMessage = nil
                } else {
                    recordings[index].status = .failed
                    recordings[index].errorMessage = "Buffer quit before recording started"
                    recordings[index].actualEnd = recordings[index].actualEnd ?? now
                }
                mutated = true
            case .scheduled:
                let endWithPad = recordings[index].scheduledEnd.addingTimeInterval(Double(postRollSeconds))
                if endWithPad < now {
                    recordings[index].status = .failed
                    recordings[index].errorMessage = "Missed — Buffer wasn't running at the scheduled time"
                    if recordings[index].wakeAt != nil {
                        cancelWake(for: recordings[index])
                        recordings[index].wakeAt = nil
                    }
                    mutated = true
                } else {
                    armSchedule(for: recordings[index])
                }
            default:
                break
            }
        }
        if mutated { saveRecordings() }
    }

    // MARK: - Live recordings

    /// Begin recording the stream the viewer is currently watching. Recording
    /// uses a separate upstream connection from playback.
    /// Async because opening the upstream stream can take several seconds on
    /// a cold channel. We hop the recorder creation onto a detached task so
    /// main stays responsive while the provider negotiates.
    @discardableResult
    func startLiveRecording(
        playlistID: UUID,
        channel: Channel,
        program: EPGProgram?
    ) async -> Recording? {
        let now = Date()
        let end = program?.end ?? now.addingTimeInterval(3 * 60 * 60)
        let fileURL = outputFileURL(
            channelName: channel.name,
            title: program?.title ?? channel.name,
            start: now
        )

        let recordingID = UUID()
        let streamURL = channel.streamURL

        // Insert the row as `.startingUp` BEFORE kicking off the recorder
        // open — that handshake can take several seconds on a cold channel
        // and the user needs immediate visual feedback that the recording
        // exists.
        let placeholder = Recording(
            id: recordingID,
            playlistID: playlistID,
            channelID: channel.id,
            channelName: channel.name,
            programID: program?.id,
            title: program?.title ?? channel.name,
            programDescription: program?.description ?? "",
            scheduledStart: now,
            scheduledEnd: end,
            streamURL: channel.streamURL,
            source: .live,
            createdAt: now,
            actualStart: nil,
            actualEnd: nil,
            fileURL: fileURL,
            status: .startingUp,
            errorMessage: nil
        )
        recordings.insert(placeholder, at: 0)
        saveRecordings()

        let startResult = await Self.startDirectRecorderAsync(
            streamURL: streamURL,
            fileURL: fileURL,
            userAgent: "Buffer/1.0",
            referer: nil
        )

        // Row may have been cancelled while we were awaiting.
        guard let index = recordings.firstIndex(where: { $0.id == recordingID }),
              recordings[index].status == .startingUp else {
            if let handle = startResult?.handle {
                buffer_direct_recorder_free(handle)
            }
            return nil
        }

        guard let startResult else {
            recordings[index].status = .failed
            recordings[index].errorMessage = "Could not start recording"
            saveRecordings()
            return nil
        }

        recordings[index].status = .recording
        recordings[index].actualStart = Date()
        recordings[index].streamInfo = startResult.streamInfo
        saveRecordings()
        if let handle = startResult.handle {
            liveSessions[recordingID] = handle
        }
        markActive(recordingID, true)
        acquirePowerAssertionIfNeeded()
        startProgressTickerIfNeeded()

        if program != nil {
            let stopAt = end.addingTimeInterval(Double(postRollSeconds))
            scheduleTimer(for: .live(recordingID), fireAt: stopAt) { [weak self] in
                self?.stopLiveRecording(id: recordingID)
            }
        }

        return recordings[index]
    }

    func stopLiveRecording(id: UUID) {
        guard let handle = liveSessions[id] else { return }
        buffer_direct_recorder_free(handle)
        liveSessions[id] = nil
        liveStopTimers[id]?.cancel()
        liveStopTimers[id] = nil

        markFinished(id: id, error: nil)
        releasePowerAssertionIfIdle()
    }

    /// True when a live recording is active for the given channel.
    func isLiveRecording(forChannel channelURL: URL) -> Bool {
        recordings.contains {
            $0.source == .live &&
            $0.status == .recording &&
            $0.streamURL == channelURL
        }
    }

    /// Thread-safe set of currently-recording IDs. Mirrors
    /// `recordings.filter { $0.status == .recording }.map(\.id)` and is
    /// updated from the MainActor whenever a recording starts/stops.
    @ObservationIgnored private let activeIDsLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var _activeIDs: Set<UUID> = []

    nonisolated func isStillRecording(id: UUID) -> Bool {
        activeIDsLock.withLock { _activeIDs.contains(id) }
    }

    private func markActive(_ id: UUID, _ active: Bool) {
        activeIDsLock.withLock {
            if active { _activeIDs.insert(id) }
            else { _activeIDs.remove(id) }
        }
    }

    // MARK: - Scheduling

    /// Schedule an unattended recording for the given program. Re-scheduling
    /// the same program replaces the existing entry.
    @discardableResult
    func schedule(
        playlistID: UUID,
        channel: Channel,
        program: EPGProgram
    ) -> Recording? {
        let now = Date()
        guard program.end > now else { return nil }

        // Dedupe: if the user already scheduled this program, bail (or
        // upgrade — for now, treat as idempotent no-op).
        if let existing = recordings.first(where: {
            $0.programID == program.id
                && $0.channelID == channel.id
                && ($0.status == .scheduled || $0.status == .recording)
        }) {
            return existing
        }

        let fileURL = outputFileURL(
            channelName: channel.name,
            title: program.title,
            start: program.start
        )

        let recording = Recording(
            id: UUID(),
            playlistID: playlistID,
            channelID: channel.id,
            channelName: channel.name,
            programID: program.id,
            title: program.title,
            programDescription: program.description,
            scheduledStart: program.start,
            scheduledEnd: program.end,
            streamURL: channel.streamURL,
            source: .scheduled,
            createdAt: now,
            actualStart: nil,
            actualEnd: nil,
            fileURL: fileURL,
            status: .scheduled,
            errorMessage: nil
        )
        recordings.insert(recording, at: 0)
        saveRecordings()
        armSchedule(for: recording)
        return recording
    }

    /// Cancel a scheduled recording or stop an in-flight one.
    func cancel(id: UUID) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        let recording = recordings[index]

        switch recording.status {
        case .scheduled:
            scheduledStartTimers[id]?.cancel()
            scheduledStartTimers[id] = nil
            scheduledStopTimers[id]?.cancel()
            scheduledStopTimers[id] = nil
            cancelWake(for: recordings[index])
            recordings[index].wakeAt = nil
            recordings[index].status = .cancelled
            saveRecordings()
        case .startingUp:
            // Recorder creation is in flight. Flip status now — the
            // pending beginScheduledRecording / startLiveRecording tasks
            // re-check `.startingUp` after the await and will tear down the
            // recorder if needed.
            scheduledStartTimers[id]?.cancel()
            scheduledStartTimers[id] = nil
            cancelWake(for: recordings[index])
            recordings[index].wakeAt = nil
            recordings[index].status = .cancelled
            saveRecordings()
        case .recording:
            // Both .live and .scheduled flows use the same direct-recorder
            // path. Stopping early is not a failure — the partial file on
            // disk is perfectly playable, so we mark it completed regardless
            // of source. Deletion is a separate explicit action.
            if let handle = liveSessions[id] {
                buffer_direct_recorder_free(handle)
            }
            liveSessions[id] = nil
            liveStopTimers[id]?.cancel()
            liveStopTimers[id] = nil
            scheduledStopTimers[id]?.cancel()
            scheduledStopTimers[id] = nil
            cancelWake(for: recording)
            markFinished(id: id, error: nil)
            releasePowerAssertionIfIdle()
        default:
            break
        }
    }

    /// Delete a completed/cancelled/failed entry from the list. Does not
    /// touch the on-disk file.
    func deleteEntry(id: UUID) {
        recordings.removeAll { $0.id == id }
        saveRecordings()
    }

    /// Stop every active recording (called from app-quit hook).
    func stopAll() {
        for (id, handle) in liveSessions {
            buffer_direct_recorder_free(handle)
            markFinished(id: id, error: nil)
        }
        liveSessions.removeAll()
        liveStopTimers.values.forEach { $0.cancel() }
        liveStopTimers.removeAll()
        scheduledStartTimers.values.forEach { $0.cancel() }
        scheduledStartTimers.removeAll()
        scheduledStopTimers.values.forEach { $0.cancel() }
        scheduledStopTimers.removeAll()
        progressTimer?.cancel()
        progressTimer = nil
        releasePowerAssertionIfIdle()
    }

    // MARK: - Scheduled execution

    private func armSchedule(for recording: Recording) {
        let startAt = recording.scheduledStart.addingTimeInterval(-Double(preRollSeconds))
        let fireAt = max(startAt, Date().addingTimeInterval(1))
        scheduleTimer(for: .scheduledStart(recording.id), fireAt: fireAt) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.beginScheduledRecording(id: recording.id)
            }
        }
        scheduleWakeIfNeeded(for: recording)
    }

    private func beginScheduledRecording(id: UUID) async {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        guard recordings[index].status == .scheduled else { return }

        let recording = recordings[index]
        guard let fileURL = recording.fileURL else {
            recordings[index].status = .failed
            recordings[index].errorMessage = "Missing output path"
            saveRecordings()
            return
        }

        // Flip to `.startingUp` so the list shows "Starting…" while the
        // recorder opens (HLS + TLS handshake can run several seconds).
        recordings[index].status = .startingUp
        saveRecordings()

        // Bounce recorder creation onto a detached task so main stays
        // responsive during the scheduled start.
        let streamURL = recording.streamURL
        let startResult = await Self.startDirectRecorderAsync(
            streamURL: streamURL,
            fileURL: fileURL,
            userAgent: "Buffer/1.0",
            referer: nil
        )

        // The recording could have been cancelled while we were awaiting.
        guard let freshIndex = recordings.firstIndex(where: { $0.id == id }),
              recordings[freshIndex].status == .startingUp else {
            if let handle = startResult?.handle {
                buffer_direct_recorder_free(handle)
            }
            return
        }

        guard let startResult else {
            recordings[freshIndex].status = .failed
            recordings[freshIndex].errorMessage = "Could not start recording"
            saveRecordings()
            return
        }
        recordings[freshIndex].status = .recording
        recordings[freshIndex].actualStart = Date()
        recordings[freshIndex].wakeAt = nil
        recordings[freshIndex].streamInfo = startResult.streamInfo
        saveRecordings()
        if let handle = startResult.handle {
            liveSessions[id] = handle
        }
        markActive(id, true)
        acquirePowerAssertionIfNeeded()
        startProgressTickerIfNeeded()

        let stopAt = recording.scheduledEnd.addingTimeInterval(Double(postRollSeconds))
        scheduleTimer(for: .scheduledStop(id), fireAt: stopAt) { [weak self] in
            self?.finishScheduledRecording(id: id)
        }
    }

    private func finishScheduledRecording(id: UUID) {
        if let handle = liveSessions[id] {
            buffer_direct_recorder_free(handle)
        }
        liveSessions[id] = nil
        scheduledStopTimers[id] = nil
        markFinished(id: id, error: nil)
        releasePowerAssertionIfIdle()
    }

    private func markFinished(id: UUID, error: String?) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        markActive(id, false)
        if let error {
            recordings[index].status = .failed
            recordings[index].errorMessage = error
        } else {
            recordings[index].status = .completed
        }
        recordings[index].actualEnd = Date()
        // Freeze final stats from disk. Sink has already closed the file
        // handle on detach, so the size reported here is the final size.
        if let url = recordings[index].fileURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            recordings[index].fileSizeBytes = size.int64Value
            recordings[index].bytesWritten = size.int64Value
        }
        saveRecordings()
        stopProgressTickerIfIdle()
    }

    // MARK: - Progress ticker

    /// Single repeating timer (1 Hz) that refreshes `bytesWritten` on every
    /// active recording. Much cheaper than bouncing per-chunk callbacks
    /// across thread boundaries — chunks arrive every few ms, the UI only
    /// needs ~once-per-second granularity.
    @ObservationIgnored private var progressTimer: DispatchSourceTimer?

    private func startProgressTickerIfNeeded() {
        guard progressTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(1), repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.tickProgress()
        }
        progressTimer = timer
        timer.resume()
    }

    private func stopProgressTickerIfIdle() {
        guard liveSessions.isEmpty else { return }
        progressTimer?.cancel()
        progressTimer = nil
    }

    private func tickProgress() {
        for index in recordings.indices where recordings[index].status == .recording {
            let id = recordings[index].id
            guard let handle = liveSessions[id] else { continue }

            let bytes = buffer_direct_recorder_bytes_written(handle)
            if bytes != recordings[index].bytesWritten {
                recordings[index].bytesWritten = bytes
            }

            guard buffer_direct_recorder_is_running(handle) == 0 else { continue }

            var error = [CChar](repeating: 0, count: 256)
            let hasError = buffer_direct_recorder_copy_error(handle, &error, error.count) != 0
            buffer_direct_recorder_free(handle)
            liveSessions[id] = nil
            liveStopTimers[id]?.cancel()
            liveStopTimers[id] = nil
            scheduledStopTimers[id]?.cancel()
            scheduledStopTimers[id] = nil

            if hasError, let message = String(validatingCString: error), !message.isEmpty {
                markFinished(id: id, error: "Recording stopped: \(message)")
            } else if let message = unexpectedStopMessage(for: recordings[index]) {
                markFinished(id: id, error: message)
            } else {
                markFinished(id: id, error: nil)
            }
            releasePowerAssertionIfIdle()
        }
        // Deliberately no saveRecordings() — bytesWritten is transient
        // during live recording and gets finalized in markFinished().
    }

    private func unexpectedStopMessage(for recording: Recording) -> String? {
        let expectedStop = recording.scheduledEnd.addingTimeInterval(Double(postRollSeconds))
        guard Date() + Self.unexpectedStopGraceSeconds < expectedStop else { return nil }
        return "Recording stopped unexpectedly"
    }

    // MARK: - Timer plumbing

    private enum TimerKey {
        case live(UUID)
        case scheduledStart(UUID)
        case scheduledStop(UUID)
    }

    private func scheduleTimer(for key: TimerKey, fireAt: Date, action: @escaping @MainActor () -> Void) {
        let interval = max(fireAt.timeIntervalSinceNow, 0)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.clearTimer(for: key)
                action()
            }
        }
        store(timer: timer, for: key)
        timer.resume()
    }

    private func store(timer: DispatchSourceTimer, for key: TimerKey) {
        switch key {
        case .live(let id):
            liveStopTimers[id]?.cancel()
            liveStopTimers[id] = timer
        case .scheduledStart(let id):
            scheduledStartTimers[id]?.cancel()
            scheduledStartTimers[id] = timer
        case .scheduledStop(let id):
            scheduledStopTimers[id]?.cancel()
            scheduledStopTimers[id] = timer
        }
    }

    private func clearTimer(for key: TimerKey) {
        switch key {
        case .live(let id): liveStopTimers[id] = nil
        case .scheduledStart(let id): scheduledStartTimers[id] = nil
        case .scheduledStop(let id): scheduledStopTimers[id] = nil
        }
    }

    // MARK: - Power management

    private func acquirePowerAssertionIfNeeded() {
        guard !holdsPowerAssertion else { return }
        let reason = "Buffer is recording a stream" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &powerAssertion
        )
        if result == kIOReturnSuccess {
            holdsPowerAssertion = true
        }
    }

    private func releasePowerAssertionIfIdle() {
        guard holdsPowerAssertion else { return }
        guard liveSessions.isEmpty else { return }
        IOPMAssertionRelease(powerAssertion)
        holdsPowerAssertion = false
        powerAssertion = IOPMAssertionID(0)
    }

    // MARK: - Wake from sleep

    /// Register a wake event with macOS so the Mac boots out of sleep a couple
    /// of minutes before we need to start the recording. No-op if wake is
    /// disabled, the event is already past, or an event is already registered
    /// for this recording at the correct time.
    private func scheduleWakeIfNeeded(for recording: Recording) {
        guard wakeMacForRecordings else { return }
        let desiredWake = wakeDate(for: recording)
        guard desiredWake.timeIntervalSinceNow > 30 else { return }

        // If we've already asked the kernel for this exact wake time, don't
        // duplicate — macOS dedupes by (date, id, type) but we also track
        // `wakeAt` for reliable cancellation.
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        if let existing = recordings[index].wakeAt, abs(existing.timeIntervalSince(desiredWake)) < 1 {
            return
        }
        if recordings[index].wakeAt != nil {
            cancelWake(for: recordings[index])
        }

        let result = IOPMSchedulePowerEvent(
            desiredWake as CFDate,
            wakeEventID(for: recording.id) as CFString,
            kIOPMAutoWake as CFString
        )
        if result == kIOReturnSuccess {
            recordings[index].wakeAt = desiredWake
            saveRecordings()
        } else {
            AppLog.recording.error("IOPMSchedulePowerEvent failed recordingID=\(recording.id.uuidString, privacy: .public) result=\(result, privacy: .public)")
        }
    }

    private func cancelWake(for recording: Recording) {
        guard let wakeAt = recording.wakeAt else { return }
        let result = IOPMCancelScheduledPowerEvent(
            wakeAt as CFDate,
            wakeEventID(for: recording.id) as CFString,
            kIOPMAutoWake as CFString
        )
        if result != kIOReturnSuccess {
            // Not fatal — macOS may already have consumed the event at wake.
            AppLog.recording.warning("IOPMCancelScheduledPowerEvent returned result=\(result, privacy: .public)")
        }
    }

    /// Reconcile registered wake events with current settings. Called when
    /// the user flips the wake toggle.
    private func reconcileWakeEvents() {
        for index in recordings.indices where recordings[index].status == .scheduled {
            if wakeMacForRecordings {
                scheduleWakeIfNeeded(for: recordings[index])
            } else if recordings[index].wakeAt != nil {
                cancelWake(for: recordings[index])
                recordings[index].wakeAt = nil
            }
        }
        saveRecordings()
    }

    private func wakeDate(for recording: Recording) -> Date {
        recording.scheduledStart
            .addingTimeInterval(-Double(preRollSeconds))
            .addingTimeInterval(-Self.wakeLeadSeconds)
    }

    private func wakeEventID(for recordingID: UUID) -> String {
        // Include the recording id so `IOPMCancelScheduledPowerEvent` can
        // uniquely match against our event vs. ones from other processes.
        "com.buffer.recording.\(recordingID.uuidString)"
    }

    // MARK: - Output paths

    private static func defaultOutputDirectory() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("Buffer Recordings", isDirectory: true)
    }

    private func outputFileURL(channelName: String, title: String, start: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: start)
        let safeChannel = Self.sanitize(channelName)
        let safeTitle = Self.sanitize(title)
        // `.ts` because the direct recorder remuxes the source into MPEG-TS.
        // MPEG-TS is self-describing so partial files play while recording
        // is in progress.
        let filename = "\(stamp) \(safeTitle).ts"
        return outputDirectory
            .appendingPathComponent(safeChannel, isDirectory: true)
            .appendingPathComponent(filename)
    }

    nonisolated private static func startDirectRecorderAsync(
        streamURL: URL,
        fileURL: URL,
        userAgent: String?,
        referer: String?
    ) async -> DirectRecorderStartResult? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: startDirectRecorder(
                    streamURL: streamURL,
                    fileURL: fileURL,
                    userAgent: userAgent,
                    referer: referer
                ))
            }
        }
    }

    nonisolated private static func startDirectRecorder(
        streamURL: URL,
        fileURL: URL,
        userAgent: String?,
        referer: String?
    ) -> DirectRecorderStartResult? {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        var error = [CChar](repeating: 0, count: 256)
        let handle: OpaquePointer? = streamURL.absoluteString.withCString { inputURL in
            fileURL.path.withCString { outputPath in
                func create(_ userAgentPtr: UnsafePointer<CChar>?, _ refererPtr: UnsafePointer<CChar>?) -> OpaquePointer? {
                    buffer_direct_recorder_create(
                        inputURL,
                        outputPath,
                        userAgentPtr,
                        refererPtr,
                        &error,
                        error.count
                    )
                }

                if let userAgent {
                    return userAgent.withCString { userAgentPtr in
                        if let referer {
                            return referer.withCString { refererPtr in
                                create(userAgentPtr, refererPtr)
                            }
                        }
                        return create(userAgentPtr, nil)
                    }
                }
                if let referer {
                    return referer.withCString { refererPtr in
                        create(nil, refererPtr)
                    }
                }
                return create(nil, nil)
            }
        }
        guard let handle else {
            if let message = String(validatingCString: error), !message.isEmpty {
                AppLog.recording.error("Recorder start failed message=\(message, privacy: .public)")
            }
            return nil
        }

        var rawInfo = BufferDirectRecorderStreamInfo()
        buffer_direct_recorder_get_stream_info(handle, &rawInfo)
        let videoCodecTuple = rawInfo.video_codec
        let audioCodecTuple = rawInfo.audio_codec
        let videoCodec = withUnsafePointer(to: videoCodecTuple) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 32) {
                String(cString: $0)
            }
        }
        let audioCodec = withUnsafePointer(to: audioCodecTuple) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 32) {
                $0.pointee == 0 ? nil : String(cString: $0)
            }
        }
        let streamInfo = StreamInfo(
            videoWidth: Int(rawInfo.video_width),
            videoHeight: Int(rawInfo.video_height),
            videoCodec: videoCodec,
            videoFPS: rawInfo.video_fps,
            audioCodec: audioCodec
        )
        return DirectRecorderStartResult(
            handleBits: UInt(bitPattern: handle),
            streamInfo: streamInfo
        )
    }

    private static func sanitize(_ string: String) -> String {
        // Keep printable ASCII plus a few friendly characters. Strip
        // everything else: unicode in mpv/libavformat filenames is hit-
        // and-miss (EPG titles carry chars like "ᴺᵉʷ" which fail mux open)
        // and shell quoting is fragile.
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -_.,()[]'&+!"
        )
        let invalid = CharacterSet(charactersIn: "/:\\?*\"<>|")
        let cleaned = string.unicodeScalars
            .map { scalar -> String in
                if invalid.contains(scalar) { return "_" }
                if allowed.contains(scalar) { return String(scalar) }
                return ""
            }
            .joined()
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Recording" : cleaned
    }

    // MARK: - Persistence

    private func loadRecordings() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let list = try? decoder.decode([Recording].self, from: data) {
            recordings = list
        }
    }

    private func saveRecordings() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(recordings) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
