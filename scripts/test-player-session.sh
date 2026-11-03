#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -D DEBUG -import-objc-header Shared/Services/BufferProbe.h \
  Shared/Models/Channel.swift Shared/Models/EPGProgram.swift \
  Shared/Models/SourceChannelIdentity.swift Shared/Models/ServerConfig.swift \
  Shared/Services/AccountCapacityLedger.swift Shared/Support/SmartLiveRecoveryPolicy.swift \
  Shared/Models/PlaybackRequest.swift Shared/Models/StreamProbe.swift \
  Shared/Services/CatchupURLBuilder.swift Shared/Support/AppLog.swift \
  Shared/Support/PlaybackEvents.swift Shared/Support/PlaybackControlState.swift \
  Shared/Support/MPVItemLifecycle.swift \
  Shared/Support/ArchiveTimestampRecovery.swift \
  Shared/Support/CatchupClipContinuationPolicy.swift \
  Shared/Support/MPVStartupReserve.swift \
  Shared/Support/MPVStartupTarget.swift Shared/Support/MPVNativeCacheOnly.swift \
  Shared/Support/PlaybackLivenessMonitor.swift benchmarks/player_session_test_support.swift \
  Shared/Support/PerfMetrics.swift Shared/Models/PlayerSession.swift benchmarks/player_session_tests.swift \
  -o .local/bench/player-session-tests
.local/bench/player-session-tests
.local/bench/player-session-tests --validate-archive-timestamps
.local/bench/player-session-tests --validate-startup-reserve
.local/bench/player-session-tests --validate-startup-target
.local/bench/player-session-tests --validate-native-cache-only
