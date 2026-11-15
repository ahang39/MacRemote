#include "rdp_graphics.h"
#include <string.h>

const char *mr_gfx_label(MRGraphicsMode mode)
{
    switch (mode) {
        case MR_GFX_H264: return "RDPGFX/AVC420 (VideoToolbox)";
        case MR_GFX_AVC444: return "RDPGFX/AVC444v2 (VideoToolbox, AVC420 fallback)";
        case MR_GFX_BALANCED: return "RDPGFX/progressive (no H.264)";
        case MR_GFX_CLASSIC: return "classic bitmap (RDPGFX disabled)";
    }
    return "unknown";
}

bool mr_gfx_parse(const char *text, MRGraphicsMode *out)
{
    if (!text || !out) return false;
    if (!strcmp(text, "h264")) *out = MR_GFX_H264;
    else if (!strcmp(text, "avc444")) *out = MR_GFX_AVC444;
    else if (!strcmp(text, "balanced")) *out = MR_GFX_BALANCED;
    else if (!strcmp(text, "classic")) *out = MR_GFX_CLASSIC;
    else return false;
    return true;
}

bool mr_gfx_configure(rdpSettings *settings, MRGraphicsMode mode)
{
    if (!settings) return false;
    const bool gfx = mode != MR_GFX_CLASSIC;
    const bool h264 = mode == MR_GFX_H264 || mode == MR_GFX_AVC444;
    const bool avc444 = mode == MR_GFX_AVC444;
    /* FreeRDP prefers AVC444v2 when negotiated, then AVC444, AVC420 and
     * the existing RDPGFX codecs. H.264 remains available for clients
     * that do not advertise AVC444. Classic is never altered. */
    return freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_ExtSecurity, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE) &&
           freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32) &&
           freerdp_settings_set_bool(settings, FreeRDP_GfxH264, h264) &&
           freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, avc444) &&
           freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444v2, avc444) &&
           freerdp_settings_set_bool(settings, FreeRDP_GfxProgressive, gfx) &&
           freerdp_settings_set_bool(settings, FreeRDP_NSCodec, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, gfx);
}
