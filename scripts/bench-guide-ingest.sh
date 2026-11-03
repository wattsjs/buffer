#!/usr/bin/env bash
# XMLTV / M3U ingest benchmark: the parsers at BASE_REF (default
# dod-integration) against the working tree, on synthetic fixtures sized like
# a large library (2M programmes / ~886 MB XMLTV, 60k-entry M3U).
# Each figure is the median of RUNS separate processes.
set -euo pipefail
cd "$(dirname "$0")/.."
BASE_REF="${BASE_REF:-dod-integration}"
RUNS="${RUNS:-5}"
OUT=.local/bench/ingest
mkdir -p "$OUT/before" "$OUT/fx"
CACHE="${TMPDIR:-/tmp}/ingest-module-cache"
git show "$BASE_REF:Shared/Services/XMLTVParser.swift" > "$OUT/before/XMLTVParser.swift"
git show "$BASE_REF:Shared/Services/M3UParser.swift" > "$OUT/before/M3UParser.swift"
COMMON=(Shared/Models/EPGProgram.swift Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift
        Shared/Models/VODItem.swift Shared/Support/AppLog.swift Shared/Support/PerfMetrics.swift)
FLAGS=(-O -module-cache-path "$CACHE" -I Shared/SwiftLibxml2 -import-objc-header Shared/Support/ChannelIdentityEncoding.h)
swiftc "${FLAGS[@]}" -D LEGACY_INGEST "${COMMON[@]}" "$OUT/before/XMLTVParser.swift" "$OUT/before/M3UParser.swift" \
  benchmarks/guide_ingest_benchmark.swift -o "$OUT/before/bench"
swiftc "${FLAGS[@]}" "${COMMON[@]}" Shared/Services/XMLTVParser.swift Shared/Services/M3UParser.swift \
  benchmarks/guide_ingest_benchmark.swift -o "$OUT/after-bench"
[ -f "$OUT/fx/guide.xml" ] || "$OUT/after-bench" gen-xml "$OUT/fx/guide.xml" 4000 500 0
[ -f "$OUT/fx/guide-interleaved.xml" ] || "$OUT/after-bench" gen-xml "$OUT/fx/guide-interleaved.xml" 2000 200 1
[ -f "$OUT/fx/list.m3u" ] || "$OUT/after-bench" gen-m3u "$OUT/fx/list.m3u" 60000

for fixture in guide guide-interleaved; do
  [ "$("$OUT/before/bench" xml-digest "$OUT/fx/$fixture.xml")" = "$("$OUT/after-bench" xml-digest "$OUT/fx/$fixture.xml")" ] \
    || { echo "XMLTV output differs for $fixture"; exit 1; }
done
[ "$("$OUT/before/bench" m3u-digest "$OUT/fx/list.m3u")" = "$("$OUT/after-bench" m3u-digest "$OUT/fx/list.m3u")" ] \
  || { echo "M3U output differs"; exit 1; }

python3 - "$OUT" "$RUNS" <<'EOF'
import json, statistics, subprocess, sys
out, runs = sys.argv[1], int(sys.argv[2])
cases = [
    ("XMLTV data -> store (grouped, 886 MB)", ["xml", f"{out}/fx/guide.xml", "1"], "readyStoreMsMedian"),
    ("XMLTV data -> store (interleaved, 177 MB)", ["xml", f"{out}/fx/guide-interleaved.xml", "1"], "readyStoreMsMedian"),
    ("XMLTV local file import -> store", ["xml-file", f"{out}/fx/guide.xml"], "readyStoreMs"),
    ("XMLTV streamed 64 KiB slices -> store", ["xml-stream", f"{out}/fx/guide.xml", "1"], "readyStoreMsMedian"),
    ("M3U 60k parseContent", ["m3u", f"{out}/fx/list.m3u", "1"], "parseContentMsMedian"),
]
print(f"{'case':44} {'before ms':>10} {'after ms':>10} {'speedup':>8} {'peak fp MB b/a':>16}")
for name, args, key in cases:
    row = []
    for binary in (f"{out}/before/bench", f"{out}/after-bench"):
        samples = [json.loads(subprocess.check_output([binary, *args])) for _ in range(runs)]
        row.append((statistics.median(s[key] for s in samples), statistics.median(s["peakFootprintMB"] for s in samples)))
    (b, bm), (a, am) = row
    print(f"{name:44} {b:10.1f} {a:10.1f} {b / a:7.1f}x {bm:7.0f}/{am:<7.0f}")
EOF
