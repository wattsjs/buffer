import Foundation

@main
enum PlayerSessionTests {
    @MainActor
    static func main() async throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        func waitFor(_ condition: () -> Bool) async {
            for _ in 0..<500 {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        func channel(_ id: String, vod: Bool = false, catchup: Bool = false) -> Channel {
            Channel(id: id, name: "Local test \(id)", logoURL: nil, group: "Tests",
                    streamURL: URL(string: "http://127.0.0.1/\(id).m3u8")!, epgChannelID: nil,
                    catchup: catchup ? CatchupInfo(kind: .shift, days: 2, source: nil) : nil,
                    contentType: vod ? .vod : .live)
        }

        let slot = PlayerSlot(channel: channel("live"), currentProgram: nil)
        slot.loadInitialLive()
        let player = slot.player
        expect(player.usesStartupReserve == CommandLine.arguments.contains("--validate-startup-reserve"),
            "startup reserve requires the explicit experiment flag")
        expect(player.startupTargetEnabled == CommandLine.arguments.contains("--validate-startup-target"),
            "reported target trial requires the explicit experiment flag")
        expect(player.nativeCacheOnlyEnabled == CommandLine.arguments.contains("--validate-native-cache-only"),
            "native-only cache trial requires the explicit experiment flag")
        for live in [false, true] {
            for active in [false, true] {
                for requested in [false, true] {
                    expect(MPVStartupReserve.enabled(forLiveLoad: live, validationActive: active, flagRequested: requested) ==
                        (live && active && requested), "startup reserve cannot leak into finite or completed diagnostic playback")
                    expect(MPVStartupTarget.enabled(forLiveLoad: live, validationActive: active, flagRequested: requested) ==
                        (live && active && requested), "reported target cannot leak into finite or completed diagnostic playback")
                    expect(MPVNativeCacheOnly.enabled(forLiveLoad: live, validationActive: active, flagRequested: requested) ==
                        (live && active && requested), "native-only cache trial cannot leak into finite or completed diagnostic playback")
                }
            }
        }
        expect(player.wantsPlayback, "initial live action requests playback")
        player.onPlaybackEnded?(.eof)
        player.pause()
        try await Task.sleep(for: .milliseconds(400))
        expect(player.loadCount == 2, "terminal live EOF still recovers")
        expect(!player.wantsPlayback, "pause after reconnect scheduling must win")
        expect(!player.isPlaying, "recovered paused stream stays paused")

        slot.pauseBackgroundWork()
        slot.pauseBackgroundWork()
        expect(!player.wantsPlayback, "sleep must retain owner pause")
        player.onPlaybackEnded?(.error(code: -1, message: "late sleep callback"))
        slot.ensureRecoveryWatchdogsArmedForFocus()
        try await Task.sleep(for: .milliseconds(400))
        expect(player.loadCount == 2, "late END_FILE during sleep must not schedule recovery")
        slot.resumeBackgroundWork()
        expect(player.loadCount == 3 && !player.isPlaying, "live wake reload preserves user pause")
        slot.resumeBackgroundWork()
        expect(player.loadCount == 3, "duplicate wake is idempotent")

        player.play()
        slot.pauseBackgroundWork()
        expect(player.wantsPlayback && !player.isPlaying, "sleep suspends playing owner intent")
        player.pause()
        slot.resumeBackgroundWork()
        expect(!player.wantsPlayback && !player.isPlaying, "new pause during sleep survives wake")

        let beforeWarnings = player.loadCount
        for _ in 0..<50 {
            player.onStreamIssue?(.httpError("HTTP error 509"))
            player.onStreamIssue?(.hlsReloadFailed("segment retry"))
            player.onStreamIssue?(.reconnecting("network retry"))
            player.onStreamIssue?(.httpError("HTTP error 502"))
        }
        try await Task.sleep(for: .milliseconds(400))
        expect(player.loadCount == beforeWarnings, "warning storms must not discard cached media")
        expect(slot.playbackStreamHealth.http509Count == 50, "509 warning diagnostics remain visible")
        expect(slot.playbackStreamHealth.playlistReloadFailureCount == 50, "playlist warning diagnostics remain visible")
        expect(slot.playbackStreamHealth.reconnectCount == 50, "demuxer retries remain visible")
        slot.cancelReconnect()

        for vod in [false, true] {
            let finite = PlayerSlot(channel: channel(vod ? "vod" : "archive", vod: vod, catchup: !vod), currentProgram: nil)
            if vod {
                finite.loadInitialLive()
            } else {
                let start = Date().addingTimeInterval(-1800)
                finite.playCatchup(from: start, timeline: DateInterval(start: start, duration: 1200), programID: nil)
            }
            let backend = finite.player
            expect(!backend.usesStartupReserve, "archive and VOD cannot inherit live startup reserve")
            expect(!backend.startupTargetEnabled && !backend.nativeCacheOnlyEnabled,
                "archive and VOD restore production cache policy")
            backend.pause()
            finite.pauseBackgroundWork()
            finite.resumeBackgroundWork()
            expect(!backend.wantsPlayback && backend.loadCount == 1, "finite paused media must retain load and pause on wake")
            backend.play()
            finite.pauseBackgroundWork()
            finite.resumeBackgroundWork()
            expect(backend.wantsPlayback && backend.isPlaying, "finite playing media resumes from same load")
            finite.cancelReconnect()
        }

        // Explicit handoff requests play synchronously. The deferred snapshot
        // task must not undo a newer pause after the view yields.
        let resumed = PlayerSlot(channel: channel("replacement-vod", vod: true), currentProgram: nil)
        resumed.resumeOnDemand(to: 75, reload: true)
        expect(resumed.player.loadCount == 1 && resumed.player.currentURL == resumed.channel.streamURL,
            "replacement resume opens the new on-demand endpoint")
        expect(resumed.player.seekCount == 0, "replacement resume waits for the new FILE_LOADED before seeking")
        resumed.player.onFileLoaded?()
        expect(resumed.player.timePos == 75 && resumed.player.seekCount == 1,
            "new on-demand FILE_LOADED applies the queued resume position")
        resumed.resumeOnDemand(to: 95, reload: false)
        expect(resumed.player.loadCount == 1 && resumed.player.timePos == 95,
            "same endpoint resume seeks without a healthy reload")
        let metadata = Channel(id: resumed.channel.id, name: "Updated title", logoURL: nil, group: "Updated group",
            streamURL: resumed.channel.streamURL, epgChannelID: nil, contentType: .vod)
        let refreshedMetadata = await resumed.replacePlaybackChannel(metadata)
        expect(refreshedMetadata && resumed.channel.name == metadata.name && resumed.player.loadCount == 1,
            "same physical request refreshes metadata without stopping healthy playback")

        let handoff = PlayerSlot(channel: channel("handoff"), currentProgram: nil)
        handoff.player.loadURL(handoff.channel.streamURL, autoplay: true)
        handoff.loadInitialLive()
        handoff.player.pause()
        await Task.yield()
        await Task.yield()
        expect(!handoff.player.wantsPlayback, "deferred live handoff must not override newer owner pause")
        handoff.cancelReconnect()

        // Replacement STOP is consumed at the production MPV item boundary.
        // Only a genuine end for the active entry reaches PlayerSlot; there
        // must be no speculative STOP count left to swallow a later end.
        let correlated = PlayerSlot(channel: channel("correlated"), currentProgram: nil)
        correlated.loadInitialLive()
        var items = MPVItemLifecycle()
        items.invalidate(generation: 1)
        let oldLoad = items.enqueue(.load("old-local"), generation: 1)!
        _ = items.complete(requestID: oldLoad.id, playlistEntryID: 11)
        items.started(playlistEntryID: 11)
        _ = items.loaded()
        items.invalidate(generation: 2)
        let currentLoad = items.enqueue(.load("current-local"), generation: 2)!
        _ = items.complete(requestID: currentLoad.id, playlistEntryID: 22)
        if let oldStop = items.ended(playlistEntryID: 11, reason: .stopped) {
            correlated.player.onPlaybackEnded?(oldStop.reason)
        }
        expect(correlated.player.loadCount == 1, "replacement STOP must not trigger current slot recovery")
        items.started(playlistEntryID: 22)
        _ = items.loaded()
        let actualEOF = items.ended(playlistEntryID: 22, reason: .eof)!
        correlated.player.onPlaybackEnded?(actualEOF.reason)
        try await Task.sleep(for: .milliseconds(400))
        expect(correlated.player.loadCount == 2, "active EOF after filtered replacement STOP must reconnect")
        items.invalidate(generation: 3)
        let errorLoad = items.enqueue(.load("failed-local"), generation: 3)!
        _ = items.complete(requestID: errorLoad.id, playlistEntryID: 33)
        items.started(playlistEntryID: 33)
        let actualError = items.ended(playlistEntryID: 33, reason: .error(code: -13, message: "local failure"))!
        correlated.player.onPlaybackEnded?(actualError.reason)
        try await Task.sleep(for: .milliseconds(600))
        expect(correlated.player.loadCount == 3, "active error must reconnect after entry filtering")
        correlated.cancelReconnect()

        for archive in [false, true] {
            for validation in [false, true] {
                let options = ArchiveTimestampRecovery.options(forArchiveLoad: archive, validationRequested: validation)
                let enabled = archive && validation
                expect(options.enabled == enabled, "timestamp recovery requires both archive and explicit validation")
                expect(options.linearize == (enabled ? "yes" : "auto"), "live/VOD restore default timestamp linearization")
                expect(options.lavf.contains("correct_ts_overflow=\(enabled ? 0 : 1)"), "every load explicitly restores wrap handling")
            }
        }

        let minute = floor(Date().addingTimeInterval(-1800).timeIntervalSince1970 / 60) * 60
        let requested = Date(timeIntervalSince1970: minute + 37)
        let archive = Channel(id: "minute-archive", name: "Minute archive", logoURL: nil, group: "Tests",
            streamURL: URL(string: "http://127.0.0.1/live.m3u8")!, epgChannelID: nil,
            catchup: CatchupInfo(kind: .xc, days: 2,
                source: "http://127.0.0.1/timeshift/${duration}/${Y}-${m}-${d}:${H}-${M}/local.ts"))
        let request = CatchupURLBuilder.request(for: archive, start: requested, duration: 120)!
        expect(request.loadedStart.timeIntervalSince1970 == minute, "minute-only URL reports its actual start")
        expect(request.initialSeekSeconds == 37, "minute rounding preserves requested sub-minute offset")
        expect(request.url.path.contains("/timeshift/3/"), "minute request length retains intended end")
        let shifted = CatchupURLBuilder.request(for: channel("second-archive", catchup: true), start: requested, duration: 120)!
        expect(shifted.loadedStart == requested && shifted.initialSeekSeconds == 0, "second-capable archive retains exact start")
        expect(CatchupURLBuilder.request(for: archive, start: Date(timeIntervalSince1970: .infinity), duration: 120) == nil,
               "non-finite archive start cannot reach integer URL conversion")

        let timeline = DateInterval(start: requested.addingTimeInterval(-600), duration: 3600)
        let archiveSlot = PlayerSlot(channel: archive, currentProgram: nil)
        archiveSlot.playCatchup(from: requested, timeline: timeline, programID: nil)
        let archivePlayer = archiveSlot.player
        expect(archiveSlot.catchup?.loadedStart == request.loadedStart, "transport timeline uses actual encoded URL origin")
        archivePlayer.onFileLoaded?()
        expect(archivePlayer.seekCount == (ArchiveTimestampRecovery.validationRequested ? 0 : 1),
               "experiment avoids unsafe initial seeks; baseline restores sub-minute position")
        archivePlayer.duration = 3600
        archivePlayer.isSeekable = true
        archivePlayer.pause()
        archiveSlot.seekCatchup(toWallClock: requested.addingTimeInterval(120))
        expect(!archivePlayer.wantsPlayback, "archive move preserves owner pause intent")
        expect(archivePlayer.loadCount == (ArchiveTimestampRecovery.validationRequested ? 2 : 1),
               "linearized archive moves rebuild URLs while baseline uses in-clip seek")
        expect(archivePlayer.seekCount == (ArchiveTimestampRecovery.validationRequested ? 0 : 2),
               "linearized archive never sends low-level seeks")
        archiveSlot.cancelReconnect()

        // These policies exercise actual terminal escalation, never log
        // warnings, guessed metadata quality, or a healthy-source upgrade.
        var policy = SmartLiveRecoveryPolicy()
        policy.noteFailure(now: 0)
        expect(policy.decision(current: "a", alternatives: ["b"], now: 20,
            playbackRequested: true, suspended: false, epochMatches: true) == .sameSource,
            "one failure is insufficient to switch")
        policy.noteFailure(now: 1)
        expect(policy.decision(current: "a", alternatives: ["b"], now: 7,
            playbackRequested: true, suspended: false, epochMatches: true) == .sameSource,
            "transient failure streak must retain source")
        expect(policy.decision(current: "a", alternatives: ["b"], now: 8,
            playbackRequested: true, suspended: false, epochMatches: true) == .alternate("b"),
            "repeated sustained failure permits configured alternative")
        for (requested, suspended, epoch) in [(false, false, true), (true, true, true), (true, false, false)] {
            expect(policy.decision(current: "a", alternatives: ["b"], now: 40,
                playbackRequested: requested, suspended: suspended, epochMatches: epoch) == .suspended,
                "paused, sleeping and stale requests cannot switch")
        }
        policy.didSwitch(from: "a", to: "b", now: 10)
        policy.noteFailure(now: 11); policy.noteFailure(now: 12)
        expect(policy.decision(current: "b", alternatives: ["a", "c"], now: 25,
            playbackRequested: true, suspended: false, epochMatches: true) == .sameSource,
            "cooldown prevents source flapping")
        expect(policy.decision(current: "b", alternatives: ["a", "c"], now: 40,
            playbackRequested: true, suspended: false, epochMatches: true) == .alternate("c"),
            "already failed source is not immediately revisited")
        policy.didSwitch(from: "b", to: "c", now: 40)
        policy.noteFailure(now: 41); policy.noteFailure(now: 42)
        expect(policy.decision(current: "c", alternatives: ["d"], now: 100,
            playbackRequested: true, suspended: false, epochMatches: true) == .sameSource,
            "live session source switches are bounded")
        policy.noteHealthy()
        expect(policy.decision(current: "c", alternatives: ["d"], now: 120,
            playbackRequested: true, suspended: false, epochMatches: true) == .sameSource,
            "healthy playback never triggers quality upgrades")

        let sourceA = UUID(), sourceB = UUID()
        func owned(_ source: UUID, logical: String = "smart:sports:fixture") -> Channel {
            Channel(id: logical, name: "Fixture", logoURL: nil, group: "Tests",
                streamURL: URL(string: "http://127.0.0.1/\(source.uuidString)/same-id.m3u8")!, epgChannelID: "wrong-guide",
                sourceOwnership: ChannelSourceOwnership(channelIdentity: SourceChannelIdentity(sourceID: source, nativeID: "same-id"),
                    accountKey: .unconfiguredSource(source), logicalChannelID: logical))
        }
        let selected = owned(sourceA), alternative = owned(sourceB)
        var fastPolicy = SmartLiveRecoveryPolicy()
        fastPolicy.minimumFailureSeconds = 0
        let smartSlot = PlayerSlot(channel: selected, currentProgram: nil, recoveryPolicy: fastPolicy)
        smartSlot.configureLiveAlternatives([alternative])
        smartSlot.loadInitialLive()
        let smartBackend = smartSlot.player
        let initialSlotID = smartSlot.id
        let staleCallback = smartBackend.onPlaybackEnded
        smartBackend.onPlaybackEnded?(.eof)
        try await Task.sleep(for: .milliseconds(400))
        smartBackend.holdsTeardown = true
        smartBackend.onPlaybackEnded?(.error(code: -1, message: "fixture"))
        try await Task.sleep(for: .milliseconds(650))
        expect(smartBackend.loadCount == 2, "alternative cannot open until previous END_FILE confirms teardown")
        expect(AccountCapacityLedger.shared.snapshot(accountKey: .unconfiguredSource(sourceA)).localReservations == 1,
            "old account lease remains while stop is pending")
        expect(AccountCapacityLedger.shared.snapshot(accountKey: .unconfiguredSource(sourceB)).localReservations == 0,
            "alternative does not consume a connection prematurely")
        smartBackend.confirmBackendIdle()
        await waitFor { smartBackend.currentURL == alternative.streamURL }
        expect(smartBackend.currentURL == alternative.streamURL && smartBackend.loadCount == 3,
            "confirmed teardown opens the configured physical alternative")
        expect(smartSlot.id == initialSlotID && smartSlot.logicalChannelID == selected.id,
            "logical channel and player window identity survive source switch")
        expect(smartSlot.sourceChangeMessage != nil, "source changes explain live continuity risk")
        expect(AccountCapacityLedger.shared.snapshot(accountKey: .unconfiguredSource(sourceA)).localReservations == 0,
            "old account is released after teardown")
        let beforeStale = smartBackend.loadCount
        staleCallback?(.eof)
        try await Task.sleep(for: .milliseconds(400))
        expect(smartBackend.loadCount == beforeStale, "stale old-source callbacks cannot own new-source recovery")
        smartSlot.retireAndRecyclePlayer()
        expect(AccountCapacityLedger.shared.snapshot(accountKey: .unconfiguredSource(sourceB)).localReservations == 0,
            "retired player releases alternative lease after backend idle")

        let pausedSource = UUID(), pausedAlternative = UUID()
        let pausedSlot = PlayerSlot(channel: owned(pausedSource), currentProgram: nil, recoveryPolicy: fastPolicy)
        pausedSlot.configureLiveAlternatives([owned(pausedAlternative)])
        pausedSlot.loadInitialLive()
        let pausedBackend = pausedSlot.player
        pausedBackend.onPlaybackEnded?(.eof)
        try await Task.sleep(for: .milliseconds(400))
        pausedBackend.holdsTeardown = true
        pausedBackend.onPlaybackEnded?(.eof)
        try await Task.sleep(for: .milliseconds(650))
        pausedBackend.pause()
        pausedBackend.confirmBackendIdle()
        await Task.yield(); await Task.yield()
        expect(pausedSlot.channel.sourceChannelIdentity?.sourceID == pausedSource && pausedBackend.currentURL == nil,
            "owner pause during teardown prevents alternative from opening")
        expect(AccountCapacityLedger.shared.snapshot(accountKey: .unconfiguredSource(pausedAlternative)).localReservations == 0,
            "pause cannot consume another account connection")
        pausedSlot.retireAndRecyclePlayer()

        let rejectedSource = UUID(), rejectedAlternative = UUID()
        let rejectedSlot = PlayerSlot(channel: owned(rejectedSource), currentProgram: nil, recoveryPolicy: fastPolicy)
        rejectedSlot.configureLiveAlternatives([owned(rejectedAlternative)], resolver: { _ in nil })
        rejectedSlot.loadInitialLive()
        let rejectedBackend = rejectedSlot.player
        rejectedBackend.onPlaybackEnded?(.eof)
        try await Task.sleep(for: .milliseconds(400))
        rejectedBackend.onPlaybackEnded?(.eof)
        try await Task.sleep(for: .milliseconds(650))
        expect(rejectedSlot.channel.sourceChannelIdentity?.sourceID == rejectedSource,
            "catalogue rejection during playback must not resurrect an old eligible alternative snapshot")
        expect(AccountCapacityLedger.shared.snapshot(accountKey: .unconfiguredSource(rejectedAlternative)).localReservations == 0,
            "rejected alternative cannot reserve an account")
        rejectedSlot.retireAndRecyclePlayer()

        let blockedSource = UUID()
        let existingRecording = try AccountCapacityLedger.shared.reserve(for: owned(blockedSource), kind: .recording, ownerID: UUID()).get()
        let blockedSlot = PlayerSlot(channel: owned(blockedSource), currentProgram: nil)
        blockedSlot.loadInitialLive()
        expect(blockedSlot.player.currentURL == nil && blockedSlot.recoveryErrorMessage != nil,
            "player cannot open before recording capacity permits its connection")
        _ = AccountCapacityLedger.shared.confirmTeardown(lease: existingRecording)
        blockedSlot.retireAndRecyclePlayer()

        let noArchive = PlayerSlot(channel: channel("no-archive"), currentProgram: nil)
        noArchive.playCatchup(from: requested, timeline: timeline, programID: nil)
        expect(noArchive.player.currentURL == nil && noArchive.recoveryErrorMessage != nil,
            "unavailable archive never silently substitutes live playback")
        noArchive.loadLive()
        noArchive.playCatchup(from: requested, timeline: timeline, programID: nil)
        expect(noArchive.player.currentURL == nil && noArchive.recoveryErrorMessage != nil,
            "failed archive action stops an existing live stream instead of displaying it as catchup")

        let continuationNow = Date()
        let oldEnd = continuationNow.addingTimeInterval(-1800)
        var immediateEOFs = 0
        for index in 1...3 {
            let decision = CatchupClipContinuationPolicy.decision(previousImmediateEOFs: immediateEOFs,
                positionSeconds: 0, timelineEnd: oldEnd, now: continuationNow)
            immediateEOFs = decision.consecutiveImmediateEOFs
            expect(decision.action == (index == 3 ? .replayUnavailable : .continueArchive),
                "three empty archive clips stop replay instead of automatically opening live")
        }
        let healthyNearLive = CatchupClipContinuationPolicy.decision(previousImmediateEOFs: 2,
            positionSeconds: 120, timelineEnd: continuationNow, now: continuationNow)
        expect(healthyNearLive.action == .returnToLive && healthyNearLive.consecutiveImmediateEOFs == 0,
            "healthy replay reaching live retains the existing live transition")
        expect(CatchupClipContinuationPolicy.decision(previousImmediateEOFs: 0,
            positionSeconds: 0, timelineEnd: continuationNow, now: continuationNow).action == .continueArchive,
            "an empty near-live clip cannot establish that archived playback reached live")
        expect(CatchupClipContinuationPolicy.decision(previousImmediateEOFs: 2,
            positionSeconds: 0, timelineEnd: continuationNow, now: continuationNow).action == .replayUnavailable,
            "repeated early failures take precedence over nominal near-live timing")
        expect(CatchupClipContinuationPolicy.decision(previousImmediateEOFs: 2,
            positionSeconds: 120, timelineEnd: oldEnd, now: continuationNow).consecutiveImmediateEOFs == 0,
            "healthy archive playback resets an earlier empty-clip failure streak")
        expect(CatchupClipContinuationPolicy.decision(previousImmediateEOFs: 2,
            positionSeconds: .nan, timelineEnd: continuationNow, now: continuationNow).action == .replayUnavailable,
            "unknown clip progress cannot qualify a live transition")

        let failedReplaySource = UUID()
        let failedReplayChannel = Channel(id: "failed-replay", name: "Failed replay fixture", logoURL: nil, group: "Tests",
            streamURL: URL(string: "http://127.0.0.1/failed-replay.m3u8")!, epgChannelID: nil,
            catchup: .init(kind: .shift, days: 2, source: nil),
            sourceOwnership: .init(channelIdentity: .init(sourceID: failedReplaySource, nativeID: "failed-replay"),
                accountKey: .unconfiguredSource(failedReplaySource)))
        let failedReplay = PlayerSlot(channel: failedReplayChannel, currentProgram: nil)
        let failedTimeline = DateInterval(start: continuationNow.addingTimeInterval(-3600), end: oldEnd)
        failedReplay.playCatchup(from: failedTimeline.start, timeline: failedTimeline, programID: "archive-program")
        let failedReplayBackend = failedReplay.player
        let lateFirstFrame = failedReplayBackend.onFirstFrame
        let savedLoadCount = failedReplayBackend.loadCount
        failedReplayBackend.holdsTeardown = true
        failedReplay.stopUnavailableReplay()
        expect(failedReplay.isCatchup && failedReplay.catchup?.timeline == failedTimeline &&
            failedReplay.catchup?.programID == "archive-program",
            "terminal empty replay preserves the explicit archived programme and timeline")
        expect(failedReplayBackend.currentURL == nil && failedReplayBackend.loadCount == savedLoadCount &&
            !failedReplayBackend.wantsPlayback && failedReplay.recoveryErrorMessage?.contains("Replay unavailable") == true,
            "terminal empty replay stops and reports its failure without loading live")
        lateFirstFrame?()
        expect(failedReplay.recoveryErrorMessage != nil, "late archive callbacks cannot erase terminal replay failure")
        expect(AccountCapacityLedger.shared.snapshot(accountKey: .unconfiguredSource(failedReplaySource)).localReservations == 1,
            "failed replay retains its lease until backend teardown is confirmed")
        failedReplayBackend.confirmBackendIdle()
        expect(AccountCapacityLedger.shared.snapshot(accountKey: .unconfiguredSource(failedReplaySource)).localReservations == 0,
            "confirmed failed replay teardown releases the account connection")
        failedReplay.playCatchup(from: failedTimeline.start, timeline: failedTimeline, programID: "archive-program")
        expect(failedReplay.isCatchup && failedReplay.recoveryErrorMessage == nil && failedReplayBackend.currentURL != nil &&
            failedReplayBackend.currentURL != failedReplayChannel.streamURL,
            "explicit replay retry loads archive again rather than substituting live")
        failedReplay.retireAndRecyclePlayer()

        // Ordinary performance provenance must not be inferred from a live
        // channel object when its actual mode or load is a diagnostic/archive.
        expect(!slot.allowsOrdinaryLiveEvidence, "diagnostic captures cannot publish ordinary live reliability")
        SavedPlaybackScenario.isCapturing = false
        PlaybackValidation.isEnabled = false
        let ordinaryEvidence = PlayerSlot(channel: channel("ordinary-evidence", catchup: true), currentProgram: nil)
        ordinaryEvidence.loadInitialLive()
        let evidencePlayer = ordinaryEvidence.player
        expect(ordinaryEvidence.allowsOrdinaryLiveEvidence, "ordinary live may publish genuine passive evidence")
        evidencePlayer.liveAnalysisEnabled = true
        expect(!ordinaryEvidence.allowsOrdinaryLiveEvidence, "analysis experiments cannot train ordinary reliability")
        evidencePlayer.liveAnalysisEnabled = false
        evidencePlayer.nativeCacheOnlyEnabled = true
        expect(!ordinaryEvidence.allowsOrdinaryLiveEvidence, "native-only cache experiment cannot train ordinary reliability")
        evidencePlayer.nativeCacheOnlyEnabled = false
        evidencePlayer.startupTargetEnabled = true
        expect(!ordinaryEvidence.allowsOrdinaryLiveEvidence, "startup holds cannot train ordinary reliability")
        evidencePlayer.startupTargetEnabled = false
        evidencePlayer.usesStartupReserve = true
        expect(!ordinaryEvidence.allowsOrdinaryLiveEvidence, "native startup reserve cannot train ordinary reliability")
        evidencePlayer.usesStartupReserve = false
        ordinaryEvidence.pauseBackgroundWork()
        expect(!ordinaryEvidence.allowsOrdinaryLiveEvidence, "background/sleep work cannot train ordinary reliability")
        ordinaryEvidence.resumeBackgroundWork()
        ordinaryEvidence.playCatchup(from: Date().addingTimeInterval(-3600),
            timeline: DateInterval(start: Date().addingTimeInterval(-3600), end: Date()), programID: nil)
        expect(!ordinaryEvidence.allowsOrdinaryLiveEvidence, "archive playback cannot qualify the live endpoint")
        ordinaryEvidence.retireAndRecyclePlayer()
        let finiteEvidence = PlayerSlot(channel: channel("finite-evidence", vod: true), currentProgram: nil)
        expect(!finiteEvidence.allowsOrdinaryLiveEvidence, "VOD playback cannot train live reliability")
        finiteEvidence.retireAndRecyclePlayer()
        print("Player session lifecycle checks: \(checks) passed")
    }
}
