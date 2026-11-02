# Parser memory and artwork decode measurements

The source comparisons use isolated standalone Swift drivers and controlled
fixtures. They never load saved sources, app preferences, keychain credentials,
or the normal app cache. Measurements do not establish full-app memory or
provider throughput.

## Repeat the checks

```bash
scripts/test-parser-memory.sh
python3 scripts/bench-parser-memory.py --configuration debug --quick
python3 scripts/bench-parser-memory.py --configuration optimized
python3 scripts/bench-artwork.py
```

The artwork driver links the existing Nuke object under
`DerivedData/Build/Products/Debug`; it does not build the app. Use
`--products-dir` to select another already-built product directory. It runs
normal JPEG, rotated JPEG, and PDF fallback correctness checks before timing.

Both drivers record source/executable hashes and structured numeric evidence.
They load a comparison report before replacing their output path:

```bash
python3 scripts/bench-parser-memory.py --configuration optimized \
  --compare benchmarks/results/parser-memory-optimized.json
python3 scripts/bench-artwork.py \
  --compare benchmarks/results/artwork-memory.json
```

Parser source controls used for the initial before/after report remain under
`.local/bench/{XMLTVParser,M3UParser}-memory-before.swift`. To repeat that source
comparison in this checkout:

```bash
python3 scripts/bench-parser-memory.py --configuration optimized \
  --before-xml .local/bench/XMLTVParser-memory-before.swift \
  --before-m3u .local/bench/M3UParser-memory-before.swift
```

The baseline XML already contains the attribute-order correctness and
cancellation fixes. Unsafe positional attribute assumptions were not restored.
The frozen M3U reference checked into `benchmarks/m3u_reference.swift` supplies
content equivalence tests independently from the optimized implementation.

## Measured production changes

| Controlled scenario | Before | After | Scope |
| --- | ---: | ---: | --- |
| 50,000 ASCII M3U entries, Swift `-O` median | 352.1 ms | 187.7 ms | 46.7% lower parse time |
| Same fixture, isolated process peak RSS | 83.8 MiB | 59.3 MiB | Includes fixture construction and allocator reuse |
| 50,000 ASCII M3U entries, Swift `-Onone` median | 589.1 ms | 505.0 ms | 14.3% lower parse time |
| Same Debug fixture, isolated process peak RSS | 84.2 MiB | 60.4 MiB | Includes fixture construction and allocator reuse |
| 1,000 XML programs, Swift `-Onone` median | 4.13 ms | 3.88 ms | Verified common attribute order |
| 4K JPEG → 256×384 fit/fill target, decode/resize surface | 8.52 ms | 2.72 ms | About 68% lower decode time; same Nuke object |
| Same JPEG isolated process peak RSS | 25.4 MiB | 30.4 MiB | Increased framework working set; no memory reduction claim |

The M3U parser consumes one UTF-8 line at a time for large lists. Small inputs
retain the Foundation line split. ASCII attributes use a byte scanner with the
same key/quoted-value grammar; Unicode lines retain the precompiled regular
expression. Async imports forward cancellation to their actual detached worker.

The XML parser sizes its initial output reservation from input bytes. A one-item
guide previously reserved capacity for 524,492 entries; it now reserves one.
`EPGProgram` has an 80-byte stride on this arm64 host, so the old capacity
represented about 40 MiB of unused element storage, excluding String payloads.
Unused reserved storage is not equivalent to resident memory. The larger guide
fixtures show little RSS change; no major XML speedup is claimed.

The artwork request uses the view's display scale, preserving cache separation
between scales, fit/fill modes, and full-resolution requests. An orientation-aware
decoder corrects Nuke's macOS flexible thumbnail sizing for EXIF-rotated images.
Formats not handled by bitmap thumbnails use the prior NSImage/resize path.
Channel logos still use their original full-resolution requests. The HTTP loader
also keeps URLCache disabled because Nuke's DataCache already owns encoded data.

The failed-image memo is bounded to 4,096 URLs, uses monotonic expiration, sweeps
expired entries during access to unrelated URLs, and batches oldest-entry
eviction. Cancellation does not mark an image as failed.

## Correctness and gate boundaries

The parser suite covers 1,224 frozen-reference M3U content comparisons, including
all supported Unicode newline sequences, empty/comment lines, EOF without a
newline, VOD metadata, and deterministic malformed/duplicate/Unicode attributes.
It also checks 22 XML order/namespace/empty cases, local imports, and cancellation.
The failure memo checks 50,000 distinct URLs and concurrent access.

Artwork checks compare final dimensions and sampled colors at 1x, 2x, and 3x
for normal/rotated JPEG and PDF. They verify same-scale cache hits, separation
from alternate scales/modes/full-resolution requests, and cancellation handling.

Parser timing gates require a regression to exceed both the relative tolerance
(15% by default) and a 0.05 ms absolute floor. A three-microsecond one-item parse
is an allocation fixture; relative-only gating is dominated by timer noise.
The reports retain raw samples, capacities, and process RSS rather than deriving
an unsupported app-memory saving from unused array capacity.

The ASCII fixture establishes that fast path's benefit. Unicode-heavy playlist
timing, repeated real guide refresh lifetime, cold/warm JSON hydration, and
retained sports/search index memory still need full-app measurements. Pixel
equivalence is sampled rather than a bitwise requirement because thumbnail and
resize kernels use different interpolation.

## Rejected experiments

Counting every XML program before parsing reduced allocation capacity but added
24–70% parse time on the initial fixtures. Foundation `enumerateLines` reduced
M3U memory but added about 24% parse time. Neither implementation was retained.
The decoded Nuke cache was not capped without a measured app working set.

Initial concurrent Debug/optimized parser scripts reused an executable path;
the mismatched reports were discarded and regenerated. The driver now uses
configuration-specific, unique executable paths to prevent that collision.
