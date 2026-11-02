#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -swift-version 6 Buffer/Support/PlaybackCacheSample.swift benchmarks/playback_cache_sample_tests.swift \
  -o .local/bench/playback-cache-sample-tests
.local/bench/playback-cache-sample-tests
