# Autoresearch — Player Stability & Performance

## Implemented (6 optimizations in MPVPlayer.swift)

| # | Setting | Original | Current | Benefit |
|---|---------|----------|---------|---------|
| 1 | CDN redirect bypass | no | URLSession HEAD + cache | ~1.3s faster startup |
| 2 | `demuxer-lavf-probesize` | 1,048,576 | 524,288 | ~0.3s faster probing |
| 3 | `demuxer-lavf-analyzeduration` | 1.0s | 0.5s | ~0.2s faster probing |
| 4 | `demuxer-lavf-buffersize` | 32KB (default) | 524,288 | 61% faster 4K startup |
| 5 | `network-timeout` | 10s | 5s | Faster failure detection |
| 6 | `rw_timeout` | 10,000,000µs | 8,000,000µs | Survives stalls, faster than 10s |
| 7 | Graduated readahead | 15s fixed | 5s→15s after first frame | Faster startup + full protection |

## Validated (this iteration)

### head-to-head: original vs optimized
- Both zero drops under 6s stalls + 50% error rate
- Optimized wins on startup speed (33-68% faster) with equal stability
- App's cache-secs=15 provides same buffer margin as original

### demuxer-max-bytes: no impact on stability
- cache-secs (15s) is the binding limit, not byte cap
- FHD: 15s ≈ 11MB; 4K: 15s ≈ 47MB — both within any tested cap
- Current 96MiB is well-sized

### cache=auto vs cache=yes
- `auto` starts ~9% faster (4169ms vs 4538ms), equal stability
- App default `auto` is correct

### 502 error recovery: zero drops
- Up to 2 consecutive 502s at 50% segment rate → 0 drops
- HLS retry + buffer absorbs errors perfectly

## Deferred (GUI-dependent or architectural)

- **Multi-view stability**: 9-slot grid with stalls — needs running app
- **Prebuffer stall interaction**: warm handoff during network issues
- **URLSession-based mpv streaming**: HTTP/3, connection reuse — major change
- **Lower-bitrate-variant-first ABR**: requires multi-variant HLS playlists
