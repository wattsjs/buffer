# Autoresearch — Complete (22 experiments, 2 sessions)

## Final State: 9 optimizations in MPVPlayer.swift

| # | Setting | Original | Current | Startup Impact | Smoothness |
|---|---------|----------|---------|---------------|------------|
| 1 | CDN redirect bypass | no | URLSession HEAD + cache | ~1.3s faster | — |
| 2 | `demuxer-lavf-probesize` | 1MB | 512KB | ~0.3s faster | — |
| 3 | `demuxer-lavf-analyzeduration` | 1.0s | 0.5s | ~0.2s faster | — |
| 4 | `demuxer-lavf-buffersize` | 32KB | 512KB | ~1.8s faster | — |
| 5 | `network-timeout` | 10s | 5s | ~0.1s faster | — |
| 6 | `rw_timeout` | 10s | 8s | — | survives stalls |
| 7 | Graduated readahead | 15s fixed | 5s→15s | ~0.05s faster | — |
| 8 | `fflags` | +discardcorrupt | +genpts+igndts | ~0.5s faster | 3→0 drops |
| 9 | `http_persistent+multiple` | off | on | ~0.5s faster | — |
| 10 | `demuxer-lavf-format` | auto | hls | ~0.3s faster | — |

**Combined: 64.1% startup reduction (5,778ms → 2,074ms) + zero stability regressions**

## Stability Validated
- 8s proxy stalls at 50% rate → 0 drops
- 2 consecutive 502 CDN errors → 0 drops
- Buffer 3s–10s sweep → all survive 7s stalls
- 4K normal playback → 0 drops (was 3, fixed by #8)
- FHD normal playback → 0 drops
- cache=auto vs yes, demuxer-max-bytes, hysteresis — all verified correct

## Settings NOT Changed (verified correct)
video-timing-offset=0.016, cache-pause-wait=2.5s, cache=auto, demuxer-max-bytes=96MiB,
demuxer-hysteresis-secs=0, HTTP/2 (no benefit), prefetch-playlist (no benefit),
audio-disable (no benefit), nofillin (breaks playback), applehttp format (breaks)

## Deferred (architectural only)
- URLSession-based mpv streaming (HTTP/3, connection reuse)
- ABR startup (lower bitrate first → 4K) — needs multi-variant playlists
- Multi-view stability — needs GUI
- Persistent CDN URL cache — disk-level
- TCP pre-warming
