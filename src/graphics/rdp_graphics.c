#include "rdp_graphics.h"

bool mr_gfx_configure(rdpSettings *settings)
{
    if (!settings)
        return false;
    return freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32) &&
           freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_GfxH264, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444v2, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_GfxProgressive, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_NSCodec, TRUE);
}
