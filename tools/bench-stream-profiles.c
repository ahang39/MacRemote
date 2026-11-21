/* Local VideoToolbox stream-profile benchmark for MacRemote High vs Low modes.
 * Exercises the exact production FreeRDP VideoToolbox H.264/AVC420 encoder,
 * SPS VUI low-latency rewriter, and server token-bucket pacer across realistic
 * synthetic desktop typing and scrolling workloads.
 *
 * Optionally dumps the first Low-mode H.264 bitstream to a path supplied in argv[1]
 * for external inspection with `ffmpeg -bsf:v trace_headers`.
 */
#include "../src/stream/stream_profile.h"
#include "shadow_stream_control.h"
#include <freerdp/codec/h264.h>
#include <freerdp/codec/color.h>
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static void fill_desktop(uint8_t *buf, uint32_t w, uint32_t h, uint32_t scrollOffset)
{
    const uint32_t stride = w * 4u;
    for (uint32_t y = 0; y < h; y++) {
        uint8_t *row = buf + (size_t)y * stride;
        const uint32_t sy = y + scrollOffset;
        const uint32_t lineIdx = sy / 20u;
        const uint32_t inLine = sy % 20u;
        const uint8_t bg = (lineIdx & 1u) ? 28u : 34u;
        for (uint32_t x = 0; x < w; x++) {
            uint8_t r = bg, g = bg, b = (uint8_t)(bg + 6u);
            /* Simulated syntax-highlighted code lines with high-frequency edges. */
            if (x >= 80 && x < w - 120 && inLine >= 4 && inLine <= 15) {
                const uint32_t token = ((x + lineIdx * 37u) / 7u) ^ (lineIdx * 13u);
                if ((token % 3u) != 0 && ((x % 7u) < 4u)) {
                    r = (uint8_t)(160u + (lineIdx * 29u) % 85u);
                    g = (uint8_t)(170u + (token * 17u) % 75u);
                    b = (uint8_t)(180u + (lineIdx * 11u) % 65u);
                }
            }
            row[x * 4 + 0] = b;
            row[x * 4 + 1] = g;
            row[x * 4 + 2] = r;
            row[x * 4 + 3] = 255u;
        }
    }
}

static void draw_typing_edit(uint8_t *buf, uint32_t w, uint32_t step)
{
    const uint32_t stride = w * 4u;
    const uint32_t x0 = 120u + (step * 18u) % (w - 300u);
    const uint32_t y0 = 220u;
    for (uint32_t y = y0; y < y0 + 24u; y++) {
        uint8_t *row = buf + (size_t)y * stride;
        for (uint32_t x = x0; x < x0 + 16u; x++) {
            const uint8_t on = ((x + y + step) & 1u) ? 240u : 40u;
            row[x * 4 + 0] = on;
            row[x * 4 + 1] = on;
            row[x * 4 + 2] = 220u;
            row[x * 4 + 3] = 255u;
        }
    }
}

static int cmp_double(const void *a, const void *b)
{
    const double da = *(const double *)a;
    const double db = *(const double *)b;
    return da < db ? -1 : (da > db ? 1 : 0);
}

static int has_idr_nal(const uint8_t *data, size_t len)
{
    for (size_t i = 0; i + 4 < len; i++) {
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1) {
            if ((data[i + 4] & 0x1Fu) == 5u)
                return 1;
        }
    }
    return 0;
}

static void run_scenario(uint32_t width, uint32_t height, MRBandwidthMode mode,
                         const char *dumpPath)
{
    const MRStreamProfile *p = mr_stream_profile_get(mode);
    H264_CONTEXT *enc = h264_context_new(TRUE);
    assert(enc);
    assert(h264_context_reset(enc, width, height));
    assert(h264_context_set_option(enc, H264_CONTEXT_OPTION_RATECONTROL, H264_RATECONTROL_VBR));
    assert(h264_context_set_option(enc, H264_CONTEXT_OPTION_BITRATE, p->h264Bitrate));
    assert(h264_context_set_option(enc, H264_CONTEXT_OPTION_FRAMERATE, p->maxFps));

    const uint32_t stride = width * 4u;
    uint8_t *fb = malloc((size_t)stride * height);
    assert(fb);
    RECTANGLE_16 full = { 0, 0, (uint16_t)width, (uint16_t)height };

    FILE *dump = dumpPath ? fopen(dumpPath, "wb") : NULL;
    BYTE *coded = NULL;
    UINT32 codedSize = 0;
    RDPGFX_H264_METABLOCK meta = { 0 };

    /* 1. Initial frame (IDR) */
    fill_desktop(fb, width, height, 0);
    const double t0 = now_ms();
    assert(avc420_compress(enc, fb, PIXEL_FORMAT_BGRX32, stride, width, height, &full,
                           &coded, &codedSize, &meta) > 0);
    const double idrMs = now_ms() - t0;
    const uint32_t idrBytes = codedSize;
    if (dump) fwrite(coded, 1, codedSize, dump);
    free_h264_metablock(&meta);

    /* 2. 10 typing edits (200 ms spacing) + 1 idle refine frame at end */
    uint64_t typingBytes = 0;
    double typingTimes[10];
    for (uint32_t i = 0; i < 10; i++) {
        draw_typing_edit(fb, width, i);
        const double s = now_ms();
        assert(avc420_compress(enc, fb, PIXEL_FORMAT_BGRX32, stride, width, height, &full,
                               &coded, &codedSize, &meta) > 0);
        typingTimes[i] = now_ms() - s;
        typingBytes += codedSize;
        if (dump) fwrite(coded, 1, codedSize, dump);
        free_h264_metablock(&meta);
    }
    assert(avc420_repeat(enc, width, height, &coded, &codedSize, &meta) > 0);
    const uint32_t refineBytes = codedSize;
    if (dump) fwrite(coded, 1, codedSize, dump);
    free_h264_metablock(&meta);

    /* 3. 5-second continuous scrolling under profile FPS + server byte pacer */
    ShadowStreamPacer pacer = { 0 };
    shadow_pacer_configure(&pacer, p->pacerBytesPerSec, p->pacerBurstBytes, 0);
    const uint64_t durationMs = 5000;
    uint64_t simMs = 0;
    uint64_t lastFrameMs = 0;
    uint64_t scrollBytes = 0;
    uint32_t scrollFrames = 0;
    uint32_t scrollIdrs = 0;
    double scrollTimes[400];
    uint32_t scrollTimeCount = 0;
    uint32_t scrollOffset = 0;

    while (simMs < durationMs) {
        const uint32_t fpsW = shadow_fps_wait_ms(lastFrameMs, p->maxFps, simMs);
        const uint32_t pacW = shadow_pacer_wait_ms(&pacer, simMs);
        const uint32_t wait = fpsW > pacW ? fpsW : pacW;
        if (wait > 0) {
            simMs += wait;
            continue;
        }
        scrollOffset += 24;
        fill_desktop(fb, width, height, scrollOffset);
        const double s = now_ms();
        assert(avc420_compress(enc, fb, PIXEL_FORMAT_BGRX32, stride, width, height, &full,
                               &coded, &codedSize, &meta) > 0);
        const double encMs = now_ms() - s;
        if (scrollTimeCount < 400)
            scrollTimes[scrollTimeCount++] = encMs;
        if (has_idr_nal(coded, codedSize))
            scrollIdrs++;
        if (dump && scrollFrames < 5) fwrite(coded, 1, codedSize, dump);
        free_h264_metablock(&meta);

        shadow_pacer_consume(&pacer, codedSize, simMs);
        scrollBytes += codedSize;
        scrollFrames++;
        lastFrameMs = simMs;
        simMs += 16; /* 60 Hz capture arrival */
    }

    qsort(typingTimes, 10, sizeof(double), cmp_double);
    qsort(scrollTimes, scrollTimeCount, sizeof(double), cmp_double);
    const double typP50 = typingTimes[4];
    const double scrP50 = scrollTimeCount ? scrollTimes[(scrollTimeCount - 1) / 2] : 0.0;
    const double scrP95 = scrollTimeCount ? scrollTimes[(scrollTimeCount * 95) / 100] : 0.0;
    const double videoKBps = (double)scrollBytes / 5000.0;
    const double audioKBps = (double)p->audioBitrate / 8000.0;
    const double totalWithAudioKBps = videoKBps + audioKBps;

    printf("%-9s %-4s | IDR=%5.1f KB (%.1fms) | 10-key=%5.1f KB + refine=%4.1f KB (p50=%.1fms) | "
           "5s scroll: %3u f (%.1f fps, %u IDR), video=%6.1f KB/s, +audio=%6.1f KB/s, enc p50/p95=%.1f/%.1fms\n",
           width == 1920 ? "1920x1080" : "2304x1296",
           p->name,
           (double)idrBytes / 1000.0, idrMs,
           (double)typingBytes / 1000.0, (double)refineBytes / 1000.0, typP50,
           scrollFrames, (double)scrollFrames / 5.0, scrollIdrs,
           videoKBps, totalWithAudioKBps, scrP50, scrP95);

    if (dump) fclose(dump);
    free(fb);
    h264_context_free(enc);
}

int main(int argc, char **argv)
{
    const char *dumpPath = argc > 1 ? argv[1] : NULL;
    run_scenario(1920, 1080, MR_BANDWIDTH_HIGH, NULL);
    run_scenario(1920, 1080, MR_BANDWIDTH_LOW, NULL);
    run_scenario(2304, 1296, MR_BANDWIDTH_HIGH, NULL);
    run_scenario(2304, 1296, MR_BANDWIDTH_LOW, dumpPath);
    return 0;
}
