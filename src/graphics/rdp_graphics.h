#ifndef MACREMOTE_RDP_GRAPHICS_H
#define MACREMOTE_RDP_GRAPHICS_H

#include <freerdp/settings.h>
#include <stdbool.h>

/* Configure standard 32-bit RDPGFX + H.264/AVC420 (VideoToolbox).
 * Clients connecting at <32bpp automatically fall back to legacy BitmapUpdate. */
bool mr_gfx_configure(rdpSettings *settings);

#endif
