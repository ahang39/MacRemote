# Live RDPGFX codec switching — 2026-11-19

## Core requirement and competing hypotheses

The purpose is to compare actual Windows input-to-visible latency and image stability between codecs without reconnecting. Live switching is only a means. The earlier 12 Mbps trial corrupted the screen and had no perceived latency improvement. The hypothesis is that Progressive's far quicker sparse dirty-region encoding may reduce typing latency; the counter-hypothesis is that Windows compositor, ACK pacing and capture dominate the visible delay.

The 2304x1296 offline benchmark showed median text-only encoding of 7.5 ms H.264 vs 0.2 ms Progressive, but whole-screen scrolling 8.3 vs 19.4 ms, Progressive ~29 times more encoded bytes for the synthetic scroll scene. This is not evidence of an end-to-end latency improvement. See 2026-11-19-lan-progressive-research.md.

## Protocol facts and source evidence

Microsoft MS-RDPEGFX negotiates capabilities at connection. AVC420 and Progressive use different graphics PDUs, with explicit codec IDs in the wire surface command; Progressive PDU2 has a separately managed codec context. Switching negotiated codecs does not inherently require a new TLS/PAM authenticated RDP session. A Progressive context requires DeleteEncodingContext on change, and surfaces are managed by CreateSurface/DeleteSurface and MapSurfaceToOutput. No assertion of mstsc compatibility without actual client evidence.

The FreeRDP 3.33.1 Shadow server has a single graphics send loop and frame acknowledgements. This allows transaction-like handling: prepare replacement; wait for old ACKs; replace context/surface on the graphics thread; redraw full first picture; commit effective state. It resembles blue-green state management and media-codec reconfiguration, but is bounded by RDPGFX's exact surface and context semantics.

## Implemented local prototype

- Capability confirmation allows AVC420 and Progressive in one RDPGFX session; Classic is restart-only.
- Existing per-client JSON profile uses graphicsCodec h264 or balanced and the watcher. Only the primary client's live preference is applied. A separate atomic PID/key-scoped rdp-graphics-effective.json reports selected server codec (result 0), unavailable (1), or 2.5s ACK timeout (2).
- FreeRDP patch patches/freerdp-3.33.1-live-graphics-switch.patch: process switches only on client graphics send thread; refuse unnegotiated codec; freeze damage while waiting for prior ACKs, timeout to original mode without disconnect; prepare new encoder; dispose old codec independently; when leaving Progressive send RDPGFX_DELETE_ENCODING_CONTEXT for surface/context 0, then delete/create/map surface; preserve monotonically increasing frame IDs; force full new image. If initial session selects Progressive, start directly with Progressive rather than briefly sending AVC420 and switching.
- Progressive wire surface has full-frame dimensions, but its compressor is passed the real dirty rectangle. This preserves the intended efficiency for small typing updates, unlike the prior full-region Progressive path.
- Existing TLS/PAM, input, audio, clipboard, port and network configuration unaffected. Existing 8/12 Mbps ACK patch not included.
- SwiftUI menu requests live H.264/Progressive modes with effective/rejected status. Choice does not change the global default for other clients. Classic cannot hot switch.

## Verified vs unverified

PASS: Full arm64 app build, 17/17 native CTest, Swift preference and display tests, Progressive partial-dirty-region moving-window roundtrip, alternate codec preference persistence/failover/invalid values, standalone app signing and bundled deps check. Isolated 127.0.0.1 random-port start of H.264 and Progressive without touching live port 3389 also passes.

NOT VERIFIED: Actual authenticated mstsc in-session switch, client compositor presentation/latency, frame corruption during switch, video/scroll workloads, server/client error recovery on mid-commit fault. A successful codec test cannot replace these. The build is staged and NOT installed, committed, pushed, or released. Do not auto-deploy.

## Required independent acceptance evidence

Use same Windows mstsc client, 1920x1080 and 2304x1296, identical synthetic editor/scroll/window movements. Do at least 10 repeated H.264→Progressive→H.264 switches within one authenticated session and three fresh-session replicas. Verify same TCP connection tuple, no new RDP logon, real Surface1/Surface2 codec IDs, ordered DeleteEncodingContext/DeleteSurface/CreateSurface PDUs, no stalled ACK frame IDs, stable final text frame after 1–2s, no disconnection or screen corruption. Record actual Windows timestamped input→GDI visible p50/p95, first scroll response, encoded payload, and actual CPU/ACK/queue values. Compare across modes using paired same-session samples; explicitly distinguish latency and image-quality findings from source encoder numbers. Do not retain real screen contents, passwords or private keys.

## Primary sources

- Microsoft [MS-RDPEGFX]: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/
- Microsoft [MS-RDPRFX]: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdprfx/
- FreeRDP 3.33.1 pinned source: server/shadow/shadow_client.c, shadow_encoder.c and channels/rdpgfx/server/rdpgfx_main.c
- Apple VideoToolbox documentation: https://developer.apple.com/documentation/videotoolbox/vtcompressionsession
