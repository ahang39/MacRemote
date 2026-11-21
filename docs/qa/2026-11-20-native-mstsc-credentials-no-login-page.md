# Windows native mstsc credentials — in-session login page removed (2026-11-20)

## Decision
Use Windows mstsc's own credential prompt and Windows Credential Manager for the Mac account password. Keep FreeRDP Shadow TLS + macOS PAM checkpw, no additional user database and no server password cache. The RDP in-session sign-in page, mouse form and custom login renderer have all been removed from the production build.

## Native client behavior
- First-time Windows command: mstsc /prompt /v:127.0.0.1:3389. Microsoft documents /prompt for requesting credentials from the Windows client. Select Remember me when offered by Windows.
- Subsequent: mstsc /v:127.0.0.1:3389 with no /prompt so stored credentials may be reused, or the existing known-working saved RDP profile.
- Existing tools/make-mstsc-profile.py creates a password-free UTF-16LE TLS/PAM compatible RDP file with enablecredsspsupport:i:0 and a 32bpp profile; --remembered enables Windows saved credential usage. Windows client policies decide whether a prompt or saved credentials can be forwarded.
- The user's 127.0.0.1 address represents preexisting client TCP forwarding. Credential Manager target names need to match the address mstsc connects to. No passwords or certificates were accessed or exported.
- MacRemote cannot force Windows CredWrite via a server-rendered checkbox, so that checkbox and the entire server login page are intentionally gone. When Windows supplies no credentials, the server now rejects the connection instead of presenting a remote password form; the Windows /prompt or existing saved RDP profile is the native recovery.

## Focused source implementation
- tools/build-dev-app.sh removed the entire pinned FreeRDP 3.33.1 macremote-login-surface patch, replacing it with a 1792-byte FreeRDP 3.33.1 mstsc-color-depth patch. The standalone patch retains the negotiated below-32bpp classic bitmap fallback and leaves 32bpp AVC420/Progressive unchanged.
- The default FreeRDP Shadow PostConnect callback is restored: Client Info username/password -> original macOS PAM checkpw; invalid or missing credentials are rejected, no server login UI. The retired login patch was archived outside production under .build/archived-login-page-20261120.patch.
- Removed three login-only CTests and archived their sources and prototype under .build/archived-auth-login-20261120; Windows RDP credential profile tests and color-depth compatibility tests remain.
- Live H264/Progressive codec switch, client device preference persistence, headless fallback and graphical output settings are unchanged.
- Updated both READMEs with official Windows /prompt first-time usage and credential reuse.

## Verification and deployment
- Exact pinned FreeRDP patch application, 23/23 native CTest, Swift tests and existing-signature bundled arm64 build PASS.
- Signed build .build/output/MacRemote-20261120T022018Z.app; server bundle strings/source checks confirm custom login UI removed and hot switch entry retained.
- Independent loopback H264 and Classic listeners started successfully without touching 3389.
- Prior signed App backed up under Library/Caches/MacRemote/product/MacRemote-before-native-cred-20261120.app.
- Installed /Applications/MacRemote.app, binary SHA256 8e83d9bf1e1c90cc9bdc094b9199d3e1862b546660c71e3e2069b0451353dfba. Final GUI PID39394, RDP PID39410, IPv4/IPv6 TCP3389 LISTEN, mode --gfx h264 --headless, codesign PASS. No changes to Windows, BetterDisplay or macOS security.
- The final Windows native /prompt and repeat credential reuse have NOT yet been independently verified with this new build. Historical user verification: saved Windows RDP file using prior saved credentials had successfully reached desktop. Do not equate signed startup and automated tests with new Windows end-to-end authentication.

## Next Windows acceptance
1. Use mstsc /prompt /v:127.0.0.1:3389, enter Mac account/password in Windows UI, select Remember me if present, and verify desktop.
2. Disconnect; use mstsc /v:127.0.0.1:3389 or the existing saved RDP file. Check if Windows reused credentials.
3. Verify 32bpp live AVC420/Progressive hot switch and that invalid account cannot view desktop. 16bpp sessions should use classic.
4. If no native prompt or no saved forwarding, compare Windows-side policies, credential target, TLS and CredSSP flags. Mac server cannot override Windows Credential Manager.
