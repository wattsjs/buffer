#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Buffer"
PROJECT="Buffer.xcodeproj"
SCHEME="Buffer"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-DerivedData}"
LOG_PREDICATE='process == "Buffer"'
TELEMETRY_PREDICATE='subsystem == "com.wattsjs.buffer"'

mode="run"
if [[ "${1:-}" == "--logs" || "${1:-}" == "logs" ]]; then
  mode="logs"
elif [[ "${1:-}" == "--telemetry" || "${1:-}" == "telemetry" ]]; then
  mode="telemetry"
elif [[ "${1:-}" == "--verify" || "${1:-}" == "verify" ]]; then
  mode="verify"
elif [[ "${1:-}" == "--debug" || "${1:-}" == "debug" ]]; then
  mode="debug"
fi

/usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true

/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS' \
  build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"

if [[ "$mode" == "debug" ]]; then
  exec /usr/bin/lldb "$APP_PATH/Contents/MacOS/$APP_NAME"
fi

/usr/bin/open -n "$APP_PATH"

if [[ "$mode" == "verify" ]]; then
  sleep 2
  /usr/bin/pgrep -x "$APP_NAME" >/dev/null
  echo "$APP_NAME is running"
elif [[ "$mode" == "logs" ]]; then
  exec /usr/bin/log stream --info --style compact --predicate "$LOG_PREDICATE"
elif [[ "$mode" == "telemetry" ]]; then
  exec /usr/bin/log stream --info --style compact --predicate "$TELEMETRY_PREDICATE"
fi
