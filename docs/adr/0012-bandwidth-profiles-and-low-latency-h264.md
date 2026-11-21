# ADR-0012: High/Low Bandwidth Profiles and Low-Latency H.264 Streaming

- Status: **Accepted (implemented on development branch; awaiting real Windows mstsc validation)**
- Date: 2026-11-21

## Context

Prior iterations accumulated overlapping graphics controls:
- Three separate RDPGFX codecs (AVC420, AVC444, RemoteFX Progressive) plus manual Classic compatibility mode.
- A 327-line mid-session live codec-switch patch (`freerdp-3.33.1-live-graphics-switch.patch`) introduced solely to work around LAN typing latency on AVC420.
- Three raw H.264 target bitrate buttons (1.4 / 2.0 / 4.0 Mbps) that did not cap VideoToolbox bursts, did not adjust Opus audio (fixed at 256 kbps = 32 KB/s), did not throttle capture/encode FPS on slow links, and still left 8 unacknowledged frames in flight.

Root-cause investigation showed why AVC420 suffered both LAN latency and WAN bandwidth overhead:
1. Apple VideoToolbox H.264 Baseline emits SPS NAL units with `vui_parameters_present_flag = 0`. Without `bitstream_restriction.max_num_reorder_frames = 0` and `max_dec_frame_buffering = 1`, decoders such as Windows `mstsc` default to Level `MaxDpbFrames` (4 frames at 1080p Level 4.0; 9 frames at 2304×1296 Level 5.0).
2. To work around decoder buffering, MacRemote previously waited 120 ms after sparse updates and burst 5–10 unchanged P-frames. In weak-network typing tests, those synthetic drain frames accounted for ~85% of transmitted video bytes.
3. Periodic IDR keyframes every 300 frames (counting drain frames) created >100 KB spikes over lossless TCP.

## Decision

1. **Collapse graphics selection into a single H.264/AVC420 pipeline with two bandwidth modes** (`src/stream/stream_profile.c`):
   - **High (`high`, LAN — default for new devices):** 60 fps max capture/encode, 8.0 Mbps H.264 average (`DataRateLimits` 1.2×/1 s), 6 frames in flight, uncapped server pacer, 128 kbps stereo Opus (16 KB/s), 1 idle refinement frame after 250 ms.
   - **Low (`low`, WAN ≤ 200 KB/s):** 15 fps max capture/encode (0 ms wait on first frame after idle), 1.05 Mbps H.264 average (`DataRateLimits` 1.2×/1 s), 155 KB/s server token-bucket byte pacer (64 KB burst), 3 frames in flight, 48 kbps stereo Opus (6 KB/s), 1 idle refinement frame after 300 ms. Worst-case sustained payload (155 + 6 = 161 KB/s) stays below 200 KB/s on the wire including RDPGFX/Wave2/TLS/TCP framing.
   - Clients negotiating `<32bpp` automatically fall back to legacy `BitmapUpdate` per connection (`freerdp-3.33.1-mstsc-color-depth.patch`), eliminating the manual Classic mode toggle.
   - Remove RemoteFX Progressive, mid-session codec switching, AVC444, and separate 1.4/2.0/4.0 Mbps presets from both the server and UI.

2. **Fix low-latency H.264 signaling at the root (`freerdp-3.33.1-h264-streaming.patch`):**
   - Rewrite VideoToolbox SPS NAL units in `libfreerdp/codec/h264_sps_vui.h` to set `vui_parameters_present_flag = 1`, `bitstream_restriction_flag = 1`, `max_num_reorder_frames = 0`, and `max_dec_frame_buffering = MAX(1, max_num_ref_frames)` while preserving any existing VUI fields.
   - Set `MaxKeyFrameInterval = 0` (no forced periodic IDR over TCP) and pair `AverageBitRate` with 1-second `DataRateLimits` (1.2× avg). Do **not** enable `kVTVideoEncoderSpecification_EnableLowLatencyRateControl`: empirical testing on Apple Silicon showed it forces VideoToolbox onto the CPU software H.264 encoder (`hardware no`) and drops frames after keyframes, whereas hardware VT with `AverageBitRate` + `DataRateLimits` keeps `hardware yes`, drops 0 frames, reduces IDR size by ~31%, and holds sustained bitrate tightly.
   - Replace the 5–10 frame drain burst with a single idle refinement frame (`MACREMOTE_AVC_REFINE_FRAMES=0..10` remains available as an environment override for real `mstsc` A/B validation).

3. **Real server-side 1 Hz telemetry (`rdp-session.json`):**
   - Track exact outbound video bytes/s, audio bytes/s, sent FPS, in-flight depth, and RDPGFX frame-ACK RTT p50/p95 from monotonic send/ACK timestamps. Report absent ACK RTT as omitted/unavailable rather than estimated.

4. **Streamlined menu bar UX:**
   - Replace the flat 14-row list with grouped native cards: Header with instant Start/Stop switch, Session card (connection status, live telemetry, High/Low segmented control, integrated remote audio), Display card (contextual apply/install button shown only when actionable), and collapsed-by-default Server settings disclosure.

## Consequences

- FreeRDP patch count drops from 19 to 15, deleting ~500 lines of codec-switch and bitrate-preset plumbing.
- High ↔ Low switching takes effect live on the next video frame and 20 ms Opus packet with zero disconnect, saved per device in `display-by-client.json` (`bandwidthMode`).
- Real Windows `mstsc` verification (LAN latency, 200 KB/s + 80 ms WAN throughput/smoothness, and final-frame presentation with `MACREMOTE_AVC_REFINE_FRAMES=0` vs `1`) remains required before promoting to a public release.
