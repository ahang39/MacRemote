# Testing and Benchmark Specification

Status: **M1/M2 measurements available; native Windows MSTSC TLS/PAM login and core input/display regression observed on 2026-11-16**. Open issues and coverage are recorded in [the current full regression](qa/2026-11-16-full-regression.md).

## 1. Test principles

- Test **true end-to-end behavior**, not just screenshots or nominal encoder FPS.
- Use the same Windows client, Mac host, resolution, display content, and network conditions for every candidate.
- Historical evaluation compared NuoRDS, FreeRDP Shadow, macrdp and MacRemote without modifying the previous production setup. Run alternative servers on distinct ports, one at a time.
- Capture actual data with reproducible scripts or device counters. All numerical targets in [PRD.md](PRD.md) are **hypotheses**, not results.
- No raw keystrokes, passwords, screen recordings, user identifiers or network secrets in published logs.

## 2. Required functional test matrix

| Category | Cases |
| --- | --- |
| Connection | New connection, reconnect, wrong credentials, unauthorized session |
| mstsc compatibility | TLS+PAM Mac account login, display reconnect, clipboard/channel capability negotiation |
| Display | First RDP connection preserves current mode, user-selected HiDPI mode is recorded per machine, correct logical/backing sizes, mouse coordinates, reconnect, UU/local coexistence, sleep/wake (ADR-0009) |
| RDP output/scaling | Editable 16:9 output width/height, two baseline choices plus custom WxH, eight nonlinear scale choices, hidden fixed 3% existing-HiDPI reuse threshold, near-16:9 checks and draft-only selection, explicit creation/restart-required/unsupported/apply mode states, independent transport pixels, 2x backing capture, cursor/mouse/drag/resize, existing display override preservation (ADR-0010) |
| Remote audio | Drag 100% → 25% → 0% during playback, mute/unmute at 25%, reconnect two devices with different preferences, disconnect the primary while both are connected, check local Mac playback throughout |
| Input | Mouse buttons, drag, long press, wheel, keyboard left/right modifiers, Command/Option, IME, Caps Lock, release on disconnect |
| Karabiner parity | Absent/present; physical vs remote; global and device-specific rules; Fn/Globe, Alt+Tab, Ctrl+Arrow, Ctrl+Insert, F11; no extra adapter |
| Extended keys | Bare Insert/Help, Ctrl+Insert, Shift+Insert, Print Screen vs numpad `*`, Home/End | Preserve extended scan codes, no unintended Help or duplicate transformations |
| Clipboard & IME | Windows↔macOS CRLF/LF/CR, intentional blank lines, Unicode, WeChat IME, clipboard manager, disconnect | Exactly one paste, no extra blank line, no sync loop; ADR-0004 |
| Office workloads | VS Code or equivalent typing, terminal scrolling, browser scrolling, text selection, copy/paste |
| Stability | Repeated connects/disconnects, permission revocation, unplugged display, long-running session |
| Security | Listener bind defaults, denied remote access, certificate validation, log redaction |

### Clipboard and IME verification

Distinguish **one paste with extra blank lines** from **two paste actions**. Test synthetic CRLF/LF/CR fixtures bidirectionally, including blank lines, repeated update events, rich/plain format precedence, clipboard manager, and 微信输入法 clipboard enabled/disabled in a test environment. Trace only **metadata** (format IDs, event generations, request counts), never user clipboard content. See [ADR-0004](adr/0004-clipboard-interoperability.md).

### Native input verification

Use actual application behavior and Karabiner EventViewer/raw event capture to establish whether remote inputs traverse its real manipulation path. Compare the same physical and RDP key sequences, record device identity differences, and test without Karabiner installed. Do not silently enable CGEventTap fallback or change user settings. No synthetic keystroke injection during the documentation phase; see [ADR-0003](adr/0003-native-input-karabiner.md).

## 3. Network profiles

| ID | Link | Purpose |
| --- | --- | --- |
| L0 | LAN, near-zero shaping | Baseline / codec capability |
| W1 | 40 ms RTT, 5 Mbps, 0.1% loss | Normal remote office |
| W2 | 80 ms RTT, 2 Mbps, 0.5% loss | Lower-bandwidth office |
| W3 | 120 ms RTT, 1 Mbps, 1% loss | Degraded-link recovery |
| H1 | Existing private HY2 path | Verify tunnel compatibility and real-world results |

Record directionality, packet loss injection method, tunnel/transport mode, and whether bitrates include encapsulation overhead. Do not compare HY2 and LAN results as though the network conditions match.

## 4. Workload definitions

1. **Idle:** cursor stationary; 60 seconds after the desktop settles; report avg and p95 bytes/sec.
2. **Text:** type 1,000 characters using a deterministic test input (never secrets), scroll terminal logs, select text.
3. **Web:** load a local static test page; sustained smooth scrolling; capture frame-time distribution.
4. **Motion:** move windows and animate a controlled, local video sample for comparison.
5. **Recovery:** interrupt network briefly and restore; measure reconnection time and key-release correctness.

For each workload, use 1920×1080 baseline; later add HiDPI and different client sizes.

## 5. Metrics and provenance

| Metric | Unit | Measurement / caveat |
| --- | --- | --- |
| Encoded and transmitted rate | FPS | Separate from client-presented FPS unless instrumented there |
| Capture and encode time | ms p50/p95 | Monotonic timestamps at stage boundaries |
| TX data rate | Kbps and Mbps | Show application vs interface rate separately |
| Frames dropped / queued | count | Bounded queue; distinguish intentional dropping |
| RTT / frame-ack latency | ms | Only when protocol/OS exposes an actual value |
| CPU, memory, energy | %, MiB, observable power | Capture during identical windows |
| Image quality | reference screenshots/SSIM if meaningful | Inspect text edges, UI artifacts and chroma distortion |
| Interactive input response | ms | External camera/high-speed capture or instrumented endpoint, explicitly describe method |

An unavailable metric must display as `N/A`. A UI **must not** fabricate a measured client FPS or end-to-end latency from server-side counters.

## 6. Reporting template

For each run: date; git commit / upstream version; macOS & Windows versions; Apple Silicon model; client name/version; exact RDP negotiated codec; display mode/resolution; port; network profile; workload; 3+ repeated runs; median/p95; failure notes; artifacts and sanitized logs.

## 7. Gates

- **M0:** all Markdown links resolve within the repository; ADR statuses and feature scope are consistent; no runtime code or build claims.
- **M1:** real mstsc secure connection demonstrated, tests reproducible, protocol ADR accepted; native input/Insert compatibility (ADR-0003) and clipboard/IME protocol validation (ADR-0004) documented.
- **M2/M3:** functional/security matrices pass; controlled performance targets measured, failed targets tracked as issues rather than hidden.

Do not reuse historical NuoRDS performance data as a live comparison; it is no longer installed.

## 8. Prior M2 (historical): NLA/SAM demo

The earlier private Alpha used independently paired test SAM credentials and
NLA. A real headless RDP client completed TLS/NLA and GDI bitmaps on loopback.
These were historical tests only; this implementation was removed after owner
review. See [ADR-0007](adr/0007-native-macos-login.md).

## 9. Current Alpha: native macOS account password

- CTest covers CLI contracts, native input, display geometry and preferences,
  codecs, and CLIPRDR. Clipboard callback tests cover overlapping format
  announcements and a new local copy during an outstanding remote request.
- The native remote audio test drives the production capture callback with
  synthetic stereo samples and decodes the Opus packets submitted to
  `rdpsnd`. It checks 640 bytes per 20 ms, 0 bytes during mute, and stale
  packet rejection on unmute. Swift tests cover updates to legacy profiles
  and preserved display fields. Client playback, format negotiation and
  end-to-end timing require real RDP sessions.
- The [real TLS/PAM loopback test](../tests/test_loopback.py) starts MacRemote
  with an explicit 127.0.0.1 test bind and an ephemeral port; the headless
  FreeRDP client negotiates TLS, supplies a *nonexistent* username, reaches
  macOS Shadow PAM, and is refused without receiving desktop pixels. This
  avoids supplying the user's actual password or risking lockouts.
- The actual Windows mstsc login happy path **was verified on 2026-11-16**
  using the Windows interactive console session and an already-saved system
  credential; no password was read or exported. Display, pointer and
  bidirectional text/partial image clipboard regression results are recorded in
  [the full report](qa/2026-11-16-full-regression.md).
- The standalone App build executes CTest and Swift regressions before signing.
  The process lifecycle test uses a helper that exits without opening a port
  and verifies that Stop cancels scheduled recovery. Live crash recovery was
  exercised separately in the [Windows regression](qa/2026-11-16-full-regression.md).
- Packaging audits every executable, bundled dylib and the OpenSSL provider.
  The provider must resolve to the same libcrypto that the server bundles.
- Other release gates: H.264/AVC444, clipboard/IME, Karabiner-native input,
  correct certificate trust for Mac login credentials, signing/notarization,
  installer, real LAN load and long-running stability.
