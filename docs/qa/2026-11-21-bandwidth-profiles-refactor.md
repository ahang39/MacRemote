# Bandwidth-Profile Refactor and Low-Latency H.264 Verification · 2026-11-21

## Scope
Consolidated MacRemote's graphics/bitrate plumbing into a single hardware-accelerated H.264/AVC420 pipeline with two live per-device bandwidth modes (**High · LAN** and **Low · ≤200 KB/s**), rewritten low-latency SPS VUI headers, 1 Hz real telemetry (`rdp-session.json`), dynamic 128/48 kbps stereo Opus audio, and a redesigned grouped SwiftUI menu bar popover. See [ADR-0012](../adr/0012-bandwidth-profiles-and-low-latency-h264.md).

## Automated Build and Tests
- **Signed candidate:** `.build/output/MacRemote-20261121T044724Z.app` (signed with `Ahang Personal Code Signing`; `codesign --verify --deep --strict` PASS; `/Applications/MacRemote.app` untouched).
- **Native CTest:** **23 / 23 PASS** (`11.77 s`), including:
  - `h264-sps-vui`: synthetic Baseline/High/existing-VUI/malformed SPS cases + real VideoToolbox 1920×1080 and 2304×1296 `avc420_compress` → VUI verification → `avc420_decompress` roundtrip + `avc420_repeat`.
  - `stream-profile`: High/Low budgets, worst-case Low wire budget (<200 KB/s with 15% framing margin), token-bucket pacer burst & steady-state cap, FPS gate, and ACK RTT p50/p95.
  - `client-preferences-audio`: per-device `bandwidthMode`, live 128 kbps (320 B/20 ms) ↔ 48 kbps (120 B/20 ms) Opus encoding & decoding, strict mute, failover, and `rdp-session.json` telemetry.
  - `graphics-capability-modes`, `startup-ack-pacing`, `scaled-dirty-tiles`, `rdp-color-depth-compat`, `cli-options`, clipboard, Karabiner, display and headless regressions.
- **Swift regressions:** **4 / 4 PASS** (`test_port_settings`, `test_bandwidth_mode_settings`, `test_display_output_settings`, `test_server_restart_policy`).
- **Runtime audit:** `bundle-runtime.py` validated all executables, embedded FreeRDP/Opus/OpenSSL dylibs, and OpenSSL legacy provider with `macos 14.0` deployment target.

## Local VideoToolbox Hardware Encoder Measurements
Measured on local Apple Silicon host via `tools/bench-stream-profiles.c` (synthetic syntax-highlighted code desktop, hardware VideoToolbox `UsingHardwareAcceleratedVideoEncoder = true`, 0 dropped frames). These are local encoder + pacer measurements, not end-to-end Windows `mstsc` presentation latency.

| Workload | IDR Keyframe | 10 Typing Edits + 1 Refine | 5 s Scroll (FPS / IDRs) | Video + Audio Payload | Encode p50 / p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1920×1080 High | 132.4 KB (23.7 ms) | 134.0 KB + 3.5 KB (5.8 ms) | 62.6 fps (313 f / 2 IDR) | 869.8 KB/s | 8.4 / 15.3 ms |
| 1920×1080 Low | 101.8 KB (29.9 ms) | 18.7 KB + 1.1 KB (16.5 ms) | 15.4 fps (77 f / 0 IDR) | 113.7 KB/s | 10.8 / 15.4 ms |
| 2304×1296 High | 182.1 KB (26.2 ms) | 173.9 KB + 1.1 KB (10.8 ms) | 62.6 fps (313 f / 2 IDR) | 856.7 KB/s | 9.9 / 20.1 ms |
| 2304×1296 Low | 148.9 KB (23.1 ms) | 49.3 KB + 0.8 KB (11.0 ms) | 15.4 fps (77 f / 0 IDR) | 98.1 KB/s | 9.3 / 20.0 ms |

Empirical VideoToolbox note: enabling `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` forced Apple Silicon VideoToolbox onto its CPU software encoder (`hardware no`) and caused frame drops after keyframes; leaving it unset while pairing `AverageBitRate` with 1 s `DataRateLimits` kept hardware encoding active with zero dropped frames and ~31% smaller IDRs.

## Independent Bitstream Verification
Inspected the dumped 2304×1296 Low-mode raw H.264 bitstream with `ffmpeg -bsf:v trace_headers`:
- Zero decode/parse errors
- `profile_idc = 66`, `level_idc = 50`, `max_num_ref_frames = 1`
- `vui_parameters_present_flag = 1`, `bitstream_restriction_flag = 1`
- `max_num_reorder_frames = 0`, `max_dec_frame_buffering = 1`

## Outstanding Real Windows `mstsc` Acceptance (N/A Locally)
1. **LAN High mode:** verify typing p50/p95, 60 fps scrolling smoothness, last-frame stability, and live switch to Low mode without disconnecting.
2. **WAN Low mode (200 KB/s cap + 80 ms RTT / HY2):** verify total wire bandwidth stays ≤ 200 KB/s during continuous scrolling + active audio, and verify typing responsiveness and text legibility.
3. **Idle refinement A/B:** compare default `MACREMOTE_AVC_REFINE_FRAMES=1` against `MACREMOTE_AVC_REFINE_FRAMES=0` on real `mstsc` to confirm zero held final frames after typing/scrolling stops.
4. **16-bit color client & audio:** verify 16bpp fallback banner in UI and live 128 kbps ↔ 48 kbps Opus audio playback on `mstsc`.
