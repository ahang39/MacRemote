# ADR-0011 — Headless display ownership and BetterDisplay coexistence

Status: IMPLEMENTED IN SOURCE, awaiting real monitor-free ScreenCaptureKit/mstsc acceptance. Not deployed.
Date: 2026-11-19.

## Requirement

Allow standard Windows mstsc to capture a real Mac GUI session after the physical display is unplugged. Guarantee that normal MacRemote physical-display use and the configuration and lifecycle of BetterDisplay, Apple Screen Sharing or other display owners are unaffected.

A virtual monitor is not the goal; a *stable capturable display* is. Existing monitors created by others are also legitimate screen sources. A registered CG display and a capturable SCDisplay are distinct observations.

## Primary-source findings

1. Existing MacRemote code: pinned FreeRDP Shadow mac_shadow_list_displays uses CGGetActiveDisplayList, and mac_capture_find_display uses ScreenCaptureKit SCShareableContent and its SCDisplay IDs. mac_shadow_capture_restart explicitly fails on inactive or sleeping displays. The app requires screen capture permission and an already logged-in Aqua user session (docs/ARCHITECTURE.md).
2. **Existing risk:** src/display/device_display.m::mr_device_display_restore and apps/macos/DisplayModeService.swift::applyPersistentMode both use CGMainDisplayID and can write modes permanently through CGCompleteDisplayConfiguration. If BetterDisplay creates the primary desktop, a saved MacRemote per-device HiDPI preference can modify it. src/macremote.c::macremote_pointer_ready also obtains CGMainDisplayID bounds even if Shadow selectedMonitor differs. These implicit-primary assumptions must be corrected before virtual screen support.
3. BetterDisplay's official virtual-screen guide documents its own identity (serial/vendor/model), associations, automatic connection/disconnection and saved layouts. Its startup restoration, lock and reconnect settings are not under MacRemote ownership.
4. CGVirtualDisplay is an undocumented/private macOS interface. macrdp and other implementations show feasibility but not a compatibility guarantee for this Mac and macOS release. No preboot/FileVault login, loginwindow control or second independent user desktop is promised.

## Decision: borrow first, own only as opt-in fallback

- If an existing currently selected physical screen is usable: **leave all existing behavior unchanged**.
- If a third-party virtual display is registered and capturable: **borrow it read-only** as a graphics source. Do not change its macOS resolution, primary role, mirroring, identity, origin, lifecycle, HDR or connection state.
- If a third-party display is registered but asleep/unavailable in ScreenCaptureKit: **wait/report unavailability**. Never interpret transient capture failure as proof of zero screens, and never delete the unknown display.
- If no display is online, a logged-in GUI user session exists, Screen Recording is granted and headless fallback is enabled: create exactly one MacRemote-owned virtual display using runtime-resolved CGVirtualDisplay with stable identity and the saved RDP output resolution. Wait for CoreGraphics registration before initializing FreeRDP Shadow. Actual ScreenCaptureKit client-frame delivery still needs a monitor-free test.
- If BetterDisplay creates an alternate screen after that: keep the MacRemote-owned screen while a Windows client depends on it; when disconnected and the foreign screen is stably capturable, release **only MacRemote's owned** object. Do not disable/recreate foreign screens.
- The CLI fallback is opt-in (--headless); the menu bar app enables this no-screen fallback by default. When a physical or third-party screen exists, it does nothing. Never start BetterDisplay, change its settings, or run a privileged display-reset helper.
- For unknown/borrowed displays, permanently changing macOS modes is forbidden. RDP output resolution is a separate stream-setting operation; for owned virtual screens, change its descriptor/settings with a controlled replacement, not the global persistent display mode.
- The capture target, RDP geometry and pointer/cursor mapping must use the **same explicitly selected CGDirectDisplayID**, rather than assuming CGMainDisplayID.
- Virtual display ownership is a resource lease: initialize before capture, hold until no client depends on it, perform make-before-break handoff only after replacement is ready. Use bounded retries and bounded identities to avoid WindowServer registry churn.
- Under FileVault preboot or missing user GUI session, report not ready. No insecure auto-login or permission bypass.

## Implemented code

- src/display/headless_virtual.m and .h: actual, runtime-resolved CGVirtualDisplay descriptor/mode/settings bridge. Creates a 60 Hz, non-HiDPI virtual monitor at the saved RDP output size (default 1920x1080) only if CG has zero active **and** zero online screens, and retains the object until released. No external display references are retained or released.
- src/macremote.c: --headless flag, creation before FreeRDP Shadow initialization, two-second poll for unplug and external-screen return, and teardown after Shadow. Existing physical-screen CLI defaults remain unchanged.
- apps/macos/ServerController.swift: includes --headless in the standard server launch; screen-present path remains no-op.
- src/display/device_display.m and apps/macos/DisplayModeService.swift: avoid persistent mode writes to CoreGraphics virtual displays identified by the virtual model marker or MacRemote's own vendor/product. Other native display mode behavior remains unchanged.
- src/macremote.c: pointer geometry uses the same selected CG display index as Shadow (rather than assuming it is the main screen).
- src/display/headless_display_policy.h: pure policy used for the creation decision; tests/test_headless_display_policy.c and tests/test_headless_virtual.m verify opt-in/ownership boundaries and real private API backend with no display creation.
- Source signed standalone app was built and the no-op-on-real-monitor path tested using a separate loopback port. Installed MacRemote, BetterDisplay and active 3389 have not been changed.

A CGVirtualDisplay can only be created in a logged-in Aqua session. The user-facing claim is conditional on real ScreenCaptureKit and Windows mstsc verification on a monitor-free machine.

## Independent acceptance tests still needed

1. Read-only probe confirmed all four CGVirtualDisplay classes and every setter/getter invoked by the implementation are available on this M4/macOS 27.2.1. Separate loopback server startup with --headless while one physical display is connected caused **no change to the CG active/online display list**.
2. Real zero-monitor test remains: CG registration, actual ScreenCaptureKit SCDisplay and frames, correct RDP Windows mstsc image and input, owned virtual display removal on exit. Do not unplug the active RDP host solely for testing.
4. Compatibility matrix: physical only; physical + BetterDisplay; BetterDisplay only; no display opt-in off/on; BetterDisplay starts/stops before and during an RDP session; Screen Sharing high-performance virtual display; sleeping display; missing TCC; no GUI; 10 re-connects; 60-minute idle, hotplug and sleep/wake.
5. Windows mstsc proves unchanged auth, screen, input, text HiDPI, audio and clipboard in existing flows; owner release does not break a connected session; borrowed screen settings and layout are byte-for-byte unchanged. Compare initial latency/CPU with baseline and record actual image/pointer consistency.
6. Only after passing tests allow optional auto-recovery. A hardware HDMI dummy and pre-existing BetterDisplay virtual screen remain user-controlled alternatives.

## References (reviewed 2026-11-19)

- macOS ScreenCaptureKit SCShareableContent and SCDisplay: https://developer.apple.com/documentation/screencapturekit/scshareablecontent
- BetterDisplay virtual display identity, connection and modes: https://betterdisplay.pro/guide/interface-reference/settings/displays/virtual-screen/
- BetterDisplay layout restore/reconnect/lock automation: https://betterdisplay.pro/guide/interface-reference/settings/displays/overview/advanced-virtual-screen-settings/
- Comparative CGVirtualDisplay virtual desktop: https://github.com/clintcan/macrdp/blob/main/docs/configuration.md
- Separate ownership/lifetime reference (not a dependency): https://github.com/kristofferaas/what-screen
