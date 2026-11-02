#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bench
swiftc Buffer/Models/ServerConfig.swift Buffer/Support/SettingsSourceDraft.swift \
  Buffer/Views/Settings/SettingsSourceWorkspace.swift benchmarks/settings_workspace_tests.swift \
  -o .local/bench/settings-workspace-tests
.local/bench/settings-workspace-tests
