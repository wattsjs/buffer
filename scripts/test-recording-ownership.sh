#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
clang -c benchmarks/recording_ownership_stub.c -o .local/bench/recording-ownership-stub.o
swiftc -swift-version 6 -import-objc-header benchmarks/recording_ownership_stub.h \
  Buffer/Models/ServerConfig.swift Buffer/Models/SourceChannelIdentity.swift \
  Buffer/Models/Channel.swift Buffer/Models/EPGProgram.swift Buffer/Models/Recording.swift \
  Buffer/Services/AccountCapacityLedger.swift Buffer/Support/AppLog.swift \
  Buffer/Services/RecordingManager.swift benchmarks/recording_ownership_tests.swift \
  .local/bench/recording-ownership-stub.o -framework IOKit -o .local/bench/recording-ownership-tests
.local/bench/recording-ownership-tests
