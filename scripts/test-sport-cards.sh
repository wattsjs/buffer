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
# Flat interned matcher vs the frozen pre-redesign String matcher (oracle),
# plus the per-scalar Unicode normalisation table vs Foundation.
matcher=(Buffer/Models/SourceChannelIdentity.swift Buffer/Models/Channel.swift Buffer/Models/EPGProgram.swift
         Buffer/Models/SportEvent.swift Buffer/Support/PerfMetrics.swift Buffer/Support/AppLog.swift Buffer/Services/StreamMatcher.swift
         benchmarks/sports_matching_fixture.swift)
swiftc -O "${matcher[@]}" benchmarks/legacy_stream_matcher.swift benchmarks/sports_matching_equivalence_tests.swift \
  -o .local/bench/sports-matching-equivalence-tests
.local/bench/sports-matching-equivalence-tests
# Benchmark (not run by default): 60k streams / 3 accounts, 300 fixtures.
#   swiftc -O "${matcher[@]}" benchmarks/sports_matching_benchmark.swift -o .local/bench/sports-matching-bench
#   .local/bench/sports-matching-bench --runs 5
