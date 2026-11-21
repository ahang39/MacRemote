# Native mstsc NLA migration and H.264 restoration (2026-11-20)

## Goal / factual diagnosis
- Windows standard mstsc credential retention and direct desktop login, no server-rendered login page; H264/Progressive hot switching, per-device memory and headless support retained.
- Previously stock mstsc /prompt was insufficient: FreeRDP Shadow TLS/PAM post-connect authentication repeatedly failed (-1), with no Mac PAM user mismatch or bad-password message, strongly suggesting missing client credentials. A known-working 32bpp RDP file fixed the picture, but real server logs still showed the private in-session login page before PAM success. Therefore previous saved RDP success did not prove credential forwarding.
- Standard mstsc NLA/CredSSP uses NTLM/Kerberos challenge-response; macOS PAM password checking cannot validate NTLM without a verifier. FreeRDP includes native NLA+SAM support.

## Implemented source
- src/auth/nla_sam.c/.h adds native local interactive command macremote-server enroll-nla. Uses readpassphrase without echo and asks for a dedicated 14+ character RDP password twice, NOT requiring or retrieving the Mac login password.
- Uses WinPR NTOWFv1A to create the standard SAM NTLM verifier. Writes an owner-only 0600 file with atomic rename in ~/Library/Application Support/MacRemote/rdp-ntlm.sam, no plaintext password in args, stdout or saved config. NT hashes are password-equivalent secrets, use a separate strong RDP password.
- After user enrollment, the server automatically negotiates NLA and uses FreeRDP NtlmSamFile. If no verifier is present, existing TLS/PAM remains; an invalid verifier fails startup rather than silently downgrading.
- In a native NLA session FreeRDP verifies the registered user via NTLM before activation, and does not rely on the in-session Mac PAM login-page workflow. The source candidate has no custom RDP login page. The pinned H264/Progressive live graphics switch and per-client settings remain.
- tools/make-mstsc-profile.py now supports --nla --remembered to output 32bpp and enablecredsspsupport:i:1. The old non-NLA RDP profile remains supported for emergency rollback.

## Verification
- 25/25 native CTests, Swift project checks, signed candidate build passed. Test nla-verifier creates a fake password SAM, verifies NT hash via the actual WinPR SAM parser, 0600 permissions, no plaintext, NLA settings, rejects mode 0644. New RDP profile Python tests passed.
- Signed candidate: .build/output/MacRemote-20261120T044202Z.app, server binary SHA256 238270a5db7e1c6a7297c9c7a5e082932f9a802c26e2dcaa5e832c671800caff.
- Isolated HOME/ephemeral loopback server with a fake password completed local terminal enrollment and selected protocol 2 (RDP_NEG_RSP PROTOCOL_HYBRID, NLA) on a real X.224 handshake. Fake secret was deleted with temporary HOME.
- An older locally modified FreeRDP Sample client advanced to DemandActive with the correct fake secret, then failed with its pre-existing MCS channel id 0000 problem that also reproduced on the known-good server. This is not native Windows mstsc end-to-end proof.

## Actual currently installed state
- For immediate live hot-switch restoration, user-requested previous signed 32bpp Windows-tested candidate .build/output/MacRemote-20261120T014126Z.app replaced Classic under /Applications/MacRemote.app. Server PID 77350, IPv4/IPv6 TCP3389 listening, --gfx h264 --headless; binary SHA256 2ce8e012734b5a7746c3a7d032a6b1f35ab7bbe739ababc4297d26f42a0f5983. The old Classic App is backed up under ~/Library/Caches/MacRemote/product/MacRemote-before-hotfix-live-20261120.app.
- This interim live build STILL includes the custom RDP login page as fallback. That is intentional to avoid locking out users before a valid NLA verifier has been enrolled. The new no-page NLA candidate has NOT been deployed.
- Final migration needs the user to run the signed candidate's enroll-nla once in a local Mac terminal and choose a dedicated RDP password, then have Windows store that password in Credential Manager under the same TERMSRV target, update its RDP profile to enablecredsspsupport:i:1, and verify real mstsc NLA + full H264 desktop + live codec switch. Switch the production app only with working signed rollback available.

## Safety
No real Mac password was queried. No SAM verifier was added to the real user account in this run. No changes to BetterDisplay, Windows computer, Mac security policy or Git remote. All NLA proof used throwaway test secrets and isolated listeners.


## 2026-11-20 follow-up: same existing Mac password, not a second RDP password

User rejected managing a separate RDP password. The NLA enrollment now prompts exactly once for the user's current macOS account password, verifies it using the same macOS checkpw PAM service as the existing Shadow login, and only on verification success derives and atomically stores the 0600 NTLM verifier. No password is sent in CLI arguments, logs or chat. A bad password fails before writing a verifier; a noninteractive process cannot enroll.

- Source: src/auth/nla_sam.c, mr_nla_verify_mac_password; original dedicated-secret enrollment prompt replaced. FreeRDP's NTLM verification and on-disk SAM format otherwise unchanged.
- Signed candidate .build/output/MacRemote-20261120T051415Z.app, full CTest 25/25 PASS, source diff check, signing PASS. The new PAM enrollment path is compile-checked, but real user Mac password was never supplied; it has not undergone a real-user PAM enrollment or Windows client NLA validation yet.
- Security tradeoff: a reusable NT hash of the actual Mac password is sensitive password-equivalent material (pass-the-hash risk). File is owner-only 0600, but this differs from macOS's normal password storage. When the Mac password changes, user must re-run enrollment or Windows saved credentials will no longer correspond.
- Production 3389 still runs the previous H.264/Progressive build with legacy sign-in fallback; no enrollment has been performed against the real Mac. Deployment must follow user-controlled local enrollment and actual Windows mstsc validation, not automatically create a verifier.


## Product acceptance update: no pre-run terminal command (2026-11-20)

User rejected any required setup command, as well as separate RDP passwords and server-rendered login pages. The desired final user experience is: MacRemote's native UI handles any necessary first-time credential authorization; Windows mstsc uses its own native credential dialog and Credential Manager thereafter; H264/Progressive hot switching remains.

Protocol constraint: FreeRDP's NLA/CredSSP NTLM verifier requires password-derived cryptographic key material. macOS checkpw PAM and Apple's LocalAuthentication authenticate but do not supply the user's reusable password or NT hash. The server cannot automatically enroll the same Mac password from the existing login session. A first-time interactive MacRemote UI password entry (or equivalent provisioned Kerberos identity) is therefore required; there must not be a silently generated second password. This must happen in the app's ordinary onboarding/start flow, not as a terminal command or unsupported custom RDP page.

**Current status:** The GUI enrollment integration is NOT implemented or deployed yet. The experimental candidate still exposes the optional CLI enroll-nla method; do not advertise the CLI as the product workflow. The live /Applications/MacRemote.app still runs the older functional H264 build on TCP 3389, with its legacy login page; it has not been replaced. A GUI enrollment attempt was abandoned before integration and its untested stdin API removed. Implementing a secure native UI that handles the password and verifier remains a follow-up. Do not claim that a macOS LocalAuthentication success alone supplies the NTLM verifier or that the CLI-only build meets the acceptance criteria.


## 2026-11-20: native GUI and independently chosen RDP password (latest decision)

User permits a remote password distinct from the macOS login password. This supersedes the earlier proposal to require the existing Mac password. No prerequisite commands are allowed.

Implemented native AppKit first-use window: account label, two secure password fields, reveal toggle, 12-240 character validation, confirmation, success state, a Change password action in the menu, and explicit service restart only after permission to interrupt clients. Automatically opens on first launch or a server start without configured credentials. Uses temporary regular-app activation so the window is visible rather than hidden behind other apps.

The signed local helper accepts a chosen password over a private stdin pipe, not command-line arguments, logs or environment. Writes only an atomic per-user SAM verifier with permissions 0600. With a verifier, FreeRDP negotiates NLA and authenticates via NTLM; this supports a password distinct from the Mac password. Existing H264/Progressive hot switch and per-client preferences remain. The legacy server-rendered sign-in page is not in the NLA candidate.

A synthetic-password child-process onboarding test was added to the existing WinPR SAM test. 25/25 CTest passed and Swift/AppKit signed compilation succeeded. Standalone setup window was launched and visually inspected on the user's Mac. Signed candidate is .build/output/MacRemote-20261120T054238Z.app, setup GUI PID 99825 at inspection time. Current live server PID 77350 remains H264 on port 3389 and has not been replaced. No real SAM verifier had been created at this time because the user has not yet submitted a password. Native Windows mstsc end-to-end login and live switching still require real Windows validation.

This section is the current product specification; earlier sections above are historical and superseded.


## Password policy adjustment — 2026-11-20
User explicitly requests no MacRemote-specific password complexity rules, matching the permissive local macOS account experience. Removed the 12-character minimum from both the native GUI validator and the child-process NLA setup helper. Passwords of any nonzero length are accepted without case/number/symbol requirements, subject only to repeat confirmation, no newline in the helper transport and the existing 240-byte GUI transport limit (not a complexity rule). A system administrator's current macOS login password policy does not automatically govern this independent RDP password.


## 2026-11-20 13:52: single-entry setup (latest UX)

The user asked why first-run RDP password setup required entering the password twice. Original confirmation was meant to prevent typos, but the product already has a Show/Hide control and a Change Password action. The latest UX uses **one secure password field only**, without confirmation or complexity requirements. The AppKit setup window height is reduced from 455 to 380 points and spacing rebalanced. The local helper continues to reject empty/newline passwords and keeps the existing password-verifier permissions. Previous 'two secure password fields' descriptions above are historical, superseded by this section.

The SAM verifier had been created by the user's live first-run setup by the time of this change; only its owner/mode/mtime were inspected. Neither password nor hash was read. The existing production RDP server is unchanged until a separately validated NLA deployment.


## 2026-11-20 correction: twice submitting setup, not a duplicate password field

User clarified that the problem was submitting setup twice, not typing a confirmation password. Earlier removing the confirmation field was a misinterpretation, and the actual defect was repeated onboarding.

Root cause: The setup-only app launch always presented a Windows login setup window even when the user had already enrolled a valid rdp-ntlm.sam. On successful save, the button changed to Done and the window remained open. Multiple staged setup GUI relaunches could trigger a second password submission. Live verifier metadata confirms an existing 0600 owner-only SAM; no password or hash was read.

Fix: The setup-only launch checks isConfigured and exits immediately when already configured. Successful Save closes the window rather than requiring another Done action. The button is disabled during helper execution and duplicate handler invocation is guarded. Explicit Change password from the menu continues to work. Password change while RDP is running announces disconnection and restarts the server to apply the new verifier. The existing streamlined single password field remains; its earlier duplicate confirmation field was not the cause.

Signed candidate .build/output/MacRemote-20261120T055918Z.app passed 25/25 CTest and signing. Direct smoke test of the signed app with the existing verifier confirmed that setup-only launch exits without displaying a form or modifying the verifier (mtime, ownership and permissions unchanged). The obsolete standalone setup UI process was shut down. The live 3389 server remains the historical H264/Progressive build, unchanged, pending a native Windows NLA end-to-end acceptance. No real password was submitted by this fix.

If the phrase refers to a Mac-side initial enrollment and a separate first Windows mstsc login, those happen on two different endpoints: the Mac creates a verifier while Windows must save its credential locally the first time. That cannot be removed by server-side setup alone.


## Credential reuse regression: primary evidence and decision

2026-11-20: Read-only investigation of actual Windows 11 mstsc and MacRemote logs. Windows Wininit event 13 at 2026-11-13 08:32:15 reports Credential Guard startup. The latest observed boot was also November 13. MacRemote had successful TLS/PAM desktop activations before the 14:12 NLA deployment, including 12:38:25 on November 20. Subsequent NLA sessions correlate with Microsoft-Windows-NTLM/Operational event 4021, including 14:48:40: Sign-On Type = Supplied Credentials, NTLMv2, reason ID 7 (IP-address target). The server logged the corresponding successful desktop activation at 14:48:43. The RDP target has no matching TERMSRV saved-credential entry in cmdkey /list. Win32_DeviceGuard SecurityServicesRunning contains 1.

The evidence establishes that the existing Credential Guard protection predates the NLA change and the currently working NLA connections use explicitly supplied credentials. Microsoft documents that Credential Guard prevents CredSSP from using saved or SSO credentials. Successful historical TLS/PAM activations alone cannot establish actual saved-credential usage rather than manual input or reconnection. Do not characterize absent credential entries as proof of a particular credential-saving rejection mechanism.

Acceptance: do not treat successful authentication, protocol negotiation, or unit test count as proof of saved-credential reuse. Use an approved test client and verify actual cold mstsc relaunch, server restart and successful connection without a new credential prompt, while preserving required security policy. For managed clients, any alternative identity/authentication route requires approval from the responsible administrator. No enterprise policy changes, credential access, authentication downgrade, or production restart performed during this investigation. Current NLA session retained; the repeated prompt itself remains unresolved.

References:
- https://learn.microsoft.com/windows/security/identity-protection/credential-guard/considerations-known-issues
- https://learn.microsoft.com/en-us/windows/security/identity-protection/remote-credential-guard
