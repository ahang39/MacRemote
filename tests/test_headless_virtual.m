#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include "../src/display/headless_virtual.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <stdio.h>
int main(void)
{
    @autoreleasepool {
        /* Display-read-only, including when no monitor is connected. */
        assert(mr_headless_start(false, NULL) == 0);
        assert(mr_headless_owned_display() == kCGNullDirectDisplay);
        mr_headless_update(false, NULL, false);
        mr_headless_stop();
        assert(mr_headless_owned_display() == kCGNullDirectDisplay);
        printf("headless private runtime API: %s\n",
               mr_headless_api_available() ? "available" : "unavailable");
    }
    return 0;
}
