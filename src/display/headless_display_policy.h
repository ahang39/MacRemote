/* Conservative opt-in headless display ownership policy.
 * Pure decision logic: never creates/disconnects/changes actual displays. */
#ifndef MACREMOTE_HEADLESS_DISPLAY_POLICY_H
#define MACREMOTE_HEADLESS_DISPLAY_POLICY_H
#include <stdbool.h>
typedef enum {
    MR_HEADLESS_USE_EXISTING,
    MR_HEADLESS_WAIT_EXISTING,
    MR_HEADLESS_WAIT_SETTLE,
    MR_HEADLESS_CREATE_OWNED,
    MR_HEADLESS_KEEP_OWNED,
    MR_HEADLESS_RELEASE_OWNED,
    MR_HEADLESS_DISABLED,
    MR_HEADLESS_NO_GUI,
    MR_HEADLESS_NO_CAPTURE_PERMISSION
} mrHeadlessDecision;
typedef struct {
    bool guiSessionAvailable;
    bool captureGranted;
    bool fallbackOptedIn;
    bool displaysSettling;
    /* Exclude MacRemote-owned ID from the following two observations. */
    bool otherDisplayPresent;
    bool otherDisplayCaptureReady;
    bool ownedDisplayActive;
    bool remoteClientConnected;
} mrHeadlessFacts;
static inline mrHeadlessDecision mr_headless_decide(mrHeadlessFacts f)
{
    if (!f.guiSessionAvailable) return MR_HEADLESS_NO_GUI;
    if (!f.captureGranted) return MR_HEADLESS_NO_CAPTURE_PERMISSION;
    /* Hold the remote desktop while the client is connected. Only release
     * an owned display after an alternative is capturable and stable. */
    if (f.ownedDisplayActive)
        return f.otherDisplayCaptureReady && !f.remoteClientConnected &&
                       !f.displaysSettling
                   ? MR_HEADLESS_RELEASE_OWNED : MR_HEADLESS_KEEP_OWNED;
    if (f.otherDisplayCaptureReady) return MR_HEADLESS_USE_EXISTING;
    /* Screen may be sleeping, temporarily unavailable or managed by
     * BetterDisplay. It must not trigger a new owned virtual display. */
    if (f.otherDisplayPresent) return MR_HEADLESS_WAIT_EXISTING;
    if (f.displaysSettling) return MR_HEADLESS_WAIT_SETTLE;
    return f.fallbackOptedIn ? MR_HEADLESS_CREATE_OWNED : MR_HEADLESS_DISABLED;
}
typedef enum {
    MR_DISPLAY_LEGACY_PROVEN_PHYSICAL,
    MR_DISPLAY_BORROWED_OR_UNVERIFIED,
    MR_DISPLAY_MACREMOTE_OWNED
} mrDisplayOwnership;
/* MacRemote may not persistently change the mode of a borrowed screen.
 * Owned CGVirtualDisplay uses its own settings API instead. */
static inline bool mr_headless_allow_legacy_mode_restore(mrDisplayOwnership o)
{
    return o == MR_DISPLAY_LEGACY_PROVEN_PHYSICAL;
}
#endif
