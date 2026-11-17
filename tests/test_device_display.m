#include "../src/display/device_display.m"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <stdlib.h>
#include <sys/stat.h>

int main(void)
{
    @autoreleasepool {
        NSDictionary *normal = @{@"logicalWidth": @1920, @"logicalHeight": @1080,
                                  @"renderWidth": @1920, @"renderHeight": @1080,
                                  @"refreshHz": @75};
        NSDictionary *retina = @{@"logicalWidth": @1920, @"logicalHeight": @1080,
                                  @"renderWidth": @3840, @"renderHeight": @2160,
                                  @"refreshHz": @75};
        assert(sameModeValues(normal, normal));
        assert(!sameModeValues(normal, retina));
        assert(!sameModeValues(@{@"width": @1920, @"height": @1080}, normal));
        assert(!sameModeValues(nil, normal));

        CGDisplayModeRef actual = CGDisplayCopyDisplayMode(CGMainDisplayID());
        assert(actual != NULL);
        NSDictionary *actualValues = modeValues(actual);
        assert([actualValues[@"logicalWidth"] unsignedLongLongValue] == CGDisplayModeGetWidth(actual));
        assert([actualValues[@"renderWidth"] unsignedLongLongValue] == CGDisplayModeGetPixelWidth(actual));
        assert([actualValues[@"renderHeight"] unsignedLongLongValue] == CGDisplayModeGetPixelHeight(actual));

        CGDisplayModeRef recovered = findSavedMode(CGMainDisplayID(), actualValues);
        assert(recovered != NULL);
        assert(sameModeValues(actualValues, modeValues(recovered)));
        CGDisplayModeRelease(recovered);
        assert(findSavedMode(CGMainDisplayID(), @{@"requestWidth": @1920}) == NULL);
        CGDisplayModeRelease(actual);

        char tmp[] = "/tmp/macremote-display-memory.XXXXXXXX";
        char *folder = mkdtemp(tmp);
        assert(folder);
        NSString *directory = [NSString stringWithUTF8String:folder];

        NSDictionary *oldClient = @{@"logicalWidth": @1920, @"logicalHeight": @1080};
        NSDictionary *newClient = @{@"rdpWidth": @2304, @"rdpHeight": @1296,
                                     @"logicalWidth": @1920, @"logicalHeight": @1080};
        uint32_t width = 0, height = 0;
        assert(!readOutputSize(oldClient, &width, &height));
        assert(readOutputSize(newClient, &width, &height));
        assert(width == 2304 && height == 1296);
        assert(!readOutputSize(@{@"rdpWidth": @0, @"rdpHeight": @0}, &width, &height));
        assert(!readOutputSize(@{@"rdpWidth": @2304, @"rdpHeight": @1080}, &width, &height));

        assert(writeOutputSize(directory, 2304, 1296));
        NSString *output = [NSString stringWithContentsOfFile:outputPath(directory)
            encoding:NSUTF8StringEncoding error:nil];
        assert([output isEqualToString:@"2304 1296\n"]);

        NSError *error = nil;
        assert([[NSFileManager defaultManager] removeItemAtPath:directory error:&error]);
        puts("device display memory: all checks passed");
    }
    return 0;
}
