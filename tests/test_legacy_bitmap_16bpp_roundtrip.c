/* Exercise real FreeRDP 16-bit BitmapUpdate codec using a 1920x1080
 * BGRX32 desktop. Validate the last row and bottom tiles are intact. */
#include <freerdp/codec/interleaved.h>
#include <freerdp/codec/color.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAILED line %d: %s\n", __LINE__, #x); return 1; } } while (0)
static int adiff(int a,int b) { int d=a-b;return d<0?-d:d; }
int main(void)
{
    enum { W=1920,H=1080,STEP=W*4 };
    BYTE* source=(BYTE*)calloc(H,STEP);
    BYTE* destination=(BYTE*)calloc(H,STEP);
    CHECK(source && destination);
    for (int y=0;y<H;y++)
        for (int x=0;x<W;x++)
        {
            BYTE* p=&source[y*STEP+x*4];
            p[0]=(BYTE)((x*3+y)&255);
            p[1]=(BYTE)((x/3+y*2)&255);
            p[2]=(BYTE)((x+y*5)&255);
            p[3]=0xff;
        }
    BITMAP_INTERLEAVED_CONTEXT* encoder=bitmap_interleaved_context_new(TRUE);
    BITMAP_INTERLEAVED_CONTEXT* decoder=bitmap_interleaved_context_new(FALSE);
    CHECK(encoder && decoder);
    const struct { unsigned x,y,w,h; } tiles[]={
        {0,0,64,64},{960,0,64,64},{1856,0,64,64},
        {0,512,64,64},{960,512,64,64},{1856,512,64,64},
        {0,1024,64,56},{960,1024,64,56},{1856,1024,64,56}
    };
    for(size_t t=0;t<sizeof(tiles)/sizeof(tiles[0]);t++)
    {
        const unsigned tx=tiles[t].x,ty=tiles[t].y,tw=tiles[t].w,th=tiles[t].h;
        BYTE encoded[64*64*4]={0};
        UINT32 size=sizeof(encoded);
        CHECK(interleaved_compress(encoder,encoded,&size,tw,th,source,
                                   PIXEL_FORMAT_BGRX32,STEP,tx,ty,NULL,16));
        CHECK(size && size<=sizeof(encoded));
        CHECK(interleaved_decompress(decoder,encoded,size,tw,th,16,
                                     destination,PIXEL_FORMAT_BGRX32,
                                     STEP,tx,ty,tw,th,NULL));
        for(unsigned y=ty;y<ty+th;y++)
            for(unsigned x=tx;x<tx+tw;x++)
            {
                const BYTE* a=&source[y*STEP+x*4];
                const BYTE* b=&destination[y*STEP+x*4];
                CHECK(adiff(a[0],b[0])<=8);
                CHECK(adiff(a[1],b[1])<=8);
                CHECK(adiff(a[2],b[2])<=8);
            }
    }
    CHECK(destination[1024*STEP+960*4+2]!=0);
    bitmap_interleaved_context_free(encoder);
    bitmap_interleaved_context_free(decoder);
    free(source);free(destination);
    puts("PASS: 16-bit tile codec roundtrip across top/middle/bottom 1920x1080");
    return 0;
}
