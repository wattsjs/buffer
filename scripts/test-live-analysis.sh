#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -swift-version 6 -D DEBUG Shared/Support/MPVLiveAnalysis.swift Shared/Support/PlaybackClockSample.swift \
  benchmarks/live_analysis_tests.swift -o .local/bench/live-analysis-tests
.local/bench/live-analysis-tests
swiftc -swift-version 6 Shared/Support/MPVLiveAnalysis.swift Shared/Support/PlaybackClockSample.swift \
  benchmarks/live_analysis_tests.swift -o .local/bench/live-analysis-release-tests
.local/bench/live-analysis-release-tests
