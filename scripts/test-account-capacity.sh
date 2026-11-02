#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -O -swift-version 6 \
  Buffer/Models/ServerConfig.swift Buffer/Models/SourceChannelIdentity.swift \
  Buffer/Models/Channel.swift Buffer/Models/EPGProgram.swift \
  Buffer/Services/AccountCapacityLedger.swift benchmarks/account_capacity_tests.swift \
  -o .local/bench/account-capacity-tests
.local/bench/account-capacity-tests
