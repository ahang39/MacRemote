/* The *production* RGB tile selector used after scaled ScreenCaptureKit capture.
 * Deliberately padded rows and differing alpha, to ensure no missing RGB damage. */
#include "mac_scaled_dirty.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void set_pixel(uint8_t* b, size_t stride, int x, int y, unsigned r, unsigned g, unsigned bl, unsigned a)
{
    uint8_t* p = b + (size_t)y * stride + (size_t)x * 4;
    p[0] = (uint8_t)bl; p[1] = (uint8_t)g; p[2] = (uint8_t)r; p[3] = (uint8_t)a;
}
int main(void)
{
    enum { W = 260, H = 259, MAX = 64 };
    const size_t stride = W*4+32;
    uint8_t* source = calloc(H, stride);
    uint8_t* dest = calloc(H, stride);
    assert(source && dest);
    macScaledDirtyRect tiles[MAX] = {0};
    for(int y=0;y<H;y++) for(int x=0;x<W;x++) {
        set_pixel(source,stride,x,y,0,0,0,255);
        set_pixel(dest,stride,x,y,0,0,0,0);
    }
    assert(mac_scaled_collect_dirty(source,stride,dest,stride,W,H,tiles,MAX)==0);
    set_pixel(source,stride,0,0,255,4,7,255);
    set_pixel(source,stride,259,258,7,88,255,255);
    set_pixel(source,stride,127,127,7,8,9,255);
    const uint32_t changed=mac_scaled_collect_dirty(source,stride,dest,stride,W,H,tiles,MAX);
    assert(changed == 2);
    assert(tiles[0].left == 0 && tiles[0].top == 0 &&
           tiles[0].right == 128 && tiles[0].bottom == 128);
    assert(tiles[1].left == 256 && tiles[1].top == 256 &&
           tiles[1].right == 260 && tiles[1].bottom == 259);
    for(uint32_t i=0;i<changed;i++)
        for(int y=tiles[i].top;y<tiles[i].bottom;y++)
            memcpy(dest+(size_t)y*stride+(size_t)tiles[i].left*4,
                   source+(size_t)y*stride+(size_t)tiles[i].left*4,
                   (tiles[i].right-tiles[i].left)*4);
    assert(mac_scaled_collect_dirty(source,stride,dest,stride,W,H,tiles,MAX)==0);
    assert(mac_scaled_collect_dirty(source,stride,dest,stride,W,H,tiles,0)==MAC_SCALED_DIRTY_FULL);
    assert(mac_scaled_collect_dirty(source,W*4-1,dest,stride,W,H,tiles,MAX)==MAC_SCALED_DIRTY_FULL);
    const unsigned largeW=2304,largeH=1296;
    uint8_t* bigSrc=calloc(largeH,(size_t)largeW*4);
    uint8_t* bigDst=calloc(largeH,(size_t)largeW*4);
    assert(bigSrc && bigDst);
    for(size_t i=0;i<(size_t)largeW*largeH*4;i+=4) bigSrc[i]=77;
    assert(mac_scaled_collect_dirty(bigSrc,(size_t)largeW*4,bigDst,(size_t)largeW*4,
                                    largeW,largeH,tiles,MAX)==MAC_SCALED_DIRTY_FULL);
    free(bigSrc);free(bigDst);free(source);free(dest);
    puts("PASS scaled dirty: exact RGB tiles, padded stride, alpha, edge, large fallback");
    return 0;
}
