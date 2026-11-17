#include "macremote_surface_geometry.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <stdio.h>
#include <math.h>

static void round_trip(double sourceW, double sourceH, double outputW, double outputH,
                       double sourceX, double sourceY)
{
    const mrSurfaceViewport viewport = mr_surface_fit(sourceW, sourceH, outputW, outputH);
    const double pixelX = mr_logical_to_surface(sourceX, viewport.left,
                                                viewport.width, sourceW, outputW);
    const double pixelY = mr_logical_to_surface(sourceY, viewport.top,
                                                viewport.height, sourceH, outputH);
    const double resultX = mr_surface_to_logical(pixelX, viewport.left,
                                                viewport.width, sourceW);
    const double resultY = mr_surface_to_logical(pixelY, viewport.top,
                                                viewport.height, sourceH);
    assert(fabs(resultX - sourceX) < 1.1);
    assert(fabs(resultY - sourceY) < 1.1);
}

int main(void)
{
    mrSurfaceViewport v = mr_surface_fit(2304, 1296, 2304, 1296);
    assert(v.left == 0 && v.top == 0 && v.width == 2304 && v.height == 1296);

    // Resized/letterboxed capture needs a full local pixel refresh.
    v = mr_surface_fit(1920, 1080, 1920, 1080);
    assert(!mr_surface_scaled_capture(1920, 1080, 1920, 1080, v));
    v = mr_surface_fit(1534, 1066, 1920, 1080);
    assert(mr_surface_scaled_capture(1534, 1066, 1920, 1080, v));
    v = mr_surface_fit(1152, 648, 1920, 1080);
    assert(mr_surface_scaled_capture(1152, 648, 1920, 1080, v));

    // User's actual RDP mismatch: source 2560x1072, output 2304x1296.
    v = mr_surface_fit(2560, 1072, 2304, 1296);
    assert(v.left == 0 && v.top == 165 && v.width == 2304 && v.height == 965);
    assert(mr_surface_to_logical(648, v.top, v.height, 1072) > 535);
    assert(mr_surface_to_logical(648, v.top, v.height, 1072) < 537);
    assert(mr_surface_to_logical(0, v.top, v.height, 1072) == 0);
    assert(mr_surface_to_logical(1295, v.top, v.height, 1072) == 1071);
    assert(mr_logical_to_surface(536, v.top, v.height, 1072, 1296) >= 647);
    assert(mr_logical_to_surface(536, v.top, v.height, 1072, 1296) <= 650);

    // Source 16:9 must consume all of the stream, regardless of its scale.
    v = mr_surface_fit(1920, 1080, 2304, 1296);
    assert(v.left == 0 && v.top == 0 && v.width == 2304 && v.height == 1296);
    v = mr_surface_fit(1152, 648, 2304, 1296);
    assert(v.left == 0 && v.top == 0 && v.width == 2304 && v.height == 1296);

    // Portrait screens need side bars and the corresponding x offset.
    v = mr_surface_fit(1080, 1920, 2304, 1296);
    assert(v.left > 0 && v.top == 0 && v.height == 1296);

    // Symmetric video/input/cursor mappings across edges and center.
    for (int i=0; i<3; i++) {
        const double srcW[] = {2560, 1920, 1080};
        const double srcH[] = {1072, 1080, 1920};
        for (int x=1; x<=9; x+=2)
            for (int y=1; y<=9; y+=2)
                round_trip(srcW[i], srcH[i], 2304, 1296,
                           srcW[i]*x/10, srcH[i]*y/10);
    }
    assert(mr_surface_fit(0, 1080, 2304, 1296).width == 0);
    puts("capture viewport and pointer mapping: all tests passed");
    return 0;
}
