#ifndef MACREMOTE_POINTER_GEOMETRY_H
#define MACREMOTE_POINTER_GEOMETRY_H

#include <stdbool.h>
#include <stdint.h>

static inline bool mr_pointer_geometry_ready(uint32_t requestedWidth,
                                              uint32_t requestedHeight,
                                              uint32_t surfaceWidth,
                                              uint32_t surfaceHeight,
                                              uint32_t displayWidth,
                                              uint32_t displayHeight,
                                              bool resizing)
{
    return !resizing && requestedWidth > 0 && requestedHeight > 0 &&
           requestedWidth == surfaceWidth && requestedHeight == surfaceHeight &&
           displayWidth > 0 && displayHeight > 0;
}

static inline bool mr_pointer_event_allowed(bool geometryReady, bool button, bool down)
{
    return geometryReady || (button && !down);
}

#endif
