#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -O -import-objc-header Shared/Support/ChannelIdentityEncoding.h \
  Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift Shared/Models/EPGProgram.swift \
  Shared/Support/GuideHistory.swift benchmarks/guide_history_tests.swift \
  -o .local/bench/guide-history-tests
.local/bench/guide-history-tests
