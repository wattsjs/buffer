#!/usr/bin/env bash
# -O benchmark of programme search: legacy linear scan vs ProgramSearchIndex.
# Usage: scripts/bench-program-search.sh [channels=15000] [programmesPerChannel=140] [legacyRuns=5]
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -O -swift-version 6 -parse-as-library \
    Shared/Models/EPGProgram.swift Shared/Support/ProgramSearchIndex.swift benchmarks/program_search_bench.swift \
    -o .local/bench/program-search-bench
.local/bench/program-search-bench "$@"
