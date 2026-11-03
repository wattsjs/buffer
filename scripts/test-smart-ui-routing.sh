#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
from pathlib import Path
import subprocess
import sys
sys.path.insert(0, 'scripts')
from test_sync import SOURCES, BRIDGE_HEADER
output = Path('.local/bench/smart-ui-routing-tests')
output.parent.mkdir(parents=True, exist_ok=True)
sources = [source for source in SOURCES if source != 'benchmarks/sync_integration.swift']
sources.append('benchmarks/smart_ui_routing_tests.swift')
subprocess.run(['swiftc', '-D', 'PROGRAM_SEARCH_INDEX_TESTING', '-I', 'Shared/SwiftLibxml2',
    '-import-objc-header', BRIDGE_HEADER, *sources, '-o', str(output)], check=True)
subprocess.run([str(output)], check=True)
PY
