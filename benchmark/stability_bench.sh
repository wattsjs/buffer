#!/usr/bin/env bash
# Stability benchmark: measures playback resilience under network disturbance.
# Injects segment-level stalls via a local proxy, then measures frame drops.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DURATION="${DURATION:-20}"
DROP_RATE="${DROP_RATE:-0.3}"
STALL_MS="${STALL_MS:-3000}"
SEED="${SEED:-42}"
STREAM_IDS="${STREAM_IDS:-26435 538870}"
SERVER="https://783.silksurfer.com"
USER="${1:-fZUKT80Y}"
PASS="${2:-d2xJ6JJr3m}"

total_penalty=0
stream_count=0

# Clean up any leftover proxy processes
pkill -f stability_proxy 2>/dev/null || true
sleep 1

port_base=21987
port_idx=0

for sid in $STREAM_IDS; do
    # Use unique port per stream
    PORT=$((port_base + port_idx))
    port_idx=$((port_idx + 1))

    STREAM_URL="${SERVER}/live/${USER}/${PASS}/${sid}.m3u8"

    # Start proxy in background, redirect stderr to log
    PROXY_LOG=$(mktemp)
    STALL_DURATION_MS=$STALL_MS SEGMENT_DROP_RATE=$DROP_RATE PROXY_PORT=$PORT SEED=$((SEED + sid)) \
        python3 "$SCRIPT_DIR/stability_proxy.py" "$STREAM_URL" 2>"$PROXY_LOG" &
    PROXY_PID=$!
    sleep 3

    if ! kill -0 $PROXY_PID 2>/dev/null; then
        echo "STREAM $sid: PROXY_FAILED"
        cat "$PROXY_LOG" | tail -5
        total_penalty=$((total_penalty + 1000))
        stream_count=$((stream_count + 1))
        rm -f "$PROXY_LOG"
        continue
    fi

    # Play through proxy, collect stats to temp file
    STAT_FILE=$(mktemp)
    set +e
    mpv --no-config --vo=null --ao=null --length=$DURATION \
        --term-status-msg='STAT t=${time-pos} drop=${frame-drop-count} ddrop=${decoder-frame-drop-count} delay=${vo-delayed-frame-count} cache=${demuxer-cache-duration}' \
        "http://127.0.0.1:${PORT}/playlist.m3u8" 2>&1 | tr '\r' '\n' | grep 'STAT' > "$STAT_FILE"
    MPV_EXIT=$?
    set -e

    # Kill proxy + wait + force-clean
    kill $PROXY_PID 2>/dev/null || true
    wait $PROXY_PID 2>/dev/null || true
    # Force-kill any remaining child threads
    lsof -ti :$PORT 2>/dev/null | xargs kill -9 2>/dev/null || true
    sleep 2

    # Count proxy stalls from log
    STALLS=$(grep -c '\[stall' "$PROXY_LOG" 2>/dev/null || echo "0")

    if [ "$MPV_EXIT" != "0" ] && [ "$MPV_EXIT" != "4" ]; then
        echo "STREAM $sid: CRASH exit=$MPV_EXIT stalls=$STALLS penalty=1000"
        total_penalty=$((total_penalty + 1000))
    else
        FINAL=$(tail -1 "$STAT_FILE" 2>/dev/null || echo "")
        if [ -z "$FINAL" ]; then
            echo "STREAM $sid: NO_DATA stalls=$STALLS penalty=500"
            total_penalty=$((total_penalty + 500))
        else
            # Extract values - use awk for robust parsing
            DROP=$(echo "$FINAL" | awk '{for(i=1;i<=NF;i++) if($i~/^drop=/) {split($i,a,"="); print a[2]; exit}}')
            DDROP=$(echo "$FINAL" | awk '{for(i=1;i<=NF;i++) if($i~/^ddrop=/) {split($i,a,"="); print a[2]; exit}}')
            DELAY=$(echo "$FINAL" | awk '{for(i=1;i<=NF;i++) if($i~/^delay=/) {split($i,a,"="); print a[2]; exit}}')
            CACHE=$(echo "$FINAL" | awk '{for(i=1;i<=NF;i++) if($i~/^cache=/) {split($i,a,"="); print a[2]; exit}}')
            DROP=${DROP:-0}
            DDROP=${DDROP:-0}
            DELAY=${DELAY:-0}

            # Composite penalty: 1 per frame drop, 2 per decoder drop, + delayed frames*10
            PENALTY=$((DROP * 1 + DDROP * 2 + DELAY * 10))
            echo "STREAM $sid: drops=$DROP ddrop=$DDROP delay=$DELAY cache=$CACHE stalls=$STALLS penalty=$PENALTY"
            total_penalty=$((total_penalty + PENALTY))
        fi
    fi
    stream_count=$((stream_count + 1))
    rm -f "$STAT_FILE" "$PROXY_LOG"
    sleep 2
done

if [ $stream_count -gt 0 ]; then
    avg_penalty=$((total_penalty / stream_count))
    echo "METRIC stability_penalty=$avg_penalty"
else
    echo "METRIC stability_penalty=1000"
fi
