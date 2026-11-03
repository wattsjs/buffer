#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -swift-version 6 Shared/Support/PlaybackControlState.swift \
  Shared/Support/MPVStartupTarget.swift benchmarks/startup_target_tests.swift \
  -o .local/bench/startup-target-tests
.local/bench/startup-target-tests
