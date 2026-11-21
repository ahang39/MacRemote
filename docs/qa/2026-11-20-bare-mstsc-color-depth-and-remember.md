# Windows native mstsc 16-bit compatibility and credential persistence (2026-11-20)

## Evidence
- The user reports that plain mstsc direct host gives a protocol error with a black screen while a previously saved .rdp file connects.
- The generated working .rdp uses 32-bit color and disables CredSSP explicitly. Server logs from an unsuccessful connection show 1920x1080@16bpp and an RDPGFX startup followed by disconnection, while a successful login shows @32bpp, RDPGFX frame acknowledgments and PAM success.
- The 16 vs 32 difference is a grounded clue, not yet a definitive root cause; security protocol negotiation and Windows client settings also differ.

## Change made
- Add per-client 16-bit compatibility selection before RDPGFX initialization. If negotiated color depth is less than 32, suppress that connection's graphics pipeline and use existing FreeRDP compressed bitmap transport for login and desktop. Other clients with 32bpp continue to use H.264 and Progressive, including live hot switching and remembered device preferences.
- New pure helper in FreeRDP shadow_color_depth_compat.h and tests/test_rdp_color_depth_compat.c. Build and packaging continue using the pinned FreeRDP 3.33.1 patch.
- Full 26/26 CTest, Swift, signature, isolated H264 and Classic startup and patch-apply checks PASS.
- Signed candidate .build/output/MacRemote-20261120T020207Z.app, SHA256 b6efa4ad0243401cfdcf5072ea5d54d7e7cefa6b20922c688d6bd325a1c0402c.
- Previous installed MacRemote backed up at ~/Library/Caches/MacRemote/product/MacRemote-before-bare-mstsc-20261120.app.
- New signed MacRemote deployed at /Applications/MacRemote.app, GUI PID 30814, server PID 30824, TCP3389 IPv4 and IPv6 LISTEN, default h264. No Windows, BetterDisplay or account setting changed.

## Remember password request: impossible with stock server-side login page alone
- Windows mstsc Credential Manager owns persistence. A server-rendered RDP login page only displays pixels and receives input events, and cannot call Windows CredWrite or otherwise force the Windows client's secure password vault to persist the entered password on checkbox selection.
- Therefore a fake server-page checkbox labeled Remember password would be misleading; it was deliberately not implemented.
- Using a remembered client IP, hostname or reported client name instead of a real secret is unsafe, since these identities can be spoofed. Do not bypass Mac PAM on that basis.
- Windows' native save-credentials UI and the existing interactive cmdkey helper (which prompts for the Mac password once without command-line plaintext) can create a TERMSRV/127.0.0.1 credential in Windows Credential Manager. The existing PAM fast path accepts valid Client Info credentials on later connections when mstsc sends them. Whether forwarding occurs depends on Windows client policy. Server does not store the password.
- A server checkbox with automatic remembering would require a trusted Windows client extension or companion app able to persist and replay a signed per-device token on later connections; that is an explicit additional client dependency, not ordinary mstsc. None was installed.

## Outstanding acceptance
- After deployment, test plain mstsc by typing host only; look for per-client 16bpp compatibility log message and verify stable login and desktop.
- Verify the working saved .rdp still connects at 32bpp and hot-switch between H264 and Progressive remains available.
- Verify one-time Windows Credential Manager save and subsequent automatic credential reuse. If direct mstsc still has an error, compare X.224 security protocol negotiation, CredSSP flags and client-side Windows event logs. End-to-end Windows proof was not available during this build.
