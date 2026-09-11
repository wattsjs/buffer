#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/.logs}"
LAST="${1:-2h}"
PREDICATE='subsystem == "com.wattsjs.buffer"'
mkdir -p "$OUT_DIR"

stamp="$(/bin/date +%Y%m%d-%H%M%S)"
out="$OUT_DIR/buffer-telemetry-$stamp.txt"
latest="$OUT_DIR/buffer-telemetry-latest.txt"

/usr/bin/log show \
  --style compact \
  --info \
  --debug \
  --last "$LAST" \
  --predicate "$PREDICATE" \
  >"$out"

/bin/cp "$out" "$latest"
/bin/echo "$latest"
/usr/bin/wc -l "$out" | /usr/bin/awk '{print $1 " lines"}'
