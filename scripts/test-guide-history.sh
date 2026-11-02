#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -O -import-objc-header Buffer/Support/ChannelIdentityEncoding.h \
  Buffer/Models/SourceChannelIdentity.swift Buffer/Models/Channel.swift Buffer/Models/EPGProgram.swift \
  Buffer/Support/GuideHistory.swift benchmarks/guide_history_tests.swift \
  -o .local/bench/guide-history-tests
.local/bench/guide-history-tests
