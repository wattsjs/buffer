#!/usr/bin/env bash
# Standalone -O benchmark: visible-window layout, scroll-step work/allocations
# and time-strip generation for the EPG grid (legacy vs current).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -O -swift-version 5 -default-isolation MainActor -module-cache-path "${TMPDIR:-/tmp}/epg-module-cache" Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift Shared/Models/EPGProgram.swift \
  Shared/Support/EPGRowLayout.swift Buffer/Support/EPGGridStyle.swift Buffer/Support/EPGProgramCanvas.swift Buffer/Support/EPGTextLine.swift \
  Shared/Support/PerfMetrics.swift Shared/Support/AppLog.swift Buffer/Views/EPGScrollGrid.swift \
  benchmarks/epg_grid_layout_benchmark.swift -o .local/bench/epg-grid-layout-benchmark
.local/bench/epg-grid-layout-benchmark "$@"
