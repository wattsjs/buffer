#!/usr/bin/env bash
# Connector decoders: scanner primitives + differential tests against the
# frozen reference decoders, then the decode benchmark (--bench).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
models=(Buffer/Models/SourceChannelIdentity.swift Buffer/Models/Channel.swift Buffer/Models/EPGProgram.swift
        Buffer/Models/ServerConfig.swift Buffer/Models/VODItem.swift Buffer/Models/VODSeries.swift Buffer/Models/SportEvent.swift)
clients=(Buffer/Services/ConnectorJSONScanner.swift Buffer/Services/XtreamColumnarDecoder.swift Buffer/Services/StalkerColumnarDecoder.swift Buffer/Services/XtreamClient.swift
         Buffer/Services/StalkerClient.swift Buffer/Services/ESPNClient.swift Buffer/Services/ESPNScoreboardDecoder.swift
         Buffer/Support/AppLog.swift)
support=(benchmarks/connector_fixtures.swift benchmarks/legacy_connector_decoders.swift)
swiftc -O Buffer/Services/ConnectorJSONScanner.swift benchmarks/connector_scanner_tests.swift -o .local/bench/connector-scanner-tests
.local/bench/connector-scanner-tests
swiftc -O -D CONNECTOR_TESTING "${models[@]}" "${clients[@]}" "${support[@]}" benchmarks/connector_decode_tests.swift \
  benchmarks/connector_decode_tests_stalker_espn.swift -o .local/bench/connector-decode-tests
.local/bench/connector-decode-tests "$@"
if [[ " $* " == *" --bench "* ]]; then
  swiftc -O -D CONNECTOR_TESTING "${models[@]}" "${clients[@]}" "${support[@]}" benchmarks/connector_decode_benchmark.swift benchmarks/connector_decode_benchmark_stalker_espn.swift \
    -o .local/bench/connector-decode-benchmark
  .local/bench/connector-decode-benchmark
fi
