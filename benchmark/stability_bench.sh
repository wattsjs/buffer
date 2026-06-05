#!/usr/bin/env bash
# Stability benchmark: measures playback resilience under network disturbance
# Uses a Python proxy to inject segment-level stalls, then plays through mpv
# and collects frame-drop / decoder-drop / stall recovery metrics.
#
# Usage: STREAM_IDS="26435 538870" DURATION=25 DROP_RATE=0.3 STALL_MS=3000 ./stability_bench.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY_PORT="${PROXY_PORT:-18765}"
DURATION="${DURATION:-25}"
DROP_RATE="${DROP_RATE:-0.3}"
STALL_MS="${STALL_MS:-3000}"
SEED="${SEED:-42}"
STREAM_IDS="${STREAM_IDS:-26435 538870}"
SERVER="https://783.silksurfer.com"
USER="${1:-fZUKT80Y}"
PASS="${2:-d2xJ6JJr3m}"

total_penalty=0
stream_count=0

cleanup() {
    kill $PROXY_PID 2>/dev/null || true
    wait $PROXY_PID 2>/dev/null || true
    # Make sure port is freed
    lsof -ti :$PROXY_PORT 2>/dev/null | xargs kill -9 2>/dev/null || true
}
trap cleanup EXIT

for sid in $STREAM_IDS; do
    STREAM_URL="${SERVER}/live/${USER}/${PASS}/${sid}.m3u8"

    # Start proxy
    STALL_DURATION_MS=$STALL_MS SEGMENT_DROP_RATE=$DROP_RATE PROXY_PORT=$PROXY_PORT SEED=$((SEED + sid)) \
        python3 "$SCRIPT_DIR/stability_proxy.py" "$STREAM_URL" &
    PROXY_PID=$!
    sleep 3

    if ! kill -0 $PROXY_PID 2>/dev/null; then
        echo "STREAM $sid: PROXY_FAILED penalty=1000"
        total_penalty=$((total_penalty + 1000))
        stream_count=$((stream_count + 1))
        continue
    fi

    # Play through proxy, collect STAT lines
    STAT_FILE=$(mktemp)
    set +e
    mpv --no-config --vo=null --ao=null --length=$DURATION \
        --term-status-msg='STAT t=${time-pos} drop=${frame-drop-count} ddrop=${decoder-frame-drop-count} delay=${vo-delayed-frame-count} mist=${mistimed-frame-count} cache=${demuxer-cache-duration}' \
        "http://127.0.0.1:${PROXY_PORT}/playlist.m3u8" 2>&1 | tr '\r' '\n' | grep 'STAT' > "$STAT_FILE"
    MPV_EXIT=$?
    set -e

    # Parse proxy stalls from stderr (capture in a temp file too)
    # Actually, proxy stderr is mixed into the same pipe. Let me get it separately.
    # For now, we'll just count from STAT lines.

    if [ $MPV_EXIT -ne 0 ] && [ $MPV_EXIT -ne 4 ]; then
        # Exit 4 = EOF (normal for --length), anything else is a crash
        echo "STREAM $sid: CRASH exit=$MPV_EXIT penalty=1000"
        total_penalty=$((total_penalty + 1000))
        stream_count=$((stream_count + 1))
    else
        # Parse final STAT line for cumulative drops
        FINAL=$(tail -1 "$STAT_FILE" 2>/dev/null || echo "")
        if [ -z "$FINAL" ]; then
            echo "STREAM $sid: NO_DATA penalty=500"
            total_penalty=$((total_penalty + 500))
        else
            # Extract values with awk
            DROP=$(echo "$FINAL" | grep -oE 'drop=[0-9]+' | cut -d= -f2)
            DDROP=$(echo "$FINAL" | grep -oE 'ddrop=[0-9]+' | cut -d= -f2)
            DELAY=$(echo "$FINAL" | grep -oE 'delay=[0-9]+' | cut -d= -f2)
            MIST=$(echo "$FINAL" | grep -oE 'mist=[0-9.]+' | cut -d= -f2)
            CACHE=$(echo "$FINAL" | grep -oE 'cache=[0-9.]+' | cut -d= -f2)

            DROP=${DROP:-0}
            DDROP=${DDROP:-0}
            DELAY=${DELAY:-0}

            # Composite stability penalty: lower is better
            # frame drops are tolerable; decoder drops are worse
            PENALTY=$((DROP * 1 + DDROP * 2 + $(echo "$DELAY" | awk '{print int($1 * 10)}')))
            echo "STREAM $sid: drops=$DROP ddrop=$DDROP delay=$DELAY cache=$CACHE penalty=$PENALTY"
            total_penalty=$((total_penalty + PENALTY))
        fi
        stream_count=$((stream_count + 1))
    fi

    rm -f "$STAT_FILE"
    kill $PROXY_PID 2>/dev/null || true
    wait $PROXY_PID 2>/dev/null || true
    sleep 2
done

if [ $stream_count -gt 0 ]; then
    avg_penalty=$((total_penalty / stream_count))
    echo "METRIC stability_penalty=$avg_penalty"
else
    echo "METRIC stability_penalty=1000"
fi
