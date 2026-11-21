#import "device_display.h"
#import "headless_virtual.h"
#include <CoreGraphics/CoreGraphics.h>
#include <unistd.h>
#include <sys/stat.h>
#include <math.h>

static NSString *capturePath(NSString *directory)
{
    return [directory stringByAppendingPathComponent:@"capture-logical.conf"];
}

static BOOL publishCaptureLogical(NSString *directory, CGDirectDisplayID display,
                                  CGDisplayModeRef mode)
{
    NSString *path = capturePath(directory);
    NSString *line = [NSString stringWithFormat:@"%u %zu %zu\n",
        (unsigned)display, CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode)];
    if (![line writeToFile:path atomically:YES
            encoding:NSUTF8StringEncoding error:nil])
        return NO;
    chmod(path.fileSystemRepresentation, 0600);
    return YES;
}

static NSDictionary *modeValues(CGDisplayModeRef mode)
{
    return @{
        @"logicalWidth": @(CGDisplayModeGetWidth(mode)),
        @"logicalHeight": @(CGDisplayModeGetHeight(mode)),
        @"renderWidth": @(CGDisplayModeGetPixelWidth(mode)),
        @"renderHeight": @(CGDisplayModeGetPixelHeight(mode)),
        @"refreshHz": @(CGDisplayModeGetRefreshRate(mode))
    };
}

static BOOL sameModeValues(NSDictionary *stored, NSDictionary *actual)
{
    if (![stored isKindOfClass:NSDictionary.class] ||
        ![actual isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *field in @[@"logicalWidth", @"logicalHeight", @"renderWidth", @"renderHeight"])
    {
        if (![stored[field] isKindOfClass:NSNumber.class] ||
            ![stored[field] isEqual:actual[field]]) return NO;
    }
    return YES;
}

static CGDisplayModeRef findSavedMode(CGDirectDisplayID display, NSDictionary *stored)
{
    if (!stored[@"logicalWidth"]) return NULL;
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(display,
        (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES});
    if (!modes) return NULL;
    CGDisplayModeRef selected = NULL;
    double difference = INFINITY;
    NSNumber *refresh = stored[@"refreshHz"];
    double savedHz = [refresh isKindOfClass:NSNumber.class] ? refresh.doubleValue : 0;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); ++i)
    {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (!sameModeValues(stored, modeValues(mode))) continue;
        double delta = fabs(CGDisplayModeGetRefreshRate(mode) - savedHz);
        if (!selected || delta < difference)
        {
            selected = mode;
            difference = delta;
        }
    }
    if (selected) CFRetain(selected);
    CFRelease(modes);
    return selected;
}

// WindowServer can revert a transient CGDisplaySetDisplayMode call.
static CGError applyPersistentDisplayMode(CGDirectDisplayID display, CGDisplayModeRef mode)
{
    CGDisplayConfigRef config = NULL;
    CGError error = CGBeginDisplayConfiguration(&config);
    if (error != kCGErrorSuccess)
        return error;
    error = CGConfigureDisplayWithDisplayMode(config, display, mode, NULL);
    if (error != kCGErrorSuccess)
    {
        CGCancelDisplayConfiguration(config);
        return error;
    }
    return CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
}

static BOOL readOutputSize(NSDictionary *profile, uint32_t *width, uint32_t *height)
{
    NSNumber *w = profile[@"rdpWidth"];
    NSNumber *h = profile[@"rdpHeight"];
    if (![w isKindOfClass:NSNumber.class] || ![h isKindOfClass:NSNumber.class])
        return NO;
    const long long x = w.longLongValue, y = h.longLongValue;
    if (x < 800 || x > 8192 || y < 450 || y > 4320 || x * 9 != y * 16)
        return NO;
    *width = (uint32_t)x;
    *height = (uint32_t)y;
    return YES;
}

static NSString *outputPath(NSString *directory)
{
    return [directory stringByAppendingPathComponent:@"display-output.conf"];
}

static BOOL writeOutputSize(NSString *directory, uint32_t width, uint32_t height)
{
    NSString *path = outputPath(directory);
    NSString *line = [NSString stringWithFormat:@"%u %u\n", width, height];
    return [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        chmod(path.fileSystemRepresentation, 0600) == 0;
}

static CGDisplayModeRef findOutputHiDPI(NSString *directory, CGDirectDisplayID display,
                                       CGDisplayModeRef current)
{
    NSString *output = [NSString stringWithContentsOfFile:outputPath(directory)
        encoding:NSUTF8StringEncoding error:nil];
    unsigned width, height;
    if (!output || sscanf(output.UTF8String, "%u %u", &width, &height) != 2 ||
        width < 800 || width > 4096 || height < 450 || height > 2160 ||
        width * 9 != height * 16)
        return NULL;
    return findSavedMode(display, @{
        @"logicalWidth": @(width), @"logicalHeight": @(height),
        @"renderWidth": @(width * 2), @"renderHeight": @(height * 2),
        @"refreshHz": @(current ? CGDisplayModeGetRefreshRate(current) : 60)
    });
}

void mr_device_display_restore(NSString *directory, NSDictionary *profile)
{
    CGDirectDisplayID display = CGMainDisplayID();
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(display);
    uint32_t width, height;
    CGDisplayModeRef chosen = findSavedMode(display, profile);
    // Legacy profiles had no RDP output. Use the configured output in that case.
    if (readOutputSize(profile, &width, &height)) {
        if (!writeOutputSize(directory, width, height))
            fprintf(stderr, "[MacRemote mode] could not select client output %ux%u\n", width, height);
    }
    if (!chosen)
        chosen = findOutputHiDPI(directory, display, current);
    /* Headless-created and third-party virtual screens have their own mode
     * lifecycle. Preserve per-client RDP output size without changing them. */
    if (chosen && mr_headless_is_virtual_display(display)) {
        CGDisplayModeRelease(chosen);
        chosen = NULL;
    }
    if (chosen) {
        if (!current || CGDisplayModeGetIODisplayModeID(current) != CGDisplayModeGetIODisplayModeID(chosen)) {
            CGError result = applyPersistentDisplayMode(display, chosen);
            if (result != kCGErrorSuccess)
                fprintf(stderr, "[MacRemote mode] could not restore display mode (%d)\n", (int)result);
            if (current) CGDisplayModeRelease(current);
            current = CGDisplayCopyDisplayMode(display);
        }
        CGDisplayModeRelease(chosen);
    }
    if (current) {
        if (!publishCaptureLogical(directory, display, current))
            fprintf(stderr, "[MacRemote mode] failed to publish capture logical dimensions\n");
        CGDisplayModeRelease(current);
    }
}

void mr_device_display_clear_capture(NSString *directory)
{
    unlink(capturePath(directory).fileSystemRepresentation);
}
