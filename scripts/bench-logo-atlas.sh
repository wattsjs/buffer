#!/usr/bin/env bash
# Channel-logo scroll benchmark: pre-atlas baseline (sources from BASE_REV)
# versus the current LogoAtlas. Needs the built Nuke object from an app build
# (DerivedData/Build/Products/Debug by default, or PRODUCTS_DIR).
set -euo pipefail
cd "$(dirname "$0")/.."
BASE_REV="${BASE_REV:-a8a3881}"
TRIALS="${TRIALS:-5}"
PRODUCTS_DIR="${PRODUCTS_DIR:-$(git rev-parse --path-format=absolute --git-common-dir)/../DerivedData/Build/Products/Debug}"
OUT=.local/bench/logo-atlas
mkdir -p "$OUT/base"
for f in Buffer/Support/RecentImageFailures.swift Buffer/Services/ArtworkImageDecoder.swift \
         Buffer/Services/ImageLoader.swift Buffer/Services/LogoColorAnalyzer.swift; do
  git show "$BASE_REV:$f" > "$OUT/base/$(basename "$f")"
done
swiftc -O -I "$PRODUCTS_DIR" "$OUT"/base/*.swift benchmarks/logo_scroll_benchmark.swift \
  "$PRODUCTS_DIR/Nuke.o" -o "$OUT/logo-scroll-baseline"
swiftc -O -D LOGO_ATLAS -I "$PRODUCTS_DIR" \
  Buffer/Support/RecentImageFailures.swift Buffer/Services/ArtworkImageDecoder.swift \
  Buffer/Services/ImageLoader.swift Buffer/Services/LogoColorAnalyzer.swift Buffer/Services/LogoAtlas.swift \
  benchmarks/logo_scroll_benchmark.swift "$PRODUCTS_DIR/Nuke.o" -o "$OUT/logo-scroll-atlas"
for present in draw materialize; do
  for i in $(seq 1 "$TRIALS"); do
    for mode in baseline atlas; do
      LOGO_PRESENT=$present "$OUT/logo-scroll-$mode" "${TMPDIR:-/tmp}/logo-scroll-$mode-$i"
    done
  done
done
