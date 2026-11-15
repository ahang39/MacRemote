# ADR-0003: Native input delivery and Karabiner interoperability

- Status: **Superseded by ADR-0008** (historical HID research)
- Date: 2026-11-13
- Priority: high; must be evaluated alongside the RDP protocol stack in M1

## User outcome

A standard RDP client should control macOS **as naturally as a locally attached keyboard and mouse**. When Karabiner-Elements is installed, its current active profile and applicable mappings should be honored **without MacRemote-specific JSON rules, companion remapper, or duplicated shortcuts**. macOS without Karabiner must remain usable.

This is an outcome goal, **not a claim that today's CoreGraphics injection already achieves it**. Device-specific Karabiner conditions can depend on a real keyboard's vendor/product identity and may not apply to a new virtual device; never spoof an unrelated physical device to promise universal equivalence.

## Why generic keyboard injection is insufficient

Karabiner's normal processing path starts at HID device input and emits events through a DriverKit virtual keyboard. It does not generally intercept every CoreGraphics-synthesized event using the same device path. Karabiner's opt-in CGEventTap fallback has different semantics, including imperfect device identity and Fn key behavior.

Therefore, `CGEventPost` at a HID event tap is **not the same as creating an HID device**, and it must not be advertised as automatic Karabiner interoperability.

Sources:
- https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md
- https://karabiner-elements.pqrs.org/docs/manual/misc/event-modification-chaining/
- https://karabiner-elements.pqrs.org/docs/manual/operation/eventviewer/
- https://karabiner-elements.pqrs.org/docs/help/advanced-topics/security/
- https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development

## M1 source-inspection finding (2026-11-13)

Karabiner transforms events from **input** HID devices and posts outputs through its own **virtual HID output**. Injecting into Karabiner's output daemon is **not** a shortcut to execute user rules and that endpoint is intentionally protected. The desired solution requires a separately testable input-side HID path that Karabiner can grab, subject to Apple's entitlement and installation constraints. FreeRDP 3.33.1's Mac Shadow backend currently uses `CGEventPost` rather than such an input-side HID path. See [M1 results](../../spikes/m1/RESULTS.md).

## M1 reproduced server-input issue (2026-11-13)

IronRDP's underlying fast/slow PDU flags expose `EXTENDED1` / `EXTENDED_1`, but `ironrdp-server::KeyboardEvent` retains only `extended: bool` for E0; both E1 variants map to the same output as normal scancodes. Reproduced with a separate Rust crate built against the actual IronRDP checkout (see [M1 Results](../../spikes/m1/RESULTS.md), section 6). The input normalization contract must account for E1 before any Karabiner/HID integration. The native HID entry path remains unproven.

## Proposed architectural boundary

```text
RDP scancode / Unicode / mouse / synchronization
                      |
              InputNormalizer
       (key-down/up, ordering, state, HID usage)
                      |
               InputDispatcher
            /                     \
  NativeHID backend           Quartz fallback
  (feasibility gated)         (CGEventPost)
            \                     /
            trusted logged-in macOS user session
                      |
        Karabiner (when actually in HID path)
                      |
                  macOS apps
```

InputNormalizer must preserve key press/release and left/right modifier identity, distinguish **physical shortcuts** from **Unicode text insertion**, handle disconnect as an all-keys-up transition, and avoid a second ad hoc PC→Mac shortcut translator as the normal path. Cursor/mouse events can use another platform backend if needed.

## Candidate paths to test (not yet selected)

1. **Native virtual HID keyboard/mouse:** ideal for physical-like events and Karabiner applicability. Evaluate supported Apple public DriverKit/HID APIs, entitlement approval, notarization, macOS 14 floor, least-privilege IPC, device identity and installation friction. No kernel extensions and no SIP changes. Avoid shipping a driver before proving that ordinary users can actually install it.
2. **Reuse existing Karabiner virtual-HID driver:** useful as a feasibility reference, but its published security model restricts access, including root and specific driver user-client entitlements. **Never assume a normal user application can attach to an installed Karabiner driver or ask users to expose unrestricted input injection**. Not a mandatory runtime dependency.
3. **Quartz CGEventPost:** supported basic fallback for general app control with Accessibility permission. Does not guarantee ordinary Karabiner remaps, real Fn behavior, or device-specific rules; show actual mode in diagnostics.
4. **Karabiner CGEventTap fallback:** opt-in experimental comparison only. The default app **must not rewrite Karabiner configuration, enable fallback silently, or require a separate adapter**.

Forcing a custom macOS-wide Karabiner rule importer, adding a background key remapping daemon, or post-processing arbitrary application shortcuts is outside the intended production architecture.

## Automatic interoperability policy

- Detect Karabiner presence and status read-only where possible; do not copy, edit, parse-and-reimplement the active user's full rules.
- If a validated HID path is available, use it without per-user remapping setup. If not, fall back to Quartz with an honest UI status: `Input: Quartz (Karabiner mappings may not apply)`.
- Where an Apple entitlement or one-time system extension approval is unavoidable, disclose it as an installation requirement, not a hidden adapter.
- MacRemote's physical/virtual input device should have its own stable, non-deceptive identity. Document that `device_if` mappings tied to other hardware may not match.
- Never use unapproved private APIs, altered SIP, third-party driver hijacking or system configuration changes to satisfy a demo.

## Insert/Help and Print Screen

The RDP input layer must preserve **extended scancode flags** and key-down/up transitions before translating to macOS HID or Quartz events. On macOS, HID Insert (usage `0x07/0x49`) commonly becomes `kVK_Help` (`0x72`), so **virtual HID alone does not guarantee Windows Insert semantics**. Test bare Insert against Help, plus Ctrl+Insert (copy), Shift+Insert (paste), Home/End, and Print Screen (`E0 37`) against keypad `*`; ensure these do not trigger Help unexpectedly or apply a Karabiner remap twice. macOS need not emulate Windows overwrite mode globally. If essential semantic compatibility needs a small mapping, contain it inside the input engine with tests, not a separate adapter or user Karabiner config mutation.

References: [RDP keyboard event](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/7acaec9f-c8a6-4ee9-87d6-d9b89cf56489), [macOS Insert/Help report](https://github.com/pqrs-org/Karabiner-Elements/issues/4232), [HID mapping reference](https://github.com/microsoft/node-native-keymap/blob/main/deps/chromium/dom_code_data.inc).

## M1 validation matrix (must be reproducible)

On the same Apple Silicon Mac using RDP input and local physical keyboard as references:

| Scenario | Measurement / acceptance |
| --- | --- |
| Karabiner **not installed** | Ordinary keys, modifier combinations, Unicode/IME, mouse all work |
| Karabiner installed, current profile | Eligible global/simple/complex remaps run exactly once, without a MacRemote-specific profile |
| Per-device Karabiner conditions | Report whether the new input identity matches; document intentional differences |
| Win key / Alt / Ctrl / Shift (left and right) | Deterministic scancode mapping; no duplicated remapping layer |
| Alt+Tab; Ctrl+Arrow; Ctrl+Shift+Arrow; F11; Ctrl+Insert; Shift+Insert | Compare local-vs-remote behavior under the same selected Karabiner profile |
| Fn/Globe, function keys, Caps Lock, dead keys | Record OS-specific divergences |
| Insert, Ctrl+Insert, Shift+Insert, Help | No unintended Help, copy/paste correct, no double mapping |
| Print Screen `E0 37` vs keypad `*` | Distinct events, safe key-up/down under fast and slow path |
| Chinese IME and Unicode text | Text insertion and shortcut dispatch are separate, no double characters |
| Reconnect and dropped key-up | All modifiers/mouse buttons released, no sticky keys |
| Secure Input / login window | Verify supported session restrictions; no claim of pre-login control |
| Driver entitlement / install | Works within normal macOS security policy; no manual third-party adapter |
| Input latency | p50/p95 key-to-effect for HID vs Quartz vs existing baseline, including Karabiner on/off |

**Hard gate for promising Karabiner-native behavior:** remote events demonstrably enter the real Karabiner modification chain under default Karabiner settings with no independent remapper, and the driver/entitlement distribution model is viable. Until that evidence exists, this remains an explicit high-priority research goal.

## Local research context (read-only verification 2026-11-13)

The development Mac has Karabiner-Elements **16.3.0** running, with its DriverKit virtual-HID components active. The selected profile contains **42 complex modification rules**, including PC-oriented navigation and shortcuts. These provide relevant test cases; the user configuration was **not changed** and no injection test was run.

## Consequences

- Protocol-specific keyboard events enter a **single input normalization boundary**, regardless of IronRDP/FreeRDP.
- No MacRemote-specific Karabiner adapter is planned; avoid treating CGEventTap fallback as a transparent substitute for hardware events.
- M1 protocol decision (ADR-0001) must record input backend interoperability and publishing feasibility, not just video/graphics capabilities.
