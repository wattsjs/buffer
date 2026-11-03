#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
sources=(Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift Shared/Models/EPGProgram.swift Shared/Models/SportEvent.swift
         Shared/Services/ESPNClient.swift Shared/Services/ESPNScoreboardDecoder.swift Shared/Services/ConnectorJSONScanner.swift Shared/Services/StreamMatcher.swift Shared/Support/AppLog.swift Shared/Support/PerfMetrics.swift
         Shared/ViewModels/SportsViewModel.swift Shared/Support/SportsFixtureCache.swift benchmarks/sports_test_support.swift)
swiftc "${sources[@]}" benchmarks/espn_request_tests.swift -o .local/bench/espn-tests
.local/bench/espn-tests
swiftc -D SPORTS_MATCH_TESTING "${sources[@]}" benchmarks/sports_lifecycle_tests.swift -o .local/bench/sports-lifecycle-tests
.local/bench/sports-lifecycle-tests

swiftc Shared/Models/SportEvent.swift Shared/Support/AppLog.swift Shared/Support/SportsFixtureCache.swift \
  benchmarks/sports_fixture_cache_tests.swift -o .local/bench/sports-fixture-cache-tests
.local/bench/sports-fixture-cache-tests
