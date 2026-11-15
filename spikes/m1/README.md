# M1 Spikes — protocol + input + clipboard

Status: **in progress**. Source inspection and safe, isolated data-model probes only. No production RDP server, keyboard injection, system changes or actual mstsc session has been claimed.

## Run current local probes

```sh
swift spikes/m1/InputModel.swift
swift spikes/m1/ClipboardModel.swift
```

The tests do **not** create HID devices, request macOS permissions, change Karabiner or access the system clipboard. Source and output are part of M1 test evidence, not production code.

## M1 gates

- **P1 Protocol:** pin current FreeRDP and IronRDP server API versions, real build, secure handshake with mstsc, capture/codec comparison.
- **P2 Input:** native HID entitlement and Karabiner event-path proof under ordinary supported installation; Quartz baseline. Test Insert, Help, Print Screen, Ctrl/Shift+Insert, left/right modifiers and E1 Pause.
- **P3 Clipboard:** bridge between RDP CLIPRDR and macOS pasteboard; validate exact source/destination line breaks and duplication with 微信输入法, using synthetic payloads.
- **P4 Packaging:** macOS 14+ Apple Silicon install and permissions; no app-specific remapping adapter, vendor cloud or mandatory HY2 configuration.

## Important input architecture note

Karabiner normally consumes **input HID devices**, applies rules, and outputs through its own DriverKit virtual devices. **Sending directly to Karabiner's output virtual HID is not equivalent to sending through its rules**; it can bypass the manipulator path. Need to test an independently created **input-side** virtual HID device that Karabiner can actually grab. The Karabiner DriverKit daemon is protected and does not offer a general unprivileged injection API.

## Verified read-only environment

- Mac: macOS 27.0.1, Apple Silicon, Karabiner Elements 16.3.0; 42 active complex rules (from the preceding M0 inspection).
- Swift command-line compiler available, Git, CMake, Ninja and Homebrew available.
- Git, Swift, CMake and Ninja were available. Rust 1.99.1 was used from an isolated local toolchain outside the default PATH; no system toolchain was installed.
- Existing third-party remote desktop software and keyboard-remapping configuration remained untouched.

See [RESULTS](RESULTS.md) for dated evidence and unresolved validation.

The upstream FreeRDP **and IronRDP** sources and build outputs are kept under the user's local cache (`~/Library/Caches/MacRemote/m1/`), **outside the Git repository**, to avoid copying third-party code or build artifacts into an unlicensed project.
