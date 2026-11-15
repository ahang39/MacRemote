# MacRemote M1 — Real loopback RDP end-to-end measurements

Measured 2026-11-13 on Mac mini M4 / 24 GB, macOS 27.0.1, Apple Silicon.

**Both server implementations passed TLS + NLA, real standard-RDP session activation, bitmap graphics transport, and GDI frame processing with the SAME headless FreeRDP client.**

**Workloads differ:** IronRDP 0a79fd2 runs its upstream 1920×1080 synthetic random-rectangle demo with an update approximately every 100 ms; FreeRDP 3.33.1 (65bcca1) runs macOS ScreenCaptureKit Shadow and captures the active physical desktop. Consequently, byte rates, frame callbacks, server CPU and RSS are NOT a fair protocol speed ranking.

## Unrestricted loopback (five full sessions for each server)

Native Release builds, NLA on, RDP legacy bitmap updates, GFX/RFX disabled, 5 seconds of active connection. Five independent trials interleaved; table is medians. No graphical client window or synthetic keyboard input.

| Metric | IronRDP (synthetic) | FreeRDP (real macOS capture) |
| --- | ---: | ---: |
| Connections with first paint | 5/5 | 5/5 |
| Client process start → post-connect/GDI init | 41 ms | 16 ms |
| Client process start → first decoded paint | 250 ms | 46 ms |
| GDI paint callbacks in ~5s | 45 count | 141 count |
| Server→client encrypted TCP bytes | 21.72 MB | 7.35 MB |
| Client→server encrypted TCP bytes | 4.39 KB | 15.23 KB |
| Server CPU time | 0.41 s | 0.91 s |
| Client CPU time | 0.21 s | 0.43 s |
| Server peak RSS | 30.67 MiB | 74.92 MiB |
| Client peak RSS | 78.39 MiB | 76.86 MiB |

Connection time includes process setup and GDI initialization, not merely TLS. First paint depends on capture and image generation. GDI callback counts are NOT monitor-presented FPS. CPU time and max RSS are per process via macOS wait4(), not codec-only measurements.

## Loopback bandwidth shaping (server→client only, no injected RTT/loss)

| Cap | Server | Authenticated connections | Sessions with first paint | First paint (median) | GDI paint callbacks/5s | Encrypted stream sent |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 5 Mbps | iron | 3/3 | 3/3 | 978 ms | 6.0 | 3.158 MB |
| 5 Mbps | free | 3/3 | 3/3 | 714 ms | 142.0 | 1.131 MB |
| 2 Mbps | iron | 2/2 | 1/2 | 2,590 ms | 1.5 | 1.266 MB |
| 2 Mbps | free | 2/2 | 2/2 | 1,698 ms | 82.5 | 1.270 MB |

At 2 Mbps the IronRDP **random-frame demo** did not complete its first paint in one of two 5-second sessions. This is a workload observation; it does NOT show an inherent IronRDP protocol or hardware-H.264 performance limit. Both servers completed authentication in all runs.

## Isolation, security and limitations

- Server binds exclusively to 127.0.0.1 on randomly selected ports. Both require TLS/NLA using ephemeral synthetic credentials. FreeRDP SAM test account hashes are removed after each session. No real Mac login password was used.
- FreeRDP Shadow disables remote interaction so no keystroke/mouse actions are injected. No screenshots or clipboard content are saved.
- Test-only client ignores the untrusted ephemeral certificate **only on loopback**. Do not apply this policy in production. No system trust stores, TCC settings, firewall, Karabiner, NuoRDS or background services were changed.
- Test client is FreeRDP Sample Test UI, modified only in a local external cloned source checkout: enable GDI decoding, timestamp post-connect and first EndPaint callback, count GDI paints and exit after 5 seconds active. The original patched third-party source is not imported into this repository.
- A test-only TCP relay counts encrypted application stream bytes; it does not model TCP/IP packet overhead, HY2/QUIC encapsulation, WAN jitter or loss.
- FreeRDP Shadow built with WITH_VERBOSE_WINPR_ASSERT=ON; this and the different workloads prevent claiming a production performance winner.
- First attempted IronRDP screenshot-client → FreeRDP Shadow handshake authenticated, then failed on a repeated Server Demand Active PDU. The shared FreeRDP GDI client succeeded against both servers. Record as an interoperability gap, not a performance result.

## Evidence

- [Unrestricted raw records](results/raw.csv) / [summary](results/summary.json)
- [5 Mbps raw records](results-5mbps/raw.csv) / [summary](results-5mbps/summary.json)
- [2 Mbps raw records](results-2mbps/raw.csv) / [summary](results-2mbps/summary.json)
- [Benchmark driver](run.py)

## Engineering decision

**ADR-0001 remains Proposed.** The next fair benchmark requires the **same controlled screen frames, encoding profile and resolution** on both servers. Then measure real H.264/AVC444 negotiation, client acknowledgements, p95 frame age, actual bandwidth, CPU and interactive latency. The present E2E result establishes viability and highlights feature/compatibility work, not the winner.
