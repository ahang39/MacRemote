# Architecture — MacRemote

Status: **private Alpha: native Mac TLS+PAM account login, standard network/input behavior and SwiftUI menu bar**
See [PRD](PRD.md) for product requirements and [ADR-0001](adr/0001-protocol-stack.md) for the selected FreeRDP foundation (also see [ADR-0005](adr/0005-freerdp-integration.md)).

## 1. Constraints

- Mac host: **Apple Silicon (arm64) or Intel (x86_64), macOS 14+**.
- Standard RDP clients, especially Windows `mstsc`.
- First release attaches to the **existing, already-logged-in macOS graphical session and physical display**.
- All primary features work without private macOS APIs or a proprietary relay.
- Networking is plain IP: HY2, WireGuard, Tailscale and SSH forwarding are **external deployment choices**.
- Prefer existing OSS protocol libraries, not a new RDP protocol implementation.

## 2. Conceptual data flow

```text
Windows mstsc / other standard RDP client
             |
    LAN / private TCP forwarding / HY2
             |
    FreeRDP Shadow protocol and graphics layer
       |           |                |
  authentication  virtual channels  graphics transport
       |           |                ^
 session policy   clipboard etc.    |
       |           |       adaptive output / frame acknowledgements
       |           |                ^
       v           v                |
   macOS session adapter ---- capture / encode pipeline
       |                               ^
       v                               |
 authenticated logged-in user    ScreenCaptureKit
       |                         VideoToolbox (if supported)
       v
  physical display + input events
```

The diagram shows **responsibility boundaries**, not a promise of process separation.

## 3. Planned modules

| Boundary | Responsibility | Important constraint |
| --- | --- | --- |
| RDP protocol adapter | FreeRDP 3.33.1 Shadow: TLS/CredSSP, capabilities, channels, transport and frames | Pinned, external upstream dependency |
| Session manager | Authorized login-to-desktop association, connection state, teardown | One logged-in user/session first |
| macOS adapter | Capture, TCC permissions, physical-display selection | Supported system API paths |
| Native input engine | Decode RDP scancodes/Unicode, preserve extended keys, track state; inject via validated HID or Quartz backends | Test Insert/Help and Print Screen against real macOS semantics; see ADR-0003 |
| ClipboardBridge | RDP CLIPRDR formats, macOS pasteboard, newline conversion and update origin/generation | No duplicate paste, extra newline or sync feedback; see ADR-0004 |
| Graphics pipeline | Dirty regions, encoder, bounded queues, frame acknowledgement | No unlimited backlog; prefer latest useful frame |
| Network adaptation | Rate limiting, quality fallback and client feedback | Input must remain responsive |
| Observability | Transfer rate, negotiated codec, frame/encode/capture rates, errors | No invented client-side metrics |
| User interface | Menu-bar app, small CLI, status/permissions/diagnostics | Thin clients over shared core logic |

A separate privileged daemon, XPC/UDS IPC, and multiple cooperating agents are **not chosen yet**. Start with the simplest session-local process architecture allowed by macOS permissions, then split only for a demonstrated reason.

## 4. Security boundary

RDP authentication is **not automatically sufficient** to authorize use of a particular macOS desktop. The M1 Spike must identify an auditable, supported strategy for:

1. authenticating the connecting RDP user;
2. checking authorization against the currently active macOS graphical session;
3. granting screen capture and event injection only where macOS permissions allow;
4. safe termination, reconnect and release of pressed keys;
5. keeping certificates, secrets and screen contents out of logs.

M2 uses FreeRDP macOS Shadow PAM callback for the process owner's Mac username/password over TLS, with NLA off. Default bind is all interfaces, port 3389, with configurable IP/port; input enabled and no MacRemote client-count cap. See [ADR-0007](adr/0007-native-macos-login.md).

## 5. Performance model and diagnostics

Treat capture -> encode -> queue -> RDP transport -> client decode/display as separate stages. Avoid conflating server-side sent FPS with client-presented FPS.

Candidate counters: TX bytes/s, encode codec and pixel mode, captured/encoded/sent FPS, encode p50/p95, capture-to-queue latency p50/p95, queued and dropped frames, transport mode, available client-ack RTT, reconnect count.

Not all counters will be available under every candidate protocol stack. UI must report missing fields as **N/A**, never estimate them without labeling the estimate. Avoid permanent raw keystroke or screen collection.

Input events and key-release handling must not be stalled by long video encoding queues. Bounded queues and cancellation are required.

### Native input and Karabiner

Keep RDP **physical scancodes** separate from **Unicode text input**. Normalize modifiers/key transitions once, then select a verified macOS backend. ADR-0008 selects an in-process Karabiner basic-rule filter over native FreeRDP CGEvents, preserving original Quartz behavior when the configuration is absent. This is current-rule compatibility, not HID injection or Karabiner engine reuse. Do not install a separate key remapper, alter Karabiner configuration, or silently enable CGEventTap fallback. See [ADR-0003](adr/0003-native-input-karabiner.md).

### Clipboard and IME boundaries

Windows `CF_UNICODETEXT` uses CRLF; macOS plain text typically uses LF. Normalize only **plain text at the format boundary**, and track clipboard update source/generation to prevent loops. Never synthesize paste on clipboard update. Extra blank lines and duplicated user paste actions are separate failure classes. See [ADR-0004](adr/0004-clipboard-interoperability.md).

## 6. Platform limitations / risks

- ScreenCaptureKit and TCC require interaction with the logged-in user session; a root service does not bypass this design issue.
- FileVault pre-boot, system login screen, and independent terminal-server sessions are out of MVP scope.
- Physical display mode is first. Headless or virtual display behavior requires separate validation and will not rely on private APIs for core availability.
- VideoToolbox availability does not guarantee that the chosen RDP stack can negotiate AVC444; validate client and server capabilities end to end.

## 7. Implementation gates

M0/M1 complete: FreeRDP selected. Current Alpha exposes Mac TLS+PAM login, configurable listener and input; successful Windows mstsc login, native Karabiner, clipboard and portable signing remain.

M1 measured stack differences, and FreeRDP selected. Karabiner HID/entitlements and clipboard/IME are still unresolved and remain required before daily-use beta.

FreeRDP is the selected protocol foundation. The current private Alpha is an actual user-session C service and SwiftUI controller; signing, portable dependency packaging, security hardening and final config remain.
