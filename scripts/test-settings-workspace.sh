#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc Shared/Models/ServerConfig.swift Shared/Support/SettingsSourceDraft.swift \
  Shared/Support/SettingsSourceWorkspace.swift benchmarks/settings_workspace_tests.swift \
  -o .local/bench/settings-workspace-tests
.local/bench/settings-workspace-tests
