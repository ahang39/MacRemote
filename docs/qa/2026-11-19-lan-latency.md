# LAN video/latency work — 2026-11-19

## 18:35 user test and immediate rollback decision (supersedes work below)
- The user reported **severe corruption/flickering and instability** with **12 Mbps** and no improvement in latency after deploying this build.
- The live mstsc session had videoBitrate=12000000 and a 2304×1296 AVC420 surface. Safely and atomically changed **only this active client's saved target to 4 Mbps**; no disconnect. Backup under ~/Library/Application Support/MacRemote/display-by-client.before-12mbps-revert-20261119T1835.json retains its previous profile.
- Mac→Windows LAN test: ICMP RTT mean 0.464 ms, 0% loss across 6 probes, macremote-server 13% CPU at sample time. This does not exclude TCP queue/backpressure, encoding errors, or decoder presentation defects; there is **no independently measured post-change input latency**.
- Two concurrent changes (higher target and the ACK-aware drain modification) were not separately validated before deployment. **Do not claim a proven root cause** from the report alone.
- Reverted both the 8/12 Mbps UI/target acceptance and the LAN/60FPS FreeRDP patch inclusion in the default local *source/build configuration*. The original patch remains **as an unreferenced file only** for investigation. Rebuilt rollback app at .build/output/MacRemote-20261119T103854Z.app, signed with the original Ahang Personal Code Signing identity; 16/16 CTest PASS, app signature PASS. This matches the pre-LAN experiment behavior at the code/configuration level.
- **IMPORTANT**: The new rollback binary is **staged, not installed**. As of this note an active TCP RDP session still exists, so the installed /Applications/MacRemote.app still runs the experimental scheduler at 4 Mbps. It will require a service restart to activate the tested rollback binary. Do not silently disconnect an active session. The older pre-LAN installed app is also backed up in ~/Library/Caches/MacRemote/product/MacRemote-before-lan-latency-20261119T1825.app.
- Next engineering priority: obtain input→display latency p50/p95, frame ACK depth/age, encoded bits/frame, VideoToolbox failures and client decode behavior. Isolate variables before reintroducing any higher bitrate or ACK changes.


## Scope
- Added per-client live AVC420 encoder targets at **8 and 12 Mbps** alongside existing 1.4/2/4 Mbps. The default stored/fallback selection remains **4 Mbps**. The 5-value choice now uses an AppKit/SwiftUI menu rather than a cramped segmented control. Unrecognized values remain rejected.
- FreeRDP AVC420 presentation drain now sends as many synthetic decoder-release pictures as fit the current frame ACK window, **reserving one slot for real screen damage**. Previously any backlog smaller than the entire scheduled 5-picture batch caused it to wait for 100 ms even when some slots were free. No change to the existing 5/10-picture upper bound until a real mstsc A/B test establishes the minimum that still presents the last text/scroll frame.
- 60 FPS is **experimental only**, enabled by environment variable 'MACREMOTE_TEST_60FPS=1' before launching the server. The same setting adjusts ScreenCaptureKit's maximum requested frame rate, the FreeRDP VideoToolbox encoder target, and Shadow's maximum adaptive output rate. Existing defaults remain 30 capture/encode FPS and up to 32 adaptive scheduler FPS. No change to the release UI default.
- VideoToolbox already sets RealTime=true and AllowFrameReordering=false. No duplicate codec tweaks were made.

## Validation
- Standalone arm64 build: FreeRDP 3.33.1 pinned patchset, C/Objective-C server, SwiftUI app, bundled runtime and ad-hoc signature.
- 16 native CTest cases, including audio/client-profile coverage; Swift preference/display/lifecycle tests.
- The client-profile unit tests accept 8/12 Mbps, reject unsupported targets, and run the actual mocked macOS capture config in both default 30 FPS and opt-in 60 FPS modes.
- New binary must not replace /Applications/MacRemote.app or restart the active port 3389 listener during testing.

## Baseline and outstanding end-to-end proof
Older same-project real mstsc tests recorded one unshaped LAN run at 1920×1080 AVC420 with **390 ms** median key-feedback and **459 ms** first-scroll-feedback. In 2 Mbps / +80 ms WAN tests, 1.4 Mbps reduced scrolling payload and startup lag relative to 4.0 Mbps. These are **historical baselines**, not measured results of this patch (see [LAN/WAN test](2026-11-17-mstsc-wan.md)).

A fresh real Windows mstsc LAN A/B is still required before claiming lower latency: same user/client, same display, codec, motion, keyboard workload and 3+ repetitions; record input-to-visible p50/p95, first scroll response, stopped-screen fidelity, transmitted Mbps, frame ACK window, CPU and observed FPS if directly measured. Compare default / new ACK scheduler and 30 / 60 FPS as separate variables. Confirm the final scroll/text picture stays stable after 1–2 seconds of no input. In the meantime 60 FPS is not a new default.
