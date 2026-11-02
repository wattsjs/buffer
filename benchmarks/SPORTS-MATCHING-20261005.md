# NFL channel matching and quality ordering

The Detroit Lions / Carolina Panthers fixture was present in both saved source guides on Sky Sports Main Event UHD. The match airs at 10:10–13:45 Brisbane on 5 October 2026; the NBC WSFA listing is 10:15–13:30 and ESPN kickoff is 10:20. The guides were read offline; no provider requests or player connections were opened for this investigation.

The inverted-index matcher previously ranked and capped candidates at 160 before checking their programme evidence. Hundreds of local NBC variants received the ESPN broadcaster token and crowded out Sky. It then capped the displayed results at 10 and let the broadcaster multiplier/preferences outrank channel quality. Smart mode additionally supplied only its 56 permanent logical feeds, hiding dedicated UHD physical alternatives held out of permanent merging.

The updated matcher retains every plausible inverted-index candidate, deduplicates query terms, reuses each source-scoped guide's programme score, and returns all alternatives. Exact event programme evidence precedes related listings and broadcaster-only guesses. Within each evidence tier, current endpoint-bound sustained reliability and measured stall burden precede performance measurements, sports motion, useful resolution, preferences, and matching score. Reliability/stall evidence must be explicitly tagged as ordinary live playback; archive, finite media, legacy untagged records and diagnostic/hold experiments do not qualify. Advertised UHD/HD labels are a preference when observed resolution is unavailable; badges continue to distinguish observation from uncertainty. A known failed UHD source is demoted, and an equally reliable 50 fps UHD source ranks above 720p regardless of a local-channel favorite. A 50 fps 720p source can beat 25 fps UHD for sports.

## Offline cache replay

The sanitized fixture keeps channel IDs/names/groups and programme text/times, replaces every stream URL with loopback, and removes descriptions containing URLs. It covers the day's relevant guide interval. Replays use the actual kickoff and deterministic `now = kickoff + 60 seconds`; timings are one standalone `swiftc -O` sample, not full-app UI or playback qualification.

| Source | Live channels | Indexed programme titles | Alternatives returned | Sky Main Event UHD variants | First result | Matching time |
|---|---:|---:|---:|---:|---|---:|
| Infinity | 28,031 | 91,295 | 392 | 5 | Sky Sports Main Event UHD | 183 ms |
| Odyssey | 16,009 | 83,675 | 327 | 5 | Sky Sports Main Event UHD | 487 ms |

`.logs/sports-matching-actual-20261005.log` contains the ranked, sanitized output. `.logs/sports-matching-capped-comparison-20261005.log` reconstructs the prior candidate-cap/query-order/result-cap behavior against the same fixture: both sources returned 10 local NBC matches and zero Sky UHD matches. This comparison isolates the prior logic; it is not a pristine historical application binary. Matching remains detached and results are cached; the broader scan's additional CPU cost is explicit and should be checked alongside playback in the app.

## Smart context and actions

`SmartSportsCoordinator.sportsMatchingSnapshot(...)` returns current retained physical alternatives across saved sources, supplemented by the active source's complete live catalog. Dedicated UHD/held-for-merge endpoints are eligible event alternatives; user-rejected, changed-identity, and duplicate-native rows are excluded. Other sources remain limited to the current curated/held cache subset, avoiding another broad cache read. It does not merge rotating feeds or assume identical guide IDs establish equivalent video.

Matching-only programme dictionary keys include source UUID. Channel native ID, raw guide ID, ownership, account key, and programme timestamps stay unchanged. Physical catalog changes invalidate old actions; guide-only enrichment retains warm results. Quality changes rematch open popovers without rebuilding the guide index. The quality snapshot is cached by physical catalog/probe revision to avoid hashing thousands of endpoints on every guide publication. Preference transformations are similarly cached by catalog, preference and logical-binding revisions.

The initial physical-snapshot implementation restamped 16k–28k active channels on each Smart guide publication, recalculating the same Xtream account digest per row. It now calculates one account/revision digest, reuses already-correct physical ownership, and caches channel rows plus source-scoped guide-key mappings by physical catalog revision. Guide-only updates replace shared programme-array references. An optimized offline fixture with 28,031 channels and 8,224 guide buckets measured about 20 ms cold and 0.69–0.76 ms for five warm snapshots, with exactly one catalog construction. Evidence: `.logs/sports-matching-snapshot-perf-20261005.log`.

Actual moving-startup and absolute broadcast-delay measurements are not yet populated in the production quality mapper. First-picture elapsed time can include a held picture; probe duration, cache length and replay-window offset cannot establish these metrics. They remain nil/unknown. The optional exact-measurement contract has fixture-only known values proving that a healthy low-delay HD source can beat slower UHD and that measured stall burden takes priority. No channel brand is hardcoded and no hypothetical fixture values enter real observations.

Reminder/record actions bind to the exact matched raw title/start/end in the current physical source. A native programme beginning after ESPN kickoff must not become the pregame show containing kickoff. Missing/stale exact programme evidence fails closed; a broadcaster-only result retains the existing explicit ESPN three-hour estimate.

The popover uses lazy rows, an explicit result count, and a 420-point scroll area for at least three normal-sized alternatives. Evidence dots describe programme relevance rather than treating a broadcaster multiplier as a confirmed match.

## Verification

- `scripts/test-sport-cards.sh`: cancellation/source reset, 240-NBC crowding fixture, all alternatives, exact UHD ordering, failures/motion/favorites, colliding physical IDs/XMLTV keys, later-start programme action binding, and genuine-known performance/motion/stall ordering fixtures pass.
- `scripts/test-sports.sh`: ESPN transport/cache/lifecycle and deferred warm-match regressions pass; `.logs/sports-matching-regressions-20261005.log`.
- `scripts/test-smart-sports-coordinator.sh`: 71 coordinator checks pass, including both physical sources, raw action identity, separate guide buckets, active-catalog supplementation, rejected/changed exclusions, guide-only cache reuse, updated guide delivery, endpoint/source-revision invalidation and precomputed account ownership.
- Swift source parse and `git diff --check` pass.

Signed full-app build and visible playback/popover validation belong to the root validation loop and remain pending at this checkpoint. No claim is made that every listed alternative is healthy, equivalent, or sustained-playback qualified.

## Finished-event action correction

Root's updated-app validation displayed 327 matching alternatives with Sky Main Event UHD first and three readable lazy rows. That exposed a separate old action-policy bug: `kickoff.timeIntervalSinceNow <= 15 minutes` accepted every past or final event, and “Play now” opened the channel's current tennis broadcast after the NFL game ended.

The corrected policy allows live/halftime live playback and scheduled prestart playback only when kickoff is 0–15 minutes ahead. Later scheduled events allow reminders/scheduled recordings. Final events expose an explicit **Replay** only when the current physical source still has the exact matched programme title/start/end and its archive window supports replay; otherwise the row says **Replay unavailable**. Past scheduled, delayed, postponed and canceled events cannot open current live content. Final rows have no record-now/reminder/live fallback.

The replay callback revalidates the match context and current native programme before using ContentView's existing source-pinned catchup request. Match-context identity now distinguishes actionable scheduled status from postponed/canceled status while preserving cosmetic live-detail caching. Fixtures cover final/past/unknown/future edges, a later native NFL programme alongside current unrelated tennis, missing/expired/unsupported archives and weak broadcaster-only evidence. `scripts/test-sport-cards.sh`, source parse and diff checks pass; this narrow action patch still requires root's incremental app build/visible validation.
