# ADR-0007: Native macOS login and normal RDP server behavior

- Status: **Accepted**
- Date: 2026-11-14
- Supersedes: [ADR-0006](0006-local-pairing.md)
- Foundation: [ADR-0005](0005-freerdp-integration.md)

## Decision

Use the existing macOS username and login password via the upstream FreeRDP 3.33.1 macOS Shadow PAM callback. FreeRDP uses the macOS checkpw PAM service and verifies that the login username matches the user running the Shadow Server. No extra pairing account, randomly generated password, or SAM/NTLM file.

Mac password authentication uses **TLS security with NLA disabled** because FreeRDP's PAM callback is invoked on the non-NLA path. Never misrepresent this as NLA. Keep TLS so Mac account passwords are not sent through legacy unencrypted RDP.

## Defaults

- Keyboard and mouse enabled.
- Listen on all interfaces; optional IPv4/IPv6 --bind address selects a specific interface.
- Port 3389 by default, with --port and the persistent menu-bar setting supporting other valid ports.
- No artificial MacRemote client-count limit; let FreeRDP handle the shared desktop.
- No separate console-user preflight or forced disconnect on fast user switching.
- Start/stop is controlled by the native menu-bar UI or CLI; project changes do not install any autostart service or modify system firewall/NuoRDS settings.

## Verification and remaining work

- The native CLI and 11 CTest cases pass, including port, authentication and input regressions; a separate Swift test verifies persistence of the user-configured port.
- Real loopback TLS client reaches upstream macOS PAM and is rejected for a nonexistent username without rendering desktop pixels.
- Windows mstsc has connected successfully in the validated Classic bitmap mode. Full regression testing of the latest build, including reconnect, clipboard/IME and display wake, is still required; never request a Mac password through chat.
- TLS certificate verification/pinning is necessary before using actual Mac login credentials over an untrusted network. This is a product release/connection UX requirement, not an extra account restriction.
- Obsolete pairing source was removed. Existing user data is not deleted automatically.

## Replaced decisions

The previous separate macremote pairing account, forced NLA/SAM, localhost-only listener, default read-only mode, one-client cap and strict console-owner rule were assistant-imposed product restrictions not approved by the owner. ADR-0006 is historical and superseded.
