#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -swift-version 6 -default-isolation MainActor \
  -import-objc-header Shared/Services/BufferProbe.h \
  Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift \
  Shared/Models/EPGProgram.swift Shared/Models/SmartSports.swift \
  Shared/Models/ServerConfig.swift Shared/Models/VODItem.swift Shared/Models/VODSeries.swift \
  Shared/Models/StreamProbe.swift Shared/Support/PerfMetrics.swift Shared/Support/AppLog.swift Shared/Services/DataCache.swift \
  Shared/Support/GuideHistory.swift \
  Shared/Services/ServerPasswordStore.swift Shared/Services/AccountCapacityLedger.swift \
  Shared/Services/SmartSportsCatalog.swift Shared/Services/SmartSportsCatalogStore.swift \
  Shared/Services/SmartSportsSnapshotLoader.swift Shared/Models/SmartChannelFilter.swift Shared/Services/AutoChannelGrouper.swift Shared/Services/SmartSportsCoordinator.swift \
  benchmarks/smart_sports_coordinator_tests.swift -o .local/bench/smart-sports-coordinator-tests
.local/bench/smart-sports-coordinator-tests
