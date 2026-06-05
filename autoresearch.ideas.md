# Autoresearch — Player Stability & Performance

## Implemented

### rw_timeout=8s (was 10s → briefly 3s → now 8s)
- rw_timeout=3s caused mpv to drop TCP connections during 4-6s CDN stalls
- 8s provides safe headroom without premature reconnects

### Larger ffmpeg I/O buffer (512KB)
- `demuxer-lavf-buffersize=524288` — 16× the 32KB default
- 4K startup: 4682ms → 1809ms (61%)

### Reduced stream probing
- probesize 524288, analyzeduration 0.5

### CDN redirect bypass + cache
- URLSession HEAD resolves silksurfer.com → CDN edge URL before mpv

### Tighter network-timeout
- network-timeout=5 (was 10)

## Validated (this iteration)

### video-timing-offset=0.016 is optimal
- 0.008s: **27 frame drops** on 4K (decoder can't keep up)
- 0.016s: 0 drops on both 4K and FHD ✅
- 0.032s: 0 drops (no benefit over 0.016)
- **Current app value is correct**

### cache-pause-wait: 10s buffer dominates
- Tested 1.0s, 2.5s, 5.0s — all zero drops with up to 8s stalls at 50%
- The 10s cache buffer absorbs stalls before cache-pause ever triggers
- Current 2.5s value is well-centered; no change needed

### Proxy stall testing effective for FHD, impractical for 4K
- Proxy-injected stalls accurately simulate network delays
- FHD segments (~1-2MB) work well; 4K segments (~4-8MB) too large for proxy relay
- Validated: 0 frame drops under 8s stalls at 50% rate on FHD

## Deferred

- **Connection reset recovery**: inject 502/503 errors to test mpv reconnect
- **demuxer-hysteresis-secs**: currently 0; adding 1s might prevent rapid pause/resume under intermittent issues
- **cache-pause-floor vs mpv cache-pause interaction**: app's guard pauses at 1.0s, mpv's pause triggers near 0 — verify these don't conflict
- **Multi-view stability**: 9-slot grid with stalls on one stream
