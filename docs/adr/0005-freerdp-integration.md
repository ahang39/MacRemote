# ADR-0005: Integrate FreeRDP Shadow directly

- Status: **Accepted — M2 implementation foundation**
- Date: 2026-11-13
- Depends on: [ADR-0001](0001-protocol-stack.md)

## Decision

MacRemote directly links FreeRDP 3.33.1 Shadow with macOS ScreenCaptureKit. Current authentication uses macOS login credentials via TLS+PAM rather than separate NLA/SAM credentials; see [ADR-0007](0007-native-macos-login.md).

The project owns the host CLI, minimal configuration policy, macOS authorization and permissions experience, native input strategy, clipboard fidelity and measurable telemetry. Our own product license remains **undecided**. FreeRDP is Apache-2.0; shipping a bundle later requires preserving all applicable third-party notices.

## Why this base

- FreeRDP: macOS Shadow capture implemented upstream; builds and completes the M1 loopback NLA + graphics benchmark. Its ZGFX decompression significantly outperformed IronRDP in identical synthetic compressed-data tests, but that test cannot decide whole-desktop FPS.
- IronRDP: solid Rust-first design, extensible server API, but requires a new macOS capture/product layer and loses E1 input scancode flags at the tested high-level boundary.
- xrdp/libxrdp: primarily Linux/Xorg integration. RDPonMAC demonstrates macOS feasibility but not a more complete general engine.
- GNOME Remote Desktop: uses FreeRDP and depends on Linux PipeWire/Mutter.
- macrdp projects and ClawTank: product-level competitors built largely around IronRDP; useful benchmarks and UX references, not a superior independent protocol foundation.
- Non-RDP systems such as Sunshine/Moonlight and RustDesk cannot meet the requirement of stock mstsc compatibility.

Other projects may be better in a specific feature, but none currently provides a more compelling **macOS-ready reusable RDP engine** for our chosen constraints. Revisit if matched workloads or security/maintenance evidence changes.

## M2 implementation boundary

- Native C `macremote` executable calls public FreeRDP Shadow Server APIs directly (not a subprocess wrapper).
- An external source checkout and build tree are linked by CMake, **not copied** into MacRemote.
- Default all-interface listening on port 3390 to coexist with NuoRDS; optional --bind IP and --port including 3389.
- Isolate the generated certificate/config directory to MacRemote application support; never mutate the default FreeRDP user config path.
- No extra pairing password or SAM. Use the logged-in Mac process owner and their existing macOS password via upstream PAM over TLS. Keyboard/mouse enabled, upstream client-count behavior.
- Version/status/doctor, listener configuration validation, graceful SIGINT/SIGTERM shutdown.
- M1 previously verified NLA graphics with test SAM; current TLS+PAM mode verifies rejection of invalid Mac login. Successful real Mac-password login still needs an interactive client test.

## Limitations

The original pairing implementation was deleted. Current product uses upstream macOS password authentication via TLS+PAM (ADR-0007). Real mstsc login, stable TCC/signing, H.264/AVC444, native Karabiner HID, clipboard/IME, telemetry and portable distribution remain release gates.

## Evidence

- [M1 evaluation](../../spikes/m1/RESULTS.md)
- [M1 loopback benchmark](../../benchmarks/m1/e2e/REPORT.md)
- [M2 build and test instructions](../m2/README.md)
- [FreeRDP 3.33.1 release](https://www.freerdp.com/2026/11/10/3_33_1-release)
