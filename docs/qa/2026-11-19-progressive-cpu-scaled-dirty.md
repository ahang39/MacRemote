# Progressive CPU investigation — real session and scaled-dirty correction

## Objective
Improve Windows mstsc input-to-visible responsiveness without unnecessarily spending 1.6–1.9 CPU cores on RemoteFX Progressive. Live CPU measurement and true dirty-region correctness take precedence over one-off synthetic encoder timings.

## Live baseline 2026-11-19 21:02-21:05
- Mac M4. Installed macremote-server PID 91293, active device 192.0.2.10, TCP 3389, video output 2304x1296. Saved and effective graphicsCodec balanced (Progressive).
- Raw, no user screen content: /tmp/macremote-live-profile-20261119-2103/cpu-60s.csv. 60 one-second readings: min 4.9% CPU, median 163.45%, peak 188.1%, 39/60 above 100%, 37/60 above 150%. CPU falls to 5–20% when screen is not changing, so workload-sensitive rather than continuous spinning.
- Apple sample profile of the same deployed build: /tmp/macremote-live-sample-20261119.txt. Main hotspots are shadow_client_send_progressive, progressive_compress, rfx_encode_message and RFX tile workers. This supports high software-encoding cost, not the cause of every image artifact.
- Server log contains repeated scaled capture: full local refresh for 2304x1296 output. In pinned FreeRDP source server/shadow/Mac/mac_capture.m, mixed source/output resolution sets fullFrameDamage and replaces each incoming SCK dirty region with a full-surface rectangle. The Shadow sender then encodes the entire surface in Progressive. This is a specific and independent source-level mechanism for unnecessary work. Precise CPU reduction still requires same-client A/B.
- nettop TCP deltas were zero in a later separate idle 5-second window. No high-motion network throughput or actual Windows client-visible latency was established by that idle probe.

## Alternative solutions rejected
Raising H.264 bitrate to 12Mbps previously caused screen corruption without reducing latency. Reducing global FPS would hide the extra encoding cost by reducing frame responsiveness. Mapping ScreenCaptureKit dirty metadata through scaling/letterbox without knowing exact coordinate spaces risks missing pixels; Apple documents dirtyRects but no guaranteed conversion for this specific configuration was established.

## Narrow correctness-preserving correction (source-only)
- New pinned vendor patch patches/freerdp-3.33.1-scaled-dirty-tiles.patch included in tools/build-dev-app.sh.
- ScreenCaptureKit retains its original full local BGRA refresh for scaled output. Before notifying clients, server compares actual **RGB values** against the prior published BGRX shadow surface in output coordinates. Alpha/X ignored as semantically unused.
- 128x128 tiles with at most 64 changed tiles; zero changed means no new frame, few means only changed tiles copied/marked, more than 64 changed or invalid metadata means full-frame copy/encode. A new or resized surface is always fully copied before comparison can begin. This is an exact per-pixel check, not lossy hashing.
- Five-second aggregate-only diagnostics: scaled surface damage: checked, unchanged, tiles, large. No capture of personal screen content, pixels or credentials.
- Existing codec switching, per-device profile, authentication, audio, TCP 3389, and 2-frame startup ACK cap from previous candidate unchanged.

## Validation
- Tests use the production diff helper (tests/test_scaled_dirty_tiles.c) with padding, distinct alpha, edge changes, tile reconstruction, invalid input and full-frame fallback.
- Full arm64 signed standalone App: .build/output/MacRemote-20261119T131114Z.app, signing identity Ahang Personal Code Signing. 19/19 CTest PASS, Swift prefs/UI tests PASS, code signature and dependency packaging PASS. Independent localhost H.264 and Progressive server startup smoke PASS.
- Reproducible tools/bench-scaled-dirty.c compiled with clang -O3 using production helper, 2304x1296, 100 iterations per scenario. Unchanged frame: 2.723ms average, 0 dirty tiles. 48x18 typing-like change: 2.676ms average, 2 dirty tiles. Entire screen change: immediate full fallback in all 100 runs. These are classification costs, not end-to-end latency or measured CPU reduction.

## Status and real-world acceptance
No replacement, restart or port 3389 disruption occurred. Current /Applications/MacRemote.app is unchanged. Not committed, pushed or released. Need explicit real mstsc A/B on 2304x1296, matching scrolling/typing activity and 60-second CPU p50/p95, visible input latency p50/p95, tile-damage summary, image integrity and last-frame stability. Roll back on any new artifacts or client stalls. H.264 remains manual fallback.

## Source references
Apple ScreenCaptureKit SCStreamFrameInfo dirtyRects documentation:
https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/dirtyrects
WebRTC source ScreenCaptureKit desktop capturer:
https://webrtc.googlesource.com/src/+/bf85c38fb360040c0a6f303a97a03b5929f57011/modules/desktop_capture/mac/screen_capturer_sck.mm
