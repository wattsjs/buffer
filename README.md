# Buffer

A native macOS IPTV player built with SwiftUI and libmpv.

<img width="2344" height="1770" alt="Screenshot 2026-04-17 at 23 02 26@2x" src="https://github.com/user-attachments/assets/737e9d90-3225-4f89-9453-2fcd2193a60d" />

## Local performance loop

```bash
scripts/build-and-run.sh --verify
scripts/bench.sh
scripts/profile.sh --observe 30
scripts/profile.sh --validate-url http://127.0.0.1:8765/live.m3u8 --seconds 20
```

`scripts/bench.sh` builds an ad-hoc-signed Debug Buffer (no developer certificate required), runs production-code benchmarks with fixed fixtures, validates outputs, and writes `.logs/bench-latest.json`. Each case has a warm-up and seven timing samples. These are Debug measurements, not release-performance claims.

The Run action uses `scripts/build-and-run.sh --verify`. It resolves a stable local signing identity before stopping this checkout's executable, builds, opens the app bundle and verifies its PID. See [local signing setup](docs/local-signing.md) to prevent repeated Keychain permission dialogs across rebuilds. Synthetic benchmarks can use ad-hoc signing without reading saved credentials, and reuse the stable identity once configured. `--telemetry` scopes unified logs to that PID; it does not mix installed copies or other checkouts.

Save a baseline **before changing code**, then compare the next build:

```bash
scripts/test-performance.sh
scripts/bench.sh
cp .logs/bench-latest.json .logs/bench-baseline.json
# Make one change, then rebuild and measure:
scripts/bench.sh --compare .logs/bench-baseline.json
```

The comparison rejects mismatched fixtures, configurations, machines, or outputs and exits with status 2 for median regressions above 15% (`--tolerance 0.15`). Status 1 means a build, execution, or evidence failure. Archived runs include binary hashes and source-revision metadata. `--skip-build` measures the existing executable and must not be used to claim unbuilt source changes.

`scripts/profile.sh` currently collects diagnostic logs for playback drops, cache pauses, guide sync, catch-up fetch, sports fixtures, and UI lag. It is **not yet an automated playback pass/fail gate**; missing telemetry does not prove healthy playback. Validation playback is Debug-only, and buffer overrides are process-local rather than saved preferences.

### Observe the normal saved library

Quit existing Buffer instances, build, then run:

```bash
python3 scripts/observe-session.py --seconds 90
# Optional process-local audio experiment; does not change preferences:
python3 scripts/observe-session.py --seconds 90 --ao avfoundation
```

Select one channel in the app. The collector opens the normal app through LaunchServices, records numeric library/player state, renderer activity, window visibility, process CPU/RSS and physical footprint, then leaves the app open. It archives only tagged JSON samples under `.logs/session-*/`; unrelated output is discarded. No source names, authenticated URLs or credentials enter the samples. A missing/short capture fails with exit 2. A complete idle or paused observation is diagnostic evidence, not proof of healthy playback. Physical footprint and RSS are separate metrics; no general live-delay measurement is available for saved providers.

Focused reproducible comparisons supplement the in-app suite:

```bash
python3 scripts/bench-epg-grid.py --output .logs/epg-grid.json
python3 scripts/bench_sync.py --output .logs/sync-http.json
scripts/test-sports.sh
```

`benchmarks/results/` retains before/after guide lookup, grid, catalog and request-budget evidence with fixture/configuration and hash metadata. Synthetic timing and request-concurrency results are not live-provider speed claims.

### Rendered playback and provider-fault experiments

Requires a logged-in macOS GUI session and `ffmpeg` (`brew install ffmpeg`). No IPTV credentials are used: the harness generates video with silent audio and serves a rolling local HLS stream.

```bash
# Build the instrumented app, then exercise the actual Buffer renderer:
scripts/bench.sh
python3 scripts/playback.py --seconds 30
# Explicit experimental audio backend and bounded FFmpeg retry policy:
python3 scripts/playback.py --seconds 45 --ao avfoundation --http-retry \
  --fault 502 --fault-at 12 --fault-seconds 4
# Native AVPlayer architecture probe using the same fixture/server:
python3 scripts/playback.py --engine native --seconds 45 \
  --fault 502 --fault-at 12 --fault-seconds 4
# GStreamer C/Objective-C probe (brew install gstreamer):
python3 scripts/playback.py --engine gstreamer --gst-sink glimagesink \
  --profile 1080p60 --seconds 30 --fault 502 --fault-at 12 --fault-seconds 4
# On this test host only, its 8-channel unpositioned audio device requires
# the explicit stereo-fixture mapping option: --gst-audio-map 8
# Negative control: this MUST fail, not report healthy playback:
python3 scripts/playback.py --seconds 12 --fault offline
```

Each run stores structured samples, resource samples, injected-fault records, stdout/stderr and a JSON verdict under `.logs/playback-*/`. The gate requires completed capture, rendered frames, advancing playback and sample coverage, and checks drop/stall budgets. MPV runs additionally require successive renderer draws, a visible player window, active audio output and sampled A/V synchronization. Schema 2 added visibility and renderer freezes; schema 3 also checks accumulated app buffering-state time, including short events between samples. Older reports did not qualify those measurements. Exit 2 means the gate failed. The native probe marks unavailable measurements explicitly; its standalone optimized CPU/RSS measurements are not comparable to the full Debug app. `--stream-type vod` is a separate finite-playlist scenario.

See [`benchmarks/PLAYBACK-FOUNDATIONS.md`](benchmarks/PLAYBACK-FOUNDATIONS.md) for the sourced engine shortlist, measured results, limitations and remaining acceptance criteria. Neither experimental audio selection nor retry settings have been enabled for normal app playback. GStreamer probes verify the active `hlsdemux2` and `vtdec_hw` elements and record sink statistics. `glimagesink`, `osxvideosink`, and `avsamplebufferlayersink` are independently selectable; the last exhibited a native callback crash on this macOS beta host. The optional channel matrix is a fixture/device experiment, not a general multichannel-audio implementation.

## Features

### Playlists and library

- Multiple IPTV playlists/accounts with Xtream Codes and M3U support
- XMLTV guide support with per-playlist caching and quick switching
- Server connection testing, guide reachability checks, and account status details
- Favorites, recently watched channels, and per-group hide/reorder controls

### Guide and discovery

- 12-hour Electronic Program Guide with current-program highlighting and a live now-line
- Fast program and channel search with fuzzy matching (`⌘F`)
- Program reminders with macOS notifications and one-click jump back into playback
- Configurable background sync for playlists and EPG data, plus manual refresh

### Playback

- Native libmpv playback with configurable network buffering
- Catchup/rewind playback for Xtream and common M3U catchup formats
- Five multi-view layouts: single, 1+2, 2×2, 3×3, and focused + thumbnails
- External player handoff for VLC, IINA, and Infuse
- Keyboard shortcuts for playback, seeking, fullscreen, search, and help

### Recording and sports

- Scheduled recordings from the guide and one-click live recording while watching
- Recording padding, wake-from-sleep support, and configurable output folder
- Playback for in-progress and completed recordings inside Buffer
- ESPN-powered live sports view with filters, live scores, and matched channel shortcuts
- Home dashboard with live sports, favorites, and recently watched channels
