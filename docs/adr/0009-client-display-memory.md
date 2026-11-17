# ADR-0009 — Per-client remembered macOS display mode

Status: implemented; Windows RDP acceptance pending.

MacRemote no longer derives a macOS resolution from the Windows client's requested desktop dimensions.

- On the first RDP connection from a source computer without a saved mode, keep the existing macOS display mode.
- While connected, select the desired mode in macOS Displays or BetterDisplay. A change stable for three seconds, after a five-second connection grace period, is saved for that source computer.
- On subsequent connections, restore the saved mode only if that exact logical and backing-pixel combination is still supported. The saved refresh rate is preferred; no substitute size is calculated.
- On disconnect, MacRemote does not change the display. Hammerspoon handles UU and local sessions.
- The source key is the normalized RDP client hostname, with peer IP fallback, hashed with SHA-256. Old client-request-driven preferences are ignored.
- Stored fields: `logicalWidth`, `logicalHeight`, `renderWidth`, `renderHeight`, `refreshHz`.
- CoreGraphics `CGDisplayModeGetWidth/Height` are logical desktop dimensions. `CGDisplayModeGetPixelWidth/Height` are the HiDPI backing dimensions. Physical panel pixel size is independent of both. RDP Shadow currently captures and transmits logical-size frames.
- The previous geometry guard delays remote pointer events while RDP client, Shadow surface and current display dimensions disagree. Real-client pointer-offset tests are still required.

Independent output mode: see ADR-0010. It supersedes the old statement that Shadow always transports logical-size frames and replaces the mouse gate with a bound-aware geometry check.
