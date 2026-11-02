#!/usr/bin/env bash
# Equivalence test + -O benchmark of the mpv property dispatch kernel
# (MPVPropertyBatch / MPVPropertyRequestRing vs the former PendingChanges path).
# Uses the Observation macro plugin: run from a Terminal if the sandbox blocks it.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -O -wmo -swift-version 6 -parse-as-library \
  Buffer/Support/MPVItemLifecycle.swift Buffer/Support/PlaybackEvents.swift \
  Buffer/Support/MPVPropertyBatch.swift Buffer/Support/PlaybackCacheSample.swift \
  Buffer/Support/PlaybackClockSample.swift Buffer/Support/PlaybackLivenessMonitor.swift \
  benchmarks/mpv_property_dispatch_benchmark.swift benchmarks/mpv_property_dispatch_harness.swift \
  -o .local/bench/mpv-property-dispatch
.local/bench/mpv-property-dispatch
