#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -O -module-cache-path "${TMPDIR:-/tmp}/parser-module-cache" -I Shared/SwiftLibxml2 \
  -import-objc-header Shared/Support/ChannelIdentityEncoding.h \
  Shared/Models/EPGProgram.swift Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift Shared/Models/VODItem.swift \
  Shared/Support/AppLog.swift Shared/Support/PerfMetrics.swift Shared/Services/XMLTVParser.swift Shared/Services/M3UParser.swift \
  benchmarks/m3u_reference.swift benchmarks/xmltv_differential_tests.swift benchmarks/parser_correctness_tests.swift \
  -o .local/bench/parser-tests
.local/bench/parser-tests
swiftc -O Buffer/Support/RecentImageFailures.swift benchmarks/image_failure_tests.swift \
  -o .local/bench/image-failure-tests
.local/bench/image-failure-tests
