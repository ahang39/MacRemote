# MacRemote: Windows mstsc authentication prompt investigation (2026-11-19)

## Goal
Make normal Windows mstsc reliably ask for credentials and authenticate the existing macOS account. A custom login window is only one implementation.

## Primary evidence
- src/graphics/rdp_graphics.c enables TLS but disables NLA/CredSSP. ADR-0007 chose local macOS PAM checkpw, without a separate SAM verifier.
- FreeRDP Shadow shadow_client_post_connect uses Username and Password from the RDP Client Info PDU, invokes Mac/mac_shadow.c PAM callback and closes on failure with ERRINFO_SERVER_INSUFFICIENT_PRIVILEGES. The Mac callback returns -1 silently for absent username/password; it never requests missing credentials. Thus the reported failure fits omitted client credentials, but does not prove why mstsc showed no prompt.
- docs/qa/2026-11-16-full-regression.md documents successful real Windows mstsc TLS/PAM login using a previously saved Windows credential.
- Microsoft MS-RDPBCGR explicitly permits an RDP-remoted server-side login prompt. It does not define a universal server instruction forcing Windows CredUI after a failed TLS/PAM login.
- NuoRDS release notes mention a separate login screen; its internal design is proprietary and not established here.

## Minimal tested candidate
tools/make-mstsc-profile.py creates a password-free UTF-16LE RDP file (BOM and CRLF). It contains target host/port, macOS username, both client credential prompt flags, disabled CredSSP to match the server, TLS negotiation, and certificate trust warnings. tests/test_mstsc_profile.py covers formatting, absence of passwords, and invalid input. This is a **client-side request**; real Windows mstsc behavior still needs testing.

## Design decision
Use the client profile first. If the product needs **zero client configuration** (type only a hostname into default mstsc), then an RDP-rendered pre-auth login surface is the sensible NuoRDS-like solution: use server-owned synthetic pixels, prevent real desktop/frame/audio/clipboard/input delivery before authentication, validate using current macOS PAM, clear passwords, then atomically open the actual shared desktop. FreeRDP Shadow lobby/inLobby can be studied but is not currently a secure login implementation. Simply toggling NLA cannot reuse local PAM without a compatible NTLM/Kerberos credential verifier.

## Independent acceptance matrix
Use the actual Windows mstsc build: 1) host only with no TERMSRV saved credential; 2) generated profile; 3) saved credential; 4) wrong credentials; 5) reconnect. Record TLS negotiation, credential field presence (never values), exact auth result, whether CredUI appears, and absence of pre-auth pixels. Verify the real TLS certificate fingerprint. Only build the larger in-session login UI if native prompting is not sufficient.

## Status
Source-only profile generator and tests; no installed MacRemote.app change, no 3389 restart, no Release update. Windows prompt unverified.

## References
Microsoft Client Info: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/732394f5-e2b5-4ac5-8a0a-35345386b0d1
Microsoft server-side login option: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/ef9db6a5-36f4-4613-84b3-97501679d210
Microsoft example RDP properties: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdwr/85159758-8f1e-432f-80aa-276ea214a971
NuoRDS login screen: https://www.nuords.com/about/news/2021/12/14/nuords-server-20211213


## Adversarial reassessment (2026-11-19, after initial recommendation)

**Withdraw the .rdp profile as the product-default solution.** Microsoft explicitly documents that already-saved credentials may suppress prompting even with client prompting policy. Since the April 2026 Windows security update, unsigned .rdp files also show an Unknown Publisher warning and can be blocked by client Group Policy. The generator remains a diagnostics/interoperability aid, not a zero-setup solution.

**Protocol error mapping:** MacRemote currently sends ERRINFO_SERVER_INSUFFICIENT_PRIVILEGES when username or password is missing; Microsoft MS-RDPBCGR says user authorization MUST only occur after credentials are received. Missing credentials need a separate authentication-needed state. Changing the error alone cannot force native Windows CredUI.

**Revised leading option for host-only Windows mstsc:** preserve Client Info PDU + macOS PAM fast path when both fields are provided. Otherwise hold the RDP session in a dedicated server-rendered pre-authentication login surface (not a local AppKit window) where the user types username/password; only then validate via existing PAM and release the real Mac desktop.

**Non-negotiable FreeRDP Shadow issue:** current shadow_client code copies server mayView/mayInteract TRUE to a client before authentication, sets inLobby depending on mayView during activation, and starts channels before post-connect PAM. The existing lobby is not itself an authentication security boundary. A login implementation must gate the real surface, Quartz keyboard and mouse, clipboard, audio, dynamic channels and reconnects on an explicit per-client authenticated state, with server-only pixels before success. Certificate identity validation/pinning matters when entering the real Mac login password; macOS App signing is not TLS remote server trust.

**CredSSP/NLA alternative:** requires TLS plus Kerberos or NTLM credential verification before the password is transferred, not just switching FreeRDP_NlaSecurity on. macOS PAM checkpw cannot validate an arbitrary NTLM response without compatible separate credential verification. Old SAM pairing was intentionally removed by ADR-0007.

**Independent go/no-go test:** actual clean Windows mstsc with no TERMSRV stored creds, host only, verify it completes TLS and can display a harmless synthetic remote surface without a password. Then verify missing and wrong credentials never reach real pixels/clipboard/audio/input, correct PAM login transitions to desktop, session reconnects; observe real client behavior, not only unit tests. Current service and 3389 remain unchanged.

Sources:
- https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-terminalserver
- https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/26043070-85f8-4ee8-8721-d7f013c755ca
- https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/remotepc/understanding-security-warnings
- https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/8e11581d-094f-461a-9fde-ba51af90cf8b
