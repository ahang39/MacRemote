# M2 MacRemote local development

MacRemote directly links the native FreeRDP 3.33.1 Shadow Server library on macOS 14+ Apple Silicon or Intel. The build produces a self-contained local App; portable binary distribution requires the licensing and notarization steps listed in the release checklist.

## Build

    tools/build-dev-app.sh

The signed standalone App includes FreeRDP 3.33.1, its required runtime
dependencies, OpenSSL, and its dynamically loaded legacy provider.
When no FreeRDP checkout exists, the script fetches the pinned upstream
release, applies MacRemote patches, builds it and deletes the temporary
source/build tree. No permanent FreeRDP project is needed to run the App.
The default build uses ad-hoc code signing. Set MACREMOTE_SIGN_IDENTITY to a Keychain identity for stable local signing; this is not Developer ID notarization.

## CLI

    /Applications/MacRemote.app/Contents/MacOS/macremote-server status
    /Applications/MacRemote.app/Contents/MacOS/macremote-server doctor
    /Applications/MacRemote.app/Contents/MacOS/macremote-server serve --port 3389

The default graphics mode is Classic. Other graphics modes remain
experimental CLI-only options.

**Login:** use the Mac username and the user's ordinary Mac login password in the RDP client. No pairing, RDP-only password or SAM file. Upstream macOS Shadow authenticates the logged-in process account using PAM under TLS (NLA disabled). Certificate verification matters when using a real Mac login password over a network; avoid accepting unexpected certificates.

**Behavior:** all interfaces by default, port 3389 (standard RDP), keyboard/mouse enabled, no artificial client limit. Use --bind to specify IPv4/IPv6. Other service listeners and firewall settings are never modified.

## Windows mstsc 0xD06 graphics investigation

On 2026-11-14 Windows mstsc (LAN client) successfully entered
the FreeRDP Shadow session at 1920x1080, then the server requested native
2304x964. The RDPGFX dynamic channel opened; the server logged repeated
fast-path input-before-activation messages, missing font-list finalization,
no frame acknowledgments after eight in-flight frames, and a failed RDPGFX
channel read. The Windows client reported 0xD06. These observations point
to a graphics/finalization interoperability problem, not a rejected password,
but do not prove the root cause.

The production menu now uses the Windows mstsc-verified Classic
graphics path automatically. Experimental AVC420/AVC444 and Balanced
remain available to developers through the server --gfx CLI only.
No graphics selection or placeholder transfer-statistics rows appear
in the menu. The menu-bar popover closes on outside clicks.


## Menu bar development App

    tools/build-dev-app.sh

The app is placed in a unique timestamped directory under ~/Library/Caches/MacRemote/product. Clicking the native AppKit NSStatusItem opens the complete SwiftUI settings popover directly, with no extra action menu. The same dismissible popover opens when the app is activated from Finder or Spotlight. The native status item belongs to the registered MacRemote application and is managed by macOS and compatible menu bar managers, without launcher indirection. The panel displays Mac login, TLS+PAM, configurable port, Start/Stop and Screen Recording permissions. App launch does not automatically start sharing. Development Apps are ad-hoc signed by default; MACREMOTE_SIGN_IDENTITY selects a stable local identity. The bundle identifier is dev.macremote.app and the App has a native .icns icon. The App includes all runtime dependencies and needs no M1 cache; public Developer ID notarization is still outstanding.

## Menu bar compatibility

MacRemote creates a native AppKit NSStatusItem in its own registered
application, just as USB Volume and Virtual Mic do. Dimble can manage
this icon directly: no App launcher, helper or icon-hiding workaround
is necessary. Clicking the icon opens SwiftUI settings. Reopening the
App from Finder or Spotlight opens the same popover.

The earlier Dimble launcher workaround is no longer part of MacRemote.
No Dimble preferences are modified by MacRemote.

## Screen Recording permission / menu popover

FreeRDP Shadow needs macOS Screen & System Audio Recording permission for the
responsible MacRemote app process. If denied, the capture backend refuses
server initialization and no listener is opened. A status CLI started by a
different parent may inherit a different TCC attribution, so the GUI now
checks both its own and the capture helper's access.

Select Enable Screen Recording in the MacRemote settings, then allow MacRemote
in System Settings → Privacy & Security → Screen & System Audio Recording.
macOS may require quitting and reopening the app. The GUI invokes Apple's
normal consent prompt; it cannot silently grant itself this permission.

The menu bar popover must use SwiftUI's intrinsic content size. The previous
fixed height (530pt versus ~345pt actual content) shifted the popover down
from y=26 to y=237 after resizing. Using NSHostingController preferred size
restores proper anchoring; icon click must not activate a separate window.

## Tests

Every standalone App build executes 11 CTests and the Swift listen-port
persistence test before signing. The FreeRDP source and build directories
are temporary, including for tests. A clean bootstrap build and codesign
verification have passed without a pre-existing FreeRDP project.

Portable runtime verification: while the standalone App is running,
check the selected listening port (3389 by default) and inspect the server process loaded modules;
all third-party libraries, including the dynamically loaded OpenSSL
legacy provider, must originate in Contents/Frameworks. Verified after
the FreeRDP project was moved out of its original location.

## Built-in keyboard compatibility (2026-11-14)

MacRemote runs a native Karabiner basic-rule compatibility engine inside the RDP
server. It reads the selected Karabiner JSON profile (read-only), converts
native FreeRDP keyboard/mouse CGEvents, and watches for configuration updates.
Karabiner, Hammerspoon, virtual HID and auxiliary services do not need
to be running. If the JSON file does not exist, original Quartz input passes
through unchanged.

Current profile: 42 enabled rules and 75/75 parsed manipulators;
four Win+Arrow window commands are executed through native macOS
Accessibility APIs. Other shell commands follow the user JSON.
Unicode/IME input bypasses physical-key matching. Per-client held-key
cleanup and modifier ownership cover disconnect and multiple RDP sessions.

See ADR-0008 for the implemented path. Tests cover the real FreeRDP
Shadow callback and native compatibility rules. Live Windows mstsc UX
acceptance is pending; unsupported future rule features are counted
and passed through.

## TLS certificate diagnostics

MacRemote keeps its existing FreeRDP-generated TLS certificate in
~/Library/Application Support/MacRemote/shadow/. The pinned FreeRDP
3.33.1 upstream source logged a certificate-extraction error unconditionally,
even when certificate initialization succeeded. MacRemote's small FreeRDP
patch only logs that error on failure; it deliberately does not rotate a
certificate that RDP clients may already trust. Client-side certificate
trust remains part of the public-release security checklist.

The CLI defaults to TCP 3389. The native menu persists any valid custom
listen port using the listenPort user default; invalid edits do not replace
the previous saved value.

## P0 stability (2026-11-15)

- The pinned FreeRDP macOS backend already polls display changes and restarts
  ScreenCaptureKit streams after a display turns off or becomes available.
  MacRemote deliberately reuses that mechanism rather than adding a second
  capture watchdog.
- The menu-bar controller owns the native server process. Unexpected server
  exit triggers one automatic restart; explicit Stop/Quit never restarts it.
  After system wake, the UI refreshes its recording-permission state while
  FreeRDP handles capture recovery.
- A disconnected RDP client releases held keys and the original left mouse
  button; the last disconnected client clears FreeRDP's modifier and
  mouse-drag state.
- The standalone build runs CTest before signing and bundling. Latest clean
  build: 11/11 green. Actual crash-kill recovery and three consecutive
  new TCP/X.224 RDP negotiations passed on the Mac.
- Real Windows mstsc reauthentication and physical sleep/monitor-change
  acceptance remain client-side/manual tests; the TCP negotiation test
  does not exercise an authenticated desktop session.

## Pending release milestones

- Real Windows mstsc: successful macOS password login, reconnect, H.264/AVC444, image quality and password/certificate UI.
- Real Windows mstsc acceptance of built-in Karabiner basic-rule compatibility, window actions, Insert/Help, and IME semantics.
- Bidirectional RDP clipboard with macOS/WeChat IME newline and duplicate paste fixes.
- Negotiated codec, frame/bytes and RTT telemetry.
- Developer ID notarization, installer, third-party notices and project license; standalone local signing is complete.
