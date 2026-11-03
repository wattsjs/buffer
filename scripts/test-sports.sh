#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
sources=(Buffer/Models/SourceChannelIdentity.swift Buffer/Models/Channel.swift Buffer/Models/EPGProgram.swift Buffer/Models/SportEvent.swift
         Buffer/Services/ESPNClient.swift Buffer/Services/ESPNScoreboardDecoder.swift Buffer/Services/ConnectorJSONScanner.swift Buffer/Services/StreamMatcher.swift Buffer/Support/AppLog.swift Buffer/Support/PerfMetrics.swift
         Buffer/ViewModels/SportsViewModel.swift Buffer/Support/SportsFixtureCache.swift benchmarks/sports_test_support.swift)
swiftc "${sources[@]}" benchmarks/espn_request_tests.swift -o .local/bench/espn-tests
.local/bench/espn-tests
swiftc -D SPORTS_MATCH_TESTING "${sources[@]}" benchmarks/sports_lifecycle_tests.swift -o .local/bench/sports-lifecycle-tests
.local/bench/sports-lifecycle-tests

swiftc Buffer/Models/SportEvent.swift Buffer/Support/AppLog.swift Buffer/Support/SportsFixtureCache.swift \
  benchmarks/sports_fixture_cache_tests.swift -o .local/bench/sports-fixture-cache-tests
.local/bench/sports-fixture-cache-tests
