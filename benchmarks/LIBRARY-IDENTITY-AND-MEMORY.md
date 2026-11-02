# Library identity and retained search storage

These checks use production parsers and the production `EPGViewModel` with
isolated cache/Keychain/platform test dependencies. They do not read saved
sources, contact providers, open player sessions, or write the app's cache.

## Correctness and rollout

VOD-disabled hydration checks the preference before decoding either catalog
cache. It rechecks the source and catalog revision after each await, so a
disable/re-enable cycle cannot publish an earlier in-flight snapshot. Tests
count cache calls: initially disabled makes zero movie/series reads; disabling
while the movie read is in flight makes one movie read and zero series reads.
The guide still hydrates, and enabling subsequently fetches a current catalog.

M3U channels without a nonempty `tvg-id` now use an opaque SHA-256 hash of their
full stream URL, encoded as unpadded URL-safe Base64. Mutable names, groups and
logos are excluded. Distinct URL
variants remain distinct. Identical URLs get an occurrence suffix, preserving
unique SwiftUI row IDs. Without a provider ID, indistinguishable duplicate rows
that reorder or disappear cannot preserve an individual row's identity.
Unknown token/query changes deliberately change fallback identity; stripping
them could merge different streams. Nonempty supplied IDs remain unchanged.

Cached UUID-based favorites, recent ordering and channel usage migrate by URL
when fresh anonymous rows replace old anonymous rows; usage combines existing
counts, and updates persist. Supplied-ID rows sharing a URL are excluded from
that mapping. Preferences for absent streams remain intact. New v8 content
identities include credentials and guide inputs, while preference identities
stay stable. Old M3U channel caches can supply a UUID-to-URL map only after a
fresh catalog has been parsed and validated for the current source; those old
URLs are never published as playable content. Legacy guides and VOD are never
hydrated. Sources whose automatic refresh is set to Never require a manual
fresh refresh after this cache-schema rollout before old UUID preferences can
resolve/migrate.

The production integration suite covers initially disabled VOD, disabled and
re-enabled in-flight hydration, unmatched/empty program search, persistent
UUID migration, mixed supplied/anonymous same-URL rows, old-cache schema
migration, inactive credential/guide edits, and failed credential refresh
followed by relaunch. The latter cases retain the old cache in the test store
to prove the new source does not restore its obsolete content.

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.test_sync
scripts/test-parser-memory.sh
```

## Measured allocation and identity cost

The search-index builder previously reserved storage for every XMLTV program,
even when the playlist had no channel for that guide ID. It now reserves only
programs reachable through the current channel mapping. The existing output
loop and first-channel-per-guide semantics remain unchanged.

On the controlled 100,003-guide-program fixture with only three searchable
programs, reserved search-entry storage fell from **8,814,520 bytes to 264
bytes**. `ProgramSearchEntry` has an 88-byte stride on this arm64 host. This
removes approximately 8.4 MiB of unused element reservation. It is not a claim
that process resident memory fell by that amount; initial repeated trials
showed the same 38.5 MiB process peak RSS and 11 ms whole-hydration median.
The report retains all raw trials because timing includes guide preparation
and publication rather than measuring search construction in isolation.

Stable identity has a measured parse cost. Optimized standalone parsing of
50,000 supplied-ID entries changed from 187.5 to 188.4 ms (+0.5%, normal
variation). The otherwise identical ID-less case changed from 185.8 to 201.0
ms (+8.2%). Debug `-Onone` supplied-ID parsing changed from 500.1 to 495.3 ms
(-0.9%); ID-less parsing changed from 460.4 to 488.5 ms (+6.1%). Both pass the
15% parser gate. Process peak RSS for the ID-less fixture increased by about
0.4 MiB in both configurations (optimized: 60.9 to 61.3 MiB; Debug: 61.3 to
61.7 MiB). The correctness improvement is retained; no ID-less parse speedup
is claimed.

The first implementation cost +18% in optimized builds. Per-byte Swift hex
formatting and Foundation Base64 string replacements each caused 22–23%
Debug regressions. The retained implementation hashes the existing UTF-8
buffer, uses one dictionary occurrence lookup, and encodes the full digest
directly into 47 ASCII bytes with a small C helper. The app's existing
bridging header and each standalone compiler harness import that same helper.
256 independent Foundation differential vectors, full 256-bit roundtrips and
surrounding guard bytes verify its bit preservation and exact output bounds;
the helper writes no NUL terminator. No cryptographic bits were discarded to
reduce the identity's size.

Evidence:

- `benchmarks/results/library-search-memory.json`
- `benchmarks/results/m3u-fallback-identity.json`
- `benchmarks/results/m3u-fallback-identity-debug.json`

Both reports record source/executable hashes and repeated before/after trials.
The before source snapshots retain all prior parser/lifecycle improvements;
they are the files immediately preceding this targeted work, not original
HEAD source with unrelated regressions restored.

```bash
PYTHONDONTWRITEBYTECODE=1 python3 scripts/bench-library-memory.py \
  --before-view-model .local/bench/EPGViewModel-library-before.swift \
  --output benchmarks/results/library-search-memory.json

PYTHONDONTWRITEBYTECODE=1 python3 scripts/bench-parser-memory.py \
  --configuration optimized --identity-cases \
  --before-m3u .local/bench/M3UParser-identity-before.swift \
  --output benchmarks/results/m3u-fallback-identity.json

# Repeat with --configuration debug for the instrumented Debug app's code mode.
```

The source snapshots are local validation artifacts under `.local/bench`.
For subsequent changes, `--compare` accepts the stored report without needing
those snapshots. Each script reads its baseline before replacing its output
path. `--identity-cases` selects a separate fixture schema; the established
parser-memory fixture and regression comparison remain unchanged.
