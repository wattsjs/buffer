#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift Shared/Models/EPGProgram.swift \
  Buffer/Support/EPGGridStyle.swift Shared/Support/PerfMetrics.swift Shared/Support/AppLog.swift Buffer/Support/EPGProgramCanvas.swift Shared/Support/EPGRowLayout.swift Buffer/Support/EPGTextLine.swift \
  Shared/Support/EPGVisibleChannelContext.swift Buffer/Views/EPGScrollGrid.swift \
  benchmarks/epg_appearance_tests.swift -o .local/bench/epg-appearance-tests
.local/bench/epg-appearance-tests
