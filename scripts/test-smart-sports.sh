#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift \
  Shared/Models/EPGProgram.swift Shared/Models/SmartSports.swift \
  Shared/Services/SmartSportsCatalog.swift Shared/Services/SmartSportsCatalogStore.swift \
  benchmarks/smart_sports_tests.swift -o .local/bench/smart-sports-tests
.local/bench/smart-sports-tests
swiftc -swift-version 6 Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift \
  Shared/Models/EPGProgram.swift Shared/Models/SmartSports.swift \
  Shared/Services/SmartSportsCatalog.swift Shared/Services/SmartSportsCatalogStore.swift \
  Shared/Models/SmartChannelFilter.swift Shared/Services/AutoChannelGrouper.swift benchmarks/auto_channel_grouper_tests.swift -o .local/bench/auto-grouper-tests
.local/bench/auto-grouper-tests
swiftc -swift-version 6 Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift Shared/Models/EPGProgram.swift \
  Shared/Support/GuideHistory.swift Shared/Services/BackgroundRefreshPolicy.swift \
  benchmarks/background_source_refresh_tests.swift -o .local/bench/background-refresh-tests
.local/bench/background-refresh-tests
