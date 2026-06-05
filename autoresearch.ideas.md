# Autoresearch — Player Stability & Performance

## Implemented

### rw_timeout=8s
- rw_timeout=3s caused premature TCP drops during 4-6s CDN stalls
- 8s provides safe headroom

### Larger ffmpeg I/O buffer (512KB)
- `demuxer-lavf-buffersize=524288` — 16× the 32KB default
- 4K startup: 4682ms → 1809ms (61%)

### Reduced stream probing
- probesize 524288, analyzeduration 0.5

### CDN redirect bypass + cache
- URLSession HEAD → cached CDN URL, skips mpv/ffmpeg redirect overhead

### Tighter network-timeout
- network-timeout=5 (was 10)

### Graduated readahead
- Startup: 5s readahead → fast first frame
- After first frame: upgraded to 15s → full stall resilience

## Validated (this iteration)

### 502 error recovery: zero drops
- 50% error rate: 1 error + 1 stall → 0 drops, cache 6.5s
- 100% error rate at 50% segment drop: 2 consecutive 502s → 0 drops, cache hit 0s but survived
- **mpv HLS retry + 10s buffer handles CDN errors perfectly**

### All settings validated
- `video-timing-offset=0.016`: 0 drops. 0.008 causes 27 drops on 4K
- `cache-pause-wait=2.5s`: zero drops across 1.0s–5.0s range
- `cache-secs=15` (app default): faster startup than 10s, better margin than 5s
- `readahead=15s`: 0.44s min cache during 7s stalls vs 0s for 5s

## Deferred

- **Multi-view stability**: 9-slot grid with stalls — needs GUI test
- **demuxer-hysteresis-secs**: currently 0; adding 1s might smooth rapid pause/resume
- **Graduated cache-secs**: like readahead, start small, ramp up after first frame
