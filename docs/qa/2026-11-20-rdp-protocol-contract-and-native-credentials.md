# MacRemote — protocol contract and native Windows credential UX
2026-11-20

## Real user objective
Use stock Windows mstsc for daily Mac remote access: one-time password entry, Windows Credential Manager keeps it, later one-click login without a MacRemote-generated page, correct full-height image, unchanged H264/Progressive hot switching and per-device settings. Do not require changes to BetterDisplay.

## Independent source evidence
- Stock mstsc default: Windows reported 1920x1080@16bpp, screen half-black/duplicated. Existing saved RDP profile: 1920x1080@32bpp, screen rendering works. This is a client-profile difference, not proof of a faulty macOS capture.
- The live recovered server log at 10:59:28 shows a 32bpp client but still logs the synthetic login surface; at 10:59:31 it logs authentication via that login page. Thus opening the saved RDP profile is NOT proof Windows sent its stored password.
- FreeRDP Shadow classic path previously selected NSCodec/RemoteFX SurfaceBits after disabling RDPGFX; that sender fixes bmp.bpp=32 although native mstsc negotiated 16. Microsoft MS-RDPNSC explicitly specifies NSCodec only in 32bpp sessions. This violates the wire pixel-format contract, explaining repeated/black pixels.
- Earlier removing the server login UI resulted in multiple PAM -1 failures at both 16bpp and 32bpp. A Windows local mstsc prompt does not prove the remote Client Info PDU includes credentials. The old server error did not distinguish missing fields from invalid PAM credentials.
- Windows mstsc documents Default.rdp and per-connection profiles; they can carry different bit-depth and CredSSP values. The known-good settings use username, TLS without CredSSP and 32bpp.

## Decision
1. Rendering is chosen from the client negotiated color depth. Below 32bpp use real FreeRDP 16bpp BitmapUpdate and bypass all 32bpp NSCodec/SurfaceBits and RDPGFX paths. At 32bpp preserve H264/Progressive and hot switching.
2. For authentication, the server logs only whether Client Info username/password are present (without values) when PAM rejects, distinguishing client credential submission from bad credentials.
3. Windows credentials belong to Windows Credential Manager; a per-target stock mstsc profile + Start shortcut preserves the proven user experience without overwriting global Default.rdp, which may affect other RDP hosts.
4. NLA/CredSSP is not a free PAM adapter: NTLM and Kerberos need a compatible server authentication backend, not only macOS local PAM. Do not add NLA/SAM emulation until direct client evidence shows a need and a secure implementation.

## Work completed
- Updated reproducible pinned FreeRDP patch patches/freerdp-3.33.1-mstsc-color-depth.patch, preserving native no-page Client Info -> PAM authentication and the existing H264/Progressive codecs; included nonsecret credential presence diagnostics.
- Existing tests/test_rdp_color_depth_compat.c and tests/test_legacy_bitmap_16bpp_roundtrip.c check codec selection and actual encoding/decoding of 1920x1080 top/middle/bottom tiles, including the final 56-pixel row.
- Signed candidate .build/output/MacRemote-20261120T031629Z.app compiled; patch applied; 24/24 native CTest and Swift tests passed; signature and isolated H264/Classic loopback starts passed. Actual Windows mstsc E2E has not yet validated this candidate.
- New tools/windows/Install-MacRemote.ps1 is a user-level stock-mstsc installer: either preserve the bytes of a known-good client .rdp profile or generate TLS, 32bpp and non-CredSSP settings, save it to Windows AppData with a backup, create a Start menu shortcut, and optionally save Mac credentials with an interactive Windows cmdkey prompt. No password value is written to the script or RDP file. Windows execution remains unverified.
- User ZIP MacRemote-Native-Connection-v2.zip contains a Windows launcher, known-good sample .rdp, installer and explanations. User may drag their exact own proven-working .rdp onto the launcher.

## Deployment gate
Currently installed /Applications/MacRemote.app remains the earlier recovered Classic + login fallback version, server PID50292, server binary SHA256 9a41a3d6656e04a6bd9219475d0d1b047507e5fecf613b1038f5b585f27b7b18. It remains TCP3389 LISTEN; no replacement, restarting, password or BetterDisplay changes in this task. This intentional non-deployment prevents locking the user out as happened on the previous native-no-page attempt.

Before deploying the no-page signed candidate, prove Windows actually sends saved credentials: from the new Start menu shortcut connect to the current server, and verify its existing log does NOT show synthetic surface ready. If it shows that string, Windows did not send usable Client Info and automatic login is NOT ready; continue protocol diagnosis, do not remove fallback.
After that, require real Windows evidence for full-height 16bpp and 32bpp rendering, successful credential reuse, and H264/Progressive hot switch.

## External standards
- Microsoft NSCodec: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpnsc/d1fbd46e-57d7-4a4c-b5b6-d7e7a8d3dcc1
- Windows mstsc default RDP settings: https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/mstsc
- Credential Manager: https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cmdkey
- FreeRDP NLA issue: https://github.com/FreeRDP/FreeRDP/issues/13567
