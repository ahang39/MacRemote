# M1 Benchmark: ZGFX protocol codec on Mac mini M4

Date: 2026-11-13. Status: measured microbenchmark, NOT an end-to-end RDP benchmark.

## Headline

- FreeRDP 3.33.1 has a substantially faster ZGFX compressed-data decoder.
- FreeRDP ZGFX compression is a raw-data pass-through (explicit FIXME in zgfx.c). IronRDP uses real LZ77 with CompressionMode::Auto, trading CPU for wire bytes.
- An incompressible-data worst case remains for IronRDP Auto, which spends CPU deciding that raw bytes are better; pre-encoded H.264 paths bypass this compression, so this test cannot predict video streaming FPS.
- Neither candidate has a matched real mstsc session, VideoToolbox encode benchmark, or HY2 input-latency benchmark. Protocol selection remains undecided.

## Setup and method

Apple Silicon Mac mini M4 / 24 GB, macOS 27.0.1, ARM64. FreeRDP 3.33.1 commit 65bcca1 built as native Release C library. IronRDP graphics 0.11.0 pinned to commit 0a79fd2178c79b3d8920b6e76f2a9da5db6331ca, built in Rust 1.99.1 Release mode.

Five randomized interleaved trials per operation / workload / implementation; 80 trials total. Each decode trial has 4,000 operations after 100 warmups. Each encode trial has 200 changing 16 KiB synthetic frames with maintained streaming history. Measured wall time, process CPU time and process peak RSS using native monotonic clock and getrusage. Numbers are five-trial medians.

Both decoder implementations consume the exact same ZGFX byte packet. Before each benchmark, the harness verifies byte-for-byte that FreeRDP and IronRDP decode IronRDP wire packets, and IronRDP can decode FreeRDP wire packets.

Independent release-mode integration verification: verify_stream decoded 200 sequential IronRDP Auto packets for each of the four workloads (800 total) using both the FreeRDP and IronRDP decoders with maintained history. FreeRDP-generated packets were also decoded back with IronRDP for the corresponding frames. All passed.

## Decode (identical wire inputs)

| Synthetic content (16 KiB) | FreeRDP MiB/s | IronRDP MiB/s | FreeRDP speedup | Wire/input |
| --- | ---: | ---: | ---: | ---: |
| Code-like text | 4,633.7 | 341.9 | 13.55x | 4.04% |
| Solid-color tiles | 2,979.7 | 205.0 | 14.54x | 5.17% |
| Mixed text and changing data | 529.0 | 112.6 | 4.70x | 30.70% |
| Incompressible random | 32,860.1 | 32,316.4 | 1.02x | 100.01% |

Decode per-packet timing (microseconds per 16 KiB packet):

| Content | FreeRDP | IronRDP |
| --- | ---: | ---: |
| code | 3.372 | 45.700 |
| solid | 5.244 | 76.230 |
| mixed | 29.538 | 138.819 |
| noise | 0.475 | 0.483 |

These are codec operation timings, NOT display-frame time, network latency or keyboard-to-photon latency.

## Encode (different work; compare wire bytes as well as time)

| Content | FreeRDP pass-through MiB/s | IronRDP Auto MiB/s | FreeRDP wire/input | IronRDP wire/input |
| --- | ---: | ---: | ---: | ---: |
| code | 2,016.1 | 200.1 | 100.01% | 0.45% |
| solid | 2,045.2 | 65.3 | 100.01% | 6.18% |
| mixed | 2,039.8 | 24.5 | 100.01% | 30.10% |
| noise | 3,419.0 | 8.6 | 100.01% | 100.01% |

The Code 0.45% ratio is from a highly repetitive synthetic sequence with cross-frame history, NOT a real-world bandwidth promise. Solid and mixed datasets are also synthetic. The noise dataset changes every frame and demonstrates futile LZ77 searching (IronRDP Auto still correctly chooses raw transfer).

## CPU and memory (microbenchmark process only)

| Workload | FreeRDP peak RSS MiB | IronRDP peak RSS MiB |
| --- | ---: | ---: |
| decode code | 16.97 | 19.47 |
| decode mixed | 17.69 | 20.19 |
| encode code | 20.12 | 23.16 |
| encode mixed | 20.84 | 31.98 |
| encode noise | 21.73 | 33.17 |

Both implementations consumed approximately 100% of one CPU core while processing. The RSS numbers include the shared Rust harness and loaded library, so they are NOT server process memory or system energy usage.

## Implications

1. ZGFX decoding performance is a FreeRDP advantage on this M4 workload. This is a useful codec-layer optimization target, but does not decide the RDP library.
2. IronRDP provides materially better wire compression for low-entropy EGFX commands, with CPU tradeoffs; H.264 video should remain on its separate already-compressed path.
3. For high-entropy data, consider a narrowly tested preflight decision to skip expensive ZGFX match search. Do not add settings until real EGFX traffic shows this matters.
4. Main project decision still depends on real Windows mstsc: H.264/AVC444, capture + transport, bandwidth/RTT, Input/HID/Karabiner, clipboard and stability.

Artifacts: results/raw.csv (80 raw records), results/summary.json (all medians), src/main.rs (native harness), run.py (runner), Cargo.toml + Cargo.lock (pinned IronRDP dependencies). External FreeRDP library is in the local Mac cache, not copied into this unlicensed project.

No service/listener was started; NuoRDS, Karabiner and system configuration were not modified.
