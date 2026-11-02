#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
clang -c benchmarks/stream_probe_stub.c -o .local/bench/stream-probe-stub.o
swiftc -swift-version 6 -import-objc-header Buffer/Services/BufferProbe.h \
  Buffer/Models/Channel.swift Buffer/Models/EPGProgram.swift Buffer/Models/StreamProbe.swift \
  Buffer/Models/SourceChannelIdentity.swift Buffer/Models/ServerConfig.swift Buffer/Services/AccountCapacityLedger.swift \
  benchmarks/stream_probe_test_support.swift Buffer/Support/PerfMetrics.swift Buffer/Support/AppLog.swift Buffer/Services/StreamProbeService.swift \
  benchmarks/stream_probe_tests.swift .local/bench/stream-probe-stub.o \
  -o .local/bench/stream-probe-tests
.local/bench/stream-probe-tests
