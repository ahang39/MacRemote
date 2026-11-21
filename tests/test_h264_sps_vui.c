#include "h264_sps_vui.h"
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

static void build_synthetic_sps(int highProfile, int withVui, int withFullRange,
                                int withOrigBr, uint32_t maxRefs,
                                uint8_t *outNal, size_t outCap, size_t *outLen)
{
    uint8_t rbsp[256];
    mrSpsBitWriter w = { .data = rbsp, .byteCap = sizeof(rbsp), .bitPos = 0 };
    assert(mr_sps_write_u(&w, 8, highProfile ? 100u : 66u)); /* profile_idc */
    assert(mr_sps_write_u(&w, 8, highProfile ? 0x00u : 0xC0u)); /* constraints */
    assert(mr_sps_write_u(&w, 8, 50u)); /* level_idc 5.0 */
    assert(mr_sps_write_ue(&w, 0u)); /* sps_id */
    if (highProfile) {
        assert(mr_sps_write_ue(&w, 1u)); /* chroma_format_idc = 4:2:0 */
        assert(mr_sps_write_ue(&w, 0u)); /* bit_depth_luma_minus8 */
        assert(mr_sps_write_ue(&w, 0u)); /* bit_depth_chroma_minus8 */
        assert(mr_sps_write_u(&w, 1, 0u)); /* qpprime_y_zero_transform_bypass */
        assert(mr_sps_write_u(&w, 1, 0u)); /* seq_scaling_matrix_present_flag */
    }
    assert(mr_sps_write_ue(&w, 0u)); /* log2_max_frame_num_minus4 */
    assert(mr_sps_write_ue(&w, 0u)); /* pic_order_cnt_type */
    assert(mr_sps_write_ue(&w, 0u)); /* log2_max_pic_order_cnt_lsb_minus4 */
    assert(mr_sps_write_ue(&w, maxRefs)); /* max_num_ref_frames */
    assert(mr_sps_write_u(&w, 1, 0u)); /* gaps_in_frame_num */
    assert(mr_sps_write_ue(&w, 143u)); /* 2304 / 16 - 1 */
    assert(mr_sps_write_ue(&w, 80u)); /* 1296 / 16 - 1 */
    assert(mr_sps_write_u(&w, 1, 1u)); /* frame_mbs_only_flag */
    assert(mr_sps_write_u(&w, 1, 1u)); /* direct_8x8_inference_flag */
    assert(mr_sps_write_u(&w, 1, 0u)); /* frame_cropping_flag */
    assert(mr_sps_write_u(&w, 1, withVui ? 1u : 0u));
    if (withVui) {
        assert(mr_sps_write_u(&w, 1, 0u)); /* aspect_ratio */
        assert(mr_sps_write_u(&w, 1, 0u)); /* overscan */
        assert(mr_sps_write_u(&w, 1, withFullRange ? 1u : 0u)); /* video_signal_type */
        if (withFullRange) {
            assert(mr_sps_write_u(&w, 3, 5u)); /* video_format = unspecified */
            assert(mr_sps_write_u(&w, 1, 1u)); /* video_full_range_flag = 1 */
            assert(mr_sps_write_u(&w, 1, 1u)); /* colour_description_present */
            assert(mr_sps_write_u(&w, 8, 1u)); /* bt709 primaries */
            assert(mr_sps_write_u(&w, 8, 1u)); /* bt709 transfer */
            assert(mr_sps_write_u(&w, 8, 1u)); /* bt709 matrix */
        }
        assert(mr_sps_write_u(&w, 1, 0u)); /* chroma_loc */
        assert(mr_sps_write_u(&w, 1, 0u)); /* timing_info */
        assert(mr_sps_write_u(&w, 1, 0u)); /* nal_hrd */
        assert(mr_sps_write_u(&w, 1, 0u)); /* vcl_hrd */
        assert(mr_sps_write_u(&w, 1, 0u)); /* pic_struct */
        assert(mr_sps_write_u(&w, 1, withOrigBr ? 1u : 0u)); /* bitstream_restriction */
        if (withOrigBr) {
            assert(mr_sps_write_u(&w, 1, 1u));
            assert(mr_sps_write_ue(&w, 0u));
            assert(mr_sps_write_ue(&w, 0u));
            assert(mr_sps_write_ue(&w, 12u));
            assert(mr_sps_write_ue(&w, 12u));
            assert(mr_sps_write_ue(&w, 4u)); /* old reorder = 4 */
            assert(mr_sps_write_ue(&w, 9u)); /* old dpb = 9 */
        }
    }
    assert(mr_sps_write_u(&w, 1, 1u));
    while (w.bitPos & 7u)
        assert(mr_sps_write_u(&w, 1, 0u));
    assert(mr_sps_escape(0x67u, rbsp, w.bitPos >> 3, outNal, outCap, outLen));
}

static void assert_no_start_code_emulation(const uint8_t *nal, size_t len)
{
    for (size_t i = 1; i + 2 < len; i++) {
        assert(!(nal[i] == 0 && nal[i + 1] == 0 && nal[i + 2] <= 2));
    }
}

static void test_synthetic_sps_cases(void)
{
    uint8_t src[256], dst[256];
    size_t srcLen = 0, dstLen = 0;
    mrSpsVuiInfo info;

    /* 1. Baseline SPS without VUI (VideoToolbox default) -> VUI injected, reorder=0, dpb=1 */
    build_synthetic_sps(0, 0, 0, 0, 1, src, sizeof(src), &srcLen);
    assert(mr_h264_parse_sps_vui(src, srcLen, &info));
    assert(info.profileIdc == 66 && info.levelIdc == 50 && info.vuiPresent == 0);
    assert(mr_h264_rewrite_sps_low_latency(src, srcLen, dst, sizeof(dst), &dstLen));
    assert_no_start_code_emulation(dst, dstLen);
    assert(mr_h264_parse_sps_vui(dst, dstLen, &info));
    assert(info.vuiPresent == 1 && info.bitstreamRestrictionPresent == 1);
    assert(info.maxNumReorderFrames == 0 && info.maxDecFrameBuffering == 1);

    /* 2. High Profile SPS with existing VUI + full-range colorimetry preserved */
    build_synthetic_sps(1, 1, 1, 0, 2, src, sizeof(src), &srcLen);
    assert(mr_h264_rewrite_sps_low_latency(src, srcLen, dst, sizeof(dst), &dstLen));
    assert_no_start_code_emulation(dst, dstLen);
    assert(mr_h264_parse_sps_vui(dst, dstLen, &info));
    assert(info.profileIdc == 100 && info.videoSignalPresent == 1 && info.videoFullRange == 1);
    assert(info.bitstreamRestrictionPresent == 1);
    assert(info.maxNumReorderFrames == 0 && info.maxDecFrameBuffering == 2);

    /* 3. Existing bitstream_restriction with large reorder/dpb gets tightened */
    build_synthetic_sps(0, 1, 0, 1, 1, src, sizeof(src), &srcLen);
    assert(mr_h264_parse_sps_vui(src, srcLen, &info));
    assert(info.maxNumReorderFrames == 4 && info.maxDecFrameBuffering == 9);
    assert(mr_h264_rewrite_sps_low_latency(src, srcLen, dst, sizeof(dst), &dstLen));
    assert_no_start_code_emulation(dst, dstLen);
    assert(mr_h264_parse_sps_vui(dst, dstLen, &info));
    assert(info.maxNumReorderFrames == 0 && info.maxDecFrameBuffering == 1);

    /* 4. Non-SPS / truncated / tiny buffer safely fail without corrupting */
    uint8_t pps[] = { 0x68, 0xCE, 0x3C, 0x80, 0x00 };
    assert(!mr_h264_rewrite_sps_low_latency(pps, sizeof(pps), dst, sizeof(dst), &dstLen));
    assert(!mr_h264_rewrite_sps_low_latency(src, 4, dst, sizeof(dst), &dstLen));
    assert(!mr_h264_rewrite_sps_low_latency(src, srcLen, dst, 4, &dstLen));
}

static int find_sps_nal(const uint8_t *stream, size_t size, const uint8_t **sps, size_t *spsLen)
{
    size_t i = 0;
    while (i + 4 < size) {
        size_t scLen = 0;
        if (stream[i] == 0 && stream[i + 1] == 0 && stream[i + 2] == 1)
            scLen = 3;
        else if (stream[i] == 0 && stream[i + 1] == 0 && stream[i + 2] == 0 && stream[i + 3] == 1)
            scLen = 4;
        if (!scLen) {
            i++;
            continue;
        }
        const size_t nalStart = i + scLen;
        size_t nalEnd = size;
        for (size_t j = nalStart; j + 3 < size; j++) {
            if (stream[j] == 0 && stream[j + 1] == 0 &&
                (stream[j + 2] == 1 || (stream[j + 2] == 0 && stream[j + 3] == 1))) {
                nalEnd = j;
                break;
            }
        }
        if (nalStart < nalEnd && (stream[nalStart] & 0x1Fu) == 7u) {
            *sps = stream + nalStart;
            *spsLen = nalEnd - nalStart;
            return 1;
        }
        i = nalEnd;
    }
    return 0;
}

static void test_videotoolbox_sps_and_roundtrip(uint32_t width, uint32_t height)
{
    H264_CONTEXT *enc = h264_context_new(TRUE);
    H264_CONTEXT *dec = h264_context_new(FALSE);
    assert(enc && dec);
    assert(h264_context_reset(enc, width, height));
    assert(h264_context_reset(dec, width, height));
    assert(h264_context_set_option(enc, H264_CONTEXT_OPTION_RATECONTROL, H264_RATECONTROL_VBR));
    assert(h264_context_set_option(enc, H264_CONTEXT_OPTION_BITRATE, 1050000));
    assert(h264_context_set_option(enc, H264_CONTEXT_OPTION_FRAMERATE, 15));

    const uint32_t stride = width * 4u;
    uint8_t *src = calloc((size_t)stride * height, 1);
    uint8_t *out = calloc((size_t)stride * height, 1);
    assert(src && out);

    /* Draw crisp horizontal bands and high-contrast text-like bars. */
    for (uint32_t y = 0; y < height; y++) {
        uint8_t *row = src + (size_t)y * stride;
        for (uint32_t x = 0; x < width; x++) {
            const uint8_t v = ((x / 32u + y / 32u) & 1u) ? 220u : 40u;
            row[x * 4 + 0] = v;
            row[x * 4 + 1] = (uint8_t)((y * 255u) / height);
            row[x * 4 + 2] = (uint8_t)((x * 255u) / width);
            row[x * 4 + 3] = 255u;
        }
    }

    RECTANGLE_16 region = { 0, 0, (uint16_t)width, (uint16_t)height };
    BYTE *coded = NULL;
    UINT32 codedSize = 0;
    RDPGFX_H264_METABLOCK meta = { 0 };
    assert(avc420_compress(enc, src, PIXEL_FORMAT_BGRX32, stride, width, height, &region,
                           &coded, &codedSize, &meta) > 0);
    assert(coded && codedSize > 0);

    const uint8_t *sps = NULL;
    size_t spsLen = 0;
    assert(find_sps_nal(coded, codedSize, &sps, &spsLen));
    assert_no_start_code_emulation(sps, spsLen);

    mrSpsVuiInfo info;
    assert(mr_h264_parse_sps_vui(sps, spsLen, &info));
    assert(info.vuiPresent == 1);
    assert(info.bitstreamRestrictionPresent == 1);
    assert(info.maxNumReorderFrames == 0);
    assert(info.maxDecFrameBuffering == (info.maxNumRefFrames > 1 ? info.maxNumRefFrames : 1));

    /* Real VideoToolbox hardware decode must accept the rewritten SPS cleanly. */
    assert(avc420_decompress(dec, coded, codedSize, out, PIXEL_FORMAT_BGRX32, stride,
                             width, height, &region, 1) >= 0);
    free_h264_metablock(&meta);

    /* Verify avc420_repeat (idle refinement frame) also encodes & decodes cleanly. */
    RDPGFX_H264_METABLOCK refineMeta = { 0 };
    assert(avc420_repeat(enc, width, height, &coded, &codedSize, &refineMeta) > 0);
    assert(coded && codedSize > 0);
    assert(avc420_decompress(dec, coded, codedSize, out, PIXEL_FORMAT_BGRX32, stride,
                             width, height, &region, 1) >= 0);
    free_h264_metablock(&refineMeta);

    free(src);
    free(out);
    h264_context_free(enc);
    h264_context_free(dec);
}

int main(void)
{
    test_synthetic_sps_cases();
    test_videotoolbox_sps_and_roundtrip(1920, 1080);
    test_videotoolbox_sps_and_roundtrip(2304, 1296);
    puts("PASS: H.264 SPS VUI low-latency rewrite + real VideoToolbox 1080p/1296p roundtrip");
    return 0;
}
