# MacRemote idle capture lifecycle — 2026-11-18

## Change
- Added `patches/freerdp-3.33.1-idle-capture-on-demand.patch` and registered it at the end of the pinned FreeRDP patch list in `tools/build-dev-app.sh`.
- macOS Shadow's worker starts ScreenCaptureKit on the transition from zero to one authenticated clients, and stops/releases it when the final client disconnects. First/last-client events wake the worker without blocking the peer callback.
- Audio and video callbacks skip work with no authenticated clients. Disconnect clears cached video frames, dirty regions, and partial PCM; display changes while idle no longer intentionally restart capture.
- The upstream source cache is fingerprinted per patchset. Existing FreeRDP build caches, the Git branch history, user settings and the installed server are untouched.

## Validation
- `tools/build-dev-app.sh`: full arm64 native rebuild **passed**; all **16/16 CTest** passed; Swift port/display/lifecycle tests passed; standalone bundle dependency audit and ad-hoc signature verification passed.
- Standalone new bundle: `.build/output/MacRemote-20261118T094240Z.app`.
- Started an isolated listener at `127.0.0.1:43991` with no client and tested successful startup, port binding, and 0.0% sampled idle CPU; the probe process was terminated. No "screen and audio capture started" transition appeared in its output.
- One `mac_capture_new` initialization log still appeared in that smoke run. The on-demand start/stop policy compiled correctly, but the remaining initialization log means the exact no-client allocation path merits deeper instrumentation before claiming zero ScreenCaptureKit object creation.
- **Not tested:** an actual authenticated Windows mstsc connect, multi-client disconnect, ScreenCaptureKit restart, or live end-to-end audio/video playback after reconnect. These remain deployment acceptance checks.
- The running `/Applications/MacRemote.app` and TCP 3389 server have not been replaced or restarted.
