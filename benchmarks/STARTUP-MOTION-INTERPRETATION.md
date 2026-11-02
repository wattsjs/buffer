# Startup motion interpretation — 2026-10-05

`scripts/analyze_startup_capture.py` annotates retained capture folders without changing original qualification results:

```sh
python3 scripts/analyze_startup_capture.py .logs/channel-matrix-20261005-121448-275620 \
  --output .logs/uhd-native-only-motion-analysis.json
```

Keep first picture, first sustained motion, initial held-picture time and post-motion interruptions separate. Motion requires same-generation requested playback, visible rendered frames, increasing frame count and finite forward media-clock progress without a jump or actual/startup/cache pause. Two consecutive intervals establish a sampled motion bracket rather than an exact instant. Intentional initial hold remains user-perceived startup time; it must not disappear from the report.

Native-cache-only qualification needs the active flag and zero application floor pauses. Startup-target qualification needs actual current-generation release evidence at the configured reported target; a requested flag or timeout does not prove release. Fresh unrounded cache duration remains an approximation of packet coverage.

The retained native-only capture has a first picture at 4,732ms, a motion bracket of 5,029–5,297ms and confirmation at 5,556ms. Its strict original result remains failed for one clock discontinuity. At 14.161→14.422s, UI position advances 0.520s over 0.261s, just 9ms above the 0.511s gate limit. The next 0.259s reports zero position change while rendered frames continue 465→477→490, pause/cache-pause remain false, frame drops remain 1 and A/V error stays near 2–3 microseconds. The enclosing 0.783s window advances 0.780s and 39 frames; 1.306s advances 1.300s and 65 frames.

This is strongly consistent with 4Hz observation aliasing against the UI's 0.25s publishing threshold. It does not prove raw PTS continuity. The annotator therefore preserves the original failure, reports neighboring windows and separates clock-only nonprogress from simultaneous clock/frame freeze. Root is adding raw current-generation time-pos/video-PTS and receipt age; only that evidence can support a revised scoring decision.

Compare whole-app CPU/memory only under matched library/guide work. Hydration, indexing, UI, compiler overlap and source/connection warmup can change process metrics independently of decoder quality. Confirm same binary, source/native endpoint, coded format, audio path and window visibility; use contemporary baseline and reverse trial order before attributing a change to a startup policy.

Four offline synthetic checks cover held pictures, quantized jump neighbors, fresh raw-clock distinction and generation changes. No provider, CUA or app build is performed by the annotator.

The ordinary passive quality producer now distinguishes `ordinaryLive` provenance and rejects archive/VOD/background/diagnostic/startup/analysis performance observations. Endpoint fingerprints survive persistence; legacy records remain uncertain. A safe moving-startup interval producer is deferred: the available first-picture duration alone must not become a moving-startup score, and replay-window offset must not become absolute broadcast delay. A future producer can confirm two same-generation fresh raw clock/render intervals, retain the first-picture-to-confirmed-motion bracket with sampling uncertainty, and compare only non-overlapping intervals under matched ordinary workloads.
