#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc Buffer/Models/SourceChannelIdentity.swift Buffer/Models/Channel.swift Buffer/Models/EPGProgram.swift \
  Buffer/Support/EPGGridStyle.swift Buffer/Support/PerfMetrics.swift Buffer/Support/AppLog.swift Buffer/Support/EPGProgramCanvas.swift \
  Buffer/Support/EPGVisibleChannelContext.swift Buffer/Views/EPGScrollGrid.swift \
  benchmarks/epg_appearance_tests.swift -o .local/bench/epg-appearance-tests
.local/bench/epg-appearance-tests
