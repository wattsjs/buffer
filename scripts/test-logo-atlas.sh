#!/usr/bin/env bash
# Logo atlas, URL interning, colour column, bitset failure memo. Needs the
# built Nuke object (DerivedData/Build/Products/Debug by default, or PRODUCTS_DIR).
set -euo pipefail
cd "$(dirname "$0")/.."
PRODUCTS_DIR="${PRODUCTS_DIR:-$(git rev-parse --path-format=absolute --git-common-dir)/../DerivedData/Build/Products/Debug}"
mkdir -p .local/bench
swiftc -O -swift-version 6 Buffer/Support/RecentImageFailures.swift benchmarks/image_failure_tests.swift \
  -o .local/bench/image-failure-tests
.local/bench/image-failure-tests
swiftc -O -swift-version 6 -I "$PRODUCTS_DIR" \
  Buffer/Support/RecentImageFailures.swift Buffer/Services/ArtworkImageDecoder.swift Buffer/Services/ImageLoader.swift \
  Buffer/Services/LogoColorAnalyzer.swift Buffer/Services/LogoAtlas.swift benchmarks/logo_atlas_tests.swift \
  "$PRODUCTS_DIR/Nuke.o" -o .local/bench/logo-atlas-tests
.local/bench/logo-atlas-tests
