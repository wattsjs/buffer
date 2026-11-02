#!/usr/bin/env bash
# Collect Buffer performance telemetry and print a playback/UI/sync summary.
# Observe the running app, or launch a validation playback session.
#
#   scripts/profile.sh --observe 30
#   scripts/profile.sh --validate-url http://127.0.0.1:8765/live.m3u8 --seconds 20
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT_DIR="${OUT_DIR:-$ROOT/.logs}"
mkdir -p "$OUT_DIR"

mode="observe"
seconds=30
url=""
buffer=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --observe)
      mode="observe"
      seconds="${2:-30}"
      shift 2
      ;;
    --validate-url)
      mode="validate"
      url="${2:-}"
      shift 2
      ;;
    --seconds)
      seconds="${2:-20}"
      shift 2
      ;;
    --buffer)
      buffer="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$OUT_DIR/profile-$STAMP.log"
: >"$LOG"
log stream --level debug --style compact --predicate 'subsystem == "com.wattsjs.buffer"' >"$LOG" 2>&1 &
LOG_PID=$!
cleanup() { kill "$LOG_PID" 2>/dev/null || true; }
trap cleanup EXIT

if [[ "$mode" == "validate" ]]; then
  APP="$ROOT/DerivedData/Build/Products/Debug/Buffer.app"
  if [[ ! -d "$APP" ]]; then
    echo "Build Buffer first: scripts/bench.sh or scripts/build-and-run.sh" >&2
    exit 1
  fi
  args=(--args --validate-url "$url" --validate-seconds "$seconds")
  if [[ -n "$buffer" ]]; then
    args+=(--validate-buffer "$buffer")
  fi
  open -n "$APP" "${args[@]}"
  sleep "$seconds"
  sleep 3
else
  sleep "$seconds"
fi

python3 - "$LOG" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors="replace")
print(f"log={sys.argv[1]} lines={len(text.splitlines())}")
patterns = [
    "validation summary",
    "validation sample",
    "mpv first-frame",
    "mpv sync heartbeat",
    "cache floor pause",
    "telemetry heartbeat",
    "ui-lag",
    "Sports stream index",
    "Sports fixtures fetched",
    "Sync finished",
    "Guide published",
    "Xtream catchup EPG",
    "Playlist catalog joined",
    "benchmark case",
]
for pattern in patterns:
    hits = [line for line in text.splitlines() if pattern in line]
    print(f"\n## {pattern} ({len(hits)})")
    for line in hits[-5:]:
        print(line)
PY
echo "wrote $LOG"
