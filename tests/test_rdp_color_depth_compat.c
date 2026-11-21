#include "shadow_color_depth_compat.h"
#include <stdio.h>
#define CHECK(x) do { if(!(x)) {fprintf(stderr,"FAILED %d: %s\n",__LINE__,#x);return 1;} } while(0)
int main(void)
{
    CHECK(mr_shadow_use_legacy_bitmap(8));
    CHECK(mr_shadow_use_legacy_bitmap(15));
    CHECK(mr_shadow_use_legacy_bitmap(16));
    CHECK(mr_shadow_use_legacy_bitmap(24));
    CHECK(!mr_shadow_use_legacy_bitmap(32));
    CHECK(!mr_shadow_use_surface_bits(16, true));
    CHECK(!mr_shadow_use_surface_bits(24, true));
    CHECK(!mr_shadow_use_surface_bits(32, false));
    CHECK(mr_shadow_use_surface_bits(32, true));
    puts("PASS 16-bit fallback and 32-bit H264 preservation");
    return 0;
}
