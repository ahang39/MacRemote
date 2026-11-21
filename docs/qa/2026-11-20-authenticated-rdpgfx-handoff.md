# RDPGFX login-to-desktop handoff fix (2026-11-20)

## Real Windows mstsc evidence
Old development build showed MacRemote's synthetic login page correctly. After valid macOS credentials, PAM succeeded, but initializing RDPGFX/H.264 after authentication caused Windows to disconnect with a protocol error. Switching only to Classic restored actual Windows login. Causal association with late RDPGFX initialization is strong, though the specific Windows decoder/protocol rejection is not independently confirmed.

## Source correction
- Pinned FreeRDP 3.33.1 patch freerdp-3.33.1-macremote-login-surface.patch now initializes only the RDPGFX protocol context before choosing the authentication fast path or per-client synthetic login surface.
- Before authentication, login pixels are sent over the negotiated RDPGFX channel after capabilities confirmation (bitmap fallback for Classic); no ScreenCaptureKit Mac image, audio/clipboard or Quartz input is unlocked.
- After valid PAM, the same RDPGFX dynamic channel and surface are reused for real desktop frames. Non-graphics channels become active only after authentication. No late RDPGFX initialization.
- H.264 / Progressive in-session hot-switch code and per-device preferences are unchanged.

## Verification and deployment
- Source patch apply check, 25/25 native CTest, Swift tests, and signed arm64 standalone build passed. Isolated H.264 localhost server startup passed.
- Candidate .build/output/MacRemote-20261120T012929Z.app signed using Ahang Personal Code Signing.
- Prior installed Classic version and preferences fully backed up under Library/Caches/MacRemote/product/MacRemote-before-authgfx-20261120.app and dev.macremote.app-prefs-before-authgfx-20261120.plist.
- Replaced /Applications/MacRemote.app and restarted service with graphicsMode=h264, GUI PID 13474 and TCP 3389 server PID 13491. Installed SHA256 fe85e122d405410ffcf881aa96bee9f2da0b60424a9c7e8d572132df755f6418, signature verified.
- Generated an empty-username and empty-domain Windows RDP connection profile pointing to the user's previous 127.0.0.1:3389 target, no password included. Server PAM is unchanged.

## Outstanding acceptance
**Not yet confirmed on real Windows mstsc after the fix.** User to test synthetic login page, PAM success, same TCP session transitioning to H.264 desktop, Progressive -> H.264 switching, and reconnect. If the protocol failure remains, return to Classic, then use prior backed-up version if needed.
