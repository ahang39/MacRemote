# mstsc 16bpp: half-black desktop and duplicated regions — 2026-11-20

## Original independent evidence
User Windows screenshot after native Windows credential login: only upper half of the remote session was painted; the lower half was black with duplicated/misaligned upper-window regions.
Server log: Client 192.0.2.10 activated at 1920x1080@16; server initially disabled RDPGFX but logged a FreeRDP NSCodec initialization. macOS capture output itself is 1920x1080.

## Root cause investigated
Disabling RDPGFX only does not disable FreeRDP shadow_client_send_surface_update's secondary SurfaceBits path. Even for 16bpp negotiated desktop, this path can select NSCodec/RemoteFX and sets its bitmap payload bpp to 32. This mismatches the 16bpp legacy session and is a plausible cause of image misregistration, but the Windows decoder reaction has not been independently recorded.

## Minimal source fix
In patches/freerdp-3.33.1-mstsc-color-depth.patch, for clients negotiating depth below 32, bypass both the RDPGFX and 32bpp NSCodec/RemoteFX SurfaceBits branches and let FreeRDP send actual 16bpp BitmapUpdate frames with interleaved RGB565 compression. 32bpp still retains accelerated H264, Progressive, in-session codec switch and per-device preferences. No change to macOS display, BetterDisplay or headless operation.
The small color-depth helper now provides mr_shadow_use_surface_bits and the CTest checks depth and supported flag combinations.
Added tests/test_legacy_bitmap_16bpp_roundtrip.c, exercising the production FreeRDP interleaved compressor and decompressor on 32bpp capture tiles at the top/middle/bottom of a 1920x1080 surface, including the 56-pixel bottom tile. It checks output locations and actual 16bpp pixel color within upstream codec quantization tolerances.

## Verified
Pinned patch application PASS, 24/24 CTest PASS, Swift tests, signed bundled App PASS; isolated H264 and Classic launch PASS.
Candidate: .build/output/MacRemote-20261120T023341Z.app; server binary SHA256 4a81dd52fa63e8093234c6d99d5d539c0802a4388ec5d7bdb435b6c94633ac5d.
Old signed app saved to ~/Library/Caches/MacRemote/product/MacRemote-before-16bpp-bitmap-20261120.app.
Installed /Applications/MacRemote.app signed and verified; GUI PID48873, RDP PID48907, IPv4/IPv6 TCP3389 listening, h264 default and headless preserved.

## Remaining acceptance
Real Windows mstsc still needs to reconnect and prove full-height 16bpp image with no misregistration. A Windows-side successful rendered frame is not established merely by 24/24 code tests. The previously working 32bpp saved RDP profile remains an alternative. No git commit/push/release.
