#!/usr/bin/env bash
# Benchmark the actual Buffer app startup time by monitoring logs
set -euo pipefail

APP_PATH="/Users/jamie/Projects/mactv/DerivedData/Build/Products/Debug/Buffer.app"

# Kill any running instance
pkill -x Buffer 2>/dev/null || true
sleep 1

# Start log monitoring in background
LOG_FILE="/tmp/buffer_bench_$(date +%s).log"
log stream --predicate 'subsystem == "com.wattsjs.buffer"' --style compact > "$LOG_FILE" 2>&1 &
LOG_PID=$!

# Launch the app
open -n "$APP_PATH"

# Wait for first-frame log entry (up to 30 seconds)
TIMEOUT=30
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  if grep -q "first-frame" "$LOG_FILE" 2>/dev/null; then
    MATCH=$(grep "first-frame" "$LOG_FILE" | tail -1)
    echo "Found: $MATCH"
    # Extract elapsedMs
    ELAPSED_MS=$(echo "$MATCH" | grep -oE "elapsedMs=[0-9]+" | cut -d= -f2)
    echo "METRIC startup_ms=$ELAPSED_MS"
    break
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  echo "Timeout: no first-frame event detected"
  echo "METRIC startup_ms=0"
fi

# Cleanup
kill $LOG_PID 2>/dev/null || true
pkill -x Buffer 2>/dev/null || true

# Show relevant log entries
echo ""
echo "=== Log summary ==="
grep -E "first-frame|load-start|file-loaded|end-file" "$LOG_FILE" | tail -20