# Autoresearch — Player Stability & Performance

## Implemented

### rw_timeout=8s (was 10s → briefly 3s → now 8s)
- rw_timeout=3s caused mpv to drop TCP connections during 4-6s CDN stalls
- 8s provides safe headroom without premature reconnects

### Larger ffmpeg I/O buffer (512KB)
- `demuxer-lavf-buffersize=524288` — 16× the 32KB default
- 4K startup: 4682ms → 1809ms (61% improvement)

### Reduced stream probing
- probesize 524288, analyzeduration 0.5

### CDN redirect bypass + cache
- URLSession HEAD resolves silksurfer.com → CDN edge URL before mpv
- 5-minute in-memory cache

### Tighter network-timeout
- network-timeout=5 (was 10)

### Graduated readahead (this iteration)
- Startup: `min(bufferSeconds, 8)` ≈ 5s readahead → faster first frame
- After first frame renders: upgraded to full `cacheCapacitySeconds` ≈ 15s
- Best of both: fast startup + full stall resilience after warm-up

## Validated

### All current settings are well-tuned
- `video-timing-offset=0.016`: 0 drops on 4K+FHD. 0.008 causes 27 drops on 4K
- `cache-pause-wait=2.5s`: zero drops across 1.0s–5.0s range — 10s buffer absorbs stalls
- `cache-secs=15` (app default): slightly faster startup than 10s, better stall margin than 5s
- `readahead=15s`: 0.44s min cache during 7s stalls vs 0s for 5s readahead

## Deferred

- **Connection reset recovery**: inject 502/503 errors to test mpv reconnect behavior
- **Multi-view stability**: 9-slot grid with stalls on one stream
- **demuxer-hysteresis-secs**: currently 0; adding 1s might smooth rapid pause/resume
- **Graduated cache-secs**: like readahead, could start smaller and ramp up after first frame
