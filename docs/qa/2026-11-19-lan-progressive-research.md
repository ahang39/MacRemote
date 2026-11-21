# LAN interactive graphics investigation · 2026-11-19

> Earlier, codec choice required stopping the server. That historical stage is now superseded by the [local live-switch prototype](2026-11-19-live-graphics-switch.md), which is not in the public Release.


## Recommendation (experimental, NOT released)
For standard Windows mstsc, try RemoteFX Progressive as an explicit, reversible LAN text-interaction option. Keep AVC420 (VideoToolbox) the default for video/scrolling and slower links. Do not interpret higher Mbps as lower latency; the 12 Mbps experiment caused noticeable image corruption and no perceived delay improvement.

The RDP graphics server already supports --gfx balanced (sets GfxProgressive, disables GfxH264). The SwiftUI menu now allows choosing LAN · Responsive text (Beta) only while server is stopped; the choice is saved in the existing graphicsMode key. H.264 · General remains default and Classic · Compatibility remains available. No mid-session codec switch or forced disconnect.

## Measured same-host source encode comparison (Mac mini M4)
FreeRDP 3.33.1, local process only. Source: tools/bench-lan-codecs.c. Identical synthetic BGRA pixels, initial frame, 7 small text-like 300x48 edits, 7 full-screen simulated scroll updates. 4 Mbps AVC420 VBR target vs RFX Progressive. Medians are per-category codec encode time, not end-to-end remote latency. Pixel patterns favor flat graphics and do not reproduce full real desktop complexity.

| Resolution/metric | H.264 AVC420/VT | RemoteFX Progressive |
| --- | ---: | ---: |
| 1920x1080 typing encode p50 | 5.4 ms | 0.2 ms |
| 1920x1080 scroll encode p50 | 6.1 ms | 13.9 ms |
| 1920x1080 startup encode | 17.2 ms | 15.5 ms |
| 1920x1080 seven-scroll encoded bytes | 39,798 | 1,174,858 |
| 2304x1296 typing encode p50 | 7.5 ms | 0.2 ms |
| 2304x1296 scroll encode p50 | 8.3 ms | 19.4 ms |
| 2304x1296 startup encode | 20.6 ms | 28.9 ms |
| 2304x1296 seven-scroll encoded bytes | 56,480 | 1,655,941 |

The 2304x1296 progressive scroll stream was about 29 times larger for this specific synthetic scene. It may be acceptable on uncongested wired LAN but unsuitable on slow links. AVC420 uses hardware encoding; RemoteFX is efficient for tile-local edits but slower for whole-frame scrolling.

## Correctness / implementation
- tests/test_progressive_roundtrip.c: 7 moving-window frames encoded and decoded with production FreeRDP codec, each sampled-image MAE below 0.3; this verifies local codec only, not actual Windows mstsc decoding.
- apps/macos/GraphicsModeSettings.swift: isolated profile persistence, preserves legacy classic, rejects invalid saved values by reverting to h264; tests/test_graphics_mode_settings.swift uses an isolated UserDefaults suite.
- Full signed build: .build/output/MacRemote-20261119T105439Z.app using Ahang Personal Code Signing; 17/17 CTest, Swift profile tests, bundled dependency audit and signature checks passed.
- Temporary 127.0.0.1-only startup on random port with --gfx balanced produced Graphics: RDPGFX/progressive and opened listener; process cleaned up. This does not verify client negotiation.
- Installed /Applications/MacRemote.app stays unchanged because 3389 has an active Windows RDP connection. Source and staged-build work only, no commit/push/release.
- Failed prior freerdp-3.33.1-lan-latency.patch stays excluded from tools/build-dev-app.sh.

## Root-cause hypotheses and limits
- Existing H.264 presentation patch schedules the AVC420 synthetic tail after 120ms and encodes 5–10 extra P-pictures when updates stop. Previous weak-link typing tests showed about 85% of bytes were synthetic drain frames. This could contribute to sparse-update delay, but is not a proven cause of image corruption.
- Apple VideoToolbox already sets RealTime true and AllowFrameReordering false and synchronously waits for VTCompressionSessionCompleteFrames. Small encode times point to a need for actual measurement of mstsc decode/render, GFX ACK and tail presentation.
- FreeRDP 3.33 direct UDP multitransport is client-side experimental; do not assume Shadow server UDP support.
- RDPGFX_FRAME_ACKNOWLEDGE queueDepth is the client unprocessed-byte count, NOT a count of frames (except special suspended ACK indicator). Do not misread e.g. 38403 as 38,403 frames.
- AVC444v2 is a separate fidelity experiment; HEVC and AV1 are not generic mstsc Shadow codecs.

## Required real Windows client validation before promoting the option
- Same 1920x1080 and 2304x1296 output, same Windows mstsc, direct Ethernet, >=3 alternating A/B sessions, with typing, Chinese IME, scroll, drag, video, final frame, reconnect, clipboard/audio.
- Verify actual negotiated RDPGFX codec is Progressive and not a fallback.
- Measure Windows input to GDI-visible p50/p95, first scroll feedback, real observed FPS, Mac per-stage encode p50/p95, ACK age/in-flight, queueDepth bytes, TX throughput and CPU. The historical one-off LAN baseline 390 ms key-feedback/459 ms scroll is NOT a progressive result.
- Pass only if typing p50 and p95 improve meaningfully, last frame is correct, video/scroll tradeoff is understood, and no new artifacts or unbounded queue appear. Keep H.264 default otherwise.

## Sources
- Microsoft MS-RDPEGFX Progressive: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/219ffb6f-4c86-4dd9-bf13-79b29af9ae99
- Microsoft MS-RDPRFX algorithm: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdprfx/e5afdc95-00bf-46f9-adea-6c641b54af26
- Microsoft RDPGFX frame ACK: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/d64cfae6-f30a-47e7-9655-d019d3d8fb0f
- FreeRDP 3.33.1 release: https://www.freerdp.com/2026/11/10/3_33_1-release
