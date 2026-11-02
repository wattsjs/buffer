#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -D DEBUG -import-objc-header Buffer/Services/BufferProbe.h \
  Buffer/Models/Channel.swift Buffer/Models/EPGProgram.swift \
  Buffer/Models/SourceChannelIdentity.swift Buffer/Models/ServerConfig.swift \
  Buffer/Services/AccountCapacityLedger.swift Buffer/Support/SmartLiveRecoveryPolicy.swift \
  Buffer/Models/PlaybackRequest.swift Buffer/Models/StreamProbe.swift \
  Buffer/Services/CatchupURLBuilder.swift Buffer/Support/AppLog.swift \
  Buffer/Support/PlaybackEvents.swift Buffer/Support/PlaybackControlState.swift \
  Buffer/Support/MPVItemLifecycle.swift \
  Buffer/Support/ArchiveTimestampRecovery.swift \
  Buffer/Support/CatchupClipContinuationPolicy.swift \
  Buffer/Support/MPVStartupReserve.swift \
  Buffer/Support/MPVStartupTarget.swift Buffer/Support/MPVNativeCacheOnly.swift \
  Buffer/Support/PlaybackLivenessMonitor.swift benchmarks/player_session_test_support.swift \
  Buffer/Support/PerfMetrics.swift Buffer/Models/PlayerSession.swift benchmarks/player_session_tests.swift \
  -o .local/bench/player-session-tests
.local/bench/player-session-tests
.local/bench/player-session-tests --validate-archive-timestamps
.local/bench/player-session-tests --validate-startup-reserve
.local/bench/player-session-tests --validate-startup-target
.local/bench/player-session-tests --validate-native-cache-only
