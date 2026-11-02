#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Buffer"
PROJECT="Buffer.xcodeproj"
SCHEME="Buffer"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-DerivedData}"

mode="run"
if [[ "${1:-}" == "--logs" || "${1:-}" == "logs" ]]; then
  mode="logs"
elif [[ "${1:-}" == "--telemetry" || "${1:-}" == "telemetry" ]]; then
  mode="telemetry"
elif [[ "${1:-}" == "--verify" || "${1:-}" == "verify" ]]; then
  mode="verify"
elif [[ "${1:-}" == "--debug" || "${1:-}" == "debug" ]]; then
  mode="debug"
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--logs|--telemetry|--verify|--debug]" >&2
  exit 2
fi

APP_PATH="$ROOT_DIR/$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_PATH/Contents/MacOS/$APP_NAME"

# Resolve before stopping the app: missing setup must leave an existing app alive.
source "$ROOT_DIR/scripts/local-signing.sh"
buffer_configure_signing normal

# Stop only this checkout's executable; preserve installed/other-worktree apps.
python3 - "$APP_BINARY" <<'PY'
import os, pathlib, signal, subprocess, sys, time
target = pathlib.Path(sys.argv[1]).resolve()
def owned():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
    return [int(fields[0]) for row in rows if len(fields := row.strip().split(None, 1)) == 2
            and pathlib.Path(fields[1]).resolve() == target]
for pid in owned():
    try: os.kill(pid, signal.SIGTERM)
    except ProcessLookupError: pass
deadline = time.monotonic() + 5
while owned() and time.monotonic() < deadline: time.sleep(.1)
if owned(): raise SystemExit('Local Buffer did not stop; refusing to launch a duplicate')
PY

/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS,arch=arm64' \
  "${BUFFER_SIGNING_ARGS[@]}" \
  build

buffer_verify_signing "$APP_PATH"

if [[ "$mode" == "debug" ]]; then
  exec /usr/bin/lldb "$APP_PATH/Contents/MacOS/$APP_NAME"
fi

# An installed Buffer can have the same bundle ID. Launch this exact checkout
# rather than asking LaunchServices to activate that other running instance.
/usr/bin/open -n "$APP_PATH"

pid="$(python3 - "$APP_BINARY" <<'PY'
import pathlib, subprocess, sys, time
target = pathlib.Path(sys.argv[1]).resolve()
for _ in range(30):
    rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
    found = [fields[0] for row in rows if len(fields := row.strip().split(None, 1)) == 2
             and pathlib.Path(fields[1]).resolve() == target]
    if len(found) == 1:
        print(found[0]); break
    time.sleep(.1)
else: raise SystemExit('Could not verify exactly one local Buffer process')
PY
)"

if [[ "$mode" == "verify" ]]; then
  /bin/ps -o pid=,comm= -p "$pid"
  echo "$APP_NAME is running"
elif [[ "$mode" == "logs" ]]; then
  exec /usr/bin/log stream --info --style compact --predicate "processIdentifier == $pid"
elif [[ "$mode" == "telemetry" ]]; then
  exec /usr/bin/log stream --info --style compact --predicate "processIdentifier == $pid AND subsystem == \"com.wattsjs.buffer\""
fi
