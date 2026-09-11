#!/usr/bin/env bash
set -euo pipefail
echo "buffer-telemetry-ready"
exec /usr/bin/log stream \
  --level debug \
  --style compact \
  --predicate 'subsystem == "com.wattsjs.buffer"'
