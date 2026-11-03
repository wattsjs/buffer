#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift Shared/Models/EPGProgram.swift \
  Shared/Support/GuideLookup.swift benchmarks/guide_lookup_tests.swift \
  -o .local/bench/guide-tests
.local/bench/guide-tests
swiftc Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift Shared/Models/EPGProgram.swift \
  Shared/Models/SportEvent.swift Shared/Support/PerfMetrics.swift Shared/Support/AppLog.swift Shared/Services/StreamMatcher.swift \
  benchmarks/stream_index_tests.swift -o .local/bench/stream-tests
.local/bench/stream-tests
swiftc Shared/Support/PlaybackControlState.swift benchmarks/playback_control_tests.swift \
  -o .local/bench/playback-control-tests
.local/bench/playback-control-tests
scripts/test-playback-cache-sample.sh
scripts/test-startup-target.sh
scripts/test-live-analysis.sh
swiftc Shared/Support/PlaybackEvents.swift Shared/Support/MPVItemLifecycle.swift \
  benchmarks/mpv_item_lifecycle_tests.swift -o .local/bench/mpv-item-lifecycle-tests
.local/bench/mpv-item-lifecycle-tests
swiftc Shared/Support/RenderInvalidationGate.swift benchmarks/render_invalidation_tests.swift \
  -o .local/bench/render-invalidation-tests
.local/bench/render-invalidation-tests
swiftc Shared/Support/PlaybackLivenessMonitor.swift benchmarks/playback_liveness_tests.swift \
  -o .local/bench/playback-liveness-tests
.local/bench/playback-liveness-tests
scripts/test-player-session.sh
scripts/test-settings-source-draft.sh
scripts/test-stream-probe.sh
scripts/test-account-capacity.sh
scripts/test-smart-sports.sh
scripts/test-smart-sports-coordinator.sh
scripts/test-smart-ui-routing.sh
scripts/test-smart-catalog-versions.sh
scripts/test-program-search-index.sh
scripts/test-recording-ownership.sh
scripts/test-sports.sh
scripts/test-sport-cards.sh
scripts/test-epg-grid.sh
scripts/test-guide-history.sh
scripts/test-epg-appearance.sh
scripts/test-parser-memory.sh
swiftc -import-objc-header Shared/Services/BufferProbe.h \
  Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift Shared/Models/EPGProgram.swift \
  Shared/Models/VODItem.swift Shared/Models/VODSeries.swift \
  Shared/Models/ServerConfig.swift Shared/Models/StreamProbe.swift \
  Shared/Support/PerfMetrics.swift Shared/Support/AppLog.swift Shared/Services/DataCache.swift benchmarks/cache_write_tests.swift \
  -o .local/bench/cache-write-tests
.local/bench/cache-write-tests
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_*.py'
