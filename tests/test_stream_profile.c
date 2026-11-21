#include "../src/stream/stream_profile.h"
#include "shadow_stream_control.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void test_profiles_and_budget(void)
{
    MRBandwidthMode mode = MR_BANDWIDTH_LOW;
    assert(mr_bandwidth_parse("high", &mode) && mode == MR_BANDWIDTH_HIGH);
    assert(mr_bandwidth_parse("low", &mode) && mode == MR_BANDWIDTH_LOW);
    assert(!mr_bandwidth_parse("medium", &mode));
    assert(!mr_bandwidth_parse("", &mode));
    assert(!mr_bandwidth_parse(NULL, &mode));
    assert(!mr_bandwidth_parse("high", NULL));

    const MRStreamProfile *high = mr_stream_profile_get(MR_BANDWIDTH_HIGH);
    const MRStreamProfile *low = mr_stream_profile_get(MR_BANDWIDTH_LOW);
    assert(strcmp(high->name, "high") == 0);
    assert(strcmp(low->name, "low") == 0);

    /* High mode: LAN-optimized 60 fps, uncapped pacer, 128k Opus. */
    assert(high->maxFps == 60);
    assert(high->h264Bitrate >= 6000000);
    assert(high->pacerBytesPerSec == 0);
    assert(high->audioBitrate == 128000);
    assert(high->refineFrames == 1);

    /* Low mode: strict <= 200 KB/s wire budget (including >=15% framing/TLS/TCP margin). */
    assert(low->maxFps == 15);
    assert(low->maxInFlight <= 3);
    assert(low->pacerBytesPerSec > 0 && low->pacerBurstBytes > 0);
    assert(low->wireBudgetBytesPerSec == 200000);
    const uint64_t worstPayloadBps =
        (uint64_t)low->pacerBytesPerSec + (uint64_t)(low->audioBitrate / 8u);
    const uint64_t worstWireEstimate = (worstPayloadBps * 115u) / 100u;
    assert(worstWireEstimate < low->wireBudgetBytesPerSec);
}

static void test_token_bucket_pacer(void)
{
    ShadowStreamPacer pacer = { 0 };
    const MRStreamProfile *low = mr_stream_profile_get(MR_BANDWIDTH_LOW);
    uint64_t now = 1000;
    shadow_pacer_configure(&pacer, low->pacerBytesPerSec, low->pacerBurstBytes, now);

    /* Initial burst allows immediate keyframe (e.g. 90 KB) with 0 ms delay. */
    assert(shadow_pacer_wait_ms(&pacer, now) == 0);
    shadow_pacer_consume(&pacer, 90000, now);
    const uint32_t waitAfterIdr = shadow_pacer_wait_ms(&pacer, now);
    assert(waitAfterIdr > 100 && waitAfterIdr < 400);

    /* Simulate 10 seconds of heavy 25 KB frames: sustained output cannot exceed pacer rate. */
    now += 5000; /* full refill after idle */
    assert(shadow_pacer_wait_ms(&pacer, now) == 0);
    uint64_t sentBytes = 0;
    const uint64_t start = now;
    const uint64_t end = start + 10000;
    while (now < end) {
        const uint32_t w = shadow_pacer_wait_ms(&pacer, now);
        if (w == 0) {
            shadow_pacer_consume(&pacer, 25000, now);
            sentBytes += 25000;
            now += 16; /* 60 fps incoming pressure */
        } else {
            now += w;
        }
    }
    const double avgBps = (double)sentBytes / 10.0;
    /* Burst at start adds at most burstBytes/10s (~6.4 KB/s) over steady-state 155 KB/s. */
    assert(avgBps <= (double)low->pacerBytesPerSec + (double)low->pacerBurstBytes / 10.0 + 3000.0);
    assert(avgBps >= (double)low->pacerBytesPerSec * 0.90);

    /* Switching back to High disables pacing immediately. */
    shadow_pacer_configure(&pacer, 0, 0, now);
    assert(shadow_pacer_wait_ms(&pacer, now) == 0);
}

static void test_fps_gate_and_rtt(void)
{
    /* High (60 fps) never introduces artificial FPS gating delay. */
    assert(shadow_fps_wait_ms(1000, 60, 1005) == 0);

    /* Low (15 fps -> 66 ms interval): immediate after idle, gated during motion. */
    assert(shadow_fps_wait_ms(0, 15, 1000) == 0);
    assert(shadow_fps_wait_ms(1000, 15, 1066) == 0);
    assert(shadow_fps_wait_ms(1000, 15, 1016) == 50);

    /* RTT ring & p50/p95 calculation. */
    ShadowRttTracker rtt = { 0 };
    uint32_t p50 = 999, p95 = 999;
    assert(!shadow_rtt_summarize(&rtt, &p50, &p95));

    const uint32_t delays[20] = {
        12, 14, 15, 16, 18, 20, 22, 24, 25, 26,
        28, 30, 32, 35, 40, 45, 50, 60, 80, 120
    };
    for (uint32_t i = 0; i < 20; i++) {
        const uint32_t fid = i + 1;
        shadow_rtt_record_send(&rtt, fid, 10000 + i * 100);
        shadow_rtt_record_ack(&rtt, fid, 10000 + i * 100 + delays[i]);
        /* Duplicate ACK for same frame ID must be ignored. */
        shadow_rtt_record_ack(&rtt, fid, 10000 + i * 100 + 999);
    }
    assert(shadow_rtt_summarize(&rtt, &p50, &p95));
    assert(p50 == 26);
    assert(p95 == 80);
    assert(!shadow_rtt_summarize(&rtt, &p50, &p95)); /* window reset */
}

int main(void)
{
    test_profiles_and_budget();
    test_token_bucket_pacer();
    test_fps_gate_and_rtt();
    puts("PASS: stream profiles, <=200 KB/s budget, byte pacer, FPS gate and ACK RTT");
    return 0;
}
