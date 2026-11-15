#ifndef MACREMOTE_RDP_GRAPHICS_H
#define MACREMOTE_RDP_GRAPHICS_H
#include <freerdp/settings.h>
#include <stdbool.h>

typedef enum {
    MR_GFX_H264,
    MR_GFX_AVC444,
    MR_GFX_BALANCED,
    MR_GFX_CLASSIC
} MRGraphicsMode;

const char *mr_gfx_label(MRGraphicsMode mode);
bool mr_gfx_parse(const char *text, MRGraphicsMode *out);
bool mr_gfx_configure(rdpSettings *settings, MRGraphicsMode mode);
#endif
