#!/usr/bin/env bash
# Stability benchmark: measures playback resilience under network disturbance.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DURATION="${DURATION:-15}"
DROP_RATE="${DROP_RATE:-0.3}"
STALL_MS="${STALL_MS:-4000}"
SEED="${SEED:-42}"
RW_TIMEOUT="${RW_TIMEOUT:-8000000}"
STREAM_IDS="${STREAM_IDS:-26435 538870}"
SERVER="https://783.silksurfer.com"
USER="${1:-fZUKT80Y}"
PASS="${2:-d2xJ6JJr3m}"

total_penalty=0
stream_count=0

# Kill any leftover proxies
pkill -9 -f stability_proxy 2>/dev/null || true
sleep 1

for sid in $STREAM_IDS; do
    PORT=$(( 25000 + (sid % 5000) ))
    STREAM_URL="${SERVER}/live/${USER}/${PASS}/${sid}.m3u8"

    # Start proxy, log to file
    PROXY_LOG=$(mktemp)
    STALL_DURATION_MS=$STALL_MS SEGMENT_DROP_RATE=$DROP_RATE PROXY_PORT=$PORT SEED=$((SEED + sid)) \
    ERROR_INJECT_RATE="${ERROR_INJECT_RATE:-0}" \
        python3 -u "$SCRIPT_DIR/stability_proxy.py" "$STREAM_URL" > "$PROXY_LOG" 2>&1 &
    PROXY_PID=$!
    sleep 3

    if ! kill -0 $PROXY_PID 2>/dev/null; then
        echo "STREAM $sid: PROXY_FAILED"
        cat "$PROXY_LOG" | tail -10
        total_penalty=$((total_penalty + 1000))
        stream_count=$((stream_count + 1))
        rm -f "$PROXY_LOG"
        continue
    fi

    # Play through proxy with a hard timeout (3x duration + 45s buffer for 4K)
    TIMEOUT=$((DURATION * 3 + 45))
    STAT_FILE=$(mktemp)
    set +e
    perl -e "alarm $TIMEOUT; exec @ARGV" -- \
        mpv --no-config --vo=null --ao=null --length=$DURATION \
        --stream-lavf-o=rw_timeout=$RW_TIMEOUT \
        --term-status-msg='STAT t=${time-pos} drop=${frame-drop-count} ddrop=${decoder-frame-drop-count} delay=${vo-delayed-frame-count} cache=${demuxer-cache-duration}' \
        "http://127.0.0.1:${PORT}/playlist.m3u8" 2>&1 | tr '\r' '\n' | grep 'STAT' > "$STAT_FILE"
    MPV_EXIT=$?
    set -e

    # Kill proxy
    kill $PROXY_PID 2>/dev/null || true
    wait $PROXY_PID 2>/dev/null || true
    lsof -ti :$PORT 2>/dev/null | xargs kill -9 2>/dev/null || true

    # Count stalls and errors from proxy log
    STALLS=$(grep -c '\[stall' "$PROXY_LOG" 2>/dev/null || echo "0")
    ERRORS=$(grep -c '\[error' "$PROXY_LOG" 2>/dev/null || echo "0")

    if [ "$MPV_EXIT" = "142" ] || [ "$MPV_EXIT" = "124" ]; then
        echo "STREAM $sid: TIMEOUT stalls=$STALLS errors=$ERRORS penalty=500"
        total_penalty=$((total_penalty + 500))
    elif [ "$MPV_EXIT" != "0" ] && [ "$MPV_EXIT" != "4" ]; then
        echo "STREAM $sid: CRASH exit=$MPV_EXIT stalls=$STALLS errors=$ERRORS penalty=1000"
        total_penalty=$((total_penalty + 1000))
    else
        FINAL=$(tail -1 "$STAT_FILE" 2>/dev/null || echo "")
        if [ -z "$FINAL" ]; then
            echo "STREAM $sid: NO_DATA stalls=$STALLS penalty=500"
            total_penalty=$((total_penalty + 500))
        else
            DROP=$(echo "$FINAL" | awk '{for(i=1;i<=NF;i++) if($i~/^drop=/) {split($i,a,"="); print a[2]; exit}}')
            DDROP=$(echo "$FINAL" | awk '{for(i=1;i<=NF;i++) if($i~/^ddrop=/) {split($i,a,"="); print a[2]; exit}}')
            DELAY=$(echo "$FINAL" | awk '{for(i=1;i<=NF;i++) if($i~/^delay=/) {split($i,a,"="); print a[2]; exit}}')
            CACHE=$(echo "$FINAL" | awk '{for(i=1;i<=NF;i++) if($i~/^cache=/) {split($i,a,"="); print a[2]; exit}}')
            DROP=${DROP:-0}; DDROP=${DDROP:-0}; DELAY=${DELAY:-0}
            PENALTY=$((DROP * 1 + DDROP * 2 + DELAY * 10))
            echo "STREAM $sid: drops=$DROP ddrop=$DDROP delay=$DELAY cache=$CACHE stalls=$STALLS errors=$ERRORS penalty=$PENALTY"
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
