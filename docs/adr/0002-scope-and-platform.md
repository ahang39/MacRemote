# ADR-0002: Platform scope and safe macOS integration

- Status: **Accepted**
- Date: 2026-11-13

## Decision

1. Support **macOS 14+ on Apple Silicon** first.
2. Control the **currently logged-in user's existing physical display** first.
3. Use public macOS APIs for production-critical capture, input and session work.
4. Private APIs may exist only in isolated, clearly experimental, disabled-by-default features.
5. Ship **menu-bar UI + CLI**, sharing one implementation core, when functionality exists.
6. Work via ordinary network paths (including HY2 TCP tunnels) with **no mandatory gateway or cloud**.
7. Keep first-time configuration minimal; require deliberate enablement of non-loopback listening.

## Why

The primary user is a cross-platform developer accessing a Mac mini from Windows via standard RDP. Existing-session control and physical display have fewer platform/security assumptions than independent virtual desktops. Avoid coupling a public OSS product to a personal tunnel or to macOS private APIs.

## Consequences

- No promise of FileVault pre-boot unlock, loginwindow control, multi-user isolated sessions, virtual display, or Intel builds in v1.
- Mac privacy permission requirements and limitations must be visible in the installation guide.
- Future alternative display engines must not destabilize the supported physical-display path.
