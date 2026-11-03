#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
clang -c benchmarks/recording_ownership_stub.c -o .local/bench/recording-ownership-stub.o
swiftc -swift-version 6 -import-objc-header benchmarks/recording_ownership_stub.h \
  Shared/Models/ServerConfig.swift Shared/Models/SourceChannelIdentity.swift \
  Shared/Models/Channel.swift Shared/Models/EPGProgram.swift Shared/Models/Recording.swift \
  Shared/Services/AccountCapacityLedger.swift Shared/Support/AppLog.swift \
  Buffer/Services/RecordingManager.swift benchmarks/recording_ownership_tests.swift \
  .local/bench/recording-ownership-stub.o -framework IOKit -o .local/bench/recording-ownership-tests
.local/bench/recording-ownership-tests
