#include <freerdp/codec/h264.h>
#include <freerdp/codec/color.h>
#include <freerdp/channels/rdpgfx.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static int verify(unsigned w,unsigned h,unsigned version) {
 size_t count=(size_t)w*h*4;
 BYTE *orig=calloc(1,count), *out=calloc(1,count);
 if(!orig || !out) return 1;
 for (unsigned y=0;y<h;y++)for(unsigned x=0;x<w;x++) {
  size_t k=(size_t)(y*w+x)*4;
  orig[k]=(BYTE)(x/7%2?220:20);
  orig[k+1]=(BYTE)(y/7%2?245:13);
  orig[k+2]=(BYTE)((x+y)/9%2?250:30);
  orig[k+3]=255;
 }
 H264_CONTEXT *enc=h264_context_new(TRUE);
 H264_CONTEXT *dec=h264_context_new(FALSE);
 if(!enc||!dec||!h264_context_reset(enc,w,h)||!h264_context_reset(dec,w,h)) {
  fprintf(stderr,"No encode/decode context\n");return 2;
 }
 RECTANGLE_16 bounds={.left=0,.top=0,.right=w,.bottom=h};
 RDPGFX_H264_METABLOCK lum={0},chr={0};
 BYTE op=255,*main=NULL,*aux=NULL;
 UINT32 ml=0,al=0;
 int encres=avc444_compress(enc,orig,PIXEL_FORMAT_BGRX32,w*4,w,h,version,&bounds,&op,&main,&ml,&aux,&al,&lum,&chr);
 if(encres<=0 || ml==0){fprintf(stderr,"Encode fail %ux%u v%u rc=%d ml=%u\n",w,h,version,encres,ml);return 3;}
 int decres=avc444_decompress(dec,op,lum.regionRects,lum.numRegionRects,main,ml,chr.regionRects,chr.numRegionRects,aux,al,out,PIXEL_FORMAT_BGRX32,w*4,w,h,version==2?RDPGFX_CODECID_AVC444v2:RDPGFX_CODECID_AVC444);
 double avg=0;uint64_t n=0;unsigned fill=0;
 for(unsigned y=24;y+24<h;y+=31)for(unsigned x=24;x+24<w;x+=31){
  size_t k=((size_t)y*w+x)*4;
  for(int c=0;c<3;c++){avg+=abs((int)orig[k+c]-(int)out[k+c]);n++;}
  if(out[k] || out[k+1] || out[k+2])fill++;
 }
 avg/=n?n:1;
 printf("AVC444v%u %ux%u enc=%d main=%u aux=%u op=%u dec=%d MAE=%.2f nonzero=%u\n",version,w,h,encres,ml,al,op,decres,avg,fill);
 fflush(stdout);
 free_h264_metablock(&lum);free_h264_metablock(&chr);h264_context_free(enc);h264_context_free(dec);free(orig);free(out);
 return decres<0 || avg>85 || !fill ? 4:0;
}
int main(void){
 const unsigned sizes[][2]={{128,128},{1534,1066},{2304,964}};
 for(int i=0;i<3;i++)for(int v=1;v<=2;v++){
  int rc=verify(sizes[i][0],sizes[i][1],v);
  if(rc) return rc;
 }
 puts("PASS encode/decode roundtrips for AVC444v1 and v2 on observed macOS desktop sizes");
 return 0;
}