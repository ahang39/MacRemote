/* Repeatable CPU-side instrumentation for scaled ScreenCaptureKit frame damage.
 * No user screen data. Build using the FreeRDP source produced by build-dev-app:
 * clang -O3 -std=c11 -I .build/sources/FreeRDP-.../server/shadow/Mac \
 *   tools/bench-scaled-dirty.c -o /tmp/bench-scaled-dirty
 */
#include "mac_scaled_dirty.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>
enum { W = 2304, H = 1296, ITER = 100, MAX = 64 };
static double ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1000.0 + (double)t.tv_nsec / 1000000.0;
}
int main(void) {
    size_t stride=(size_t)W*4, bytes=(size_t)H*stride;
    uint8_t* image=calloc(1,bytes),*old=calloc(1,bytes);
    if(!image||!old)return 2;
    macScaledDirtyRect regions[MAX];
    double cases[3]={0};
    unsigned tilesSum[3]={0},fullCount[3]={0};
    for(int kind=0;kind<3;kind++){
      memset(image,0,bytes);
      memset(old,0,bytes);
      for(int frame=0;frame<ITER;frame++){
        if(kind==1){
          int left=100+(frame%8)*3,top=70;
          for(int y=top;y<top+18;y++)
            for(int x=left;x<left+48;x++)
              image[(size_t)y*stride+(size_t)x*4]=(uint8_t)(frame+1);
        }
        if(kind==2)memset(image,frame+1,bytes);
        double begin=ms();
        uint32_t n=mac_scaled_collect_dirty(image,stride,old,stride,W,H,regions,MAX);
        cases[kind]+=ms()-begin;
        if(n==MAC_SCALED_DIRTY_FULL){
            fullCount[kind]++;
            memcpy(old,image,bytes);
        } else {
            tilesSum[kind]+=n;
            for(uint32_t k=0;k<n;k++)
                for(uint32_t y=regions[k].top;y<regions[k].bottom;y++)
                    memcpy(old+(size_t)y*stride+(size_t)regions[k].left*4,
                           image+(size_t)y*stride+(size_t)regions[k].left*4,
                           (regions[k].right-regions[k].left)*4);
        }
      }
    }
    const char* kinds[3]={"unchanged","48x18 typing","full-screen scroll"};
    for(int i=0;i<3;i++)
      printf("%-18s avg diff %.3f ms per frame, avg dirty tiles %.2f, fallback %u/%d\n",
             kinds[i],cases[i]/ITER,(double)tilesSum[i]/ITER,fullCount[i],ITER);
    free(image);free(old);
    return 0;
}
