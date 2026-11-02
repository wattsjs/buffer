# Archive timestamp discontinuity — 2026-10-05

The saved-provider capture exposed a native timing failure, distinct from its
occluded video window. Case 2 in `.logs/channel-matrix-20261005-020306-309179`
initially reported normal position. At elapsed 19.263s, libmpv duration/cache
became 95,097.21/95,088.53s while position was 5.294s. At elapsed 40.320s,
position became 95,097.41s. Generation stayed 1 and recovery reloads stayed 0.
`MPVPlayer` publishes these properties directly; no Swift wall-clock rebase
created them. Render count stopped at 83 when window visibility became false
at elapsed 16.256s, so that run does not qualify continuous visible rendering.

## Local reproduction

Bundled libmpv reports `mpv v0.41.0-dirty`, FFmpeg `n8.0.1`. Five existing
two-second H.264/AAC TS segments were reused, with only PES PTS/DTS and PCR
clock fields changed. No encoding, provider requests, UI, or saved-source
access was used. Each option run used a fresh libmpv handle with null audio
and video outputs and an eight-times clock to finish quickly. This is native
demux/decode timing evidence, not rendered performance or physical audio.

The continuous fixture starts around 500s. The reset fixture uses the same
media bytes but subtracts 367.08s from timestamps after the sixth second. The
true-wrap fixture crosses the 33-bit MPEG-TS timestamp boundary. A forward
367.08s discontinuity is included as a limitation check.

| Fixture/profile | Maximum native duration | Maximum native cache | Maximum sampled position |
| --- | ---: | ---: | ---: |
| Continuous/current flags | 10.005s | 6.720s | 9.721s |
| Backward reset/current flags | 95,086.643s | 95,083.358s | 95,086.526s |
| Backward reset/discardcorrupt only | 95,086.643s | 95,083.358s | 95,086.459s |
| Backward reset/linearize only | 95,086.643s | 95,083.358s | 95,086.392s |
| Backward reset/overflow correction disabled | 6.016s | 3.669s | 5.855s |
| Backward reset/overflow disabled + linearize | 9.984s | 6.699s | 9.855s |
| True wrap/current flags | 10.005s | 6.720s | 9.955s |
| True wrap/overflow correction disabled | 3.456s | 6.208s | 3.255s |
| True wrap/overflow disabled + linearize | 9.984s | 6.699s | 8.955s |

Removing `genpts+igndts` does not fix this failure. FFmpeg initializes wrap
reference 60 seconds before the first timestamp and can add 2^33 to later
timestamps below that reference. A backward reset of 367.08s then becomes a
forward jump of approximately 95,076.64s, matching the provider failure class.
This mechanism is visible in [FFmpeg 8 demux.c](https://github.com/FFmpeg/FFmpeg/blob/n8.0/libavformat/demux.c#L467).
Actual provider packets were not captured, so the local reproduction does not
prove which timestamp field/reset sequence that provider supplied.

MPV linearization corrects backward keyframe timestamps, which alone cannot
repair a reset already converted into a large forward wrap. The pair restores
the reset and true-wrap fixture's bounded timeline. A genuine forward clock
jump remains approximately 377s under every tested profile; this pair is not
a universal timestamp repair. See [MPV 0.41 demux_lavf.c](https://github.com/mpv-player/mpv/blob/v0.41.0/demux/demux_lavf.c#L1278).

## Seek hazard and restricted experiment

The pair breaks low-level seeking. With `cache=no`, even the continuous
fixture's request for 8s landed at 9.988s; a following request for 2s landed at
11.955s and enlarged duration to 20.352s. Seeking to 8s in the reset/wrap
fixtures ended playback. Cached targets in the ten-second fixtures landed
within 0.022s. MPV itself warns that low-level seeks cannot work after its
timestamp linearization. The reason and restriction appear in
[MPV's seek implementation](https://github.com/mpv-player/mpv/blob/v0.41.0/demux/demux_lavf.c#L1328).

`--validate-archive-timestamps` is therefore DEBUG-only and applies only to an
explicit archive load. It enables `correct_ts_overflow=0` and
`demuxer-lavf-linearize-timestamps=yes`. Creation, live/VOD loads, and handle
reuse restore overflow correction and automatic linearization. No production
default changed. The experimental wall-clock seek reloads the provider archive
URL and retains the owner's pause intent, rather than sending an unsafe
low-level seek.

Xtream URLs encode only a minute. The normal path now records that actual
minute as `loadedStart`, extends request duration to retain its intended end,
and seeks the initial sub-minute offset after FILE_LOADED. The experiment
reports the actual URL minute and does not send the initial offset seek.
Consequently **only minute-aligned requests can qualify exact wall-clock
behavior in this experimental mode**. Exact-second recovery would require
verified cached-range seeking or a different transport timeline implementation.

Before promotion, capture the actual provider archive with a visible window,
prove stable A/V and hardware decoding, exercise minute-aligned forward/back
archive moves while playing and paused, then return to live and VOD and prove
the options reset. Provider forward discontinuities remain an explicit gap.

## Reproduce

```
python3 benchmarks/mpv_timestamp_probe.py \
  --app DerivedData/Build/Products/Debug/Buffer.app \
  --fixture-dir .local/hls-720p30-70 \
  --output-dir .local/archive-timestamp-reproduction

scripts/test-player-session.sh
python3 -m unittest scripts/test_mpv_timestamp_probe.py
```

The probe records native MPV/FFmpeg versions, binary and fixture SHA256,
timeline samples, start/load/end events, and bounded warnings. The pure fixture
tests verify 3,009 PTS/DTS vectors, PCR extension preservation, invertible clock
shifts, and invalid TS rejection. The PlayerSlot suite passes 44 checks in
baseline mode and 44 with the opt-in flag, including explicit archive gating,
live/VOD option reset, actual URL start, duration rounding, and paused reloads.

First captured reports: `.logs/archive-timestamp-probe.json` (24 cases),
`.logs/archive-timestamp-seek.json` (6 seek cases), and
`.logs/archive-timestamp-player-session-tests.log`.
