# Autoresearch — Player Stability & Performance

## Implemented (stability session)

### rw_timeout=8s (was 10s → briefly 3s → now 8s)
- **Finding**: rw_timeout=3s caused mpv to drop TCP connections during transient 4-6s CDN stalls ("Stream ends prematurely" + BrokenPipe)
- **Fix**: 8s provides safe headroom above typical CDN segment fetch times (2-6s) without being as conservative as the 10s ffmpeg default
- **Validated**: FHD stream survived 2×5s proxy-injected stalls with zero frame drops

### Larger ffmpeg I/O buffer (512KB, from prior session)
- `demuxer-lavf-buffersize=524288` — 16× the 32KB default, cuts syscall overhead for 4K HEVC segments
- Validated: 4K startup from 4682ms → 1809ms (61% improvement)

### Reduced stream probing (from prior session)
- `demuxer-lavf-probesize=524288`, `demuxer-lavf-analyzeduration=0.5`
- Safe for HLS; stream info is in playlist or first segment header

### CDN redirect bypass (from prior session)
- URLSession HEAD request resolves silksurfer.com → CDN edge URL before mpv loadfile
- 5-minute in-memory cache; generation-guarded to prevent stale resolution

### Tighter network-timeout (from prior session)
- `network-timeout=5` (was 10); app's reconnect policy recovers faster than waiting

## Key Findings

- **10s cache buffer handles 5-6s stalls without drops** on FHD streams
- **4K proxy testing impractical** — full 4K segment download through local proxy exceeds benchmark timeouts; real app fetches directly from CDN
- **rw_timeout must exceed max expected segment fetch time** — otherwise it triggers false reconnects during healthy-but-slow CDN responses
- **Stability metrics**: frame-drop-count, decoder-frame-drop-count, vo-delayed-frame-count from mpv term-status-msg are reliable indicators

## Deferred

- **Connection reset recovery**: test mpv behavior when CDN returns 502/503 mid-stream
- **Multi-view stability**: test 9-slot grid with stalls on one stream
- **cache-pause-floor tuning**: the app's own emergency pause guard might interact with rw_timeout
- **Prebuffer + stall interaction**: if a prebuffered channel stalls, does the pool handle handoff correctly?
