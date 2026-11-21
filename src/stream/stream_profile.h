#ifndef MACREMOTE_STREAM_PROFILE_H
#define MACREMOTE_STREAM_PROFILE_H

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    MR_BANDWIDTH_HIGH = 0,
    MR_BANDWIDTH_LOW = 1
} MRBandwidthMode;

typedef struct {
    MRBandwidthMode mode;
    const char *name;
    uint32_t h264Bitrate;       /* VideoToolbox average bitrate (bps) */
    uint32_t maxFps;            /* Max video capture/encode FPS */
    uint32_t maxInFlight;       /* Max unacknowledged RDPGFX frames */
    uint32_t pacerBytesPerSec;  /* 0 = disabled; >0 = hard video payload cap (B/s) */
    uint32_t pacerBurstBytes;   /* Token bucket burst capacity (bytes) */
    uint32_t refineDelayMs;     /* Delay after last update before idle refine frame */
    uint32_t refineFrames;      /* Idle refine frames (default 1 with SPS VUI fix) */
    uint32_t audioBitrate;      /* Compressed audio target bitrate (bps: Opus 48k / AAC 64k) */
    bool audioPreferLossless;   /* High (LAN): prefer 48 kHz 16-bit stereo PCM; Low: compressed */
    uint32_t wireBudgetBytesPerSec; /* 0 = uncapped; Low mode = 200000 B/s */
} MRStreamProfile;

const MRStreamProfile *mr_stream_profile_get(MRBandwidthMode mode);
const char *mr_bandwidth_name(MRBandwidthMode mode);
bool mr_bandwidth_parse(const char *text, MRBandwidthMode *out);

#endif
