# Reproducing the MacRemote ZGFX microbenchmark

Scope: ZGFX compression/decompression functions. Does NOT measure RDP stream latency, H.264, image fidelity, capture FPS or HY2.

Requirements: Mac arm64, Rust toolchain, Python 3 stdlib, native Release FreeRDP 3.33.1 libfreerdp3.dylib.

1. Build the benchmark with Cargo in this directory (Cargo.toml pins the exact IronRDP Git SHA). Use --release --locked. Setting CARGO_TARGET_DIR to a cache path avoids polluting this source folder.
2. Run run.py with --binary pointing to the compiled macremote-zgfx-bench, --freerdp-lib pointing to the FreeRDP libfreerdp3.dylib, --out ./results and --trials 5.
3. The runner randomizes order, checks every subprocess, validates bidirectional ZGFX byte equality and writes raw.csv and summary.json.
4. Run the optional verify_stream release binary with the FreeRDP library path to check 800 sequential cross-decoded packets with maintained ZGFX history.

Exact tested paths on this Mac:
- Source: ~/dev/repos/MacRemote/benchmarks/m1/zgfx
- Rust output: ~/Library/Caches/MacRemote/m1/zgfx-target/release/macremote-zgfx-bench
- FreeRDP 3.33.1 lib: ~/Library/Caches/MacRemote/m1/freerdp-build/libfreerdp/libfreerdp3.dylib

Commands:

    export CARGO_TARGET_DIR="$HOME/Library/Caches/MacRemote/m1/zgfx-target"
    cargo build --release --locked --manifest-path "$HOME/dev/repos/MacRemote/benchmarks/m1/zgfx/Cargo.toml"
    python3 run.py --binary "$CARGO_TARGET_DIR/release/macremote-zgfx-bench" --freerdp-lib "$HOME/Library/Caches/MacRemote/m1/freerdp-build/libfreerdp/libfreerdp3.dylib" --out ./results --trials 5

Read REPORT.md before interpreting the numbers: the FreeRDP encoder is currently a ZGFX pass-through while IronRDP performs actual compression, so encoding speed alone is not an apples-to-apples comparison.
