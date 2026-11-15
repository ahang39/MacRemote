# ADR-0001: Select the RDP protocol foundation

- Status: **Accepted — FreeRDP 3.33.1 for M2 (ongoing compatibility verification)**
- Date: 2026-11-13
- Decision owner: MacRemote maintainers

## Context

MacRemote needs a standards-compatible RDP **server**, not merely an RDP client or a framebuffer stream. A mature existing protocol implementation reduces attack surface, maintenance burden and compatibility risk. Candidate libraries: **IronRDP** (Rust) and **FreeRDP** (C).

FreeRDP 3.33.1 (2026-11-10) specifically introduced a ScreenCaptureKit backend for macOS shadow server and improved frame backpressure/VideoToolbox support. This materially changes the previous assumption that IronRDP must be the first choice. Source: https://www.freerdp.com/2026/11/10/3_33_1-release

IronRDP: https://github.com/Devolutions/IronRDP
FreeRDP: https://github.com/FreeRDP/FreeRDP

## Decision

**Select FreeRDP 3.33.1 Shadow Server** as the MacRemote protocol and macOS screen-capture foundation. Compared with IronRDP, FreeRDP has an integrated ScreenCaptureKit backend and mature RDP graphics/channel handling, and was proven usable on the target Mac. The independent ZGFX decode test favored FreeRDP, but end-to-end screen workloads were not matched: the selection reflects overall implementation maturity and maintenance burden, not a claim of universal performance superiority. See [ADR-0005](0005-freerdp-integration.md).

## Evaluation protocol (M1)

In a separate, disposable spike environment, verify on real Apple Silicon macOS and Windows mstsc:

1. **Interoperability (30%):** TLS / NLA / CredSSP, display, input and modifiers; include native HID/Karabiner feasibility (ADR-0003), with evidence and versions recorded.
2. **Security (20%):** authentication surface, patch cadence, lifecycle, fuzz/testing support, safe session authorization.
3. **Performance (20%):** codec negotiation, H.264/AVC420/AVC444 capabilities, dirty regions, frame feedback and CPU/latency/bandwidth under identical conditions.
4. **Maintainability (15%):** upstream codebase health, server extensibility, ABI/FFI burden, upgrade diff.
5. **Delivery (10%):** clean macOS 14+ Apple Silicon build, packaging and supported APIs.
6. **Legal (5%):** licenses and obligations for linking, copying code and shipping binaries.

**Hard gates:** no anonymous control, usable input + display, reproducible mstsc connection, and acceptable distribution terms. Scores do not override failed hard gates.

Compare official functionality rather than assuming README claims equal tested behavior. Use [TESTING.md](../TESTING.md). Do not modify the existing NuoRDS installation.

## M1 progress (2026-11-13)

Source review found FreeRDP 3.33.1 Mac Shadow ScreenCaptureKit plus Quartz `CGEventPost`; `freerdp-shadow-cli` compiled locally on Apple Silicon at commit `65bcca1`. IronRDP server and EGFX compiled locally from `0a79fd2` using installed Rust 1.99.1; 44 server tests passed. Its high-level input callback drops the E1 flag (independent repro). At this earlier checkpoint neither had completed live mstsc, Karabiner or low-bandwidth benchmarks. Later tests confirmed local NLA/graphics using a shared headless FreeRDP client, including bandwidth shaping. Windows mstsc and Karabiner HID interoperability remain pending. See [M1 results](../../spikes/m1/RESULTS.md).

## M1 measured ZGFX performance (2026-11-13)

[Reproducible M4 ZGFX benchmark](../../benchmarks/m1/zgfx/REPORT.md): FreeRDP 3.33.1 was ~4.7–14.5x faster than IronRDP on identical compressed ZGFX decode payloads, while IronRDP Auto compression saved wire bytes in synthetic compressible workloads at a substantial CPU cost. The benchmark isolates ZGFX, not H.264, RDP FPS or input latency. The codec microbenchmark alone was insufficient to choose a full protocol foundation; the overall architecture decision now selects FreeRDP.

## M1 real loopback connection and frame processing (2026-11-13)

[Measured E2E test](../../benchmarks/m1/e2e/REPORT.md): both FreeRDP 3.33.1 and IronRDP connected and decoded bitmap graphics using the same headless FreeRDP GDI client over TLS/NLA on 127.0.0.1. Five unrestricted successful trials per server: median post-connect 16 ms FreeRDP, 41 ms IronRDP; median first paint 46 ms FreeRDP, 250 ms IronRDP. Tests at 5 Mbps (three pairs) and 2 Mbps (two pairs) also completed NLA; one 2 Mbps IronRDP **synthetic random-frame** session never painted within five seconds. **Screen sources and encoders differ**, so no matched-performance winner is established by these measurements. The broader integration and maintenance evaluation favors FreeRDP. The initial IronRDP screenshot example could not handle a repeated FreeRDP Server Demand Active PDU; the FreeRDP headless client worked with both.

## Consequences

- M2 directly links the pinned upstream FreeRDP 3.33.1 Shadow library via CMake; project and upstream license notices are kept separate.
- Keep M1 evidence, including source/build versions and reproducible benchmarks, and maintain IronRDP as an external technical reference.
- Require real mstsc, H.264/AVC444, secure user authorization, Karabiner and clipboard/IME validation before a public release.
