#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc -swift-version 6 -default-isolation MainActor -strict-concurrency=complete \
  Buffer/Models/ServerConfig.swift Buffer/Support/SettingsSourceDraft.swift \
  benchmarks/settings_source_draft_tests.swift -o .local/bench/settings-source-draft-tests
.local/bench/settings-source-draft-tests
