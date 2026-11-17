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

/* Confirm the actual AVC420 encoder/decoder, independently of AVC444.
 * A successful codec round-trip alone does not establish MSTSC RDPGFX. */
static int verify_avc420(unsigned w, unsigned h) {
 size_t count=(size_t)w*h*4;
 BYTE *orig=calloc(1,count), *out=calloc(1,count);
 if(!orig || !out) {free(orig);free(out);return 10;}
 for(unsigned y=0;y<h;y++)for(unsigned x=0;x<w;x++) {
  size_t k=((size_t)y*w+x)*4;
  orig[k]=(BYTE)(x/7%2?220:20);
  orig[k+1]=(BYTE)(y/7%2?245:13);
  orig[k+2]=(BYTE)((x+y)/9%2?250:30);
  orig[k+3]=255;
 }
 H264_CONTEXT *enc=h264_context_new(TRUE), *dec=h264_context_new(FALSE);
 if(!enc||!dec||!h264_context_reset(enc,w,h)||!h264_context_reset(dec,w,h)){
  fprintf(stderr,"AVC420 context unavailable\n");
  h264_context_free(enc);h264_context_free(dec);free(orig);free(out);return 11;
 }
 if(!h264_context_set_option(enc,H264_CONTEXT_OPTION_BITRATE,4000000))return 15;
 RECTANGLE_16 bounds={.left=0,.top=0,.right=w,.bottom=h};
 RDPGFX_H264_METABLOCK meta={0};
 BYTE* stream=NULL; UINT32 length=0;
 int erc=avc420_compress(enc,orig,PIXEL_FORMAT_BGRX32,w*4,w,h,&bounds,&stream,&length,&meta);
 if(erc<=0 || length==0 || !stream){
  fprintf(stderr,"AVC420 encode fail %ux%u rc=%d len=%u\n",w,h,erc,length);
  free_h264_metablock(&meta);h264_context_free(enc);h264_context_free(dec);
  free(orig);free(out);return 12;
 }
 int drc=avc420_decompress(dec,stream,length,out,PIXEL_FORMAT_BGRX32,w*4,w,h,
                            meta.regionRects,meta.numRegionRects);
 double avg=0;uint64_t n=0;unsigned fill=0;
 for(unsigned y=24;y+24<h;y+=31)for(unsigned x=24;x+24<w;x+=31){
  size_t k=((size_t)y*w+x)*4;
  for(int c=0;c<3;c++){avg+=abs((int)orig[k+c]-(int)out[k+c]);n++;}
  if(out[k] || out[k+1] || out[k+2])fill++;
 }
 avg/=n?n:1;
 printf("AVC420 %ux%u enc=%d bytes=%u dec=%d MAE=%.2f nonzero=%u\n",
        w,h,erc,length,drc,avg,fill);
 free_h264_metablock(&meta);
 /* An identical frame is skipped by AVC420, not acknowledged by the
  * RDP client. Shadow must therefore reclaim its reserved frame ID. */
 RDPGFX_H264_METABLOCK noChange={0};
 int repeated=avc420_compress(enc,orig,PIXEL_FORMAT_BGRX32,w*4,w,h,
                              &bounds,&stream,&length,&noChange);
 free_h264_metablock(&noChange);
 h264_context_free(enc);h264_context_free(dec);
 free(orig);free(out);
 if(repeated!=0) {
  fprintf(stderr,"AVC420 repeated frame unexpectedly produced output: %d\n",repeated);
  return 14;
 }
 return drc<0 || avg>85 || !fill ? 13:0;
}

/* A moving window exercises dirty tiles, clearing its old location and
 * continuous P-frames. Previous smoke tests checked only the first frame. */
static int verify_avc420_motion(void) {
 const unsigned w=640,h=360;
 BYTE* input=calloc((size_t)w*h,4),*out=calloc((size_t)w*h,4);
 if(!input||!out) {free(input);free(out);return 21;}
 H264_CONTEXT* enc=h264_context_new(TRUE),*dec=h264_context_new(FALSE);
 if(!enc||!dec||!h264_context_reset(enc,w,h)||!h264_context_reset(dec,w,h))
  return 22;
 const RECTANGLE_16 full={0,0,w,h};
 for(unsigned frame=0;frame<6;frame++) {
  unsigned left=frame%2?330:35;
  for(unsigned y=0;y<h;y++)for(unsigned x=0;x<w;x++) {
   size_t k=((size_t)y*w+x)*4;
   int box=x>=left&&x<left+235&&y>=45&&y<310;
   input[k]=box?28:242;
   input[k+1]=box?79:242;
   input[k+2]=box?202:242;
   input[k+3]=255;
  }
  RDPGFX_H264_METABLOCK meta={0};
  BYTE* encoded=NULL; UINT32 bytes=0;
  int rc=avc420_compress(enc,input,PIXEL_FORMAT_BGRX32,w*4,w,h,
                          &full,&encoded,&bytes,&meta);
  if(rc<=0 || bytes==0 || meta.numRegionRects==0) {
   fprintf(stderr,"AVC420 motion encode frame=%u rc=%d bytes=%u rects=%u\n",
           frame,rc,bytes,meta.numRegionRects);
   return 23;
  }
  int drc=avc420_decompress(dec,encoded,bytes,out,PIXEL_FORMAT_BGRX32,
                             w*4,w,h,meta.regionRects,meta.numRegionRects);
  unsigned bad=0;
  for(unsigned y=80;y<290;y+=20)for(unsigned x=20;x<w-20;x+=20) {
   size_t k=((size_t)y*w+x)*4;
   for(unsigned c=0;c<3;c++)
    if(abs((int)input[k+c]-(int)out[k+c])>90) bad++;
  }
  fprintf(stdout,"AVC420 moving window frame=%u bytes=%u rects=%u errors=%u\n",
          frame,bytes,meta.numRegionRects,bad);
  free_h264_metablock(&meta);
  if(drc<0 || bad>4)return 24;
 }
 h264_context_free(enc);h264_context_free(dec);free(input);free(out);
 return 0;
}

/* A few moving glyph pixels must not turn periodic presentation-drain
 * pictures into full-screen keyframes. Uses the actual VideoToolbox encoder. */
static int has_h264_idr(const BYTE* data, UINT32 size) {
 for(UINT32 n=0;n+4<size;n++)
  if(data[n]==0 && data[n+1]==0 && data[n+2]==0 &&
     data[n+3]==1 && (data[n+4]&31u)==5u)
   return 1;
 return 0;
}
static int verify_avc420_sparse_desktop(void) {
 const unsigned width=640,height=360;
 const RECTANGLE_16 full={0,0,width,height};
 const size_t bytes=(size_t)width*height*4u;
 BYTE* image=malloc(bytes);
 if(!image)return 31;
 for(unsigned y=0;y<height;y++)for(unsigned x=0;x<width;x++){
  const size_t offset=((size_t)y*width+x)*4u;
  const BYTE color=(x%9==0 && y>35 && y<325)?20:245;
  image[offset]=image[offset+1]=image[offset+2]=color;
  image[offset+3]=255;
 }
 H264_CONTEXT* encoder=h264_context_new(TRUE);
 H264_CONTEXT* decoder=h264_context_new(FALSE);
 BYTE* output=calloc(bytes,1);
 if(!encoder||!decoder||!output||
    !h264_context_reset(encoder,width,height)||
    !h264_context_reset(decoder,width,height))return 32;
 if(!h264_context_set_option(encoder,H264_CONTEXT_OPTION_RATECONTROL,H264_RATECONTROL_VBR)||
    !h264_context_set_option(encoder,H264_CONTEXT_OPTION_BITRATE,4000000)||
    !h264_context_set_option(encoder,H264_CONTEXT_OPTION_FRAMERATE,30))return 33;
 unsigned idr=0;
 unsigned packets=0;
 uint64_t updateBytes=0,drainBytes=0;
 for(unsigned tick=0;tick<48;tick++){
  for(unsigned y=51;y<78;y++)for(unsigned x=160;x<163;x++){
   const size_t i=((size_t)y*width+x)*4u;
   const BYTE v=(tick%2)?15:245;
   image[i]=image[i+1]=image[i+2]=v;
  }
  RDPGFX_H264_METABLOCK meta={0};
  BYTE* stream=NULL;UINT32 length=0;
  const int rc=avc420_compress(encoder,image,PIXEL_FORMAT_BGRX32,
                                width*4,width,height,&full,&stream,&length,&meta);
  if(rc<=0||!length)return 34;
  idr+=has_h264_idr(stream,length);
  packets++;
  updateBytes+=length;
  if(avc420_decompress(decoder,stream,length,output,PIXEL_FORMAT_BGRX32,
                       width*4,width,height,meta.regionRects,meta.numRegionRects)<0)return 35;
  free_h264_metablock(&meta);
  if(tick%6==5){
   for(unsigned n=0;n<5;n++){
    RDPGFX_H264_METABLOCK repeated={0};
    BYTE* packet=NULL;UINT32 size=0;
    if(avc420_repeat(encoder,width,height,&packet,&size,&repeated)<=0||!size)return 36;
    idr+=has_h264_idr(packet,size);
    packets++;
    drainBytes+=size;
    if(avc420_decompress(decoder,packet,size,output,PIXEL_FORMAT_BGRX32,
                         width*4,width,height,repeated.regionRects,repeated.numRegionRects)<0)
      return 37;
    free_h264_metablock(&repeated);
   }
  }
 }
 printf("AVC420 office 48 edits + 40 drain pictures: frames=%u IDR=%u update=%llu drain=%llu bytes\n",
        packets,idr,(unsigned long long)updateBytes,(unsigned long long)drainBytes);
 h264_context_free(encoder);h264_context_free(decoder);
 free(image);free(output);
 return packets==88 && idr==1 ? 0:38;
}

int main(void){
 int rc420=verify_avc420(1920,1080);
 if(rc420)return rc420;
 int motion=verify_avc420_motion();
 if(motion)return motion;
 int sparse=verify_avc420_sparse_desktop();
 if(sparse)return sparse;
 const unsigned sizes[][2]={{128,128},{1534,1066},{2304,964}};
 for(int i=0;i<3;i++)for(int v=1;v<=2;v++){
  int rc=verify(sizes[i][0],sizes[i][1],v);
  if(rc) return rc;
 }
 puts("PASS encode/decode roundtrips for AVC444v1 and v2 on observed macOS desktop sizes");
 return 0;
}