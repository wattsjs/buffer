#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -O -swift-version 6 \
  Shared/Models/ServerConfig.swift Shared/Models/SourceChannelIdentity.swift \
  Shared/Models/Channel.swift Shared/Models/EPGProgram.swift \
  Shared/Services/AccountCapacityLedger.swift benchmarks/account_capacity_tests.swift \
  -o .local/bench/account-capacity-tests
.local/bench/account-capacity-tests
