# Smart Sports validation — 2026-10-05

This is an implementation and validation record, not stream-equivalence or sustained-reliability qualification. The worktree remains uncommitted.

Latest offline build: `.logs/uhd-offline-final-build.log` passes with the pinned signature;195 aggregate Python tests pass in `.logs/uhd-offline-final-python.log`. Further source checks pass:41 coordinator/loader checks including warm-cache failure retention,10 actual catalog-version checks,25 actual routing checks, and120 player checks in five modes. Programme-only Smart updates retain warm Sports catalog identity and in-flight matches. Same-revision read failures retain bounded usable guides with explicit warnings; changed, removed or unresolved source revisions are not restored. VOD uses current source ownership and replacement resume loading. Repeated early archive EOFs stop with replay unavailable and preserve archived intent.

Sources and Reviews now use ordinary auxiliary SwiftUI windows to allow comparison alongside the guide. Their actual controls remain unqualified: the Mac locked after the separate UHD comparison, so manual unlock is needed before continuing native UI validation. No additional provider, recording or failover qualification is implied by the offline build.

## Implemented behavior

- The playlist picker includes Smart Sports alongside Odyssey and Infinity. The sanitized catalog contains 56 stable logical feeds, 320 source-scoped variants, and 73 held endpoints excluded from automatic membership. Rotating slots and dedicated UHD/Ultimate editions remain separate review decisions.
- Current configured source snapshots resolve playable endpoints by source UUID and native ID. Changed name, group, raw guide binding or content type requires review. Native IDs and guide IDs alone do not establish identity.
- Manual links, splits, exclusions, current-identity acceptance, playback source preferences and independent guide preferences persist through atomic actor writes. Restoring an endpoint removes its manual membership decisions; still-changed metadata requires review again.
- Playback selection applies source/account/device/mode eligibility before fresh observed reliability, sports motion, useful resolution and startup evidence. Unmeasured variants retain uncertainty. Legacy cached formats without endpoint revision do not rank current quality. New observations are tied to a one-way digest of the endpoint actually used.
- Display guide lookup keys are namespaced per logical feed. Raw source guides and their timestamps remain separate. A physical playback/action channel retains its own provider/native ID, account and guide binding.
- Unvalidated Smart catchup fails explicitly and offers the original source guide. An archive never silently falls back to live. Recordings are pinned to physical source ownership. Players, recordings and probes share capacity reservations; teardown confirmation releases a lease.
- Bounded live source recovery uses the existing player owner, preserves logical window identity and explains a source change. Archive and VOD modes do not use live failover. Healthy playback does not switch sources to upgrade quality.

## Build and automated checks

The full optimized instrumented Debug app built successfully through `scripts/bench.sh --configuration optimized`, retaining the pinned Apple Development identity `3CA7CA94D514ABFA330E86B5A8A767BC4EC2A0C0`. This is not a Release performance claim. Build evidence: `.logs/smart-sports-build-final.log` and `.logs/bench-build-optimized.log`.

| Check | Actual result |
|---|---|
| Smart catalog identity, review, selection, guide, archive and persistence | 50 checks pass |
| Real coordinator/loader namespaces, source actions, account gating and stale epochs | 30 checks pass |
| Actual EPGViewModel Smart source routing | 16 checks pass |
| Actual RecordingManager ownership/capacity with a local blocking recorder | 14 checks pass |
| Existing aggregate Swift checks | Pass, including 81 player lifecycle checks in each of three configurations, 901 settings draft checks, 50 source-scoped probe checks, 45 grid checks, 325 appearance checks and parser/cache suites |
| Aggregate Python checks | Final 190 pass in `.logs/smart-sports-python-final.log`; the earlier zero-match fixture awaited a redundant revision and was repaired without changing production search |

The aggregate log is `.logs/smart-sports-full-tests.log`. Source-specific regressions cover wrong BBCOne/dummy/event guide bindings, source-native ID collisions, region/language/+1/edition distinctions, preserved manual decisions, obsolete endpoint observations, stale source callbacks, capacity including recordings/probes, and archive refusal without validated timing.

## Actual app inspection

The previous diagnostic process was closed through CUA after the Window menu showed only its library window. The updated app was opened by exact checkout path with zero diagnostic arguments, as PID28578. Its current ordinary source was Infinity and remained Infinity before Smart selection.

Confirmed through native CUA accessibility and screenshots:

- Ordinary Home displayed 11 live sports entries, including real NFL fixtures and scores.
- The playlist picker showed Smart Sports, Odyssey, Infinity and source management.
- Smart Sports loaded all 56 logical channel rows, with AU/CA/QA/UK/US groups and populated dark EPG cards and titles.
- The membership review sheet opened and displayed exactly 73 held rows, with Odyssey and Infinity ownership visible.

A real defect was reproduced: `Playback & Guide Sources…` inside a transient channel context menu dismissed the menu without presenting its inspector. Presentation state was moved to EPGViewModel and the persistent ContentView presenter. That full signed optimized build passes (`.logs/smart-sports-build-presenter.log`), but the next native accessibility read crashes the automation helper; inspector interaction qualification remains pending.

After opening the review sheet, CUA reported `Sky Computer Use native pipe closed before response` on held-row selection and subsequent exact app rebindings. Inventory still worked. The app remained alive; `.logs/smart-review.sample.txt` showed its main thread idle in the event loop and MPV idle, rather than an application hang. Actual `SkyComputerUseService` crash reports at04:50:24,04:51:12,04:52:37,05:03:09 and05:03:39 show a Swift `Array.remove(at:)` assertion/SIGTRAP in the helper. Restarting the verified idle checkout and resetting CUA repaired ordinary UI inspection, but modal inspector interaction repeated the helper crash. Manual source/guide mutations, review round trips and provider playback must not be claimed validated from this partial UI pass.

After the first bridge recovery, actual Settings inspection confirmed Content, Playback, Refresh and Recordings. Show Movies and TV was restored to OFF through its switch (`disableVOD` subsequently reads1). Show Live Sports remains ON, catchup lookback All available, buffer5seconds, expanded media details, technical metadata ON, internal player None, refresh24hours/6hours, recording padding30/60seconds and wakeON. These controls were inspected without changing source credentials or starting refresh/recording jobs.

## Remaining validation and limits

- The passive quality producer is now explicitly ordinary-live and generation-bound. Archive, VOD, background and diagnostic/experimental performance samples cannot qualify the live endpoint. Endpoint fingerprints survive Codable round trips; missing legacy provenance remains unknown. PlayerSession129 checks pass in all five configurations and the real probe service61 checks pass. Moving startup and absolute broadcast delay remain unknown until independently measured; first-picture time, probe operation time and replay-window offset are not substituted.
- A later source-only fix addresses the user's grey/offline logical Fox Footy and Fox Sports News rows. Aggregate status distinguishes unavailable, account busy, recent successful observation, uncertain alternatives and recent failures. It requires a matching endpoint fingerprint, explicit provenance and bounded age; unknown alternatives are never labelled online. Initial live selection avoids a freshly failed preferred physical endpoint when another eligible alternative exists, preserves the preference and explains the fallback. Existing-owner replacement planning can ignore its held capacity while actual reservations remain mandatory. Strict coordinator/loader coverage now passes 57 checks in `.logs/smart-availability-tests.log`; full app/UI qualification of these later source changes remains with root and the UI owner.
- Build/CUA ownership is released back to root to prioritize the user's UHD startup report. The UI integration owner is implementing narrow auxiliary inspector/review windows so the library stays usable while comparing sources. That scene change has not yet been built or inspected in this record.
- Verify the repaired source inspector, independent source/guide choice and review mutations in the actual app, then restore test changes.
- The original Show Movies and TV setting was restored to OFF. Respect the user's newer Infinity source choice.
- Complete ordinary source, Smart favorites/recents, reminder/record action feedback and catchup refusal UI checks. Recording network execution is covered only by a local recorder fixture here; no paid/provider recording was started.
- No provider playback, cross-provider live failover, current stream equivalence, HDR, sustained quality or healthy-source upgrade was qualified in this UI pass.
- The separate handoff retains real live/VOD/archive measurements and failed fault experiments. These failures are not superseded by a successful Smart catalog build.
- One idle process sample reported roughly1.63GiB RSS and0% CPU after both Smart source caches loaded. This is a single point, not a sustained playback performance measurement.
- The user's UHD initial cache-floor pause still needs the baseline/startup-reserve comparison with actual flag evidence. The startup reserve is DEBUG capture-only; normal app opens must retain baseline behavior after a capture ends.
