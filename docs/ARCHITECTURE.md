# Architecture — MacRemote

Status: **private Alpha: native Mac TLS+PAM account login, standard network/input behavior and SwiftUI menu bar**
See [PRD](PRD.md) for product requirements and [ADR-0001](adr/0001-protocol-stack.md) for the selected FreeRDP foundation (also see [ADR-0005](adr/0005-freerdp-integration.md)).

## 1. Constraints

- Mac host: **Apple Silicon (arm64) or Intel (x86_64), macOS 14+**.
- Standard RDP clients, especially Windows `mstsc`.
- Supported Release baseline attaches to the **existing, already-logged-in macOS graphical session and physical display**. The development source adds an opt-in native-server virtual display fallback if there are zero registered online displays; this still needs actual no-monitor Windows mstsc acceptance.
- Core capture, RDP, input and clipboard work without private macOS APIs or a proprietary relay. Optional manual display re-detection is isolated in a helper that uses an OS-private symbol.
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

## 3. Implemented process and ownership boundaries

Two processes are deliberately retained: the SwiftUI menu-bar application
manages a child RDP server; FreeRDP Shadow, capture, authentication, clipboard
and input remain in the C/Objective-C server. No daemon or IPC framework is
needed.

| Module | Ownership |
| --- | --- |
| SwiftUI app / menu delegate | Native status item, grouped popover cards, live session telemetry and user interaction |
| ServerController | Child-process lifecycle, default bandwidth mode, terminal failures and bounded restart policy |
| DisplayOutputSettings | User choices, effective scale state and visible status |
| DisplayModeService / DisplayModeOperations | CoreGraphics mode discovery and explicitly authorized helper execution |
| DisplayConfigurationStore | Output selection and capture-geometry file persistence |
| ClientDevicePreferences | Per-device output, HiDPI mode, bandwidth mode (`high`/`low`), volume, mute and `rdp-session.json` telemetry |
| src/macremote.c | CLI, server bootstrap, stream hooks and FreeRDP input hooks |
| src/stream/stream_profile.c | Single source of truth for High (LAN) and Low (≤200 KB/s WAN) video/audio/pacing budgets |
| src/device/client_preferences.m | Primary client ownership, remembered profile loading, live stream/audio profile updates and 1 Hz telemetry |
| src/display/device_display.m | Restores remembered display modes and publishes capture geometry |
| src/audio/remote_audio.c | Remote gain, dynamic 128/48 kbps stereo Opus encoding, mute enforcement and byte accounting |
| src/input/mac_clipboard.m | CLIPRDR sessions, advertised snapshots and one in-flight format request per client |
| src/input/clipboard_formats.m | UTF-16/CRLF text and PNG/DIB codec boundary |
| src/graphics/rdp_graphics.c | Standard 32-bit RDPGFX + H.264/AVC420 session configuration |
| patches/freerdp-3.33.1-h264-streaming.patch | Low-latency SPS VUI rewrite, VideoToolbox DataRateLimits, byte pacer, FPS gate and ACK RTT telemetry |
| patches/freerdp-3.33.1-shadow-output-geometry.patch | Version-controlled FreeRDP 3.33.1 display geometry integration |

The fixed RDP surface is selected at server startup. CoreGraphics logical
desktop changes rebuild capture without live RDP surface resizing. The common
surface viewport maps video, pointer input and cursor feedback, including
letterbox/pillarbox offsets.

### Remote volume

When a client authenticates, the server loads its profile using the existing
normalized hostname hash and IP fallback. Additional clients share the
first client's audio setting. When that primary disconnects, the oldest
remaining client becomes primary and its audio setting takes effect while
the current display mode stays in use. On the final disconnect the server
clears effective audio and retains the last key for the display preferences.

The client marker includes the server PID while connected. The popover
uses the marker for its own server process to select the current profile
and disables the audio controls while disconnected. Slider and mute edits
merge into that profile and atomically replace the JSON. Missing audio
fields default to 100% and unmuted. A muted slider edit updates the level
that will be restored on unmute.

The server watches the configuration directory for atomic replacements and
applies effective audio and bandwidth settings live. ScreenCaptureKit supplies
48 kHz stereo PCM. The audio module ramps gain over 5 ms and encodes one 20 ms
CBR Opus packet at **128 kbps** (320 B, High mode) or **48 kbps** (120 B, Low
mode), suppressing packets after 200 ms of silence. Shadow queues the encoded
packets and `rdpsnd` sends them as Wave2 PDUs. Clients must negotiate Opus and
support Wave2 to receive audio. See [ADR-0012](adr/0012-bandwidth-profiles-and-low-latency-h264.md)
for the unified High/Low streaming architecture and low-latency SPS VUI rewrite.

Mute and 0% stop submitting audio payloads to `rdpsnd` as soon as the new
setting takes effect. The send boundary discards queued packets from earlier
mute states. On resume the module resets the encoder and starts at a new PCM
frame with a brief fade-in. Data already handed off to FreeRDP or the network
can drain, and RDP channel control messages can still be exchanged.

## 4. Security boundary

FreeRDP's macOS Shadow PAM callback validates the process owner's Mac
account over TLS, with NLA disabled (ADR-0007). Shadow initializes the
desktop channels only after PAM succeeds. The server attaches to the
existing logged-in desktop, uses macOS TCC grants for capture, and injects
input through Quartz. Default listener binding is all interfaces on TCP 3389;
the CLI and GUI allow a custom port, and the CLI supports an explicit bind IP.
The listener must be protected by a private network/VPN, with certificate
verification before password entry.

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

## 7. Current verification boundary

The native tests exercise geometry, remote audio, clipboard, Karabiner
input, graphics and the CLI. The audio test injects synthetic stereo samples
through the production capture callback and decodes the outgoing Opus packets.
Swift tests cover display and audio preferences and drive the menu controller against
an isolated helper process to verify error reporting and retry cancellation.
The Windows mstsc Classic login/display path has been verified, while rapid
typing, Windows image clipboard exchange, audio and all HiDPI interactions
still require real-client regression.

The pinned FreeRDP patch series is applied with explicit compatibility checks
and requires the exact upstream commit. Native and Swift build checks are automated; source
checks do not substitute for a real Windows RDP session.
