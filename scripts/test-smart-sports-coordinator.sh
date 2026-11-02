#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -swift-version 6 -default-isolation MainActor \
  -import-objc-header Buffer/Services/BufferProbe.h \
  Buffer/Models/SourceChannelIdentity.swift Buffer/Models/Channel.swift \
  Buffer/Models/EPGProgram.swift Buffer/Models/SmartSports.swift \
  Buffer/Models/ServerConfig.swift Buffer/Models/VODItem.swift Buffer/Models/VODSeries.swift \
  Buffer/Models/StreamProbe.swift Buffer/Support/PerfMetrics.swift Buffer/Support/AppLog.swift Buffer/Services/DataCache.swift \
  Buffer/Support/GuideHistory.swift \
  Buffer/Services/ServerPasswordStore.swift Buffer/Services/AccountCapacityLedger.swift \
  Buffer/Services/SmartSportsCatalog.swift Buffer/Services/SmartSportsCatalogStore.swift \
  Buffer/Services/SmartSportsSnapshotLoader.swift Buffer/Models/SmartChannelFilter.swift Buffer/Services/AutoChannelGrouper.swift Buffer/Services/SmartSportsCoordinator.swift \
  benchmarks/smart_sports_coordinator_tests.swift -o .local/bench/smart-sports-coordinator-tests
.local/bench/smart-sports-coordinator-tests
