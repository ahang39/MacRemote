# Remotr comparison: cold first-paint and capture lifecycle audit

Date: 2026-11-19
Scope: MacRemote cold connection / initial broken picture / graphics recovery. Deliberately excludes NLA, commercial authorization, clipboard feature parity or adding alternative graphics protocols.

## Rewritten engineering task

Verify and fix the actual source of first-connect visible corruption and delayed interactive readiness in the **same Windows mstsc session**. Evaluate vendor issue reports as hypotheses only. Preserve macOS/BettterDisplay display ownership, the deployed 3389 process, and existing H.264/Progressive semantics. Prove a fix using RDP protocol correctness, deterministic state transition tests and an independent Windows presentation A/B, not marketing claims.

## Primary materials and attribution

1. Remotr's own changelog, https://remotr.app/changelog . Published 2026-10-19 v0.9.21 says it improved initial 4K RemoteFX fragmented tiles, puts complete repaints in one frame when possible, and tracks initial-display submission per monitor. Published 2026-09-15 v0.8.08 says it stopped outdated capture tasks from interrupting new display streams on resize or reconnection. The claims describe Remotr's shipped changes; internal source and quantitative A/B are not public.
2. Microsoft protocol [MS-RDPEGFX], revision 19.0 (2026-05-11), https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/ ; specifically RDPGFX_START_FRAME and END_FRAME and requirements that WIRE_TO_SURFACE belongs to a logical frame. These define protocol obligations, but matching them is not proof of timely client presentation.
3. Pinned FreeRDP 3.33.1 source and our actual patchset at .build/sources/FreeRDP-3.33.1-0ade2d5f628e. In server/shadow/shadow_client.c, shadow_client_send_progressive calls SurfaceFrameCommand with start/end frame IDs. In channels/rdpgfx/server/rdpgfx_main.c, rdpgfx_send_surface_frame_command serializes STARTFRAME, WIRETOSURFACE and ENDFRAME into a **single** segmented virtual-channel payload. Therefore the tempting hypothesis 'MacRemote is missing atomic logical frames' is **false on source examination**. Do not build another frame protocol wrapper.
4. Real deployed 3389 logs ~/Library/Logs/MacRemote/server.log: the 20:05:35 session initially announced 1920x1080 and changed to 2304x1296; mac_shadow_subsystem_thread first completed capture at 20:05:36.146, but mac_shadow_displays_changed ran at 20:05:36.168 (22ms later) and created a second SCStream around 20:05:36.185. The display-change code reported 2304x1296 before AND after. This is observed recreation, **not yet proof** that the re-create is unnecessary or that a stale callback caused the user's visual artifact. GFX caps were confirmed 20:05:37.498; first H.264 frame sent 20:05:37.525; first frame ACK at 20:05:38.156 (631ms from send to ACK); earlier logging indicated 8 frames in flight before ACK. Frame ACK is not Windows physical-present timestamp. No client-side visual sample was taken.
5. Current macOS capture source server/shadow/Mac/mac_capture.m uses SCStream delegates and async start/stop. Each MacCaptureOutput stored a shared macShadowSubsystem pointer as callback context. A stream that is already retired can call didStopWithError after a new capture starts, and the callback would SetEvent(mac->lostEvent), making the subsystem treat the new stream as lost. Likewise, old screen/audio buffers can reach the same shared subsystem. This is a **confirmed lifecycle ownership gap in source**, but occurrence during the recorded session is **unverified**.
6. Cross-domain reference: cancel/replace of asynchronous media consumers resembles seek-generation epochs and stale-response isolation in concurrent services. The remedy is an epoch token carried by one capture instance, checked by the receiver, rather than global locking or increasing retry timers.

## Minimal change implemented and verified

- Added pinned FreeRDP patch patches/freerdp-3.33.1-mac-capture-generation.patch. One atomic uint64 generation per macShadowSubsystem, incremented before an intentional SCStream retire/replace. The created stream stores its generation in its own config. Delegate video/audio callbacks check current generation before forwarding; onFrame and onStopped carry generation to the subscriber, which validates again before updating current frame or lostEvent. The existing Opus receiver ABI is preserved (its callback is filtered at the producer).
- No changes to RDPEGFX frame encoding, STARTFRAME/ENDFRAME, bitrate, startup frame pacing, RDP surface reconstruction, TCC, display modes, BetterDisplay state, or service-control behavior.
- Deterministic production-helper regression tests/test_capture_generation.c specifically exercises old callback accepted before retirement, rejected after retirement, new valid after replacement, and rejected after disconnect. Asserts are active in Release even with -DNDEBUG.
- Signed development build .build/output/MacRemote-20261119T145539Z.app (Ahang Personal Code Signing), 22/22 native CTest PASS, Swift UI/preferences tests PASS, strict codesign PASS. Two separate ephemeral 127.0.0.1 startup tests with --gfx h264 and --gfx balanced and --headless PASS. Not deployed to /Applications/MacRemote.app, port 3389 unchanged, no git commit/push/Release.

## Independent validation still required

- On a real Windows mstsc client at a fixed target resolution, capture 10 fresh connections for baseline and revised app separately; timestamp client connect/TLS activation, capture start, display change and source generation, GFX channel/caps, CREATE/MAP_SURFACE, first complete frame ID, first ACK, and actual first stable client presentation. Prove no corruption at 1x/HiDPI, typed cursor and terminal text intact. Report p50/p95 from repeat runs, not a single lucky first paint.
- Change physical display mode or dynamically resize across sessions with a separate test instance: confirm old capture generation's delayed onStopped/video cannot mark current stream lost, and current spontaneous stop still initiates recovery.
- Compare H.264 and Progressive separately because the earlier 20:05 event initially negotiated H.264. The 160% Progressive CPU during scaled full-frame damage is a different demonstrated mechanism, already addressed in a separate un-deployed patch, not causal proof of the cold-start artifact.
- An offline unit test plus loopback listener does not verify actual Windows compositor display; visible startup corruption remains unresolved until that A/B is obtained. If it remains, next probe image content completeness, display-mode transitions, AVCC decoder warm-up and 2-frame initial ACK policy before any new code.

## Practical priority

(1) Prove and stabilize capture stream lifecycle; (2) measure first complete Windows picture and ACK/frame pacing; (3) only then consider changing first-frame surface batching. Preserve best existing behavior and no third-party display mutations.

## Extra references

Apple asynchronous SCStreamDelegate stop: https://developer.apple.com/documentation/screencapturekit/scstreamdelegate
FreeRDP GFX implementation: https://github.com/FreeRDP/FreeRDP/blob/3.33.1/channels/rdpgfx/server/rdpgfx_main.c
Microsoft RDP interoperability tests: https://github.com/microsoft/WindowsProtocolTestSuites (the listed RDP client GFX scenarios are NOT a direct drop-in validation of MacRemote as a server).
