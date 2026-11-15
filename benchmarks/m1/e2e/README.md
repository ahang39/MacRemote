# Reproduce M1 loopback RDP end-to-end benchmark

Read [REPORT.md](REPORT.md) before comparing numbers.

Dependencies: Mac arm64; built IronRDP server example; FreeRDP 3.33.1 macOS Shadow Server, WinPR hash CLI, and locally instrumented headless FreeRDP Sample Test UI. The build artifacts are under the local ~/Library/Caches/MacRemote/m1 directory, NOT checked into this repository.

The test client source was instrumented in the isolated FreeRDP clone only: GDI decoding enabled, post-connect/first paint timestamp and paint count logged (M1BENCH), and 5-second active session. These modifications were NOT copied to the unlicensed MacRemote project.

Run from MacRemote root, using a fresh result directory each time:

    python3 benchmarks/m1/e2e/run.py 5
    python3 benchmarks/m1/e2e/run.py 3 5
    python3 benchmarks/m1/e2e/run.py 2 2

The first argument is trial pairs; the second optional argument is server→client Mbps (0 means unrestricted). The script refuses to overwrite an existing raw.json. Results are JSON/CSV (not screenshots). Temporary SAM credentials are deleted after each trial. Everything uses 127.0.0.1, TLS/NLA and remote input disabled. Neither NuoRDS nor Mac security configuration is changed.

Note: synthetic random rectangles on IronRDP vs the actual physical Mac desktop on FreeRDP are NOT equivalent workloads. The byte and CPU numbers do not decide which protocol stack is faster.
