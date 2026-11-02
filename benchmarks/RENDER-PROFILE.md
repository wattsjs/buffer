# Production renderer stack attribution

2026-10-05, controlled local 1080p60 H.264 HLS, full optimized instrumented
Buffer, experimental AVFoundation audio output. This was a dedicated capture:
no competing player, provider request, build, or encoding job was launched.

Command: `python3 scripts/profile-playback.py --configuration optimized --seconds 30`.
The wrapper attached `/usr/bin/sample` only to its own exact Buffer child after
rendered playback had started. It sampled for five seconds at a requested
one-millisecond interval. This is **stack attribution, not a CPU benchmark**.
Sampling includes blocked thread stacks and perturbs the process.

Evidence:

- `.logs/render-profile-20261005-030616-862901/stacks.sample.txt`
- `.logs/render-profile-20261005-030616-862901/metadata.json`
- `.logs/playback-20261005-030617-044166/report.json`
- Actual signed artifact fingerprint:
  `9c1c014254756becbe9dc3aed92389a450f219a6136f8bccc469c4f962fc8664`.

## Finding

The main thread had 2,681 sampled stacks. Of these, 2,157 (80.5%) were under
the synchronous `CAOpenGLLayer` draw, and 2,066 (77.1%) were blocked inside
`mpv_render_context_render → pthread_cond_wait`. This is time unavailable to
AppKit, **not 77.1% process CPU**. Active render stacks also show OpenGL/Metal
command submission and GL timer queries. SwiftUI body evaluation and Buffer's
event pump do not dominate this sampled window.

This matches the bundled render API contract: `BLOCK_FOR_TARGET_TIME` defaults
to one and can wait for the configured video timing offset. The corresponding
[mpv 0.41.0 presentation wait](https://github.com/mpv-player/mpv/blob/v0.41.0/video/out/vo_libmpv.c#L384-L391)
occurs after drawing and waits for the VO's presentation count. The sample
does not distinguish the CPU costs of GPU submission, decoding, or audio, and
does not measure whole-system GPU/decoder energy.

The sampled playback capture failed its frame-drop budget: 11 renderer drops,
zero decoder drops, zero reported stalls/frozen-renderer time, 552 ms startup,
and maximum sampled A/V error of 0.079 ms. The drop counter changed from zero
to 11 during sampler attachment. Retain the failed verdict; do not compare this
capture's CPU or drops with unsampled engine baselines.

## Source change and next experiment

The paused resize/uncover correctness fix is in `MPVRenderView.swift`: an actual
Core Animation draw must repaint mpv's retained picture into its target even
when no new decoded frame exists. `SKIP_RENDERING` ignores that target. Only a
new-frame update increments render telemetry, so display redraws do not invent
playback progress. **This fix was not in the sampled binary.** No render timing
or callback scheduling was changed for this capture.

The next bounded experiment is now implemented in source with the DEBUG-only
`--validate-render-no-block` launch flag, setting both
`video-timing-offset=0` and `BLOCK_FOR_TARGET_TIME=0`. Changing only the latter
can offset A/V timing according to the bundled API documentation. Compare
unsampled clean and transport-fault captures with the existing startup, drop,
buffering, renderer activity, progress, and A/V gates, then sample the opted-in
renderer separately to confirm that the main-thread presentation wait is gone.
Keep the production default until qualified across frame rates, source types,
paused resize/fullscreen, and longer playback. Use Time Profiler running-state
attribution for a subsequent CPU optimization; this blocked-stack sample
does not establish an engine CPU ranking.

`MPVRenderTiming.validationNoBlock` requires an active `PlaybackValidation` or
`SavedPlaybackScenario` launch. Release and unflagged launches explicitly keep
offset 0.016 and blocking enabled. Each new mpv handle receives the matching
option, and each draw receives the matching render parameter; no preference
is saved or left on a reused handle. Compilation and runtime qualification of
the experiment are still pending the next combined build.
