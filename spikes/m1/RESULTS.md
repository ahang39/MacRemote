# M1 evidence — 2026-11-13

Status: **PARTIAL — source audit, FreeRDP native build, IronRDP native build/tests and isolated model tests completed; no live RDP session yet.**

## 1. Controlled environment and non-interference

- macOS: **27.0.1**, ARM64 / Apple Silicon; 24 GB memory.
- Target remains **macOS 14+ Apple Silicon**; building with a 14.0 deployment target is **not equivalent to runtime testing macOS 14**.
- User's Karabiner-Elements **16.3.0** has its DriverKit component running and 42 active complex rules (read-only checks from M0/M1).
- Git, Swift, CMake and Ninja were available. Rust 1.99.1 was used from an isolated local toolchain outside the default PATH; no system toolchain was installed.
- No system software was installed, no new permissions were granted, no keyboard input was injected, and no clipboard or unrelated remote-access configuration was changed.
- No test server bound to a port; **no mstsc client connection performed**.

## 2. Protocol stack inspection: source-verified, not benchmarked

| Item | FreeRDP **3.33.1** | IronRDP (source as of 2026-11-13) |
| --- | --- | --- |
| RDP server | Native `freerdp-shadow-cli`; source `65bcca1` | `ironrdp-server`, server example; HEAD `0a79fd2` |
| macOS capture | **ScreenCaptureKit** Mac shadow backend implemented | No product-integrated macOS capture; platform work required |
| macOS keyboard backend | `server/shadow/Mac/mac_shadow.c` sends `CGEventPost(kCGHIDEventTap)` | `RdpServerInputHandler::keyboard` callback exposes scancode code + extended flag |
| Karabiner-native HID | **Not provided** by current Quartz input backend | Not provided out of box; easy place to attach custom backend |
| Media/flow control | Shadow dirty-tile skipping, client backpressure, H.264 / VideoToolbox build features | Has EGFX-related server infrastructure, require integration validation |
| Default Mac FPS | `MAC_SHADOW_FPS 30` constant at release source line 49 | Depends on custom frame source and server implementation |
| Security | NLA by default, SAM or PAM authentication modes; verify actual user-bound session | Server TLS / hybrid CredSSP extension points; validate authentication and authorization |
| Clipboard | Core CLIPRDR and server channels exist; actual macOS shadow interaction not tested | `CliprdrServerFactory` present in server example; actual macOS bridge needed |
| Current Mac build | **Succeeded**: native macOS Shadow Server executable | **Succeeded**: server crate, EGFX feature, full example checks; 44 server tests passed |

### FreeRDP local build — PASS

The exact FreeRDP release source was cloned to:

`~/Library/Caches/MacRemote/m1/FreeRDP-3.33.1`

- Tag **3.33.1**, resolved commit **`65bcca1`**.
- CMake Ninja build directory: `~/Library/Caches/MacRemote/m1/freerdp-build`.
- Flags (key ones): `CMAKE_OSX_DEPLOYMENT_TARGET=14.0`, `WITH_CLIENT=OFF`, `WITH_CLIENT_CHANNELS=OFF`, `WITH_SERVER=ON`, `WITH_SHADOW=ON`, `WITH_APPLE_VIDEOTOOLBOX=ON`, `WITH_GFX_H264=ON`, `WITH_X11=OFF`, `WITH_PROXY=OFF`.
- First CMake attempt hit **missing libusb** from unneeded client URBDRC subcomponent; corrected by `WITH_CLIENT_CHANNELS=OFF` and `CHANNEL_URBDRC=OFF` without installing dependencies.
- Configure succeeded. `cmake --build ... --target freerdp-shadow-cli -j 6` succeeded; re-run reports `ninja: no work to do`.
- Binary: `freerdp-build/server/shadow/cli/freerdp-shadow-cli`.
- `/version` reports **FreeRDP 3.33.1 (git 65bcca1)**. `/buildconfig` confirms `WITH_SHADOW=ON`, `WITH_APPLE_VIDEOTOOLBOX=ON`, `WITH_GFX_H264=ON`; `PAM_LIBRARY` and `PAM_INCLUDE_DIR` were discovered by CMake.
- **No auth handshake, frame, input, audio, clipboard or performance claim** is made based on building alone.

### References

- [FreeRDP release announcement](https://www.freerdp.com/2026/11/10/3_33_1-release)
- [FreeRDP 3.33.1 Mac shadow source](https://github.com/FreeRDP/FreeRDP/blob/3.33.1/server/shadow/Mac/mac_shadow.c)
- [FreeRDP 3.33.1 Mac subsystem CMake](https://github.com/FreeRDP/FreeRDP/blob/3.33.1/server/shadow/Mac/CMakeLists.txt)
- [IronRDP server handler](https://github.com/Devolutions/IronRDP/blob/master/crates/ironrdp-server/src/handler.rs)
- [IronRDP server example](https://github.com/Devolutions/IronRDP/blob/master/crates/ironrdp/examples/server.rs)
- [Karabiner event modification chaining](https://karabiner-elements.pqrs.org/docs/manual/misc/event-modification-chaining/)
- [Karabiner virtual-HID security](https://karabiner-elements.pqrs.org/docs/help/advanced-topics/security/)
- [RDP E0/E1 scancode flags](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/089d362b-31eb-4a1a-b6fa-92fe61bb5dbf)
- [Apple virtual HID entitlement discussion](https://github.com/libusb/hidapi/blob/master/src/tests/README.md)

## 3. Input and Karabiner findings

**Confirmed:** Karabiner's normal chain is physical/virtual **input HID** -> manipulator rules -> Karabiner's **output virtual HID** -> applications. Writing to Karabiner's output driver directly **does not imply** the original rules will execute. That output service also restricts control to privileged, authenticated software.

Candidate design remains **MacRemote RDP event normalization -> independently identified virtual input HID -> Karabiner input interception -> apps**. Apple-controlled virtual HID entitlements, driver approval, stable device identity and user install friction are the unresolved product gates. No unsupported driver injection was attempted.

**FreeRDP's Mac Shadow currently synthesizes Quartz CGEvents**, so it does **not meet** the proposed Karabiner-transparent input goal without an alternate input backend. IronRDP offers an application-owned event handler; its high-level `KeyboardEvent` loses E1 in both fast and slow paths as demonstrated in section 6. Pause/E1 behavior needs an input-adapter fix.

A hardware-like input backend alone also will not solve Insert's macOS Help semantics; RDP E0/E1 and application-facing actions still require explicit cross-platform tests.

## 4. Executed model probes

The retired Swift model probes both completed with exit code **0** on the target Mac.
Current regression tests exercise the [native input path](../../tests/test_freerdp_karabiner_callback.c)
and [CLIPRDR callbacks](../../tests/test_clipboard.m).

- **Input: 15/15 assertions PASS** — E0 Insert vs keypad 0, E0 Print Screen vs keypad *, E1 Pause marker distinct, repeat handling, key-up state, reconnect/disconnect release. **No HID events injected.**
- **Clipboard: 38/38 assertions PASS** — 11 CRLF/LF/CJK/Unicode fixtures x3 round-trip/idempotency tests, malformed payload rejection, clipboard echo-origin model. **No system pasteboard touched.**
- These are small **data-model unit probes**, not tests of a real RDP session, actual CLIPRDR traffic, Karabiner event processing or 微信输入法.

## 5. Outstanding M1 gates

1. **Run authenticated live RDP connection:** ideally Windows mstsc against a loopback/private-only test port and **not** the existing NuoRDS port. Confirm NLA/PAM, display, cursor, input and channel operations. A real Windows client has not been accessed in this run.
2. **IronRDP native work:** building and unit-test gates completed using the already-installed Rust 1.99.1. The live macOS capture/input implementation and independent mstsc interoperability remain unresolved.
3. **Prove native HID entry:** establish supported entitled and notarizable virtual **input** HID path; verify that unmodified active Karabiner rules execute exactly once, on Mac with/without Karabiner, no elevated "keyboard helper" outside the product's normal install flow.
4. **Clipboard E2E:** compare actual mstsc -> WeChat Input Method and reverse transfers for duplicated newline vs duplicate paste actions, using synthetic strings.
5. **Performance:** latency, text sharpness, 1–5 Mbps / HY2 and codec negotiation only once live authenticated sessions exist.

**ADR-0001 and ADR-0003 stay Proposed. No protocol stack or virtual HID implementation decision has yet passed the hard gates.**

## 6. 2026-11-13 continuation — native Rust toolchain found, IronRDP evaluated

### Rust environment found (corrects the earlier environment statement)

The existing Mac toolchain is **not on the default PATH**, but already installed under a different local project:

- Executables: `a local Rust toolchain (Apple Silicon macOS)`
- `rustc 1.99.1 (58cf8f9c3 2026-10-13)`
- `cargo 1.99.1 (5f94df478 2026-08-27)`
- IronRDP source checkout: `~/Library/Caches/MacRemote/m1/IronRDP`, exact HEAD `0a79fd2178c79b3d8920b6e76f2a9da5db6331ca`.
- Cargo registry and compiled targets were kept outside the project under an isolated user cache directory, using explicit PATH, CARGO_HOME and CARGO_TARGET_DIR. Neither the system PATH nor the isolated Rust toolchain was modified.
- The IronRDP repo pins Rust 1.94.1 in its `rust-toolchain.toml`; the available 1.99.1 compiler is newer, but compiler-version compatibility with exactly 1.94.1 was **not** tested.

### IronRDP macOS ARM64 compilation and tests

| Check | Measured result |
| --- | --- |
| `cargo check --locked -p ironrdp-server` | **PASS** |
| `cargo test --locked -p ironrdp-server --lib` | **44 passed, 0 failed** |
| `cargo check --locked -p ironrdp-server --features egfx` | **PASS** (EGFX dependency and server feature build) |
| `cargo check --locked -p ironrdp --features cliprdr,connector,rdpsnd,server --example server` | **PASS** (a full example compiles; no server was started) |
| `cargo test --locked -p ironrdp-cliprdr --lib` | **PASS as a command; 0 tests actually run**. Provides no clipboard behavioral coverage. |

No server binary has been distributed, connected to mstsc, or run against the Mac display. A valid Rust server library does not constitute an end-to-end usable Mac RDP server.

### Direct IronRDP E1 input-flag probe — PASS (reproduces a real API limitation)

Created an **external, untracked scratch crate** at
`~/Library/Caches/MacRemote/m1/ironrdp-input-probe`. It imports actual
`ironrdp-server::KeyboardEvent` and `ironrdp-pdu` types without modifying the upstream checkout.

Observed output:

```text
fast path normal=(29, false) E0=(29, true) E1=(29, false)
slow path normal=(29, false) E1=(29, false)
PASS reproduced the E1 flag loss in current IronRDP high-level server input events
```

The underlying PDU parser **has** `fast_path::KeyboardFlags::EXTENDED1` and
`scan_code::KeyboardFlags::EXTENDED_1`, but
`crates/ironrdp-server/src/handler.rs` maps them to a high-level event
with only `extended: bool` (reflecting E0). The high-level API therefore cannot
distinguish E1 from normal input for the same code in this version.

**Implication:** add an explicit E1-preserving input normalization contract
or upstream fix before promising Pause/Break or other E1 compatibility.
This direct API probe is not a physical keyboard or Karabiner injection test.

### Technical comparison at this gate

| Criterion | FreeRDP 3.33.1 | IronRDP HEAD 0a79fd2 |
| --- | --- | --- |
| Native Apple Silicon build | **PASS**: executable macOS Shadow Server | **PASS**: server library+EGFX+example compile; no integrated macOS service |
| Built-in Mac display capture | **Yes**, ScreenCaptureKit | **No** turnkey Mac adapter; ScreenCaptureKit integration needed |
| Built-in Mac input injection | **Quartz CGEventPost** | **Application-defined callback**, no Mac injection backend |
| Native Karabiner input-chain guarantee | **No** | **No** (ideal insertion point, but HID entitlement/distribution unresolved) |
| Extended scan code handling | E0 recognized; E1 handling requires dedicated test | E0 retained; **E1 lost** in high-level event (reproduced) |
| Graphics codecs | VideoToolbox / H.264 compile flags enabled; live negotiation untested | EGFX AVC420/AVC444 + feedback interfaces compile; encoder/capture integration not provided by the example |
| Clipboard | CLIPRDR and Mac channel code exist; WeChat IME behavior untested | CLIPRDR server interface exists; `--lib` found **0 tests**, Mac bridge untested |
| Authentication | NLA defaults and PAM/SAM integration available; live handshake untested | TLS / hybrid authentication hooks; real macOS-user authorization untested |
| Engine ownership / maintainability | Mature turnkey implementation, C-native adapter customization | Rust-first, explicit handlers and safer extension boundaries |
| Performance / HY2 | **Not measured** | **Not measured** |

**Engineering recommendation:** keep protocol ADR-0001 **Proposed**. FreeRDP is
currently the quicker way to get a captured Mac desktop on a standard RDP client.
IronRDP is promising for a product-specific native input/codec pipeline but
requires substantially more macOS integration work. Do not choose based on
programming language or an isolated build test.

### Remaining hard gates

1. Real **authenticated** standard-client connection with a test listener isolated from NuoRDS; verify actual NLA/mstsc behavior, user authorization and frame negotiation. No Windows test machine was accessed in this run.
2. Demonstrate an **input-side** virtual HID device whose keystrokes truly traverse an unmodified Karabiner rule chain; document entitlement, notarization and macOS 14+ constraints. Do not confuse Karabiner's protected *output* driver with an input entry point.
3. Close E1, Insert/Help, Ctrl+Insert/Shift+Insert and Print Screen issues in the chosen adapter.
4. End-to-end clipboard transfer, CRLF, paste duplication and WeChat IME with synthetic text.
5. Comparable reproducible network/encoder benchmarks including low-bandwidth HY2.

**No pre-existing remote desktop or keyboard-remapping configuration was changed, and no RDP listener was started during the earlier isolated library probes.**

## 7. Native ZGFX performance benchmark — 2026-11-13

[Full benchmark report](../../benchmarks/m1/zgfx/REPORT.md), [raw 80 trials](../../benchmarks/m1/zgfx/results/raw.csv), [medians](../../benchmarks/m1/zgfx/results/summary.json), [reproducible source](../../benchmarks/m1/zgfx/README.md).

The same 16 KiB ZGFX compressed packets were decoded by both native implementations. FreeRDP 3.33.1 was **13.6x faster for code-like data**, **14.5x for solid tiles**, and **4.7x for mixed data** (median 5 rounds, single-core compute). Raw uncompressed data was approximately equal. FreeRDP ZGFX encode is a pass-through, whereas IronRDP Auto compresses with LZ77, lowering bytes at CPU cost. All 80 test cases completed; an additional 800 sequential Auto packets passed cross-library decode verification. This is **a narrow codec-layer benchmark**, not RDP streaming, HY2, H.264 encoding, Karabiner compatibility or end-to-end latency. ADR-0001 remains Proposed.

## 8. Real single-Mac loopback end-to-end benchmark — 2026-11-13

[Results, limitations and raw data](../../benchmarks/m1/e2e/REPORT.md). Both native server builds completed TLS/NLA standard RDP sessions with the same headless FreeRDP sample client, which processed GDI paint callbacks. Five unrestricted trials per service, three pairs at 5 Mbps and two pairs at 2 Mbps. All connections succeeded. One IronRDP 2 Mbps **synthetic random-frame** case did not paint within five seconds; FreeRDP captured the live Mac desktop, so workload-dependent metrics do not establish protocol dominance. Testing used local temporary ports, temporary credentials, and closed every client/server/relay. No NuoRDS port or settings were touched. ADR-0001 remains Proposed pending matched-frame/codec experiments.
