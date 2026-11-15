# MacRemote

**Remote into your Mac with Windows Remote Desktop — keep the shortcuts, clipboard, and workflow you already know.**

MacRemote brings native RDP access to macOS. Use Windows' built-in **Remote Desktop Connection (`mstsc`)** or another standard RDP client to control your Mac's existing desktop. No custom Windows client, browser session, or cloud relay required.

[简体中文](README.zh-CN.md) · [Build](#build-and-run) · [Architecture](docs/ARCHITECTURE.md) · [Contributing](CONTRIBUTING.md)

[![CI](https://github.com/ahang39/MacRemote/actions/workflows/source-checks.yml/badge.svg)](https://github.com/ahang39/MacRemote/actions/workflows/source-checks.yml)
![macOS](https://img.shields.io/badge/macOS-14%2B-222222?logo=apple)
![CPU](https://img.shields.io/badge/CPU-Apple%20Silicon%20%7C%20Intel-222222)

## Download

**[MacRemote v0.1.0 — Initial Ad-hoc Preview](https://github.com/ahang39/MacRemote/releases/tag/v0.1.0-adhoc.1)** — macOS 14+.

| Mac | Download |
| --- | --- |
| Apple Silicon (M1/M2/M3/M4 and newer) | [ARM64 DMG](https://github.com/ahang39/MacRemote/releases/download/v0.1.0-adhoc.1/MacRemote-v0.1.0-macos-arm64.dmg) |
| Intel (x86_64) | [Intel DMG](https://github.com/ahang39/MacRemote/releases/download/v0.1.0-adhoc.1/MacRemote-v0.1.0-macos-x86_64.dmg) |

Ad-hoc builds are not notarized: drag the app into Applications; if the first launch is blocked, choose **System Settings → Privacy & Security → Open Anyway**. Grant Screen & System Audio Recording before starting the RDP service.

## Why MacRemote?

### Windows-native remote desktop

Open `mstsc`, enter your Mac's address, and use the familiar Windows RDP workflow. MacRemote serves the **existing logged-in macOS desktop** through FreeRDP Shadow and ScreenCaptureKit, with keyboard and mouse input, configurable listening port, and a compact native SwiftUI menu bar app.

### Your Karabiner shortcuts, even over RDP

Most remote input paths bypass macOS keyboard remappers. MacRemote instead **reads your active Karabiner-Elements profile** and interprets supported **basic manipulator** rules inside the RDP input pipeline:

- Key remapping, modifiers, app-specific conditions and mouse-button mappings
- In-process native macOS window actions for supported shortcut rules
- Automatic configuration refresh, with no extra background remapping service
- Normal Quartz input when Karabiner is not installed or configured

The compatibility layer supports the basic-rule subset, rather than every Karabiner feature. [Implementation details](docs/adr/0008-inprocess-karabiner-compat.md).

### Clipboard that understands Windows

Copy text and images between Windows and macOS over the standard RDP clipboard channel. Text is normalized to **Windows CRLF line endings (`\r\n`) on both sides**, making multiline content behave consistently across editors, terminals and input methods. Clipboard loop handling and Windows bitmap interoperability are built in.

## Features at a glance

| | |
| --- | --- |
| **Standard RDP** | Windows `mstsc` and other RDP clients; FreeRDP 3.33.1 Shadow |
| **Mac authentication** | Existing macOS user credentials via TLS + PAM |
| **Desktop capture** | ScreenCaptureKit captures the logged-in display |
| **Keyboard & mouse** | Quartz input + built-in Karabiner basic-rule compatibility |
| **Clipboard** | Bidirectional text/images, PNG/DIB and Windows CRLF normalization |
| **Native control** | SwiftUI menu bar controls, start/stop, permissions and persistent port |
| **Standalone build** | Bundled runtime dependencies, no Homebrew runtime needed on the target Mac |

Windows `mstsc` connectivity has been verified with the **Classic** graphics path. H.264/AVC444 negotiation is an active [development area](docs/m2/AVC444.md).

## Build and run

**Requirements:** macOS 14+ with a supported 64-bit Mac, Xcode Command Line Tools, and Homebrew build dependencies (CMake, Ninja, pkg-config, Opus, OpenSSL 4 and json-c). The build script retrieves pinned FreeRDP 3.33.1 sources when necessary.

```bash
git clone https://github.com/ahang39/MacRemote.git
cd MacRemote
./tools/build-dev-app.sh
```

The generated `MacRemote-*.app` is placed under `~/Library/Caches/MacRemote/product/`, with runtime libraries bundled. Open it, allow **Screen & System Audio Recording**, and start the RDP service from the menu bar.

On Windows, run `mstsc`, connect to your Mac's IP address (TCP **3389** by default), and sign in with your macOS account. The port can be changed and is remembered between launches.

For build options, signing and test commands, see the [build guide](docs/m2/README.md).

**Network security:** use a trusted private network or VPN and verify the RDP certificate before entering your Mac password. Authentication currently uses TLS + PAM without NLA; avoid exposing the listener directly to the public Internet. See [Security](SECURITY.md).

## Under the hood

```text
Windows mstsc / standard RDP client
                 |
         FreeRDP Shadow
          /     |     \
 ScreenCaptureKit  Input  CLIPRDR
                      |
             Karabiner-compatible
              native input rules
                      |
                  macOS desktop
```

MacRemote's RDP server is implemented in C/Objective-C with a native AppKit/SwiftUI interface. It extends pinned FreeRDP via focused upstream integration changes instead of requiring proprietary protocols or a second remote-control app.

Browse the [architecture](docs/ARCHITECTURE.md), [design decisions](docs/adr/), [tests](docs/TESTING.md) and [benchmarks](benchmarks/). The local build runs 11 native CTests plus a Swift preferences regression test.

## Roadmap

- [ ] Complete Windows `mstsc` regression coverage for Karabiner mappings, clipboard, IME, reconnect and sleep/wake
- [ ] Improve certificate trust UX and desktop session recovery
- [ ] Stabilize accelerated H.264/AVC444 graphics and publish reproducible performance measurements
- [ ] Prepare a signed, notarized binary release after third-party dependency licensing review

Track release engineering in the [checklist](docs/RELEASE_CHECKLIST.md).

## Contributing

Issues, reproducible bug reports, compatibility findings and pull requests are welcome. See [Contributing](CONTRIBUTING.md) and [Security](SECURITY.md).

## License

See [LICENSE](LICENSE) for project terms and [third-party notices](THIRD_PARTY_NOTICES.md) for dependency licenses.
