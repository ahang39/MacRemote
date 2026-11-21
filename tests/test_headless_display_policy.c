#include "headless_display_policy.h"
#include <assert.h>
#include <stdio.h>
int main(void)
{
    const mrHeadlessFacts base={.guiSessionAvailable=true,
        .captureGranted=true,.fallbackOptedIn=true};
    mrHeadlessFacts f=base;
    assert(mr_headless_decide(f)==MR_HEADLESS_CREATE_OWNED);
    f.fallbackOptedIn=false;
    assert(mr_headless_decide(f)==MR_HEADLESS_DISABLED);
    f=base;f.guiSessionAvailable=false;
    assert(mr_headless_decide(f)==MR_HEADLESS_NO_GUI);
    f=base;f.captureGranted=false;
    assert(mr_headless_decide(f)==MR_HEADLESS_NO_CAPTURE_PERMISSION);
    /* BetterDisplay, physical panels and Apple Screen Sharing all win. */
    f=base;f.otherDisplayPresent=true;f.otherDisplayCaptureReady=true;
    assert(mr_headless_decide(f)==MR_HEADLESS_USE_EXISTING);
    f=base;f.otherDisplayPresent=true;
    assert(mr_headless_decide(f)==MR_HEADLESS_WAIT_EXISTING);
    f=base;f.displaysSettling=true;
    assert(mr_headless_decide(f)==MR_HEADLESS_WAIT_SETTLE);
    f=base;f.ownedDisplayActive=true;
    assert(mr_headless_decide(f)==MR_HEADLESS_KEEP_OWNED);
    /* No deleting a live client's screen when BetterDisplay appears. */
    f=base;f.ownedDisplayActive=true;f.remoteClientConnected=true;
    f.otherDisplayPresent=true;f.otherDisplayCaptureReady=true;
    assert(mr_headless_decide(f)==MR_HEADLESS_KEEP_OWNED);
    f.remoteClientConnected=false;
    assert(mr_headless_decide(f)==MR_HEADLESS_RELEASE_OWNED);
    f.displaysSettling=true;
    assert(mr_headless_decide(f)==MR_HEADLESS_KEEP_OWNED);
    f=base;f.ownedDisplayActive=true;f.otherDisplayPresent=true;
    assert(mr_headless_decide(f)==MR_HEADLESS_KEEP_OWNED);
    assert(mr_headless_allow_legacy_mode_restore(
        MR_DISPLAY_LEGACY_PROVEN_PHYSICAL));
    assert(!mr_headless_allow_legacy_mode_restore(
        MR_DISPLAY_BORROWED_OR_UNVERIFIED));
    assert(!mr_headless_allow_legacy_mode_restore(
        MR_DISPLAY_MACREMOTE_OWNED));
    puts("PASS: opt-in, borrowed display priority, no preemption, safe release and mode isolation");
    return 0;
}
