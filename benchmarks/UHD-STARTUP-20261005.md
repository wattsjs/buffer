# Sky Sports UHD startup — 2026-10-05

## Actual app reproduction

The normal signed optimized Debug checkout was opened with no diagnostic flags. Infinity remained selected. Opening its Recently Watched **UK: Sky Sports Main Event UHD** reproduced a visible start-then-pause. The programme was darts at the time of validation; this is the same channel the user reported while watching NFL.

| Event | Measured result |
|---|---|
| Current item FILE_LOADED | 6,494 ms after load |
| First rendered picture | 6,672 ms after load |
| App cache-floor pause | Media position 0.525 seconds; valid reported forward cache 0 |
| Emergency floor / resume reserve | 1.0 / 1.75 seconds |
| Pause duration | 2,272 ms |
| Resume exact cache | 1.856 seconds; rounded UI cache 1.600 |
| Actual format | HEVC, 3840 × 2160, 50 fps, VideoToolbox, six decoded audio channels |
| Later heartbeat | Cache approximately 15 seconds, 9 early frame drops, 0 decoder drops; later counters stable |

Numeric logs: `.logs/sky-uhd-ui-startup.json` and `.logs/sky-uhd-ui-render.json`. The owned player was closed through the app before subsequent tests.

The valid-zero cache observation directly explains Buffer's own 2.27-second pause. The 6.49 seconds before FILE_LOADED includes network, redirect, demux, header and decoder initialization; this evidence does not isolate decoder cost. An initial picture is not necessarily moving playback.

## Changes and comparison method

- Invalid or unavailable cache observations now retire older precise samples immediately. Negative, NaN and infinite values cannot trigger the cache guard. Valid zero remains an underrun. This correction does not explain or remove the reproduced valid-zero pause by itself.
- A DEBUG capture-only startup trial sets `cache-pause-initial=yes` on the actual live `loadfile` entry, using the existing 2.5-second cache wait at the user's five-second setting. Archive, VOD, ordinary subsequent playback and handle reuse retain baseline settings.
- Current-item asynchronous mpv readback reports `cachePauseInitial` and `cachePauseWaitSeconds`; intended flags alone cannot qualify the experiment.
- Saved scenario startup is sampled at four Hz for the first 15 seconds, then one Hz. This can distinguish a short moving burst before a pause from an initial buffer wait. Existing drop, A/V, visibility, discontinuity and interruption gates remain unchanged.

## Paired provider captures

Both used the same signed binary, Infinity stream 375494, a 30-second capture, the user's five-second setting, and the baseline renderer. They completed with confirmed teardown/restoration before the Mac locked.

| Capture | First sampled picture | Sampled stalls | Reported buffering | Frame / decoder drops | Max A/V error | Result |
|---|---:|---:|---:|---:|---:|---|
| Baseline | 8.253 s | 4.079 s | 1.774 s | 8 / 0 | 20.0 ms | Fails interruption, drop and freeze gates |
| Native initial reserve | 8.092 s | 8.496 s | 9.142 s | 2 / 0 | 11.8 ms | Fails interruption, buffering and freeze gates |

Baseline: `.logs/channel-matrix-20261005-052849-283013`. Native reserve: `.logs/channel-matrix-20261005-053252-891902`. The latter confirms actual mpv option readback `cache-pause-initial=true`, wait 2.5 seconds, yet stays initially paused until about 13.77 seconds and then incurs two Buffer cache-floor pauses. It is not adopted. Picture timing includes a held initial picture; sampled stalls include that initial wait and are not exclusively later interruptions.

The baseline buffering counter underreports its interruption: a floor resume clears the UI buffering flag even while mpv remains paused for cache. A correction is being verified separately; these retained measurements are not retroactively made healthy.

The [mpv property documentation](https://mpv.io/manual/stable/#properties-demuxer-cache-duration) describes cache duration as an unreliable approximation. Here “exact” telemetry means the fresh, unrounded property value, not independently measured playable packet coverage. The [cache pause option documentation](https://mpv.io/manual/stable/#options-cache-pause-wait) also permits earlier resume when prefetching stops at a capacity or other limit. A reported zero therefore identifies the app guard trigger, without proving the native decoder had already starved.

Two separate DEBUG trials are being prepared: a bounded hold for the reported buffer target, and native cache handling without Buffer's proactive floor. Neither changes ordinary playback. Visible qualification and remaining auxiliary-window interactions are blocked until the Mac is unlocked.

## Final offline build

Both trials are now built, retaining the pinned development signature: `.logs/uhd-offline-final-build.log`. `--startup-target` waits for the reported configured target with existing pause ownership and a 12-second limit after FILE_LOADED; failed holds remain paused with an error and cannot qualify. `--native-cache-only` keeps native buffering and skips the proactive app floor. Archive, VOD, reused handles and normal playback after completed captures retain baseline behavior.

The native buffering flag now survives a floor resume, fixing the premature UI/counter clearing. Verification passed 27 target/control checks, 82 existing control checks, 20 cache sample checks, 120 player lifecycle checks in five configurations, and 195 aggregate Python tests. Actual visible trial qualification remains pending the manual unlock; the reproduced stall is not marked fixed.

An existing unoptimized bundled mpv v0.41.0 API check accepted per-file `pause=yes` and filled a paused local fixture to a reported 5.4 seconds. `.logs/bundled-startup-options.json` records its older code fingerprint and null outputs. It validates that API capability only, not the new app's performance.

The live path currently retains a 2 MiB probe budget and five-second analysis ceiling. That ceiling is not a fixed wall-clock sleep. A subsequent known-format DEBUG comparison can try one–two seconds of analysis while retaining the probe budget and complete stream-info detection; the aggressive local-recording probe path is not a live default. Require actual option readback, HEVC dimensions/FPS, decoded audio parameters and the existing performance gates. Use AB/BA ordering and numeric network, stream-info and decoder initialization milestones to distinguish cold connections from analysis or decoder cost. This additional experiment is proposed, not implemented or qualified. References: [mpv analysis option](https://mpv.io/manual/stable/#options-demuxer-lavf-analyzeduration), [FFmpeg stream analysis](https://github.com/FFmpeg/FFmpeg/blob/n8.0.1/libavformat/demux.c#L2354).
