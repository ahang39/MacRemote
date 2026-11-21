# MacRemote headless fallback — implementation and verification

Date: 2026-11-19
State: source implementation, signed standalone App built, not installed and not released.

## Behavior implemented
- MacRemote GUI starts the native server with --headless. Direct CLI users enable it explicitly with the same option. Physical and registered third-party screens, including BetterDisplay's virtual displays, take priority and are never created/released by MacRemote.
- If there are zero active AND zero online displays, the RDP server in the logged-in GUI session creates one CGVirtualDisplay. Resolution comes from the existing display-output.conf (fallback 1920x1080), color primaries use Rec.709/D65, 60 Hz non-HiDPI, stable vendor/product/serial. No privileged daemon, display driver, third-party dependency or BetterDisplay configuration changes.
- Runtime dispatch uses private CoreGraphics class discovery, then keeps the allocated display object strongly retained until the RDP server exits. Initialization occurs before Shadow enumerates displays. The service loop checks every 2 seconds for a removed screen or a returned existing screen. An active RDP client is never intentionally deprived of its owned screen. When an alternate screen is active and all clients disconnect, only the MacRemote-owned object is released.
- Per-device output size remains saved. Native macOS display mode restoration via device_display.m and the menu's DisplayModeService is suppressed for the recognized CoreGraphics virtual model marker and MacRemote's virtual vendor/product pair, to avoid overwriting BetterDisplay's modes. Physical monitor behavior is unchanged.
- Pointer geometry uses Shadow's selected CG display index, rather than always CGMainDisplayID.

## Evidence and tests
- Exact macOS machine runtime: Apple M4, macOS 27.2.1; all four CGVirtualDisplay family classes plus all 20 Objective-C setters/getters/methods used by our code exist. Read-only Objective-C selector probe performed, no display creation.
- Current baseline: physical AOC monitor online, BetterDisplay installed but not active in process list, the installed MacRemote 3389 service running independently.
- Separate loopback startup of the **new signed candidate**, both --gfx h264 and --gfx balanced with --headless, succeeded on ephemeral 127.0.0.1 ports. CG active and online inventory before and after both runs was identical. Neither isolated process created a virtual display because the actual physical monitor existed.
- Full native 21/21 CTest, GUI Swift and configuration tests, strict signature and dependency bundle audit PASS. Includes production-linked headless-provider-noop and headless-display-policy tests. Project git diff --check PASS.
- Candidate: .build/output/MacRemote-20261119T141302Z.app, signed with Ahang Personal Code Signing.

## Not yet proven
- Actual CGVirtualDisplay initialization while absolutely no physical/virtual display is registered; this intentionally was **not** invoked on the running Mac because it would change macOS display topology and could interrupt an active remote session.
- After creation: ScreenCaptureKit enumerating/streaming that display, Windows mstsc visual output, mouse coordinates, reconnection, reboot/wake, and BetterDisplay appearing mid-session. These require real headless hardware and client observation. Do not equate selectors existing or unit-test success with real zero-monitor end-to-end success.

## Independent acceptance check
On a Mac with a logged-in graphical user session and screen capture permission: capture before state of active and online display IDs; ensure there are none; start new signed candidate with --headless on an isolated port; confirm its own vendor/product display appears in CG and SCShareableContent and yields frames; connect Windows mstsc and verify readable desktop, pointer drag, input, audio and reconnect; stop process, confirm only owned display disappears. Repeat with a BetterDisplay-created display already active: zero creation by MacRemote and no persistent mode change. On physical monitor, verify pre/post display mode and inventory unchanged.

## Sources
Chromium virtual display controller: https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm
BetterDisplay virtual screen guide: https://betterdisplay.pro/guide/interface-reference/settings/displays/virtual-screen/
Project architecture: docs/adr/0011-headless-display-coexistence.md
