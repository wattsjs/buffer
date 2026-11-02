# macOS playback foundations: evidence and candidate experiments

Research checked 2026-10-04. This is a shortlist, not a migration decision or a claim that any engine solves provider outages. Primary sources below were inspected directly. The configured web-search service was unavailable; the VideoLAN GitLab site presented an access challenge, so its official GitHub mirror was used. The configured background-research agent had no accounts, so source inspection was performed in this session.

## Recommendation

Benchmark **GStreamer**, **native AVPlayer**, **the current libmpv stack with bounded HTTP recovery**, and **KSPlayer** in the primary evaluation. The user explicitly requested GStreamer testing; it is now implemented in the same fault harness. Keep **VLCKit** as a compatibility challenger. Consider a custom FFmpeg/native-rendering hybrid only where measurements show these foundations cannot meet the requirement.

Transport resilience and presentation are separate decisions. An engine can decode flawlessly while its segment downloader amplifies a provider outage. Conversely, adding an intelligent downloader will not repair bad audio lifecycle code.

## Candidates

| Foundation | Primary-source capabilities relevant to Buffer | Costs / uncertainties / next test |
|---|---|---|
| AVPlayer / AVFoundation | Native live-offset controls: `configuredTimeOffsetFromLive`, `recommendedTimeOffsetFromLive`, `automaticallyPreservesTimeOffsetFromLive`. Apple documents the recommendation as based on observed network conditions. [A1] | Less control over HTTP retry scheduling than a custom transport. Must test malformed manifests, IPTV codecs, auth headers/redirects, TS catch-up, timestamp discontinuities, multiview, HDR, and recording parity. Native HLS buffering is not a guarantee of low live latency. |
| KSPlayer | Swift Apple-platform framework using AVPlayer and FFmpeg; documented macOS support, hardware decoding, network-adaptive stream switching, buffer duration controls, format/decoder options, and player fallback. [K1] | **Current public project is GPL**, not simply a free LGPL player. The README describes a paid LGPL version and paid/edition-specific functionality. Rewind, memory caching, zero-delay switching and other attractive features differ by edition. Pin a revision and license before integration. Performance claims in its README are claims, not our results. |
| VLCKit / libVLC | Official Objective-C wrapper for libVLC on macOS; explicitly aimed at formats/protocols AVFoundation does not handle. LGPL 2.1-or-later per upstream. [V1] | Framework/plugin distribution, Swift bridging and licensing compliance need review. Mirror README contains older installation instructions; do not treat its example version as the latest release. Test first-frame latency, recovery, frame stats and hardware output on the actual Mac build. |
| GStreamer | `hlsdemux2` and its adaptive base expose measured bandwidth, separate audio/video buffered durations, time/fragment watermarks, bitrate limits, and bounded retry/backoff controls (retry properties documented since 1.26). `vtdec` uses VideoToolbox with hardware or software implementation depending on device. [G1–G3] | Particularly interesting for adaptive reserve experiments. More pipeline, plugin and packaging work than AVPlayer. VideoToolbox does **not** imply hardware decode is always active. Need to benchmark the actual video sink and texture/copy path. macOS install documentation includes outdated OS examples; verify current packages before adopting. [G4] |
| FFmpeg demux + VideoToolbox + Apple sample-buffer rendering | Own transport and demux control while using system decoding/presentation. `AVSampleBufferRenderSynchronizer` synchronizes queued renderers to a single timeline. FFmpeg exposes HTTP retries and custom I/O options. [A2, F1] | Highest engineering ownership: timestamps, clocks, seek/recovery, audio, HDR, deinterlacing, subtitle composition and decoder lifecycle. Prefer native synchronized sample-buffer rendering before writing an entire Metal/audio scheduler. This is a proposed composition, not a pre-tested library. |
| Existing libmpv with another audio/rendering path | Current bundled library includes CoreAudio and AVFoundation audio outputs (verified with symbols and runtime `current-ao`). FFmpeg transport options allow bounded status-specific retry. [F1, local evidence] | Current CoreAudio path failed initialization and later crashed twice in `hotplug_cb`. AVFoundation **audio output inside mpv is not the same thing as AVPlayer**. Renderer and libmpv versions still need evaluation. Preserve the compatibility fallback until alternatives have passed the codec/stream corpus. |

## A further low-level option worth investigating

Current upstream FFmpeg documentation describes an optional **libcurl protocol backend** with a dedicated transfer event-loop per AVFormatContext, connection reuse, and HTTP/2/HTTP/3 multiplexing. It can be selected with `prefer_libcurl` or a `libcurl:` URL when the build includes it. [F1]

This may be a much smaller intervention than replacing playback: improve transport beneath the existing demux/decoder. **Its presence in the FFmpeg bundled by MPVKit has not been verified.** HTTP/3 only helps when the provider/CDN supports it and cannot create missing media. Do not claim HTTP/3 support from the CLI FFmpeg version installed for fixture generation.

## Provider-resilience architecture to evaluate

1. Track segment fetch latency distributions, retryable errors, reserve seconds and true live offset separately.
2. Use bounded retries while cached media plays. Classify auth expiry, throttling, transient 5xx, timeout, malformed segment and playlist discontinuity separately. Never turn 401/403/509 into rapid retry storms.
3. Increase safety reserve after trouble; decrease slowly after sustained healthy delivery. Explicitly price the additional live delay.
4. Keep the already-decoded timeline/cache across recoverable errors where possible. Reload is an escalation, not the first response.
5. Only use bitrate adaptation when equivalent renditions exist. Only use provider failover when authorized equivalent feeds are known; align their timelines instead of blindly switching URLs.
6. A shared local segment cache/fetch broker could serve playback and recording without duplicate provider connections. It requires careful credential scoping, encryption-key handling, bounded disk/memory use, cancellation and connection-limit compliance.
7. A local HLS normalizer/remuxer can bridge provider quirks into AVPlayer without re-encoding where codecs permit. It cannot invent content, remove encoder delay, or promise compatibility with arbitrary DRM.

## Measurements so far (not an engine ranking)

- `scripts/playback.py` now serves a real-time rolling HLS playlist or explicit VOD playlist and injects scheduled stalls/502s/offline behavior. Video is generated locally; no IPTV credentials are required.
- Early VOD-fixture tests must not be conflated with subsequent rolling-live tests. Reports record `stream_type` once that distinction was added.
- Current mpv + AVFoundation audio, rolling live, 4-second 502 burst at 12 seconds: 8.165 seconds sampled stalled time before retry experiment; 2.604 seconds with bounded HTTP retry experiment. These are single-run observations and need repetition. Zero sampled drops in both; A/V error under 15ms and 8ms respectively.
- CoreAudio-only test produced no real audio output / no A/V-sync metrics. Two default-backend runs previously crashed in `mp_msg_va → mp_msg → hotplug_cb`; logs reported failure to set the input channel layout before the crashes. Successful video-only retries do not prove stability.
- Standalone optimized AVPlayer probe, clean rolling HLS, 30 seconds: ~501ms observed startup, zero reported drops/stalls, ~6.52s median wall-clock live delay from program-date-time. The probe reported ~0.5% process CPU / ~95MiB peak RSS. **Not a valid app-vs-app CPU comparison:** the Buffer probe is a full Debug app, the native probe a small optimized executable, and some system decoding work may run outside either process. Native A/V-sync error is not exposed by this probe.

- Standalone AVPlayer, 45 seconds, rolling HLS with a 4-second 502 burst at 12 seconds: zero observed stalls, zero access-log dropped frames, ~6.51s median live offset; two requests received injected 502s. This is a promising single-run result, not evidence across provider formats or a matched-latency head-to-head. Artifact: `.logs/playback-20261004-200344/report.json`.

## GStreamer implementation and initial results

GStreamer 1.28.7 was installed via Homebrew. `benchmarks/gstreamer_player.m` is a Cocoa host using the actual GStreamer C API, not an external-player handoff or headless decoder. It prefers `vtdec_hw`, uses `playbin3`/`hlsdemux2`, hosts the selected sink in an NSWindow, collects sink-rendered/dropped counters and audio output buffers, and checks actual instantiated elements. The adaptive demux is configured for 5s high watermark, 1.5s low watermark, three retries and bounded exponential backoff.

- Initial audio negotiation failed: this host's default audio output advertises eight unpositioned channels. An explicit 8x2 stereo-to-device matrix fixed negotiation without changing the system default device. The mapping is an experimental flag for this fixture, not general channel-layout support.
- `avsamplebufferlayersink` then crashed once in `libgstapplemedia`'s `_request_data` callback / `g_mutex_unlock`. Do not call that sink stable on this host.
- `osxvideosink`: clean 720p30 passed, zero observed drops/stalls, about **30%** median process CPU.
- `glimagesink`: clean 720p30 passed, zero observed drops/stalls, about **2.8%** median process CPU. Same fixture, hardware decoder and audio map; sink selection is a large measured difference.
- `glimagesink`, 45s, 720p30, 4-second 502 burst: passed with zero observed drops/stalls, four failed requests injected, about **3%** median process CPU.
- Added a sink-sample timestamp observation. Known fixture playlist origin minus the last frame's GStreamer stream time estimates **6.67s live delay**. This is fixture-specific evidence, not a generic provider wall-clock latency metric.
- `glimagesink`, 30s, **1080p60 at 8Mbit/s**, 4-second 502 burst: passed with zero observed drops/stalls, about **5.3%** median process CPU, **131.5MiB** peak RSS and **6.68s** fixture-estimated live delay. Artifact: `.logs/playback-20261004-202347/report.json`.

These are preliminary single-run measurements. GStreamer and native probes still do not expose independent A/V-error and decoder-drop metrics; they must not be reported as measured zeros. The hardware decoder and real sinks are verified, but perceptual audio routing, HDR, multiview, provider compatibility, and long-run stability remain unverified.

## Acceptance criteria for an engine decision

Repeat clean and fault scenarios at equal presentation size, codecs, frame rates, bitrates and live-offset targets. Include 1080p50/60, 4K HEVC, interlaced sports, long GOPs, timestamp gaps, bad playlists, segment truncation, auth redirects, audio output changes, catch-up seek, channel zapping, multiview, recording and wake/sleep. Record missing metrics explicitly, not as zeros. Compare both normal Release builds and profiled builds.

The decision should minimize interruption **at a stated live-delay budget**, rather than rewarding whichever player silently buffers the most. Include process plus system CPU/GPU/power, RSS, startup percentiles, outage recovery, dropped frames, A/V sync, stream failures and feature parity.

## Primary sources

- [A1] Apple live-offset APIs: https://developer.apple.com/documentation/avfoundation/avplayeritem/configuredtimeoffsetfromlive ; https://developer.apple.com/documentation/avfoundation/avplayeritem/recommendedtimeoffsetfromlive ; https://developer.apple.com/documentation/avfoundation/avplayeritem/automaticallypreservestimeoffsetfromlive (Apple documentation JSON inspected where HTML was empty).
- [A2] Apple sample-buffer synchronizer: https://developer.apple.com/documentation/avfoundation/avsamplebufferrendersynchronizer
- [K1] KSPlayer upstream feature/edition/license/options documentation: https://github.com/kingslay/KSPlayer
- [V1] VideoLAN's official VLCKit mirror and license: https://github.com/videolan/vlckit
- [G1] HLS demuxer: https://gstreamer.freedesktop.org/documentation/adaptivedemux2/hlsdemux2.html
- [G2] Adaptive buffering and retry controls: https://gstreamer.freedesktop.org/documentation/adaptivedemux2/GstAdaptiveDemux2.html
- [G3] VideoToolbox decoder: https://gstreamer.freedesktop.org/documentation/applemedia/vtdec.html
- [G4] macOS integration: https://gstreamer.freedesktop.org/documentation/installing/on-mac-osx.html
- [F1] FFmpeg HTTP and libcurl protocol documentation: https://ffmpeg.org/ffmpeg-protocols.html
- [F2] FFmpeg licensing depends on enabled components: https://ffmpeg.org/legal.html
- [M1] CoreAudio callback/init lifecycle in mpv 0.41: https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/audio/out/ao_coreaudio.c ; compare current upstream: https://raw.githubusercontent.com/mpv-player/mpv/master/audio/out/ao_coreaudio.c . Current upstream cleans up failed initialization, unlike the inspected 0.41 source. This supports the failure-lifecycle hypothesis but is not itself proof of a patched binary fix.
