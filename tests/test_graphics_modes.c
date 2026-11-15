#include "../src/graphics/rdp_graphics.h"
#include <stdio.h>
#include <string.h>

#define CHECK(x) do {if (!(x)) {fprintf(stderr,"graphics settings fail line %d: %s\n",__LINE__,#x);return 1;}}while(0)
int main(void)
{
    MRGraphicsMode mode=MR_GFX_CLASSIC;
    CHECK(mr_gfx_parse("avc444",&mode) && mode==MR_GFX_AVC444);
    CHECK(!strcmp(mr_gfx_label(mode),"RDPGFX/AVC444v2 (VideoToolbox, AVC420 fallback)"));
    CHECK(mr_gfx_parse("h264",&mode) && mode==MR_GFX_H264);
    CHECK(mr_gfx_parse("balanced",&mode) && mode==MR_GFX_BALANCED);
    CHECK(mr_gfx_parse("classic",&mode) && mode==MR_GFX_CLASSIC);
    CHECK(!mr_gfx_parse("hevc",&mode));
    CHECK(!mr_gfx_parse(NULL,&mode));
    CHECK(!mr_gfx_parse("avc444",NULL));

    for(int i=0;i<4;i++) {
        rdpSettings *s=freerdp_settings_new(FREERDP_SETTINGS_SERVER_MODE);
        CHECK(s!=NULL);
        CHECK(mr_gfx_configure(s,(MRGraphicsMode)i));
        int enabled=i!=MR_GFX_CLASSIC;
        int codec=i==MR_GFX_H264 || i==MR_GFX_AVC444;
        int avc444=i==MR_GFX_AVC444;
        CHECK(!!freerdp_settings_get_bool(s,FreeRDP_SupportGraphicsPipeline)==enabled);
        CHECK(!!freerdp_settings_get_bool(s,FreeRDP_GfxH264)==codec);
        CHECK(!!freerdp_settings_get_bool(s,FreeRDP_GfxAVC444)==avc444);
        CHECK(!!freerdp_settings_get_bool(s,FreeRDP_GfxAVC444v2)==avc444);
        CHECK(!!freerdp_settings_get_bool(s,FreeRDP_GfxProgressive)==enabled);
        CHECK(freerdp_settings_get_uint32(s,FreeRDP_ColorDepth)==32);
        freerdp_settings_free(s);
    }
    CHECK(!mr_gfx_configure(NULL,MR_GFX_AVC444));
    puts("PASS: native graphics profiles and explicit AVC444v2->AVC444->AVC420 compatibility flags");
    return 0;
}