#!/usr/bin/env bash
# Connector decoders: scanner primitives + differential tests against the
# frozen reference decoders, then the decode benchmark (--bench).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
models=(Shared/Models/SourceChannelIdentity.swift Shared/Models/Channel.swift Shared/Models/EPGProgram.swift
        Shared/Models/ServerConfig.swift Shared/Models/VODItem.swift Shared/Models/VODSeries.swift Shared/Models/SportEvent.swift)
clients=(Shared/Services/ConnectorJSONScanner.swift Shared/Services/XtreamColumnarDecoder.swift Shared/Services/StalkerColumnarDecoder.swift Shared/Services/XtreamClient.swift
         Shared/Services/StalkerClient.swift Shared/Services/ESPNClient.swift Shared/Services/ESPNScoreboardDecoder.swift
         Shared/Support/AppLog.swift)
support=(benchmarks/connector_fixtures.swift benchmarks/legacy_connector_decoders.swift)
swiftc -O Shared/Services/ConnectorJSONScanner.swift benchmarks/connector_scanner_tests.swift -o .local/bench/connector-scanner-tests
.local/bench/connector-scanner-tests
swiftc -O -D CONNECTOR_TESTING "${models[@]}" "${clients[@]}" "${support[@]}" benchmarks/connector_decode_tests.swift \
  benchmarks/connector_decode_tests_stalker_espn.swift -o .local/bench/connector-decode-tests
.local/bench/connector-decode-tests "$@"
if [[ " $* " == *" --bench "* ]]; then
  swiftc -O -D CONNECTOR_TESTING "${models[@]}" "${clients[@]}" "${support[@]}" benchmarks/connector_decode_benchmark.swift benchmarks/connector_decode_benchmark_stalker_espn.swift \
    -o .local/bench/connector-decode-benchmark
  .local/bench/connector-decode-benchmark
fi
