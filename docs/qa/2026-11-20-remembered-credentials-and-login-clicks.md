# Remembered credentials + clickable MacRemote login (2026-11-20)

## Requirements
Daily Windows mstsc should reuse saved credentials to avoid retyping a Mac password; uncached clients can use the RDP-rendered MacRemote login form, which now supports mouse clicks in both fields and a Sign in button.

## Design
- The existing valid Client Info PDU -> macOS PAM fast path stays unchanged. No second account database, saved plaintext password, token impersonation or change to the H264/Progressive hot-switch protocol.
- Windows Credential Manager handles saving the user's Mac account password. A one-time Windows command with omitted password is: cmdkey /generic:TERMSRV/127.0.0.1 /user:ahang. Windows prompts for password interactively and saves it under its own login, not on the Mac.
- A separate daily RDP profile from tools/make-mstsc-profile.py --remembered includes the username, prompt for credentials:i:0, prompt for credentials on client:i:1, enablecredsspsupport:i:0 and TLS trust validation. The default diagnostic profile still forces a client-side credential prompt.
- Windows Credential Manager has its own OS policy and per-host identity. The 127.0.0.1:3389 target assumes the pre-existing local RDP forwarding. No passwords appear in the RDP profile or helper script.
- The per-client shadow_login_form.h supplies a pure click-hit-test for the CoreGraphics visual rectangles, converting Windows RDP top-left mouse Y to the login renderer's bottom-left Y. Account and Password gain focus on click, while Sign in submits through the same PAM path as Enter, only if both values are provided.
- Pre-auth mouse input is intercepted before Mac display coordinate offsets; button presses never reach Quartz. Post-auth mouse retains the existing path. The sign-in button is drawn on the login surface.

## Verification
- tests/test_rdp_login_form.c: live assertions on both 1920x1080 and 800x480 coordinate hitboxes, submit, missing password and outside clicks.
- tests/test_rdp_login_input_isolation.c: production callback routing, no real Mac preauth mouse, postauth input continuity.
- tests/test_rdp_login_render.c: synthetic canvas paints while real desktop pixel sentinel remains unchanged.
- Critical test correction: undef NDEBUG in these three tests so assertions are really executed in Release mode.
- tests/test_mstsc_profile.py: default and saved-credential RDP options, filename/format, no embedded password.
- Project signed build and 25/25 CTest passed, including three actual authentication tests. No real Windows saved-credentials login outcome yet verified for this revision.

## UX contract
There is no fake Remember password checkbox on the RDP-rendered login surface: a remote bitmap server cannot write directly to the Windows user's secure Credential Manager. The user saves credentials once in Windows and uses the daily .rdp thereafter. If no credentials are submitted, the clickable in-session login remains available. Verify both flows on real Windows mstsc.


## Deployment — 2026-11-20
- Signed candidate .build/output/MacRemote-20261120T014126Z.app; full native and Swift suite 25/25 PASS with live Release-mode assertions.
- Backed up prior signed /Applications/MacRemote.app to ~/Library/Caches/MacRemote/product/MacRemote-before-click-20261120.app. Deployed updated signed app with server SHA256 2ce8e012734b5a7746c3a7d032a6b1f35ab7bbe739ababc4297d26f42a0f5983.
- Final GUI PID 21807; final server PID 21819; listens TCP3389 IPv4+IPv6; --gfx h264 --headless; code signature and git diff check PASS. Corrected a duplicate GUI instance: terminated only superseded GUI PID13474 (no active server child); retained new GUI PID21807 and listener PID21819. No change to BetterDisplay, per-device codec memory or hot-switch patch.
- Created downloadable MacRemote-Remembered-Connection.zip containing a Windows .rdp profile, a one-time interactive cmdkey Windows .cmd setup, and instructions. Never contains a password. Windows saved-credential automatic PAM flow and real pointer clicks require user-side mstsc verification after installation; source-level tests alone are not client E2E proof.
