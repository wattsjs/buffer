#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -O -module-cache-path "${TMPDIR:-/tmp}/parser-module-cache" -I Buffer/SwiftLibxml2 \
  -import-objc-header Buffer/Support/ChannelIdentityEncoding.h \
  Buffer/Models/EPGProgram.swift Buffer/Models/SourceChannelIdentity.swift Buffer/Models/Channel.swift Buffer/Models/VODItem.swift \
  Buffer/Support/AppLog.swift Buffer/Support/PerfMetrics.swift Buffer/Services/XMLTVParser.swift Buffer/Services/M3UParser.swift \
  benchmarks/m3u_reference.swift benchmarks/xmltv_differential_tests.swift benchmarks/parser_correctness_tests.swift \
  -o .local/bench/parser-tests
.local/bench/parser-tests
swiftc -O Buffer/Support/RecentImageFailures.swift benchmarks/image_failure_tests.swift \
  -o .local/bench/image-failure-tests
.local/bench/image-failure-tests
