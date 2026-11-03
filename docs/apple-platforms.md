# iPhone, iPad and Apple TV

Buffer builds for macOS, iOS/iPadOS and tvOS from one Xcode project.

## Layout

| Folder | Targets | Contents |
| --- | --- | --- |
| `Shared/` | Buffer, Buffer iOS, Buffer tvOS | Models, `DataCache`, guide lookup and `EPGRowLayout`, the Xtream/Stalker/M3U/XMLTV/ESPN clients, Smart Channels, `StreamMatcher`, `StreamProbeService`, `AccountCapacityLedger`, `EPGViewModel`, `SportsViewModel`, `MPVPlayer`/`PlayerSession`, the country filter editor, the C probe/recorder and the bridging header |
| `Buffer/` | Buffer (macOS) | AppKit views, NSTableView guide, windows and popovers, Sparkle, recordings, reminders, logo atlas, validation tooling |
| `SharedUI/` | Buffer iOS, Buffer tvOS | App model, full-screen player, GLES render view, source editor, Sports, search |
| `BufferMobile/` | Buffer iOS | Adaptive root (tab bar in compact width, sidebar + EPG grid in regular width) and the UIKit virtualised guide grid |
| `BufferTV/` | Buffer tvOS | Tab-sidebar root and the focus-driven guide |

Each folder is a synchronized group, so new files join their targets automatically. Platform differences inside `Shared/` use `#if os(macOS)`; validation tooling (`PlaybackValidation`, `SavedPlaybackScenario`, `SessionObservation`) is compiled out off the Mac.

## Playback

The Mac draws mpv through `CAOpenGLLayer`. iOS and tvOS use mpv's OpenGL ES render API on a `CAEAGLLayer` (`SharedUI/MPVGLESRenderView.swift`) with the same `MPVRenderTarget` model: mpv's update callback renders on a dedicated queue, and teardown waits for any frame in flight. Binding the renderbuffer to the layer happens on the main thread, which UIKit requires, under a lock shared with the render queue. On iOS/tvOS mpv disables direct rendering and PBO uploads (OpenGL ES cannot map them) and keeps the single-pass bilinear scaler (spline36 needs float intermediate framebuffers, which rendered corrupt frames on GLES); the simulator also decodes in software because it has no VideoToolbox/GLES interop. GLES cannot output 10-bit video (mpv#7846).

## Guide grids

Both read the same `EPGRowLayout` SoA columns as the Mac grid.

- iOS/iPadOS: `GuideGridScrollView` keeps only the rows in the viewport, reuses row views, and draws just the cells in the visible time span; the channel column and time strip are sticky.
- tvOS: lazy rows of focusable cards for a three-hour page; moving focus past either edge pages the timeline.

## Building and checking

```bash
scripts/build-touch.sh ios
scripts/build-touch.sh tvos
```

UI walk-throughs add an Xtream source against a local fixture, browse the guide, Sports and the country filter, and play a channel. Full-screen captures land in `.logs/shots/<device>/named/`.

```bash
python3 scripts/fake_xtream_server.py
scripts/test-touch-ui.sh ios "iPhone 17 Pro"
scripts/test-touch-ui.sh ios "iPad Pro 13-inch (M5)"
scripts/test-touch-ui.sh tvos "Apple TV 4K (3rd generation)"
```

The fixture serves user `demo` / password `demo` at `http://127.0.0.1:8899`. XCUITest typing into a `SecureField` does not reach its binding on the iOS 27 simulator and the tvOS keyboard is not scriptable, so DEBUG builds accept `BUFFER_PREFILL_XTREAM="url|user|password"` to pre-fill the new-source form; saving still goes through the form's button.

Set `BUFFER_PACKAGES_DIR` to an existing `SourcePackages` folder to avoid downloading MPVKit again for each derived-data folder.
