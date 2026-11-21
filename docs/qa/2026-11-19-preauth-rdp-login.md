# MacRemote — zero-setup mstsc login screen implementation

Date: 2026-11-19 (development build, not deployed).

## First-principles requirement
A user should be able to open unmodified Windows mstsc, enter a MacRemote host, and sign in with the current macOS account/password even if Windows supplied no Client Info credentials. The existing valid-client fast path remains unchanged. No extra authentication database, NLA identity verifier, local AppKit password window, or custom Windows application is introduced.

## Root evidence
- Current FreeRDP 3.33.1 Shadow with TLS / PAM checks Client Info username and password in shadow_client_post_connect. If absent, old server returned ERRINFO_SERVER_INSUFFICIENT_PRIVILEGES and disconnected before a login UI was ever offered.
- FreeRDP Shadow defines a global lobby but its server defaults mayView/mayInteract true, and virtual channels historically initialized before the PAM verification. Reusing this lobby as-is is not a trustworthy authentication boundary.
- Pinned Mac backend client count increases only from mac_shadow_client_connect. ScreenCaptureKit starts on this event, so deferring that callback until PAM succeeds also avoids capturing the Mac desktop during pre-auth login.
- Microsoft MS-RDPBCGR supports an RDP server-rendered login stage after TLS/RDP establishment.

## Implemented code
- New reproducible FreeRDP pinned patch patches/freerdp-3.33.1-macremote-login-surface.patch, last in tools/build-dev-app.sh. Upstream source remains pinned at 3.33.1, original protocol and PAM callback retained.
- Per-client state in FreeRDP public shadow struct: loginPending, loginPaintPending, authenticated, loginSurface and loginForm. Prior to PAM, mayView/mayInteract false.
- If Client Info already contains valid username/password: same PAM path, then access to the desktop is granted and normal cliprdr/rdpsnd/audin/rdpgfx channels initialized.
- If absent/invalid: allocate one synthetic client-specific RDP framebuffer at the negotiated remote size. A native C renderer backed by CoreGraphics/CoreText draws English account/password inputs, masked password and failure state. It is independent of the actual macOS desktop buffer and does not create an AppKit window.
- Login keyboard handler processes RDP scan codes, Tab/Enter/backspace and Unicode events into per-client bounded buffers. Submits to original checkpw PAM callback. Wipes password immediately; up to 5 failures before refusing further attempts. A successful login is the only grant to mayView, mayInteract, Mac ClientConnect and channel init. The login surface is destroyed on success and on connection teardown.
- Every upstream Quartz keyboard/mouse callback is now gated on authenticated, regardless of mayInteract. Login keystrokes only affect the synthetic input form. Pointer/audio surface messages dropped until authenticated. The login bitmap is sent in the RDP client event loop, without requiring a ScreenCaptureKit refresh or subscriber. Before authentication, no desktop resizing from macOS is attempted.
- Existing graphics, display and per-client profile preferences remain separate.

## Independent verification
- Production C form model tests: username/password independence, scan-code shift/caps, Unicode, backspace, submit, bounded storage and wiped password.
- New test_rdp_login_render links actual production FreeRDP shadow_login_render.c and shadow_surface.c, paints a synthetic login page, and asserts every pixel of a sentinel-filled real desktop framebuffer remains unchanged across normal and error renders.
- New test_rdp_login_input_isolation links actual production shadow_input.c, injects keyboard and mouse callbacks, confirms zero real Mac calls before auth even when mayInteract is TRUE, routes login keystrokes only into the login form hook, and confirms normal Mac keyboard/mouse callbacks only after authenticated.
- Full project CTest, Swift preferences/UI tests, signed App packaging and exact FreeRDP patch application verified through build-dev-app.sh.
- Built a separate sample FreeRDP client at .build/preauth-client-build/client/Sample/sfreerdp, with test-only framebuffer telemetry. Initially failed because missing client-side drdynvc/rdpdr addins; rebuilt with client channel support. After that, this headless sample still rejects the TLS server's DemandActive with unexpected MCS channel id 0000. The **same headless test-client failure reproduces against the older known-good MacRemote build** (tested against .build/output/MacRemote-20261119T115645Z.app). This distinguishes a broken test harness from evidence of a new server login regression. No Windows mstsc user-visible proof has yet been obtained.
- Isolated ports and invalid account test never use actual Mac password. No passwords or raw screen data logged in production.

## Go/no-go
Current build is a development candidate, not ready to release or replace the working 3389 listener until Windows native mstsc proves:
1. Connect to isolated port without saved credentials -> synthetic login page visible, client remains connected.
2. Pre-auth: no Mac desktop pixels / clipboard / audio / Quartz injection, including resize, wrong password and disconnect.
3. Enter real credentials in the login page -> PAM success, same RDP TCP session transitions to desktop; keyboard/mouse and audio/clipboard restore.
4. A client that supplies valid credentials in Client Info continues to connect directly with no login page.
5. Same tests in Classic, H.264 (and Progressive) with three fresh reconnects and a pre-auth disconnect.
Keep self-signed TLS identity warning visible; stable TLS certificate trust is part of using the real account password.

## Status
No changes to installed /Applications/MacRemote.app, TCP 3389, BetterDisplay, Windows credential cache, system security or networks. No git commit/push/release. User's existing working RDP session remains unaffected.

## Source references
- Microsoft MS-RDPBCGR client authentication / server login: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/ef9db6a5-36f4-4613-84b3-97501679d210
- Pinned FreeRDP shadow_client.c, shadow_input.c, shadow_channels.c and Mac/mac_shadow.c
- docs/qa/2026-11-19-mstsc-credential-prompt.md
