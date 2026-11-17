# MacRemote release acceptance checklist

Status: **v0.1.0 initial Ad-hoc preview for Apple Silicon and Intel**. Developer ID notarization and broader interoperability validation remain future milestones. Updated 2026-11-15.

## Validated on the Mac

- [x] FreeRDP 3.33.1 Shadow directly linked and macOS ScreenCaptureKit preserved.
- [x] Native C server and app-owned AppKit NSStatusItem directly opening SwiftUI settings, macOS 14+ Apple Silicon development build.
- [x] Original standalone RDP pairing/SAM modules removed; no custom RDP account or password stored.
- [x] Default all-interface bind (port 3389, persistent menu setting), full keyboard/mouse and no MacRemote client cap; optional IP/port.
- [x] TLS + upstream macOS Shadow PAM path; loopback RDP client with invalid username is denied and receives no desktop image.
- [x] CLI/CTest groups pass, App builds and existing personal code-signing identity verifies.
- [x] FreeRDP 3.33.1 PEM logging false positive fixed; existing RDP certificate fingerprint retained.
- [x] Launching the App alone does not open an RDP listener; the native icon directly opens the SwiftUI settings popover and is a normal registered App status item.

## Must verify before calling it daily-use Beta

- [x] **Mac account login in Windows mstsc and reconnect** tested 2026-11-16 without exposing credentials; actual TLS certificate-trust UX still needs separate verification ([full regression](qa/2026-11-16-full-regression.md)).
- [ ] Karabiner-native remote input, Insert/Help, extended keys, modifiers, mouse and key-up behavior.
- [ ] CLIPRDR bidirectional clipboard, Windows CRLF/Mac LF and WeChat IME duplicate-paste corrections.
- [ ] Reconnect/soak testing, sleep/wake and display changes.

## Post-Beta performance work (not a Classic-mode release gate)

- [ ] Resolve AVC420/AVC444 Windows graphics negotiation and 1/2/5 Mbps adaptation.
- [ ] Measure actual codec, bytes/sec, FPS and RTT for performance profiling.

## Required for portable public release

- [ ] Correct TLS certificate validation/trust UX when using a Mac account password over LAN/WAN.
- [ ] Desktop session/user authorization tests, invalid password handling and auth robustness.
- [x] Bundle pinned FreeRDP, codec/crypto dependencies and dynamic
      OpenSSL provider, verified after deleting the separate checkout.
- [x] Ad-hoc build disables FFmpeg/SWScale and bundles third-party license texts; package audit refuses FFmpeg/x264/x265 libraries. Verify the actual dependency graph for each release architecture.
- [ ] Developer ID signature, notarization and clean-machine install; ad-hoc preview DMG is a separate opt-in distribution.
- [x] Project LICENSE and third-party notices are included and checked during packaging.

## Evidence

- [Approved native-login decision](adr/0007-native-macos-login.md).
- [Local build and test guide](m2/README.md).
- [Historical M1 comparison](../benchmarks/m1/e2e/REPORT.md).

Previous extra pairing constraints are documented only as a [superseded historical ADR](adr/0006-local-pairing.md).
