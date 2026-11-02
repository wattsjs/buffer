# Buffer performance / playback-resilience handoff

_Last updated: 2026-10-05, local continuation. Repository: `/Users/jamie/Code/buffer`._

## Active continuation after unlock (2026-10-05)

The Mac is unlocked. Root owns every CUA/provider capture/full build. All changes remain uncommitted. User added three concrete requirements: Smart rows must not inherit one physical source's offline badge; Sports NFL matching must include Sky UHD first and show more alternatives; completely redesign Settings structure/UI using SwiftUI Expert, macOS patterns and Liquid Glass. Preserve the user's newer ordinary source Odyssey and Sports context (they changed it while browsing), plus original ShowMovies/TV OFF. Check active player windows before restarting; computer-use guard reported user changes during two attempted actions, so root left the browsing session open.

Visible native-cache-only trial: `.logs/channel-matrix-20261005-121448-275620`, Infinity375494 now carrying Lions/Panthers NFL. No reported buffering, appfloor0, sampled clock nonprogress0.259s,5frame drops/0decoder, A/V10.6ms, firstpicture4732ms. Strict gate stillfails one clock discontinuity. Catalog agent proved it is consistent with UI0.25s quantization:0.520s advance over0.261 followedbyzero over0.259 whileframes progress; combined0.783s has0.780clock/39frames. Old failure stays retained. New fresh raw time-pos/receipt-age capture telemetry and asyncrefresh are implemented, plus unsupportedvideo-pts staysnull. New Python score uses raw timing only when supplied, rejects missing/stale moving samples, retains old legacy-report behavior and unchanged jump/drop/stall budgets. Narrow46playback+21matrix tests pass. Annotator `scripts/analyze_startup_capture.py` preserves originalpass/fail; `.logs/uhd-native-only-motion-analysis.json`, `benchmarks/STARTUP-MOTION-INTERPRETATION.md`.

Startup timing owner is frozen: new MPVLiveAnalysis.swift/PlaybackClockSample.swift, DEBUG --validate-live-analysis=1|2 only recognized network live/activecapture, per-entry baseline/trial/fastrecord options, actualanalyze/probesize/probeinfo readbacks/audio samplerate, numeric coarsephases.67DEBUG/59Release helperchecks, MainActor typecheck andparse pass. RootCLI --live-analysis wiresflag, actual readback+audio confirmation. No startup default adopted; need contemporary same-binary baseline/native-only/target/analysis comparisons without compiler overlap.

Smart availability source is frozen: domain64coordinatorchecks(current suite includes matching additions), UI/probe57, player120five modes, routing25. It distinguishes unknown/busy/missing/recentfailures, only freshendpoint/provenance-bound failure can demote selection; alternatives remain visible; logicaldimming usesaggregate. New endpointfingerprint onC/passive records; archivedformat doesn't assert liveavailability. It is not built/actualUIvalidated in root's current app yet.

Sports matching source is frozen: removed160candidate/10result truncation, exactevent tier beforequality/reliability/motion/resolution, expandedSmart physicalUHD alternatives with ownsourceguides. ActualsanitizedcachereplaySkyMainUHDfirst: Infinity392results/5SkyUHD/~183ms; Odyssey327/5/~487ms(detached/cached, not full-apptimings). Old reconstructedlogic10NBC/0Sky provescause. Lazy420ptpopover/count showsatleast3rows. Native programmeactionbinding usesexactmatchedtitle/start/end ratherthanpregamecontainingESPNkickoff. Sports/sport-card/64coordinator checks pass. See benchmarks/SPORTS-MATCHING-20261005.md. Sourcefiles include new SportsProgrammeBinding.swift and ContentView snapshot/quality-version wiring.

Settings UI owner is actively rewriting SettingsView + Views/Settings/*.swift. Root readLiquidGlassSKILL andSettings/macOSScene refs. New hierarchy Sources/Library/Guide&Sports/Playback/Recordings/Appearance, nativeglass sidebar/toolbar/grouped forms; Sources own master/detail, explicitTest/Use/Save controls. Root-owned perUUIDSettingsSourceWorkspace retains unsaved drafts throughsource/section navigation, storedcredential updates still mergeuntouchedfields. Standardtitlebar1120x760 scene planned. All files parse now, but UI owner must finish state checks/freeze before rootcombinedbuild. No actualsource/pref/credential mutations have been performed for this redesign.

## UHD startup continuation (2026-10-05, supersedes status below)

**Final offline checkpoint:** `.logs/uhd-offline-final-build.log` signed optimized full app build and pinned-signature verification pass. `.logs/uhd-offline-final-python.log`195 Python tests pass. Swift checks: startup target/pause27, control82, cache20, PlayerSession120 in allfive configurations, coordinator/loader41, catalog-version10, actualrouting25, Sports warm-match regression and existingSports suites pass. All source owners are frozen. The new archive EOF, warm Smart cache/matching, truthful buffering, startup target/native-only trial code is now BUILT. Trials remain DEBUG capture-only and unqualified; ordinary startup defaults remain baseline. No Buffer process is running. Mac unlock remains required for provider/visible/auxiliary-window validation.

User reported a short first-open stall on Sky Sports UHD while watching NFL. Root reproduced it through the normal app's Infinity Recently Watched row, UK: Sky Sports Main Event UHD (native ID375494; now airing darts). Actual first picture6672ms, then Buffer's cache-floor guard paused at media0.525 for2272ms. VideoToolbox decoded3840x2160/50fps. The preceding6494ms load phase is not isolated decoder cost. Safe numeric evidence: `.logs/sky-uhd-ui-startup.json`, `.logs/sky-uhd-ui-render.json`, and `benchmarks/UHD-STARTUP-20261005.md`.

Latest combined signed optimized build passed `.logs/uhd-startup-build-final.log`, preserving pinned certificate. FullPython193 passed `.logs/uhd-startup-python-final.log`. New pure cache sample20 checks, source routing25, PlayerSlot86 in each of three modes, Smart catalog-version10 passed. Aggregate script now includes the new identity/capacity/Smart/search/recording/cache suites. Native Sources/Reviews auxiliary windows compile, but controls still need actual UI qualification.

Two same-binary Infinity UHD30s captures completed with confirmed backend teardown/restoration: baseline `.logs/channel-matrix-20261005-052849-283013` fails4.079s sampled stalls/8frame drops; native initial reserve `.logs/channel-matrix-20261005-053252-891902` confirmsactualtrue/2.5s settings but fails8.496s sampled stalls/9.142s reported buffering/2frame drops/twoappfloorpauses. Neither is healthy. Initial held pictures are counted by old startup/stall gates; retain raw evidence and distinguish motion. Native initial reserve is NOT adopted.

Primary mpv docs say demuxer-cache-duration is an unreliable approximation, sometimes unavailable with data buffered. "Exact" cache telemetry means fresh and unrounded, not independently measured packet coverage. A reportedzero proves the app guard trigger, not native starvation. Native cache pause may resume below its target at prefetch limits. Root asked recovery owner for two separateDEBUGcapture-only trials: reported startup target hold and native cache-only (skip proactive app floor). CLI `--startup-target`/`--native-cache-only` is wired and narrowPythonchecks pass. Recovery owner is implementing/testing; these newer changes are not in the captured binary and ordinary defaults remain baseline.

Completed production fixes in that build: invalid cache observations immediately retire old precise samples; VOD resolver stamps current sourceUUID/nativeID/account and rejects stale async returns; replacement resume queues seek before loading; ordinary live actions resolve current endpoints; Smart programme-only updates no longer bump channelCatalogVersion or clear warmSports indexes. Newly requested next-cycle fixes: archive repeated early EOF must report unavailable and retain archived intent (UI owner); same-revision Smart cache failures must preserve warm sources/guide and deferred warmSports matching must not invalidate in-flight work (catalog owner). Coordinate source freeze before next build.

Mac locked after both captures. CUA reports automatic unlock failed; root requested manual unlock asynchronously. Do not bypass the lock or run invisible provider captures. Root closed only its completed, confirmed-idle capture processPID61907; no Buffer process remains. Infinity and original ShowMovies/TV OFF remain preserved. Continue offline source/fixture/build work, then validate actual auxiliary controls, native-only/target startup trials, varied channels and finite/archive playback when unlocked. No final completion or default-performance qualification claim.

## Smart integration checkpoint (2026-10-05, 04:50 Brisbane)

Smart implementation code is now present and the optimized app builds. Build/UI owner is subagent smart_catalog; it owns all CUA/builds until releasing them. Root should avoid competing validation. It launched normal PID28578 without any diagnostic flags, preserved Infinity, observed actual Home NFL/live fixtures, Smart picker with56 logical rows/five country groups/populated dark EPG, and Review sheet with73held/source provenance. One aggregate Python190 test timed out in search-empty-index, delegated to UI owner; not fullgreen yet. Source inspector context-menu sheet presenter is transient; UI owner fixing. CUA encountered native pipe errors but actual app sample showed857/857mainloopidle; app was not hung. All source owners report frozen except those narrow fixes.

Smart UI owner smart_ui_integration completed16 production routing checks plus22 matching search-snapshot/coalescing checks. It stamped normal source channels/status, added independent Smart selection, all source-aware record/reminder/program actions, logical request registry matching, source-change/capacity UI, inspector/review menus, and blocks Smart external players because their capacity/teardown cannot be tracked. Ordinary external remains. Optional persisted reminder ownership/raw programme preserves legacy decoding. Smart archives do not automatically trust borrowed guide time; users route to original source guide until timing validated. Old PendingCatchup side channel removed in favor of explicit requests.

Capacity/search owner capacity_ledger completed45 ledger/identity tests and22 actual EPG search tests. Forty progressive updates now produce first/final indexes only; matching programSearchStore is published atomically, source/Smart revision changes reject old workers. SourceSnapshot/current metadata changes cannot silently resurrect native IDs. All test compiler lists include ownership dependencies; test_sync uses actual Smart dependencies and minimal isolated framework stubs.

Recovery owner smart_recovery completed70 PlayerSlot checks in two archive modes,50 probe checks,14 recording checks. Shared caps reserve beforeopen and hold tillbackendEND+commandidle/Cprobeclosed/recorderclosed; pinned recordings use uniqueUUID filenames. Physical replacement compares source+native ANDURL, same-idtoken revisions teardown before new. Live alternatives are bounded and root supplies current catalog resolver; no healthy upgrades/transient-buffer flapping. Source-scope probe cache and passive metadata/evidence replace fake probe-duration latency. Root still needs completed real Smart action/capacity/provider validation report; no stream equivalence or live failover qualification claim.

Root added --startup-reserve to playback/channel matrix scripts; telemetry startupReserveEnabled+exactCacheSeconds proves actual flag. New MPVStartupReserve helper is DEBUG capture-only; live flag passed byPlayerSlot, per-file loadfileoptions establish cache-pause-initial deterministically, finite/archive/reuse restorebaseline. Precise cache guard uses per-generation fresh samples (<2.5s), not quantizedUIcache. Dynamic SavedScenario.isCapturing +render/archive helpers prevent experiment flags leaking to ordinary opens after completedtest. Root Actor default-param fix ArchiveTimestampRecovery.options validationRequested Bool?=nil is applied.

Startup user'sSkyUHDNFL originalpause:03:36:14 cache0/time1.292/loadedfalse(loadingfalse), immediate appcache-floorpause floor1/resume1.75. HEVCinvalidNAL/DTS warnings nearby but no proof ofterminaldisconnect. HLS live_start_index defaults-3segments; 2sfixturesroughly6s horizon, not five-second reserve. cache-secs can override smallerreadahead; no default changed except precisecachecorrectness. Startupwaittrial still needs actualqualification. User original ShowMoviesTV OFF was temporarilyenabled; buildowner shouldrestoreOFF whenfinished, respecting any explicit userchanges.

Root authored benchmarks/PLAYBACK-COMPARISON-20261005.md eleven rows from captured evidence. Local broker completed32requests/retried9HTTP502, preservedcompletebytes/AVsync0.128ms butstillfailed3.534s interruption/4.522sbuffer/26drops. Not a production broker. All provider captures must be sequential and respect newcapacity. Rendering no-block and TS recovery remain DEBUG experiments. Root regular playback clean1080p60 qualifies, manyfault/UHD/proxy/resume trials failed and remain retained. Fullapp UI/perf SourceIDs/caplimits/Smart integration must be reviewed through completion before final claims.

## Latest continuation: playback and Smart Sports (2026-10-05)

This is active unfinished work, all uncommitted. Read this before the historical notes below.

**Latest source fix:** Smart programme-only publications no longer increment the channel catalog version and clear Sports' warm matching index. Full displayed metadata/ownership changes still invalidate it; Smart/original mode transitions also invalidate prior source matches. The actual EPGVM/coordinator regression passes 10 checks (`bash scripts/test-smart-catalog-versions.sh`). This source is frozen for root's next combined UHD validation build. Read-only cache-retention and deferred in-flight matching findings are recorded in `docs/EPG-SPORTS-REVIEW.md`; they remain unedited and do not delay playback captures.

**Follow-up source fixes are now frozen:** Same-revision Smart channel/guide read failures retain compatible bounded warm data with an explicit warning. Successfully resolved inputs prove the revision; removed, password/guide-changed, unresolved or recycled native identities cannot revive old content. The strict coordinator/loader suite passes41 checks (`.logs/smart-warm-guide-tests.log`). Deferred same-source history updates no longer invalidate an in-flight warm Sports match when there is no index work to cancel; a deterministic blocked-worker regression and existing Sports/fixture suites pass (`.logs/sports-warm-match-tests.log`). These changes are not yet full-app built in this agent's evidence; root combines them with the archive EOF fix after current UHD captures. No provider requests, app builds or CUA actions were performed for these fixtures.

**Latest validation update, 2026-10-05, approximately 05:05 Brisbane:** Smart Sports is implemented and full signed optimized builds pass, most recently `.logs/smart-sports-build-presenter.log`. The bundled catalog contains 56 logical feeds, 320 variants and 73 held endpoints. Domain50, coordinator30, actual EPG routing16 and actual RecordingManager ownership14 checks pass. Existing aggregate Swift suites pass; all 190 final Python tests pass in `.logs/smart-sports-python-final.log`. The earlier search-empty timeout was an obsolete fixture waiting for a redundant revision; only the fixture changed.

Actual zero-flag app UI showed Infinity Home live NFL fixtures, Smart Sports with 56 rows/five country groups/populated dark cards, and exactly 73 held reviews. The transient context-menu inspector bug was fixed with persistent EPGVM/ContentView state. Actual source/guide manual-choice validation remains incomplete because SkyComputerUseService itself traps in `Array.remove(at:)` on modal UI transitions; Buffer stays responsive with its backend idle. Crash reports045024/045112/045237/050309/050339 and `.logs/smart-review.sample.txt` retain evidence. Restarting the idle app and resetting CUA restores ordinary UI.

Current normal app PID41459 has zero diagnostic flags. No provider player was opened by this validation owner. The original Show Movies/TV OFF setting was restored through actual Settings UI (`disableVOD`1); Infinity remains the current ordinary source. Settings Content, Playback, Refresh and Recordings were inspected. See `docs/SMART-SPORTS-VALIDATION.md` for actual evidence and limits. No stream equivalence, sustained quality, provider recording or real cross-source failover qualification is claimed. Build/CUA ownership has been released back to root to prioritize the user's UHD startup pause. The UI integration owner is implementing narrow auxiliary source/review windows that improve desktop comparison and keep the library usable; these are not yet built or validated. The baseline UHD/startup-reserve provider trial remains for root once idle.

User priorities: video performance first; validate different sources/resolutions plus catchup/VOD/all UI/settings; refine dark EPG and spacing; fully explore original handoff ideas; work faster with parallel agents. User confirmed accidental Enter when diagnostic players stole focus. Diagnostics now use a nonactivating NSPanel with the real PlayerView; normal player windows stay normal.

Latest successfully built full signed optimized app: `.local/DerivedData-Optimized/Build/Products/Debug/Buffer.app`, phase10. Signing retains pinned certificate `3CA7CA94D514ABFA330E86B5A8A767BC4EC2A0C0`. Many newer Smart files and capture-lifetime fixes are NOT built yet. No commits or PRs.

IMPORTANT temporary state: Show Movies and TV was originally OFF and enabled through UI for validation. Restore it to OFF after testing. `.local/ui-validation-original.json` records source Odyssey, disableVOD true, buffer5, media details expanded, stream probes on. User later selected Infinity and reported Sky Sports Main Event UHD NFL initial two-second stall; respect their current source. Do not stop their active player to run another provider capture.

Actual user app was PID70641 from optimized checkout, left running after `.logs/channel-matrix-20261005-032604-853906`. It carries saved-scenario/archive/render experiment argv. Root is fixing experiment lifetime to use `SavedPlaybackScenario.isCapturing`, so normal opens after a completed capture cannot inherit experiment behavior. That lifetime code is currently partial/source only: SavedScenario and ArchiveTimestampRecovery/MPVRenderTiming/PlayerView changed; recovery agent owns MPV per-load/reuse offset reset and unit stubs. Do not claim current process is baseline. Installed `/Applications/Buffer.app` was an older instance; it was closed. build-and-run now uses `open -n` exact checkout to avoid activating installed old bundle.

Playback evidence:
- `.logs/playback-20261005-024952-988866`: full optimized Buffer1080p60 clean AVFoundation passes, startup547ms,0drops/decoder drops/stalls, maxAV0.076ms, processCPU21.2%, RSS237MiB.
- Baseline4s502 `.logs/playback-20261005-025124-590338`: fails,7.578s stalls,3.776s AV error, clock jumps.4s delayed response `.logs/playback-20261005-025440-031860` fails3.541s stalls.
- Native AVPlayer clean/502/stall pass: `.logs/playback-20261005-022436-387072`, `...025843-722947`, `...030229-634191`;5022.5s stalls, others0 sampled stalls. Standalone host, independent AVsync/decoder metrics unavailable. Native host has since been changed to nonactivating, not rerun yet.
- GStreamer current output is TWO channels, historical8 mapping now fails preflight. Nonactivating probe clean/502/stall passes current gates at4.7-4.75% processCPU/102-106MiB RSS. Bothfaults had1s sampled readiness loss, not zero interruption. Evidence `benchmarks/GSTREAMER-CURRENT-LAYOUT.md` and `.logs/gstreamer-current-layout-matrix.json`.
- Root fixed score to count only rendered/requested same-generation progress, exclude/fail clock jumps, count post-start readiness loss.37 playback +21matrix tests passed. Old reports must be re-scored before comparisons; do not pool unequal hosts/metrics.
- Renderer sample `benchmarks/RENDER-PROFILE.md`:77.1% main stacks inside synchronous mpv render wait (WALLTIME, notCPU); sample introduced11drops, retain as perturbed failure. Paused resize/uncover fix repaints retained frame, preserving decoded-frame telemetry.
- DEBUG paired `--validate-render-no-block` offset0+BLOCK0 experiment remains nondefault. Clean `.logs/playback-20261005-031540-177089` passes3drops/maxAV3.76ms; actualHEVC Main10 SDR UHD50 `.logs/playback-20261005-032220-789090` fails81drops/occlusion/clockjump. Never call HDR qualified. Fixture repaired BT709 VUI losslessly;33segments/audio/timestamps verified, corpus1afb503e...619d.
- NativeHTTP retry4s502 `.logs/playback-20261005-031947-994183` stillfails5.567s stall/1.657sAV. No production retry default change.
- Local-only HLS broker prototype: `benchmarks/hls_retry_proxy.py`, `--transport-proxy`,15 socket tests. Root capture `.logs/playback-20261005-033059-758266` stillfails3.534s stalls/4.522sbuffering/26drops but AV0.128ms. No production proxy/migration. Details `benchmarks/HLS-RETRY-PROXY.md`.
- Actual VOD start (Sisu id665358 Odyssey) passes in matrix `...032604-853906`; resume60 fails15drops/4.029sbuffering. Archive repair removes95k-second jump, maxAV23ms/3drops/no stalls, but strict clock gate stillfails small positive positionjump. These captures restore/teardown correctly. AppCPU60-85% reflects whole library workload, not decoder-only.
- TS reset cause reproduced on native bundled libmpv: backward367s interpreted as33-bit wrap95,076s. Pair correct_ts_overflow0+linearizeyes fixes local reset/wrap; unsafe low-level seeks demonstrated. DEBUG archive only, reload URL for moves, preserve pause. Normal Xtream minute-origin accounting corrected. `benchmarks/ARCHIVE-TIMESTAMP-DIAGNOSIS.md`;24nativecases+6seekcases,44+44slot checks.

UI/work completed: viewport-backed EPG fixed actual80k compositor card disappearance; dark palette actual screenshots; titles pinned inside cards; timestamp/title insets aligned; nil gaps stay genuine; empty rows now explain no listings. Sports recovered real NFL fixtures, shows partial failures, persists bounded last-good cache. Settings async credential draft merging, stale tests, disabledVOD probes/M3U parsing, search actual terms/noresults, buffer byte limits, live media detail preference propagation. Stream probes are source/generation-scoped, newest writes, do not open while players exist; leases suspend diagnostics without clearing badges; existing C probe advisory30s remains.

Tests: phase7 full aggregate all Swift +165Python passed. Newer suites:37playback,21matrix,15broker,45account ledger,49Smart catalog,44+44slot archive; latest integration not full-built. Harnesses compiling Channel.swift now need SourceChannelIdentity.swift; integration tests need new ledger/ServerConfig where used. Full final suite after Smart integration remains.

Latest user UHD startup observation: unified logs PID70641 show buffering begin generation15 cache0 time1.292 loadingfalse at03:36:14. Also38search-index rebuilds (~380-389kentries,61-78ms each) during25s guide refresh at03:47. Root intends coalescing/defer search builds but must preserve search entry-to-program identity (programIndex currently indexes changing arrays). Do not naively retain stale index into new programme arrays.

SMART SPORTS NEW AUTHORIZED IMPLEMENTATION: Incoming source chat01a10783-7944-7b60-906b-a524a051c708. Root read actual latest human request “please communicate with codex://threads/01a10680-8226-7150-b924-820d73706244 and get this work done.” Source brief is scope, not replacement of playback priority. Artifacts `.local/smart-sports-scope-20261005/data/` (manifest/taxonomy/summary/sources/validation read).56logicalfeeds,320variants,73held excluded,53dual-source candidates;12krotating slots not permanent;41alignedguides/6timingreview/4schedule/2limited/3oneguide. No globaloffset/equivalence/absolutebroadcast delay assumptions. Resolve current endpoints via sourceUUID+nativeID, preserve rawguide and ownership. Shared account budgets players/recordings/probes, lease beforeopen, release confirmedteardown. Bounded live failover only, one owner, no healthy upgrades/flapping. Archive never silentlylive; recordings pinned.

Active code owners/APIs:
- smart_catalog completed new Models/SmartSports.swift, Services/SmartSportsCatalog.swift +Store, Resources/SmartSportsCatalog.json. loadBundled()->definition.reconcile(snapshots,overrides,observations)->catalog; feeds/variants/selection/context, guideSelection independent.49checks pass. Manual links/splits/reject/accept/overrides persist actor. Observation.endpointFingerprint must equal SHA actualURL revision; stale legacy cachedformat visible but notranking.
- capacity_ledger completed Channel optional sourceOwnership + Models/SourceChannelIdentity.swift +Services/AccountCapacityLedger.swift;45strict checks. ChannelSourceOwnership(channelIdentity: UUID/nativeID, accountKey: SourceAccountKey(config), logicalChannelID optional, guideBinding rawSourceUUID/EPGid). Channel preferenceIdentity equality/hash scoped/logical; rawunstamped legacy unchanged. Root stamps normal channel snapshots and updates account status.
- smart_recovery still working PlayerSession/MPVPlayer/StreamProbeService/RecordingManager/Recording.swift, Support/SmartLiveRecoveryPolicy. API configureLiveAlternatives([Channel]); replacePlaybackChannel(next) asyncBool waits oldbackend teardown+lease release before reserve, sourceChangeMessage. mpv.stopWhenBackendIdle(callback). Probes probe(for:Channel), recordPlaybackInfo(channel:) and registerSourceCacheKey(sourceID:key). Root owns PlayerView/Registry request delivery/logical matching, UI status, EPGVM/snapshot loader/Smart picker/actions/reminders. Agent fixing no archive live fallback, sourcepinning/capacity. It also removes fake probe-duration latency; root label actual value replay-window offset.

Root SMART UI/EPG integration has NOT started. Need implement source snapshot loader (resolve async Keychain config, current-v8 caches; no rawsecret output), Smart observable coordinator, playlist picker virtual selection, logical Channel rows, favorites/recents scope, source overrides/review UI, independent guides, correct archive/reminder/record bindings. Avoid overwriting normal source channels/programs with Smart while normal sync runs; use effective displayed snapshots/caches. Preserve ordinary playlists and all existing code. Test identity/collisions/held/exclusions/overrides/sourceactions/caps/stalecallbacks then fullbuild+actualUI.

Current app may be playing user's NFL; inspect before builds/provider captures. Do not repeat old test loops or broad source refreshes. Read diagnostic notes/artifacts, preserve all failures. Original full handoff ideas mapped and primary refreshed in `benchmarks/HANDOFF-IDEA-COVERAGE.md`; KSPlayer/VLCKit/customsynchronizer/libcurl/adaptive reserve remain feasibility/prototypes, not qualified production migrations.

## Current continuation (2026-10-05)

This section supersedes the historical build/signing/runtime notes below. All changes remain uncommitted. Goal mode is currently off. Preserve the existing worktree.

- The user's Apple Development certificate is pinned in ignored `.local/code-sign-identity` (public SHA1 `3CA7CA94D514ABFA330E86B5A8A767BC4EC2A0C0`). Use `scripts/local-signing.sh` and `scripts/build-and-run.sh`; do not recreate/revoke the certificate. Both shell and Python verification use `-R=...` with current codesign.
- Latest full app build: `scripts/bench.sh --configuration optimized`, signed full Debug app with `-O`/WMO and DEBUG instrumentation. This is not an ordinary Release build. Normal path: `.local/DerivedData-Optimized/Build/Products/Debug/Buffer.app`. Build log `.logs/bench-build-optimized.log`; benchmark log `.logs/phase3-optimized-build.log`.
- Current real saved sources are Infinity and Odyssey. Use one provider player at a time; never log configuration, credentials, authenticated URLs, or third-party stderr. The deterministic scenario bypasses usage/recents, confirms actual backend END_FILE/idle before next channel, and restores original source/model selection.
- Actual EPG compositor failure was reproduced: the full approximately80k-point archive canvas lost every card/title while a separate metadata overlay remained visible. Programme hosting and native backing are now viewport-sized, with document-coordinate geometry and translated hit-testing. Actual dark UHD guide screenshot confirms cards and titles render: `.logs/phase3-dark-guide.png`. A later title-pin change is in source and needs the next combined build.
- EPG colors use the consuming view's appearance with dark neutral surfaces, light labels, restrained live/replay cues, and measured contrast checks. Offline dimming remains on channel tiles rather than making programme text unreadable. 308 appearance/render/interaction plus45 grid checks passed before the later title-pin addition.
- Guide loading publishes current listings and visible catch-up history early, retains bounded cached history through sparse/failing responses, deduplicates aliases, coalesces publications, and bounds concurrent HTTP requests. It never invents missing provider listings or copies unrelated channel schedules. The controlled progressive fixture reports first-current3086→100ms and first-history3086→165ms, six publications/main commit0.18ms. These are fixture measurements, not provider timings.
- Sports index rebuilds defer through history enrichment while preserving a usable warm index; cold startup still builds the first available current guide. Source/index/preference cancellation and stale publication tests pass.
- DiagnosticOutput replaces blocking stdout/FIFO writes and synchronous main-thread draining with bounded nonblocking transport and explicit dropped-record failures. A stopped collector cannot freeze the normal app. Actual unattended scenario launch now starts without computer-use activation.
- Validation: Swift aggregate suites passed;147 current Python tests passed across aggregate plus updated matrix suite. The aggregate's only failure was a stale expected helper-check count, corrected and covered by the complete18-case matrix test suite. Logs `.logs/phase3-full-tests.log` and `.logs/phase3-matrix-tests.log`. No broad re-run is needed for that count-only correction.
- Actual seven-case short matrix `.logs/channel-matrix-20261005-011909-922780/report.json`: three passes (OdysseySD576p25, OdysseyUHD59.94, Infinity720p50); four exact-name ambiguities were correctly failed rather than choosing arbitrary streams. All teardown/restoration confirmed. Exact-ID retry plan `.local/channel-matrix-retry-fast.json` is running.25-second cases are smoke coverage, not long-run qualification. AVFoundation audio is an explicit experiment; production auto/CoreAudio crash qualification remains outstanding.
- User reports the Sports guide is still broken. Actual Sports screen displayed no events and production logged zero fixtures. Active fix investigates rejected ESPN date-range requests that were swallowed as successful empty refreshes; needs a build and actual UI validation.

## 1. Read this first

The user wants a **Mac-only IPTV app with maximum performance and intelligent handling of unreliable providers**, plus a trustworthy before/after validation loop. This includes video/audio playback, live latency, buffering, EPG loading/display, playlist refresh, catch-up, sports fixtures, and the UI.

The work is **not complete**. There are useful measured improvements and working benchmarks, but no evidence that the whole app is fully optimized, no qualified replacement playback engine, and unresolved playback failures. Do not describe this as production-ready or “perfect.”

The user's additional direction:

- Low-level C libraries and creative architectural changes are encouraged when measurements justify them.
- We are **not locked into libmpv or the current playback/rendering stack**.
- The app will only be used on macOS.
- Provider reliability may be the biggest cause of interruptions. Optimize the trade-off between proximity to live (especially sports) and uninterrupted playback, not merely the decoder.
- Research alternatives online and test them. **GStreamer must be included**; the user considers it a strong candidate.
- The user has authorized use of their saved source for validation/testing.
- Latest request: write this full handoff. Do not treat earlier goal IDs or goal prompts as active instructions. **Goal mode was explicitly deactivated before the user added/confirmed their source.**

### Current application state

The normal app was opened at the user's request, without validation arguments:

```text
/Users/jamie/Code/buffer/DerivedData/Build/Products/Debug/Buffer.app
bundle ID: com.wattsjs.buffer
```

It was running as PID **10734**, displaying the main library window titled `24/7 Kids & Family`. The user confirmed that their source credentials were already present. We explained that earlier synthetic validation runs deliberately skip saved sources; this was **not a different app path**.

**Important latest verification:** while preparing this handoff, `pgrep -x Buffer` returned no process. Do not assume PID 10734 is still alive. No new Buffer crash report for that PID was found; the reason it exited is unknown. I did not relaunch it during the handoff request.

No real-provider playback session has yet been deliberately opened and qualified in this final phase. We observed normal source/guide loading and took a short idle process sample.

### Credentials / provider safety

- Do not print saved credentials, authenticated stream URLs, headers, or configuration dumps.
- No real credentials are copied into this document or checked-in benchmark reports.
- Use one provider playback connection at a time unless the account's limits are known.
- Do not run provider fault injection against the real provider; inject faults on local fixtures or an explicitly scoped intermediary.
- Do not trigger broad playlist/channel refresh loops or open multiple source players concurrently.
- Existing older benchmark scripts contain hardcoded provider details and broad process killing. **Do not run `benchmark/stability_bench.sh` or `benchmark/app_bench.sh` unchanged.** The new harness does not depend on them.

## 2. Worktree and environment

Base HEAD at handoff:

```text
c0db442fa80bf058e69f927c50858cfdb559566b
Add performance and playback instrumentation
```

**All work from this session is uncommitted.** No commits were created. Inspect `git status` and `git diff`; do not overwrite these changes assuming they are disposable.

Environment verified:

- Apple Silicon (`arm64`).
- macOS **27.0 beta**.
- Xcode **27.0**, build `27A5252f`, selected via `/Applications/Xcode-beta.app`.
- Swift app target uses default MainActor isolation and Debug `-Onone`.
- MPVKit package resolved at **0.41.0**; Sparkle 2.9.1; Nuke 12.8.0.
- No valid development signing identity was installed. Local builds use ad-hoc signing via command-line overrides; project signing settings were not replaced.
- Installed Homebrew **ffmpeg 9.0.2** for fixture generation.
- Installed Homebrew **GStreamer 1.28.7** (formula revision `_2`), including its plugins and dependencies.
- GStreamer plugin registry used by the harness: `.local/bench/gst-registry.bin`.
- Accessibility scripting was enabled: `osascript` / System Events could inspect Buffer's UI tree.

Installation notes:

- GStreamer initial plugin scanning was slow and emitted GI library and duplicate GTK class warnings. The explicit local registry worked afterward.
- The configured `websearch` tool was unavailable (`PI_WEB_TOOLS_EXA_ENDPOINT` missing). Research used direct primary-source `webfetch` calls.
- Attempted to launch a background research agent with `cxa`, but it had no configured accounts. No account/config changes were made; research was done in this session.

## 3. How to build and run

### Reliable local build

```bash
cd /Users/jamie/Code/buffer
xcodebuild \
  -project Buffer.xcodeproj \
  -scheme Buffer \
  -configuration Debug \
  -derivedDataPath DerivedData \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  CODE_SIGNING_REQUIRED=NO \
  build
```

This build has succeeded repeatedly. `scripts/bench.sh` performs the same build and records output in `.logs/bench-build.log`.

### Normal app, including saved source

First inspect processes to avoid opening duplicate normal instances:

```bash
pgrep -x Buffer
open /Users/jamie/Code/buffer/DerivedData/Build/Products/Debug/Buffer.app
```

Do **not** pass `--validate-url` when trying to use the saved library. Synthetic validation deliberately bypasses source loading and hydration. The normal app uses the same bundle ID and normal saved configuration.

The old `scripts/build-and-run.sh` still assumes normal signing and broadly kills Buffer before running; prefer the explicit commands above for this session.

## 4. Implemented framework

### 4.1 Production-code microbenchmarks

Files:

- `Buffer/Support/PerformanceBenchmark.swift`
- `scripts/bench.sh`
- `scripts/bench.py`
- `scripts/test_bench.py`

Commands:

```bash
scripts/bench.sh
cp .logs/bench-latest.json .logs/bench-baseline.json
# Make one change, rebuild, compare:
scripts/bench.sh --compare .logs/bench-baseline.json
# Existing binary only; do not claim this tests unbuilt source:
scripts/bench.sh --skip-build --compare .logs/bench-baseline.json
```

Behavior:

- Launches the actual built Buffer executable with `--benchmark`.
- Runs before normal app bootstrap; `EPGViewModel` skips saved-account hydration in benchmark mode.
- Uses production M3U parser, XMLTV parser, guide lookup, and StreamMatcher.
- Five fixed-fixture cases, warm-up plus seven measured samples each.
- Validates result checksums and records elapsed time as floating-point milliseconds.
- Structured output prefix: `BUFFER_BENCH_JSON `.
- Archives timestamped reports and `.logs/bench-latest.json`.
- Records fixture/schema, OS/architecture, Debug configuration, HEAD, worktree diff hash, executable hash, timestamp.
- Rejects incompatible baselines or changed outputs.
- Exit **2** for median regressions beyond default 15%; configurable `--tolerance`.
- Exit **1** for execution/evidence errors.
- Baseline is loaded before overwriting `bench-latest.json`, so comparing against that path does not silently compare the run to itself.

**Limitations:** these are Debug `-Onone` timings, not Release claims. The worktree diff hash does not include untracked source files; the binary hash is the definitive executable identifier. Checksum validation checks counts/case-specific invariants, not all content; separate differential tests cover index contents.

Early draft benchmarks compared no-ops and simulated sleeps against work. Those were **removed**. Do not cite their output or earlier conversational claims as evidence.

### 4.2 Correctness / regression tests

```bash
scripts/test-performance.sh
```

At the last full run:

- **555 guide lookup checks**: empty lists, boundaries, gaps, duplicate starts, overlapping schedules.
- Shared-guide sports-index equivalence against independent indexing: serialized entries, tokens, document-frequency weights, Unicode descriptions, hidden groups, empty guide.
- Cancellation before and during StreamMatcher indexing.
- **17 Python unittest cases**:
  - Five benchmark comparison/gate tests.
  - Seven playback-gate tests.
  - Five actual HTTP catch-up integration tests, including serial/concurrent output equivalence.

Relevant files:

```text
benchmarks/guide_lookup_tests.swift
benchmarks/stream_index_tests.swift
benchmarks/catchup_integration.swift
scripts/test_bench.py
scripts/test_playback.py
scripts/test_catchup.py
scripts/test-performance.sh
```

Standalone Swift tests compile production files. Some target-wide Xcode isolation/compiler settings differ from standalone `swiftc`; full app builds remain required.

### 4.3 Actual rendered playback and fault injection

Files:

```text
Buffer/Support/PlaybackValidation.swift
scripts/playback.py
benchmarks/native_player.swift
benchmarks/gstreamer_player.m
```

The Python harness:

- Generates local H.264 + silent AAC HLS fixtures with FFmpeg; no provider credentials.
- Caches fixtures in `.local/hls-*`.
- Supports **720p30 at 3Mbit/s** and **1080p60 at 8Mbit/s**.
- Serves rolling, real-time HLS by default (moving window, no ENDLIST).
- Supports explicit `--stream-type vod` as a different scenario.
- Includes program-date-time in rolling playlists.
- Injects scheduled segment stalls or 502s, or a permanently offline source.
- Binds only loopback on an ephemeral port.
- Owns and cleans up its child process/server; does not broadly kill existing apps.
- Captures structured samples, process CPU/RSS, request-fault events, executable hash, stdout/stderr, and a JSON verdict under `.logs/playback-*/`.
- Samples at roughly 500ms.
- Requires start/end evidence, sufficient sample coverage, video readiness/dimensions, progressing playback, and drop/stall budgets.
- Aggregates per-generation drop maxima so reconnect counter resets do not erase all earlier drops.
- For MPV, checks a real selected audio backend and sampled A/V error (150ms gate).
- For GStreamer, checks actual `hlsdemux2` and `vtdec_hw` instantiation and real output samples.
- Missing native/GStreamer measurements are identified as limitations rather than claimed as measured decoder-drop/A/V-sync zeros in current summary output.

Commands:

```bash
# Actual Buffer renderer, unchanged default backend:
python3 scripts/playback.py --seconds 30

# Experimental libmpv AVFoundation audio output, bounded transport retry:
python3 scripts/playback.py --seconds 45 --ao avfoundation --http-retry \
  --fault 502 --fault-at 12 --fault-seconds 4

# Native AVPlayer standalone Cocoa probe:
python3 scripts/playback.py --engine native --seconds 45 \
  --fault 502 --fault-at 12 --fault-seconds 4

# GStreamer: primary candidate pipeline:
python3 scripts/playback.py --engine gstreamer --gst-sink glimagesink \
  --gst-audio-map 8 --profile 1080p60 --seconds 30 \
  --fault 502 --fault-at 12 --fault-seconds 4

# MUST fail, not report healthy playback:
python3 scripts/playback.py --seconds 12 --fault offline
```

`--gst-audio-map 8` is specific to the unpositioned eight-channel default audio device on this host and our stereo fixture. It is **not** a general multichannel solution or something to enable on every Mac.

The native and GStreamer probes compile with optimization. Full Buffer is currently Debug. **Do not compare their CPU/RSS as if they were equivalent full apps or equivalent compiler configurations.** System decoder work may also occur outside the measured process.

### 4.4 Normal-session diagnostics

Existing/new scripts:

- `scripts/profile.sh --observe 30`: collects unified logs and prints selected playback/UI/sync signals.
- `scripts/stream-telemetry.sh`
- `scripts/dump-telemetry.sh`

`profile.sh` is a diagnostic collector, **not a health gate**. Its launch/validation path is older than `playback.py`; prefer the latter for controlled fixtures. Normal-source diagnostics should scope to the current PID to avoid mixing recent synthetic and real sessions.

Existing useful instrumentation:

- `PerformanceMonitor`: Debug-only off-main heartbeat measuring main-queue delay.
- `AppLog`: OSLog categories and signposts for app/sync/sports.
- MPV state snapshots, buffering begin/end, cache-floor pause/resume, first-frame/file-loaded events, stream health/recovery counters.
- Guide preparation/publication/search index stage timings.
- Sports fixture fetch and sports-index build timing.
- New playlist-catalog join and catch-up HTTP timing.

## 5. Production changes and evidence

### Shared-guide sports indexing

`Buffer/Services/StreamMatcher.swift` now normalizes schedule data once for channel variants sharing an XMLTV ID. Channel-specific name tokens remain separate. It caches only shared guide IDs, not every unique schedule.

Measured Debug medians on the same fixture:

```text
96,000 titles across shared-guide channel variants:
before 213.794ms
initial after 119.947ms (43.9% lower)
later runs ~123–124ms (about 42% lower)

48,000 titles across unique guide IDs:
before 107.568ms
later ~109–113ms (small overhead/variation; within current gate)
```

Evidence:

- `benchmarks/results/shared-guide-before.json`
- `benchmarks/results/shared-guide-after.json`
- `.logs/bench-before-shared-guide.json`
- Later `.logs/bench-*.json`

Differential tests verify contents, token isolation and IDF weights, not just counts.

### Sports rebuild coalescing/cancellation

`SportsViewModel.swift`:

- Uses an input token from full catalog version, guide version, hidden groups.
- Skips redundant rebuild requests for unchanged inputs.
- Builds at utility priority, or background priority while a player session is active.
- Stores/cancels the actual detached worker, not just the debounce task.
- StreamMatcher has cancellation checkpoints and returns an empty result on cancellation; cancelled worker results are not published.

`ContentView.swift` observes catalog/guide **versions**, replacing count-only observations that miss same-count content changes. Sports gets full `channelCatalogVersion`, not the currently filtered sidebar version.

Needs further end-to-end testing: repeated refresh, account switching, large real guides during video, worker lifecycle/deinit, and priority impact on responsiveness.

### Catch-up HTTP fetch concurrency

`XtreamClient.fetchCatchupEPG`:

- Bounded task group, default maximum eight requests (clamped 1..8).
- Optional `maxConcurrentRequests` supports controlled serial/concurrent comparison.
- Uses local response decoding per request.
- Returns successful partial results when some channels fail; throws if all fail.
- Preserves underlying errors rather than converting everything into a generic error string.
- Checks task cancellation before work and after collection; cancels the group and stops enqueuing on cancellation.

An integration test found a real cancellation error regression and now passes after the fix.

Actual production Swift client against a local 24-channel HTTP API with 40–70ms response latency:

```text
Serial:   1477, 1440, 1452ms
Parallel:  281,  272,  268ms
~81% median reduction on this fixture
Peak concurrent HTTP requests observed: 6 (URLSession's effective per-host behavior)
Decoded content equivalent after canonical ordering
Cancellation: only 6 requests started, no post-cancel expansion to 24
```

Evidence: `benchmarks/results/catchup-http.json`, `.logs/catchup-bench.json`, `scripts/test_catchup.py`.

**Limitations:** real providers may rate-limit API calls; this is not a live-provider speed claim. Completion order differs from serial order; tests canonicalize results. Audit any consumer relying on stable ordering or duplicate-ID precedence. Batch preparation builds all job URLs before network dispatch.

### Playlist catalog / guide overlap

`EPGViewModel.performSync` now starts movie/series catalog work before guide processing and joins it after the guide, instead of blocking guide loading on the entire catalog.

- Catalog task is cancelled with a defer.
- Disabled-VOD path explicitly clears old items/details.
- Catalog join timing is logged.

**Not yet fully integration-tested.** This is a high-priority audit item: cancellation/account changes must not publish stale catalog or guide state. Some helpers swallow network errors into empty arrays. Ensure cancellation and playlist identity guards are sufficient before keeping this change in production.

### EPG display/version work

Files: `EPGViewModel.swift`, `EPGGridView.swift`, `EPGScrollGrid.swift`.

- Replaced full channel-ID concatenation on every grid body evaluation with a source-driven version token.
- Added `filteredChannelSetVersion`, incremented on filtered-cache rebuilds, including metadata changes (Channel equality is ID-only).
- Added full `channelCatalogVersion`.
- Cached archive bounds by channel-set version, lookback and exact timeline anchor using a reference cache, avoiding mutation of observable state during body evaluation.
- Scroll grid skips repeated ID/name mapping when its item-set version is unchanged.
- Coordinator's initial version is nil so first update still populates names.

**Not yet verified with automated scrolling/same-ID metadata/UI tests.** Check visible row refresh ordering, item updates, initial names, favorites/group changes, same-count channel renames, lookback resets and reveal scrolling. The current update path still contains an awkward `Optional(items.map(...))` conditional worth simplifying after tests exist.

### Guide lookup correctness

`GuideLookup.swift` is used by `currentProgram` and date lookup.

An initial binary-search implementation was **wrong for overlapping EPG entries**, returning later overlapping items instead of the first existing match. A failing differential test caught it. Current implementation binary-searches the upper start-time bound then searches that prefix, preserving earliest-match semantics for overlapping/duplicate starts.

This is **not a proven O(log n) lookup optimization**; the prefix search remains linear. Do not claim a major speedup. Published lists must remain start-sorted. `GuideLookup` also retains some earlier fingerprint/join helpers that may be unused and should be reviewed for cleanup.

## 6. Playback experiments and failures

### MPV/CoreAudio crash: unresolved in production

Two actual crashes:

```text
~/Library/Logs/DiagnosticReports/Buffer-2026-10-04-193923.ips
~/Library/Logs/DiagnosticReports/Buffer-2026-10-04-194352.ips

mp_msg_va -> mp_msg -> hotplug_cb -> CoreAudio property notification
EXC_BAD_ACCESS / null pointer
```

Before the crashes, OSLog reported:

```text
unable to set the input channel layout on the audio unit (.../-50)
```

A forced CoreAudio run rendered video but reported no real audio output and no A/V synchronization samples; the strengthened gate correctly failed it.

Primary-source comparison: mpv 0.41's CoreAudio init path registers hotplug callbacks before potentially failing AudioUnit initialization and does not clean up on that failure path. Current upstream moves registration later and cleans failed initialization. This **supports**, but does not fully prove, the stale-callback hypothesis. No patched libmpv binary has been integrated.

### MPV AVFoundation audio experiment

The bundled libmpv contains `audio_out_avfoundation` (verified by symbols and runtime `current-ao`). Passing `--ao avfoundation` to the harness selects that audio backend in validation only.

**This is not AVPlayer.** Video remains on the existing libmpv renderer.

Clean runs have passed with zero sampled drops/stalls and millisecond-level A/V error. One run remained paused with no time progress from startup; preserve this as unresolved rather than dismissing it. Investigate actual pause property/owners and lifecycle/initial-state races.

### Cache-preserving bounded retry experiment

`--http-retry` adds validation-only FFmpeg options to HLS stream/demux input:

```text
reconnect_on_http_error=502
reconnect_on_network_error=1
reconnect_max_retries=3
reconnect_delay_max=2
reconnect_delay_total_max=5
```

Does not enable reconnect-at-EOF, blanket retry all 4xx/5xx, or retry provider 509 throttling. Existing timeout/HLS options remain.

Single-run comparison, rolling live, 45 seconds, four-second 502 burst starting at 12 seconds:

| MPV + AVFoundation audio | Sampled stalled time | Drops | Max sampled A/V error |
|---|---:|---:|---:|
| Original transport | 8.165s | 0 | ~14.9ms |
| Bounded retry experiment | 2.604s | 0 | ~7.9ms |

Artifacts:

```text
.logs/playback-20261004-195453/report.json
.logs/playback-20261004-195648/report.json
```

Need repeat trials, additional statuses/timeouts, and verification of which option path actually controls nested HLS fetching. Both stream and demux options were changed for the experiment. Neither retry selection nor alternate audio backend is enabled in ordinary playback.

### AVPlayer standalone experiment

`benchmarks/native_player.swift`: Cocoa window, AVPlayerLayer, AVPlayerItem, 5-second preferred forward buffer, normal system playback.

- Clean rolling HLS: ~501ms observed startup, zero reported dropped frames/stalls, ~6.52s median live offset via program-date-time/currentDate.
- Four-second 502 burst at 12s, 45s test: zero observed stalls/drops, ~6.51s live offset, two requests actually received the injected failure.
- Example probe CPU ~0.5–0.6%, RSS ~95MiB, **not comparable to full Debug Buffer**.
- Independent A/V-sync error/decoder drops unavailable in this probe; audio label identifies the engine, not physical audibility verification.
- Uses accessLog/errorLog APIs deprecated in macOS 27; async replacements remain to be adopted.

Artifacts:

```text
.logs/playback-20261004-200132/report.json
.logs/playback-20261004-200344/report.json
```

### GStreamer actual tests

`benchmarks/gstreamer_player.m` uses Objective-C/C and real GStreamer APIs:

- `playbin3` / `hlsdemux2`.
- Hardware-only `vtdec_hw` selected by feature rank; instantiated elements recorded and checked.
- `osxaudiosink`; actual audio buffers counted.
- Selectable Cocoa-hosted `glimagesink`, `osxvideosink`, `avsamplebufferlayersink`.
- Sink rendered/dropped stats, position, audio/video buffered levels, element list and errors sampled.
- Sink's last sample mapped through its GstSegment to stream-time; compared with known local playlist origin for fixture-specific live-delay estimate.
- Adaptive demux: 5s high/max watermark, 1.5s low watermark, 3 retries, backoff factor .25, max backoff 2s.

Findings:

1. Default audio negotiation failed: host's output advertises **8 unpositioned channels**. Explicit fixture-specific 8x2 matrix preserves stereo L/R and silences six remaining channels. It does not change the system default audio device.
2. `avsamplebufferlayersink` then crashed once in `_request_data` / `g_mutex_unlock` in `libgstapplemedia`. Do not call this sink stable on the macOS beta host.
3. `osxvideosink`, clean 720p30: zero stalls/drops, **~30% median process CPU**.
4. `glimagesink`, clean 720p30: zero stalls/drops, **~2.8% median process CPU**.
5. `glimagesink`, 720p30, four-second 502 burst: zero stalls/drops, **~3% CPU**.
6. `glimagesink`, **1080p60 at 8Mbit/s**, four-second 502 burst: zero stalls/drops, **~5.3% CPU**, **131.5MiB peak RSS**, **~6.68s fixture-estimated live delay**.

Representative artifacts:

```text
.logs/playback-20261004-201339/report.json  initial audio-negotiation failure
.logs/playback-20261004-201620/report.json  sample-buffer-sink crash
.logs/playback-20261004-201740/report.json  osxvideosink, high CPU
.logs/playback-20261004-201859/report.json  glimagesink clean
.logs/playback-20261004-201954/report.json  glimagesink 502 burst
.logs/playback-20261004-202239/report.json  live-delay sample observation
.logs/playback-20261004-202347/report.json  1080p60 502 burst
benchmarks/results/gstreamer-initial.json  summarized successes AND failures
```

This makes GStreamer a serious primary candidate, **not a production migration decision**. Test an appropriate Apple-native/Metal output path if possible, but do not replace a stable low-CPU path based on theoretical superiority alone.

### Harness limitations / audit items

- “Rendered” means the instrumented player/layer/sink reported video readiness/frames. The harness does not currently perceptually verify each on-screen frame or detect a frozen image while media time advances.
- MPV's first-frame generation tagging can be affected by render handoff/stale-frame timing; audit the actual loaded-generation relationship.
- MPV `firstFrameElapsedMs` and cache-floor counters were added to the player; pooled/reused-player reset semantics need review for ordinary sessions.
- Per-generation sampled maxima can miss a very short generation or reset between samples.
- Native/GStreamer independent A/V error and separate decoder drops are unmeasured, not zero.
- Audio fixtures are silent. Physical channel routing and audible output still require a suitable test.
- Native/GStreamer standalone optimized probes vs full Debug Buffer is not a fair full-app resource comparison.
- CPU is sampled process CPU, not whole-machine decoder/GPU/power cost. RSS is not physical footprint.
- HLS fixtures lack a codec/format/provider corpus, throttled throughput, truncation, malformed playlists, discontinuities, real auth redirects, long runs, multiview, HDR and interlaced sports.
- Early reports used finite VOD HLS; distinguish them from rolling-live reports. Schema was not fully versioned across all harness iterations; inspect scenario fields and code revision before comparing.
- Artifacts use second-resolution directory names; concurrent harness runs are not supported and can collide.
- Some unsupported engine-specific flag combinations still need validation.
- `--http-retry` is scoped by validation configuration but properties persist on a reused MPV handle; verify reset behavior before broadening it.
- The last MPV live-delay test was interrupted/killed before a report was written. No result exists to cite. The new `demuxer-start-time`/wall-time observations are present but their mapping to true source time is **unverified**.

## 7. Real-source observation at handoff

After the user confirmed credentials, we inspected only selected performance messages (not source config/URLs) and sampled the normal process.

Observed normal library workload:

```text
channels: 28,064
groups: 249
EPG program keys: 8,451 -> 8,452
sports index titles: 482,224 -> 503,075
sports index builds: 3,102ms and 3,335ms
second index publication main-queue wait: 50ms
EPG-only sync: 26 seconds, guide reachable
guide merge: ~203ms
hour-bucket preparation: ~211–212ms
```

Main-queue heartbeat during idle was generally p95/max 0ms, with one 6ms max sample. A single `ps` snapshot showed ~10.8% CPU and ~1.8GiB RSS; this is not a sustained resource profile. `sample` reported **816.2MiB physical footprint**, **1.5GiB peak footprint**. Do not confuse these memory metrics or call it a memory leak without repeated measurements.

Short idle call-stack sample:

```text
.logs/real-source-idle.sample.txt
```

Accessibility was available. Inspected hierarchy:

```text
Buffer main window
  group 1
    split group
```

No playback was started through that UI during this final phase. Next agent can continue through System Events, or implement a narrowly scoped in-app debug command to select a saved channel without exporting its credential-bearing URL to shell arguments/logs.

## 8. Alternative-engine research

Full sourced notes:

```text
benchmarks/PLAYBACK-FOUNDATIONS.md
```

Primary shortlist:

- **GStreamer**: explicitly requested, now tested; useful reserve/bandwidth/retry control and hardware VideoToolbox decode.
- **Native AVPlayer**: now tested; native live-offset controls, promising simple HLS behavior.
- **libmpv + targeted transport/audio fixes**: current compatibility baseline; still unresolved production crash path.
- **KSPlayer**: Apple-focused AVPlayer/FFmpeg framework; **public GPL**, paid LGPL edition with important edition-specific caching/rewind/switching functionality. No package integrated or runtime benchmark yet.
- **VLCKit/libVLC**: official macOS wrapper, broader compatibility; no runtime benchmark yet. Upstream GitHub mirror was used because GitLab blocked direct fetching.
- **Custom FFmpeg demux + VideoToolbox + Apple sample-buffer synchronization/rendering**: architectural option, not implemented. Consider AVSampleBufferRenderSynchronizer before inventing a complete clock/scheduler.

A further option: current upstream FFmpeg docs describe an optional **libcurl transport backend** with shared connection cache and HTTP/2/HTTP/3 multiplexing. **Not verified in our bundled MPVKit FFmpeg.** CLI FFmpeg installed for fixtures is a different build. Do not assume support from documentation alone.

Licenses vary by build/edition. FFmpeg can be LGPL or GPL depending on enabled components. Do not make distribution/licensing claims without inspecting the exact artifacts.

## 9. Outstanding work / recommended next sequence

### A. Resume safely with the user's real source

1. Check whether Buffer is running; last handoff check found none.
2. Launch normally without synthetic validation flags if needed.
3. Inspect UI/source availability without printing credentials.
4. Select one representative sports stream; do not create duplicate provider sessions.
5. Observe baseline startup, codec/resolution/frame rate, actual audio backend, A/V sync, reserve, frame-drop deltas, network warnings, buffer/reload events, UI lag, CPU and footprint.
6. Preserve filtered artifacts and reproducible channel identifiers without authenticated URLs.

### B. Make comparisons fair

- Release/instrumented Release builds and comparable app hosts.
- Match target live latency and reserve, presentation size, codec/FPS/bitrate.
- Repeat trials and record variance, not only successful single runs.
- Include true/estimated live-delay budget in pass/fail criteria.
- Measure system CPU/GPU/energy, not only process RSS/CPU.
- Add long-running and source-switch tests; distinguish provider outage from decoder/render/UI contention.

### C. Fix correctness before increasing aggressiveness

- Resolve or avoid the production CoreAudio failed-init/stale-callback crash with verified lifecycle fixes or a qualified alternate backend.
- Investigate startup-paused MPV run; do not auto-unpause indiscriminately, as that could fight user intent.
- Audit playlist-switch cancellation/stale publication, VOD overlap, initial UI row population and metadata invalidation.
- Reset new MPV telemetry appropriately for pool reuse and channel changes.
- Complete caught-up source-generation tracking before relying on first-frame attribution.

### D. Intelligent provider recovery

User's intended direction:

- Separate transport-resilience policy from decoder/rendering choice.
- Classify transient 5xx/network errors vs expired credentials, provider throttling and terminal content errors.
- Preserve usable cached media during recovery; avoid immediate whole-stream reloads.
- Adapt reserve from observed segment-delay/outage distributions. Increase quickly after trouble; decrease conservatively after healthy delivery.
- State explicit low-delay/balanced/resilient budgets. A longer reserve means more delay; do not hide that trade-off.
- Catch up gradually when viable rather than jumping continuously; retain explicit Go Live.
- Consider a shared bounded segment-fetch/cache broker for playback/recording and conditional rendition/provider failover where equivalent authorized sources exist.
- A custom cache/normalizer can address broken providers without committing to a particular renderer, but needs cancellation, byte/time bounds, auth/key isolation and provider connection-limit compliance.

None of the adaptive-reserve controller, shared fetch broker, transparent provider failover, or new production engine has been implemented yet.

### E. Finish whole-app coverage

- EPG scrolling/search/current-program/lookback rendering, particularly with the real 28k-channel/500k-title index.
- Cold/warm hydrate and memory lifetime during successive guide/index refreshes.
- Playlist and VOD concurrent refresh correctness and cancellation.
- Catch-up seek/load and long history behavior with actual providers.
- Sports fixture polling, cancellation, redundant refreshes, match latency.
- Multiview focus/background correctness and performance.
- Recording coexistence, wake/sleep and audio-device changes.
- Stable UI automation or in-app deterministic scenario driver; currently only initial accessibility inspection exists.

## 10. Source-file map

Modified tracked files:

```text
.gitignore                              ignore Python __pycache__
README.md                               build/benchmark/playback usage + caveats
Buffer/BufferApp.swift                  benchmark entry, validation isolation
Buffer/ContentView.swift                version observation, internal validation launch
Buffer/Services/MPVPlayer.swift         C-property telemetry + validation-only transport/audio experiments
Buffer/Services/StreamMatcher.swift     shared-guide cache + cancellation checks
Buffer/Services/XtreamClient.swift      bounded catch-up concurrency/error/cancellation
Buffer/ViewModels/EPGViewModel.swift    versions, guide lookup, VOD/EPG overlap, validation isolation
Buffer/ViewModels/SportsViewModel.swift token coalescing, worker cancellation/QoS, fetch timing
Buffer/Views/EPGGridView.swift          channel token and archive-bound cache
Buffer/Views/EPGScrollGrid.swift        token-driven item/name mapping
```

New files are listed in `git status`; notable groups:

```text
Buffer/Support/{GuideLookup,PerformanceBenchmark,PlaybackValidation}.swift
benchmarks/{guide_lookup_tests,stream_index_tests,catchup_integration,native_player}.swift
benchmarks/gstreamer_player.m
benchmarks/PLAYBACK-FOUNDATIONS.md
benchmarks/results/*.json
scripts/{bench.py,bench.sh,playback.py,profile.sh,test-performance.sh}
scripts/test_{bench,playback,catchup}.py
handoff.md
```

## 11. Verification status at handoff

Most recent full verification before real-source inspection:

- `scripts/test-performance.sh`: passed Swift checks and all **17** Python tests.
- `scripts/bench.sh --compare .logs/bench-before-shared-guide.json`: built successfully and passed the 15% regression gate; shared-guide case remained ~42% lower than original baseline.
- `git diff --check`: passed on the preceding complete check; re-run after any further edits.
- GStreamer 1080p60 injected-502 run passed the current probe gate.
- Native AVPlayer rolling-HLS injected-502 run passed its current probe gate.
- Offline playback negative control failed as required.
- CoreAudio-only test, sample-buffer sink test, and earlier MPV crash runs failed and are retained as unresolved evidence.

Do not use an old report or prior conversational claim as proof for a newly changed binary. Preserve the distinction between **verified measurements**, **promising experiments**, **unverified production changes**, and **proposed architecture**.
