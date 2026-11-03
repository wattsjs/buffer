#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
clang -c benchmarks/stream_probe_stub.c -o .local/bench/stream-probe-stub.o
swiftc -swift-version 6 -import-objc-header Shared/Services/BufferProbe.h \
  Shared/Models/Channel.swift Shared/Models/EPGProgram.swift Shared/Models/StreamProbe.swift \
  Shared/Models/SourceChannelIdentity.swift Shared/Models/ServerConfig.swift Shared/Services/AccountCapacityLedger.swift \
  benchmarks/stream_probe_test_support.swift Shared/Support/PerfMetrics.swift Shared/Support/AppLog.swift Shared/Services/StreamProbeService.swift \
  benchmarks/stream_probe_tests.swift .local/bench/stream-probe-stub.o \
  -o .local/bench/stream-probe-tests
.local/bench/stream-probe-tests
