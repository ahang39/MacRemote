#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

/* Calls are all on the RDP process startup/shutdown thread. */
bool mr_headless_api_available(void);
/* Returns 1 when we created an owned display, 0 if any display exists,
 * -1 if a headless display could not be created. */
int mr_headless_start(bool enabled, const char* configDirectory);
/* Called every ~2s while serving: handles unplug and foreign-display return. */
void mr_headless_update(bool enabled, const char* configDirectory, bool hasClients);
void mr_headless_stop(void);
CGDirectDisplayID mr_headless_owned_display(void);

/* Chromium's CoreGraphics virtual display model marker is 'virt'.
 * Also identify our own display using its private vendor/product pair.
 * Never persistently modify a borrowed virtual screen's macOS mode. */
static inline bool mr_headless_is_virtual_display(CGDirectDisplayID id)
{
    return id && (CGDisplayModelNumber(id) == 0x76697274 ||
                  (CGDisplayVendorNumber(id) == 0x4d52 &&
                   CGDisplayModelNumber(id) == 0x4844));
}
