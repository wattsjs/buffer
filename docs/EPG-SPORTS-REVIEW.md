# EPG and Sports continuation review — 2026-10-05

This review used current production source and retained validation evidence. It made no provider requests, app builds or computer-use actions. Root retains ownership of the user's UHD playback/startup comparison.

## Fixed: guide publications were clearing the warm Smart Sports index

`EPGViewModel.smartSportsDidChange` previously advanced `channelCatalogVersion` for every coordinator callback. Programme-only and progressive history callbacks therefore looked like source/catalog replacement to `SportsViewModel`. Its catalog-change branch cleared the usable warm index before the history-defer branch could preserve it.

The model now compares the displayed channel snapshot's actual metadata and ownership rather than `Channel.==`, which intentionally compares only preference identity. Stable programme-only callbacks advance `guideVersion` without advancing the catalog version or rebuilding channel-derived caches. Physical source, endpoint URL, raw guide binding, name/logo/group, archive and content-type changes still invalidate the catalog. Entering Smart mode resets the snapshot; returning to the same original source explicitly advances catalog/guide versions so logical matches cannot survive that mode switch.

The actual production model/coordinator regression passes 10 checks in `.logs/smart-catalog-versions-tests.log`, through `bash scripts/test-smart-catalog-versions.sh`. It verifies four programme-only refreshes, current programme publication, manual source and guide ownership changes, original-source return and Smart reentry. Production source is frozen for root's combined build.

## Existing protections confirmed in source

- Ordinary hydration and sync use source generations plus full source-input equality. Checks run after background decode/merge awaits, rejecting stale A→B→A work and credential/guide edits.
- Progressive guide publication serializes commits, checks the sync/source identity before and after preparation, and updates touched guide buckets/lookups. Successful current/history rows are published before the full enrichment tail.
- `GuideHistory` retains valid source-provided rows through sparse incoming responses, replaces matching IDs/starts, bounds history/future retention and caps dense channels near the present programme. It does not invent listings for missing provider coverage.
- Cold Sports matching builds the first useful current-guide snapshot. Warm matching can retain a valid index while history enrichment completes. The catalog-version fix above prevents Smart programme-only callbacks from defeating that behavior.
- Sports scoreboard failures remain distinguishable from successful empty responses. Rejected large date ranges use bounded fallback; partial/failed leagues retain bounded last-good fixtures and surface a warning. Actual earlier UI inspection showed NFL fixtures and scores; it did not establish that every league supplies a complete seven-day horizon.
- Smart displayed guides remain independently chosen, namespaced and tied to a source/native endpoint. Physical playback/actions retain raw guide times and source ownership. Unqualified Smart catchup is refused explicitly, with access to the original source guide; it cannot become live playback.

## Follow-up fixes — source frozen for the next build

1. **Warm Smart cache was lost on local read failure.** The loader now reports successfully resolved source inputs even when the content read fails, and distinguishes a failed guide read from a successful empty result. The coordinator retains warm data only when the exact content revision still matches. Guide fallback retains only compatible source/native metadata and endpoint bindings, filters wrong guide buckets and applies ordinary history/future bounds on a utility worker. Removed, password/guide-changed, unresolved and recycled native identities cannot borrow or resurrect old content. Source issues and refresh warnings remain explicit; fallback never claims a successful refresh. The strict coordinator/loader fixture suite now passes41 checks in `.logs/smart-warm-guide-tests.log`. No failure was injected against the user's cache.

2. **Deferred warm guide updates invalidated in-flight matches without publishing a new index.** The defer branch now changes the generation only for a catalog change or actual cancellation of pending index work. A deterministic fixture holds the actual match worker, publishes four same-source history updates and confirms that the warm match completes successfully with no new index publication. This test-only barrier is excluded from ordinary app compilation. Existing cold/warm, source-switch, transport cancellation, fixture outage/partial retention and fixture-cache suites pass in `.logs/sports-warm-match-tests.log`.

These narrow fixes introduce no fabricated listings, copied schedules, global time offsets, broad refreshes or rewrite. Production source is frozen; the combined app build and runtime qualification remain with root. They do not qualify playback performance, provider equivalence or sustained reliability.
