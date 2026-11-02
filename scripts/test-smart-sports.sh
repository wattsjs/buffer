#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc Buffer/Models/SourceChannelIdentity.swift Buffer/Models/Channel.swift \
  Buffer/Models/EPGProgram.swift Buffer/Models/SmartSports.swift \
  Buffer/Services/SmartSportsCatalog.swift Buffer/Services/SmartSportsCatalogStore.swift \
  benchmarks/smart_sports_tests.swift -o .local/bench/smart-sports-tests
.local/bench/smart-sports-tests
swiftc -swift-version 6 Buffer/Models/SourceChannelIdentity.swift Buffer/Models/Channel.swift \
  Buffer/Models/EPGProgram.swift Buffer/Models/SmartSports.swift \
  Buffer/Services/SmartSportsCatalog.swift Buffer/Services/SmartSportsCatalogStore.swift \
  Buffer/Models/SmartChannelFilter.swift Buffer/Services/AutoChannelGrouper.swift benchmarks/auto_channel_grouper_tests.swift -o .local/bench/auto-grouper-tests
.local/bench/auto-grouper-tests
swiftc -swift-version 6 Buffer/Models/SourceChannelIdentity.swift Buffer/Models/Channel.swift Buffer/Models/EPGProgram.swift \
  Buffer/Support/GuideHistory.swift Buffer/Services/BackgroundRefreshPolicy.swift \
  benchmarks/background_source_refresh_tests.swift -o .local/bench/background-refresh-tests
.local/bench/background-refresh-tests
