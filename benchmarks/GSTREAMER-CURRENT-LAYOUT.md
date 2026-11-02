# GStreamer output-layout diagnosis, 2026-10-05

The earlier `hlsdemux2` not-negotiated failure was caused by the obsolete
`--gst-audio-map 8` fixture workaround. The current default output has two
channels. An eight-row matrix forces eight output channels, which cannot
negotiate with the current stereo sink. The previous eight-channel host layout
is documented in `handoff.md`; it must not be assumed across device changes.
[GStreamer's matrix contract](https://gstreamer.freedesktop.org/documentation/audio/gstaudioconverter.html)
defines one row per output channel and one column per input channel.

`gstreamer_player.m` now queries only the default output channel count; it never
records device names or IDs. A requested matrix that disagrees with that count
fails before pipeline/window startup. A no-window `--gst-audio-preflight` check
accepts the current default and explicit two-channel map, and rejects the old
eight-channel map. Default stereo negotiation needs no explicit map.

The probe now uses a nonactivating accessory `NSPanel` that cannot become key or
main. Every sampled state in the final three runs confirms the app stayed
inactive and its panel stayed non-key/non-main.

## Final local live-HLS captures

All captures were 30 seconds, H.264 1920x1080 at 60 fps, `glimagesink`, default
stereo negotiation. Faults lasted four seconds beginning at 12 seconds. The
existing hardware/HLS/audio/error/drop/start/end gates all passed, with actual
`vtdec_hw`, `hlsdemux2`, and `osxaudiosink` audio buffers negotiated to two channels.

| Case | Median process CPU | Peak RSS | Sampled sink drops | Video unavailable after startup | Buffering samples |
| --- | ---: | ---: | ---: | ---: | ---: |
| Clean | 4.70% | 102.23 MiB | 0 | 0 s | 0 s |
| 502 burst | 4.75% | 102.77 MiB | 0 | 1.0 s | 0.500 s |
| Delayed response | 4.70% | 106.16 MiB | 0 | 1.0 s | 0.501 s |

First rendered sample was 1,005 ms in every capture. Both faults briefly
exhausted the reserve and reset sink statistics once, then resumed. The generic
clock-stall score is zero because it omits intervals starting with
`rendered=false`; that value must not be described as zero observable
interruption. The unavailable/buffering durations above are estimates at the
500 ms sampling interval, not precise event-duration or perceptual measurements.

Each final report uses schema 5 and the same verified corpus SHA-256:
`994d1d4505fec83af4e5f51dba4bd21568d72cb790224995b6eb38f2f99d70de`.
The final executable fingerprint is
`c670fd6225f59fff9c668ad9a060235fc4049b51fa289d390f180eb1fea2590f`.

Artifacts:

- `.logs/playback-20261005-024111-980740/report.json` — clean.
- `.logs/playback-20261005-024143-749383/report.json` — four injected 502 responses.
- `.logs/playback-20261005-024215-275041/report.json` — one delayed response.
- `.logs/gstreamer-current-layout-matrix.json` — compact results plus sampled availability/focus observations.
- `.logs/gstreamer-audio-layout-preflight.json` — current-layout positive and stale-map negative checks.

Failed evidence is retained:

- `.logs/playback-20261005-022932-239920/report.json` — original obsolete-map negotiation failure.
- `.logs/playback-20261005-023847-819791/report.json` and
  `.logs/playback-20261005-023952-477550/report.json` — successful media output but
  failed telemetry protocol gate because a new layout event preceded `start`.
  Source ordering was corrected and both captures were rerun; no gate was relaxed.

## Limits

This is an optimized standalone clang `-O2` probe, not a full Buffer build or a
fair full-app CPU/RSS comparison. Sampled process metrics exclude decoder/GPU
work in other processes, system power, and physical footprint. Independent A/V
sync and separate decoder drops are unmeasured. The fixture is silent, so audio
buffers do not qualify audible output or physical channel routing. Sink stats
reset during the fault captures, so sampled zero drops are not an exact
continuous drop audit. These runs do not qualify a production engine migration.

`python3 -m unittest discover -s scripts -p test_playback.py` passed 30 tests;
the final probe compiled successfully, the three actual layout preflight checks
passed, and the scoped diff check was clean.
