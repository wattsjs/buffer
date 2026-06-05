# Autoresearch Ideas — 4K Video Playback Startup Optimization

## Implemented Optimizations

### 1. CDN Redirect Bypass (~22% improvement)
- **What**: Resolve Xtream server → CDN edge redirect via URLSession HEAD request before passing URL to mpv
- **Why**: mpv/ffmpeg's internal HTTP stack takes ~1.3s longer for redirect + TLS renegotiation. URLSession reuses connections and supports HTTP/3.
- **Code**: `MPVPlayer.resolveRedirect()` + async in `loadURL()`
- **Cache**: 5-minute TTL in-memory cache to avoid HEAD request on every channel switch

### 2. Reduced Stream Probing (~5% improvement)
- `demuxer-lavf-probesize`: 1,048,576 (1MB) → 524,288 (512KB)
- `demuxer-lavf-analyzeduration`: 1.0s → 0.5s
- For HLS streams, stream info (codec/resolution/fps) is in the playlist or first segment header. The large probe windows were never fully utilized for HLS.

### 3. Tighter Network Timeouts (~3% improvement)
- `rw_timeout`: 10,000,000µs (10s) → 3,000,000µs (3s)
- `network-timeout`: 10s → 5s
- Healthy CDN segments arrive in 2-4 seconds. Waiting 10s for a timeout blocks the app's own reconnect policy from taking over.

## Deferred / Future Optimizations

### A. Persistent CDN URL Caching
Save resolved CDN URLs to disk (per playlist). On channel list load, pre-resolve all channel URLs in the background. This eliminates the HEAD request entirely for cached channels.
- **Risk**: CDN tokens expire; need refresh strategy
- **Estimated savings**: ~0.3-0.5s (HEAD request time on cache hit)

### B. Pre-warm TCP Connections to CDN
Before `loadURL`, open a raw TCP socket to the CDN host and complete the TLS handshake. When mpv issues its first HTTP request, it can reuse the existing connection.
- **Complexity**: High (raw socket + TLS integration with mpv)
- **Estimated savings**: ~0.3-0.5s (TCP+TLS round trips)

### C. Stream Data via URLSession (Custom mpv Stream Protocol)
Implement a custom mpv `stream_cb` that fetches data through URLSession instead of mpv/ffmpeg's internal HTTP stack. Benefits:
- HTTP/3 support (CDN advertises h3 via Alt-Svc)
- Connection reuse across streams
- System-level DNS caching and Happy Eyeballs
- Better integration with macOS networking (VPN, proxies, etc.)
- **Complexity**: Very high (architectural change)
- **Estimated savings**: ~1-2s (eliminates mpv HTTP stack overhead)

### D. Prebuffer More Channels
Currently, the Home view prebuffers only the top candidate (most recent 4K or recent channel). Prebuffer the top 2-3 channels, or prebuffer on sidebar hover.
- **Estimated savings**: Near-zero startup for prebuffered channels
- **Risk**: Increased bandwidth usage; may trigger provider connection limits

### E. Lower Bitrate Variant First (ABR Startup Trick)
If the stream has multiple HLS variants, load the lowest bitrate variant first to get a quick first frame, then immediately switch to the 4K variant. This is what YouTube/Netflix do.
- **Requirement**: Multi-variant HLS playlist (not available on current test streams)
- **Estimated savings**: ~1-2s (lower bitrate segments download faster)

### F. Cache First Segment Locally
When probing or prebuffering, cache the first ~1MB of the TS segment to disk. On playback, serve from local cache while the CDN connection establishes.
- **Complexity**: Medium (requires custom stream handling)
- **Estimated savings**: ~1-2s (eliminates segment download wait)

## Benchmark Notes
- The existing `prebuffer` mechanism in `HomeView` covers the common case (recent channel replay)
- Cold-start time is dominated by network download of the first TS segment (~2-3s for 4K HEVC)
- Network variance is high (±20% between runs); need many samples for statistical significance
- Avoid overfitting to one CDN edge server; test across multiple streams and times of day
