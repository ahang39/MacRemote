# ADR-0006: User-bound NLA pairing and safe local service lifecycle

- Status: **Superseded by [ADR-0007](0007-native-macos-login.md) — historical, not implemented**
- Date: 2026-11-13
- Foundation: [FreeRDP integration](0005-freerdp-integration.md)

**Historical note (2026-11-14):** The owner rejected the additional pairing account, mandatory NLA, loopback-only networking, read-only input and single-client restriction. Related pairing source was deleted. This document records an abandoned prototype, not current requirements.\n\n## Decision

MacRemote uses a **separate randomly generated RDP credential** for CredSSP/NLA. Do not send the user's macOS account password through RDP. This is necessary because FreeRDP's macOS PAM callback currently handles the **non-NLA** path only; setting NLA means authentication happens earlier, before the platform callback.

- On explicit `macremote pair`, use Apple's `SecRandomCopyBytes` to generate 24 uniformly random bytes (**192 bits**), encoded as 32 URL-safe Base64 characters.
- Only the 16-byte NT hash (WinPR `NTOWFv1A`) is stored in a SAM entry, under `~/Library/Application Support/MacRemote/credentials.sam`. The plaintext pairing password is displayed once and wiped from memory after printing.
- The application-specific directory must be owned by the current user and mode `0700`; the SAM file must be owned and mode `0600`, not a symlink. Reject insecure permissions. Pairing uses a temporary file and an atomic link operation to avoid overwriting another credential.
- `macremote pair --reset` explicitly rotates the credential by atomic rename. The menu-bar app requires user confirmation and disallows rotation while its own server is running. Existing clients need their saved password updated. Manually started servers should be stopped before rotating.
- RDP username is always `macremote`; no per-user account database, cloud identity, domain server or system password is needed.
- Only the **currently active console user** may start sharing (`SCDynamicStoreCopyConsoleUser` UID must match the effective UID). The server checks the console owner during operation and stops if the user changes.
- Network defaults: `127.0.0.1:3390`, TLS/NLA only, one client, remote keyboard and mouse disabled by default. Quartz input is an explicit experimental option.
- FreeRDP certificate/config files are isolated in MacRemote's user-owned application-support directory. No changes to NuoRDS, firewall, system trust or macOS login accounts.

## Security properties and boundaries

An NT hash is a **password-equivalent verification secret**. Protect the file as sensitive; the random pairing password makes offline guessing impractical. The hash generation function's name (`NTOWFv1A`) does not imply that NLA negotiates NTLMv1; the end-to-end authentication path is handled by upstream FreeRDP.

Console-user checking binds the running process to the graphical session but does not implement independent macOS account password login, per-client consent, or full device ownership verification. Any other process executing as the same macOS user can access that user's protected file; operating-system account compromise remains out of scope.

Loopback-only is a deliberate gate: no Internet-facing or LAN listener until rate limiting, trusted certificate handling, authentication audit, reconnect revocation and a threat-model/security review are completed. Fronting a localhost listener with a user-managed private tunnel is a deployment choice outside core.

## Verified locally

- New pairing + status and permission probes work against an ephemeral HOME.
- File/directory permissions `0600`/`0700`, duplicate-pair refusal, explicit atomic reset and tampered-file rejection are covered by CTest.
- Real loopback client has completed TLS/NLA, 1920x1080 GDI image updates and clean shutdown using newly generated credentials.
- A native SwiftUI menu-bar app provides opt-in start/stop, pairing, password-copy and reset confirmation. Development bundle signature and native CLI smoke checks passed.

## Unfinished before public release

Secure local/remote transport policy and rate limit, optional LAN access, actual Windows mstsc and certificate pinning UX, signed/notarized portable dependency bundle, fully native Karabiner HID backend, clipboard/IME bridge, and measured codec/transport telemetry. MacRemote project license is still undecided.
