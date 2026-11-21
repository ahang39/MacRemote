#include "mac_capture_generation.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <stdio.h>

int main(void)
{
    macCaptureGeneration state;
    atomic_init(&state.current, 0);
    /* No stream exists before it receives a generation. */
    assert(!mr_capture_generation_current(&state, 0));
    const uint64_t old = mr_capture_generation_next(&state);
    assert(old == 1);
    assert(mr_capture_generation_current(&state, old));

    /* A display change invalidates old callbacks BEFORE stopping its
     * SCStream. The replacement receives a new generation token. */
    (void)mr_capture_generation_next(&state);
    assert(!mr_capture_generation_current(&state, old));
    const uint64_t current = mr_capture_generation_next(&state);
    assert(current == 3);
    assert(mr_capture_generation_current(&state, current));

    /* An asynchronous stopped/old video/old audio callback from the
     * retired stream cannot trigger recovery or supply stale pixels. */
    int restarts = 0, frames = 0, audio = 0;
    if (mr_capture_generation_current(&state, old))
        ++restarts;
    if (mr_capture_generation_current(&state, old))
        ++frames;
    if (mr_capture_generation_current(&state, old))
        ++audio;
    assert(restarts == 0 && frames == 0 && audio == 0);
    if (mr_capture_generation_current(&state, current))
        ++restarts;
    assert(restarts == 1);

    /* Disconnect retires the last stream, too. */
    (void)mr_capture_generation_next(&state);
    assert(!mr_capture_generation_current(&state, current));
    puts("PASS: retired ScreenCaptureKit stream callbacks cannot affect new generation");
    return 0;
}
