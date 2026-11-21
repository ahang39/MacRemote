#include "stream_profile.h"
#include <string.h>

/* Single source of truth for MacRemote's two bandwidth modes.
 *
 * High (LAN): unrestricted 60 fps, 100 Mbps H.264 ceiling (no DataRateLimits,
 *   no byte pacer, 8 frames in flight), lossless 48 kHz 16-bit stereo PCM audio
 *   (1.536 Mbps = 192 KB/s, zero resample/encode latency; falls back to 128 kbps
 *   Opus/AAC if a client omits PCM).
 * Low (WAN): strictly bounded under 200 KB/s (200,000 B/s) on the wire:
 *   video pacer <= 155,000 B/s + compressed audio (48 kbps Opus = 6,000 B/s or
 *   64 kbps AAC-LC = 8,000 B/s) <= 163,000 B/s payload, leaving ~37,000 B/s
 *   (~19%) for RDPGFX/Wave2/TLS/TCP framing and input/cursor/clipboard traffic.
 */
static const MRStreamProfile kProfiles[] = {
    [MR_BANDWIDTH_HIGH] = {
        .mode = MR_BANDWIDTH_HIGH,
        .name = "high",
        .h264Bitrate = 100000000u,
        .maxFps = 60u,
        .maxInFlight = 8u,
        .pacerBytesPerSec = 0u,
        .pacerBurstBytes = 0u,
        .refineDelayMs = 400u,
        .refineFrames = 1u,
        .audioBitrate = 128000u,
        .audioPreferLossless = true,
        .wireBudgetBytesPerSec = 0u,
    },
    [MR_BANDWIDTH_LOW] = {
        .mode = MR_BANDWIDTH_LOW,
        .name = "low",
        .h264Bitrate = 1050000u,
        .maxFps = 15u,
        .maxInFlight = 3u,
        .pacerBytesPerSec = 155000u,
        .pacerBurstBytes = 64000u,
        .refineDelayMs = 300u,
        .refineFrames = 1u,
        .audioBitrate = 48000u,
        .audioPreferLossless = false,
        .wireBudgetBytesPerSec = 200000u,
    },
};

const MRStreamProfile *mr_stream_profile_get(MRBandwidthMode mode)
{
    return mode == MR_BANDWIDTH_LOW ? &kProfiles[MR_BANDWIDTH_LOW]
                                    : &kProfiles[MR_BANDWIDTH_HIGH];
}

const char *mr_bandwidth_name(MRBandwidthMode mode)
{
    return mr_stream_profile_get(mode)->name;
}

bool mr_bandwidth_parse(const char *text, MRBandwidthMode *out)
{
    if (!text || !out)
        return false;
    if (strcmp(text, "high") == 0) {
        *out = MR_BANDWIDTH_HIGH;
        return true;
    }
    if (strcmp(text, "low") == 0) {
        *out = MR_BANDWIDTH_LOW;
        return true;
    }
    return false;
}
