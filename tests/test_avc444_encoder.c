#include <freerdp/codec/h264.h>
#include <freerdp/codec/color.h>
#include <freerdp/channels/rdpgfx.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
    enum { WIDTH=128, HEIGHT=128 };
    BYTE *pixels=calloc(WIDTH*HEIGHT,4);
    if(!pixels) return 1;
    for(unsigned y=0;y<HEIGHT;y++)
        for(unsigned x=0;x<WIDTH;x++) {
            const unsigned i=4*(y*WIDTH+x);
            pixels[i+0]=(BYTE)(x*2);
            pixels[i+1]=(BYTE)(y*2);
            pixels[i+2]=(BYTE)(((x/8+y/8)%2)?255:0);
            pixels[i+3]=255;
        }
    for(unsigned version=1;version<=2;version++) {
        H264_CONTEXT *ctx=h264_context_new(TRUE);
        if(!ctx || !h264_context_reset(ctx,WIDTH,HEIGHT)) {
            fprintf(stderr,"H.264 encoder unavailable for AVC444v%u\n",version);
            free(pixels);return 2;
        }
        const RECTANGLE_16 region={.left=0,.top=0,.right=WIDTH,.bottom=HEIGHT};
        RDPGFX_H264_METABLOCK luma={0},chroma={0};
        BYTE op=255,*mainData=NULL,*auxData=NULL;
        UINT32 mainLen=0,auxLen=0;
        int rc=avc444_compress(ctx,pixels,PIXEL_FORMAT_BGRX32,WIDTH*4,
                               WIDTH,HEIGHT,(BYTE)version,&region,&op,
                               &mainData,&mainLen,&auxData,&auxLen,&luma,&chroma);
        printf("AVC444v%u: rc=%d op=%u main=%u aux=%u lumaRegions=%u chromaRegions=%u\n",
               version,rc,op,mainLen,auxLen,luma.numRegionRects,chroma.numRegionRects);
        fflush(stdout);
        int ok=(rc>0 && op<=2 && mainLen>0 &&
                luma.numRegionRects>0 && chroma.numRegionRects>0 &&
                (op!=0 || auxLen>0));
        free_h264_metablock(&luma);
        free_h264_metablock(&chroma);
        h264_context_free(ctx);
        if(!ok){free(pixels);return 3+(int)version;}
    }
    free(pixels);
    puts("PASS: AVC444 and AVC444v2 both encode real BGRA source frames");
    return 0;
}