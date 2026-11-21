# MacRemote startup stutter and tile-artifact investigation (2026-11-19)

## Observations
The user reports substantial lag and mosaic-like artifacts for the first seconds of an mstsc connection. This is a perception report, not proof of an invalid bitstream.

Actual macOS server logs for the 20:05 session: activation at 20:05:35.622 (1920x1080), resize to 2304x1296 requested at 20:05:35.951, capture refreshed again around 20:05:36.185, RDPGFX opened 20:05:36.070, caps confirmed 20:05:37.498 (1.43s after open). First AVC420 picture sent at 20:05:37.525, first frame ACK at 20:05:38.156 (631ms later). Before ACK, server warned of 8 frames in flight. The queueDepth field measures unprocessed bytes, not frames.

Client profile requests Progressive but its file was updated at 20:05:48, 13 seconds after first video frame. The initial H.264 frame is expected, NOT evidence of an accidental codec switch at connection.

The connected macremote-server (PID 91293) used approximately 157-165% CPU in subsequent samples. 3 seconds of Apple sample profile at /tmp/macremote-live-sample-20261119.txt showed substantial progressive_compress, rfx_encode_message and RFX tile encoding CPU. In real workloads this Beta codec can be expensive despite its 0.2ms synthetic typing benchmark.

## Narrow startup correction
FreeRDP default permits eight RDPGFX frames in flight. This project's AVC420 presentation tail can add ten P-picture drain frames at 2304x1296 and fill the initial ACK window. A reversible prototype in patches/freerdp-3.33.1-startup-ack-pacing.patch reduces the pre-ACK max to TWO, restoring normal 8 after the first ACK. It allows only one synthetic decoder-release picture per pacing pass before initial ACK (five after ACK), and keeps the existing 2-second stall recovery, normal established throughput, and user graphics preferences. The production helper is in a patched shadow_startup_pacing.h and is tested by tests/test_startup_ack_pacing.c.

## Validation and status
Final isolated arm64 candidate .build/output/MacRemote-20261119T121715Z.app, signed using Ahang Personal Code Signing. 18/18 native CTest, Swift tests and code-signing checks passed; isolated localhost H.264 and Progressive startup smoke tests passed. This correction has NOT been installed, no active 3389 connection interrupted, and no commit/push/release.

Outstanding independent proof: real Windows mstsc A/B with identical resolution and workload, visual first-5s recording, ACK/queue timeline, p50/p95 input response, image corruption duration, codec/CPU comparison, and idle tail-frame stability. If it still stutters, investigate repeated display capture reset and Windows graphics decode/presentation. Do not attribute a 631ms first ACK solely to bandwidth or network.

RDPGFX ACK specification: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/0241e258-77ef-4a58-b426-5039ed6296ce
