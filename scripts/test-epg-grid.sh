#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift Shared/Models/EPGProgram.swift \
  Shared/Support/EPGTimelineInputs.swift Shared/Support/EPGRowLayout.swift Buffer/Support/EPGTextLine.swift Buffer/Support/EPGProgramCanvas.swift \
  Buffer/Support/EPGGridStyle.swift \
  Shared/Support/PerfMetrics.swift Shared/Support/AppLog.swift Buffer/Views/EPGScrollGrid.swift \
  benchmarks/epg_grid_tests.swift -o .local/bench/epg-grid-tests
.local/bench/epg-grid-tests "$@"
