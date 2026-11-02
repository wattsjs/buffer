#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc Buffer/Models/SourceChannelIdentity.swift Buffer/Models/Channel.swift Buffer/Models/EPGProgram.swift \
  Buffer/Models/SportEvent.swift Buffer/Support/PerfMetrics.swift Buffer/Support/AppLog.swift Buffer/Services/StreamMatcher.swift \
  Buffer/Support/SportEventMatchState.swift benchmarks/sport_card_matching_tests.swift \
  -o .local/bench/sport-card-tests
.local/bench/sport-card-tests
swiftc Buffer/Models/SourceChannelIdentity.swift Buffer/Models/Channel.swift Buffer/Models/EPGProgram.swift \
  Buffer/Models/SportEvent.swift Buffer/Support/PerfMetrics.swift Buffer/Support/AppLog.swift Buffer/Services/StreamMatcher.swift \
  Buffer/Support/StreamMatchVisibility.swift Buffer/Support/SportsProgrammeBinding.swift benchmarks/stream_match_tests.swift \
  -o .local/bench/stream-match-tests
.local/bench/stream-match-tests
