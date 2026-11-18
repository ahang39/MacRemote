<p align="center">
  <img src="docs/assets/macremote-icon.png" alt="MacRemote" width="96">
</p>

<h1 align="center">MacRemote</h1>
<p align="center"><strong>Windows Remote Desktop. Now for your Mac.</strong></p>
<p align="center">
  Open `mstsc` on Windows and connect to the Mac you already use.<br>
  No extra Windows app. No cloud account. No relay server.
</p>

<p align="center">
  <a href="https://github.com/ahang39/MacRemote/releases/tag/v0.2.1-adhoc.1"><img src="https://img.shields.io/badge/release-v0.2.1--alpha-D48752" alt="v0.2.1 alpha"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-444444?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-%26%20Intel-444444" alt="Apple Silicon and Intel">
  <a href="https://github.com/ahang39/MacRemote/actions/workflows/source-checks.yml"><img src="https://github.com/ahang39/MacRemote/actions/workflows/source-checks.yml/badge.svg" alt="Source checks"></a>
</p>
<p align="center">
  <a href="https://github.com/ahang39/MacRemote/releases/tag/v0.2.1-adhoc.1"><strong>Download for macOS</strong></a>
  &nbsp;·&nbsp; <a href="#get-started">Get started</a>
  &nbsp;·&nbsp; <a href="#features">Features</a>
  &nbsp;·&nbsp; <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="docs/assets/macremote-settings.png"><img src="docs/assets/macremote-settings.png" width="420" alt="Actual MacRemote menu bar app showing RDP output, HiDPI scaling, H.264 target bitrate and remote audio controls"></a>
</p>
<p align="center"><sub>Real macOS menu bar interface · Personal account details blurred</sub></p>

## Why MacRemote?

Windows already has an excellent RDP client. MacRemote gives your **existing, logged-in Mac desktop** a standard RDP endpoint—without another viewer, another identity system, or a subscription.

- **Use Windows' built-in client.** Open `mstsc`, connect over your LAN or VPN, and sign in with your Mac account.
- **Keep your Mac workflow.** Native keyboard and mouse input, bidirectional text/image clipboard, and built-in compatibility for supported Karabiner-Elements basic rules.
- **Make Retina readable.** Choose the RDP output resolution separately from the macOS HiDPI desktop. Adjust UI scale without forcing the remote video to use that same resolution.
- **Tune video and audio per client.** VideoToolbox H.264/AVC420 with live 1.4 / 2.0 / 4.0 Mbps targets, stereo Opus remote audio, volume and mute preferences.
- **Less work while disconnected.** Screen and system-audio capture start when a client connects and stop after the last disconnects.
- **A real Mac app.** Compact SwiftUI menu bar controls; self-contained binaries with pinned runtime dependencies—no Homebrew required to run the downloaded app.

## Get started

**Latest preview: [v0.2.1-adhoc.1](https://github.com/ahang39/MacRemote/releases/tag/v0.2.1-adhoc.1)** · macOS 14 or newer.

| Your Mac | Download |
| --- | --- |
| Apple Silicon (M1, M2, M3, M4 and newer) | **[MacRemote for Apple Silicon (.dmg)](https://github.com/ahang39/MacRemote/releases/download/v0.2.1-adhoc.1/MacRemote-v0.2.1-macos-arm64.dmg)** |
| Intel (x86_64) | **[MacRemote for Intel (.dmg)](https://github.com/ahang39/MacRemote/releases/download/v0.2.1-adhoc.1/MacRemote-v0.2.1-macos-x86_64.dmg)** |

1. Open the DMG and drag **MacRemote.app** into **Applications**. Grant **Screen & System Audio Recording** when prompted.
2. Start the RDP server from the menu bar (default **TCP 3389**).
3. On Windows, launch `mstsc`, enter `MAC_IP:3389`, and authenticate with your existing macOS username and password.

These preview packages use **ad-hoc signing** and are **not notarized**. If macOS blocks the first launch, use **System Settings → Privacy & Security → Open Anyway**. Connect over a trusted private network or VPN; don't expose TCP 3389 directly to the Internet.

> [!NOTE]
> The [v0.2.1-adhoc.1 release](https://github.com/ahang39/MacRemote/releases/tag/v0.2.1-adhoc.1) and its source archives are published from the same source revision as the attached DMGs. The older v0.2.0 release tag remains unchanged.

## Features

| | What you get |
| --- | --- |
| **Standard RDP** | Native Windows `mstsc` support, FreeRDP 3.33.1 Shadow, TLS + macOS PAM login |
| **HiDPI display** | Separate RDP output and Mac UI scaling; 8 scale levels from 100% to 200%; reuse compatible existing HiDPI modes |
| **Per-device settings** | Remember a client's output resolution, nominal scale, selected HiDPI mode, video target and audio preferences |
| **H.264 video** | VideoToolbox accelerated AVC420, live bitrate selection and display/cursor coordinate handling |
| **Remote sound** | 48 kHz stereo Opus over `rdpsnd` when negotiated by the client; remote gain and strict mute |
| **On-demand capture** | Suspend ScreenCaptureKit video/audio capture after the last client disconnects; restart for a new client |
| **Keyboard & mouse** | Native Quartz input and an in-process Karabiner basic-rule compatibility layer |
| **Clipboard** | Two-way Unicode text and image transfer with PNG/DIB handling and line-ending normalization |
| **Native management** | SwiftUI status menu, permissions, configurable port, start/stop and recovery controls |

### Retina, without a one-size-fits-all desktop

MacRemote separates **transport pixels** from **macOS logical desktop pixels**. Pick an RDP output such as 1920 × 1080, then choose **100%, 105%, 110%, 120%, 135%, 150%, 175% or 200%** Mac UI scaling. It reuses matching existing HiDPI modes; a missing mode can be created on demand and loaded after a macOS restart.

<p align="center">
  <a href="docs/assets/macremote-hidpi-scales.png"><img src="docs/assets/macremote-hidpi-scales.png" width="420" alt="MacRemote's actual 8-level HiDPI scaling menu"></a>
</p>
<p align="center"><sub>Eight scaling levels, showing the actual resolved HiDPI sizes</sub></p>

### Built with real-client measurements

In a controlled Windows `mstsc` test at **2 Mbps downlink + 80 ms added RTT**, switching the AVC420 video target from **4.0 to 1.4 Mbps** reduced the median scrolling downlink volume by **44%** and the first visible scrolling feedback from **3.30 s to 0.99 s**. The measurement used a synthetic scrolling workload; see the [test setup and results](docs/qa/2026-11-17-mstsc-wan.md).

## Under the hood

`Windows mstsc → RDP over TLS → FreeRDP Shadow → ScreenCaptureKit / VideoToolbox → your logged-in Mac desktop`

MacRemote combines C/Objective-C server components with an AppKit/SwiftUI menu bar app. It uses existing macOS capture and input APIs, bundles its dependencies, and doesn't require a proprietary protocol or a cloud service.

**Current scope:** the already logged-in desktop, rather than macOS's pre-boot/login screen. Authentication uses TLS + PAM (no NLA at present). Accelerated AVC444 remains experimental; Windows `mstsc` behavior, audio negotiation and reconnect edge cases continue to be tested.

Read the [architecture](docs/ARCHITECTURE.md), [technical decisions](docs/adr/), [test matrix](docs/TESTING.md), and [release checklist](docs/RELEASE_CHECKLIST.md).

## Build from source

On macOS 14+ with Xcode Command Line Tools, CMake, Ninja, pkg-config, Perl and Python 3:

```bash
git clone https://github.com/ahang39/MacRemote.git
cd MacRemote
./tools/build-dev-app.sh
```

The standalone app is generated under `.build/output/`. The build pins FreeRDP and builds private dependencies. See the [build guide](docs/m2/README.md). Build from `main` for the latest preview source.

## Project

This is an **alpha preview**, developed with real Windows RDP compatibility and reproducible testing as priorities. Contributions and clear bug reports are welcome: [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Issues](https://github.com/ahang39/MacRemote/issues).

**License:** [PolyForm Noncommercial 1.0.0](LICENSE) for MacRemote; bundled dependencies retain their [respective licenses](THIRD_PARTY_NOTICES.md).

## Friends

[LINUX DO — 新的理想型社区](https://linux.do/)
