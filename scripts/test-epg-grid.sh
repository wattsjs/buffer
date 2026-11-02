#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc Buffer/Models/SourceChannelIdentity.swift Buffer/Models/Channel.swift Buffer/Models/EPGProgram.swift \
  Buffer/Support/EPGTimelineInputs.swift Buffer/Support/EPGTimeStripCache.swift \
  Buffer/Support/EPGGridStyle.swift \
  Buffer/Support/PerfMetrics.swift Buffer/Support/AppLog.swift Buffer/Views/EPGScrollGrid.swift \
  benchmarks/epg_grid_tests.swift -o .local/bench/epg-grid-tests
.local/bench/epg-grid-tests "$@"
