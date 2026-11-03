#!/usr/bin/env bash
# Guide data-core benchmark: baseline (HEAD JSON cache + per-key lookups +
# hour buckets) vs the columnar store. Usage:
#   scripts/bench-guide-store.sh [channels] [programmesPerChannel] [runs] [baseline-ref]
set -euo pipefail
cd "$(dirname "$0")/.."
channels=${1:-30000}
per=${2:-100}
runs=${3:-5}
ref=${4:-HEAD}
out=.local/bench
base=.local/bench/guide-store-baseline-src
mkdir -p "$out" "$base"
for f in Shared/Services/DataCache.swift Shared/Support/GuideLookup.swift Shared/Support/GuideHistory.swift \
         Shared/Models/Channel.swift Shared/Models/EPGProgram.swift Shared/Models/SourceChannelIdentity.swift; do
  git show "$ref:$f" > "$base/$(basename "$f")"
done
# The baseline needs the same cache-directory override to run outside ~/Library/Caches.
python3 -I - "$base/DataCache.swift" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {"
new = ("        let override = ProcessInfo.processInfo.environment[\"BUFFER_CACHE_DIRECTORY\"].map { URL(fileURLWithPath: $0) }\n"
       "        guard let base = override ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {")
if "BUFFER_CACHE_DIRECTORY" not in s: s = s.replace(old, new)
# Foundation's .atomic stages in a temporary-items folder the Bash sandbox
# denies; stage beside the target and rename instead (same bytes, same atomicity).
s = s.replace("try? data.write(to: url, options: .atomic)",
              "let staged = url.appendingPathExtension(\"tmp\"); try? data.write(to: staged); _ = rename(staged.path, url.path)")
p.write_text(s)
PY
common=(Shared/Models/VODItem.swift Shared/Models/VODSeries.swift Shared/Models/ServerConfig.swift
        Shared/Models/StreamProbe.swift Shared/Support/PerfMetrics.swift Shared/Support/AppLog.swift)
swiftc -O -swift-version 6 -module-cache-path .local/module-cache -D BASELINE -import-objc-header Shared/Services/BufferProbe.h \
  "$base/SourceChannelIdentity.swift" "$base/Channel.swift" "$base/EPGProgram.swift" \
  "$base/DataCache.swift" "$base/GuideLookup.swift" "$base/GuideHistory.swift" "${common[@]}" \
  benchmarks/guide_store_benchmark.swift -o "$out/guide-store-baseline"
swiftc -O -swift-version 6 -module-cache-path .local/module-cache -import-objc-header Shared/Services/BufferProbe.h \
  Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift Shared/Models/EPGProgram.swift \
  Shared/Services/DataCache.swift Shared/Support/GuideLookup.swift Shared/Support/GuideHistory.swift "${common[@]}" \
  benchmarks/guide_store_benchmark.swift -o "$out/guide-store-columnar"
swiftc -O -swift-version 6 -module-cache-path .local/module-cache -D VERIFY_PRUNE -import-objc-header Shared/Services/BufferProbe.h \
  Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift Shared/Models/EPGProgram.swift \
  Shared/Services/DataCache.swift Shared/Support/GuideLookup.swift Shared/Support/GuideHistory.swift "${common[@]}" \
  benchmarks/guide_store_benchmark.swift -o "$out/guide-store-verify"
for variant in baseline columnar; do
  dir="$PWD/$out/guide-store-cache-$variant"
  rm -rf "$dir"; mkdir -p "$dir"
  BUFFER_CACHE_DIRECTORY="$dir" "$out/guide-store-$variant" write "$channels" "$per"
  /bin/ls -l "$dir"/buffer | awk 'NR>1 {print "  " $5 " bytes " $9}'
  for _ in $(seq "$runs"); do BUFFER_CACHE_DIRECTORY="$dir" "$out/guide-store-$variant" load; done
  BUFFER_CACHE_DIRECTORY="$dir" "$out/guide-store-$variant" query
done
BUFFER_CACHE_DIRECTORY="$PWD/$out/guide-store-cache-columnar" "$out/guide-store-verify" load
