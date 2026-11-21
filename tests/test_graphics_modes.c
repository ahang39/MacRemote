#include "../src/graphics/rdp_graphics.h"
#include <stdio.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "graphics config fail line %d: %s\n", __LINE__, #x); return 1; } } while (0)

int main(void)
{
    rdpSettings *s = freerdp_settings_new(FREERDP_SETTINGS_SERVER_MODE);
    CHECK(s != NULL);
    CHECK(mr_gfx_configure(s));
    CHECK(freerdp_settings_get_uint32(s, FreeRDP_ColorDepth) == 32);
    CHECK(freerdp_settings_get_bool(s, FreeRDP_SupportGraphicsPipeline) == TRUE);
    CHECK(freerdp_settings_get_bool(s, FreeRDP_GfxH264) == TRUE);
    CHECK(freerdp_settings_get_bool(s, FreeRDP_GfxAVC444) == FALSE);
    CHECK(freerdp_settings_get_bool(s, FreeRDP_GfxAVC444v2) == FALSE);
    CHECK(freerdp_settings_get_bool(s, FreeRDP_GfxProgressive) == FALSE);
    CHECK(freerdp_settings_get_bool(s, FreeRDP_RemoteFxCodec) == FALSE);
    CHECK(freerdp_settings_get_bool(s, FreeRDP_NSCodec) == TRUE);
    freerdp_settings_free(s);
    CHECK(!mr_gfx_configure(NULL));
    puts("PASS: single H.264/AVC420 RDPGFX graphics configuration");
    return 0;
}
