#include "../src/input/pointer_geometry.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <stdio.h>

int main(void)
{
    assert(!mr_pointer_event_allowed(false, false, false));
    assert(!mr_pointer_event_allowed(false, true, true));
    assert(mr_pointer_event_allowed(false, true, false));
    assert(mr_pointer_event_allowed(true, false, false));
    assert(mr_pointer_event_allowed(true, true, true));

    assert(mr_pointer_geometry_ready(1920,1080,1920,1080,1920,1080,false));
    assert(mr_pointer_geometry_ready(2560,1072,2560,1072,2560,1072,false));
    assert(!mr_pointer_geometry_ready(2560,1440,1920,1080,1920,1080,false));
    assert(!mr_pointer_geometry_ready(1920,1080,2560,1072,1920,1080,false));
    assert(mr_pointer_geometry_ready(2304,1296,2304,1296,1920,1080,false));
    assert(mr_pointer_geometry_ready(1920,1080,1920,1080,1152,648,false));
    assert(!mr_pointer_geometry_ready(1920,1080,1920,1080,0,1080,false));
    assert(!mr_pointer_geometry_ready(1920,1080,1920,1080,1920,1080,true));
    puts("pointer geometry: all checks passed");
    return 0;
}
