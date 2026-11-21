#import "headless_virtual.h"
#import "headless_display_policy.h"
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

/* The four classes are private CoreGraphics API.  Resolve their Classes at
 * runtime so an OS update cannot break normal monitor-backed RDP startup.
 * This module retains only the display it creates, never an external one. */
@interface MRVirtualDisplayDescriptor : NSObject
@property(nonatomic) unsigned int vendorID, productID, serialNum, serialNumber;
@property(strong, nonatomic) NSString* name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(strong, nonatomic) dispatch_queue_t queue;
@property(copy, nonatomic) id terminationHandler;
@end
@interface MRVirtualDisplaySettings : NSObject
@property(strong, nonatomic) NSArray* modes;
@property(nonatomic) unsigned int hiDPI, rotation;
@end
@interface MRVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height
                  refreshRate:(double)hz;
@end
@interface MRVirtualDisplay : NSObject
@property(readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(MRVirtualDisplayDescriptor*)descriptor;
- (BOOL)applySettings:(MRVirtualDisplaySettings*)settings;
@end

static MRVirtualDisplay* ownedDisplay;

static Class virtualClass(const char* name)
{
    return objc_getClass(name);
}

bool mr_headless_api_available(void)
{
    Class desc = virtualClass("CGVirtualDisplayDescriptor");
    Class disp = virtualClass("CGVirtualDisplay");
    Class mode = virtualClass("CGVirtualDisplayMode");
    Class sets = virtualClass("CGVirtualDisplaySettings");
    return desc && disp && mode && sets &&
        [disp instancesRespondToSelector:@selector(initWithDescriptor:)] &&
        [disp instancesRespondToSelector:@selector(applySettings:)] &&
        [mode instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)];
}

CGDirectDisplayID mr_headless_owned_display(void)
{
    return ownedDisplay ? ownedDisplay.displayID : kCGNullDirectDisplay;
}

static void headlessResolution(const char* directory, unsigned* width, unsigned* height)
{
    *width = 1920;
    *height = 1080;
    if (!directory)
        return;
    NSString* path = [[NSString stringWithUTF8String:directory]
        stringByAppendingPathComponent:@"display-output.conf"];
    NSString* text = [NSString stringWithContentsOfFile:path
        encoding:NSUTF8StringEncoding error:nil];
    unsigned w = 0, h = 0;
    if (text && sscanf(text.UTF8String, "%u %u", &w, &h) == 2 &&
        w >= 800 && w <= 4096 && h >= 450 && h <= 2160)
    {
        *width = w;
        *height = h;
    }
}

int mr_headless_start(bool enabled, const char* configDirectory)
{
    @autoreleasepool
    {
        /* First verify the full online list: a sleeping, inactive or
         * BetterDisplay-managed display is not ours to replace. */
        uint32_t active = 0, online = 0;
        if (CGGetActiveDisplayList(0, NULL, &active) != kCGErrorSuccess ||
            CGGetOnlineDisplayList(0, NULL, &online) != kCGErrorSuccess)
            return 0;
        const mrHeadlessFacts facts = {
            .guiSessionAvailable = true,
            .captureGranted = CGPreflightScreenCaptureAccess(),
            .fallbackOptedIn = enabled,
            .otherDisplayPresent = active > 0 || online > 0,
            .otherDisplayCaptureReady = active > 0
        };
        if (mr_headless_decide(facts) != MR_HEADLESS_CREATE_OWNED)
            return 0;
        if (!mr_headless_api_available())
        {
            fprintf(stderr, "[MacRemote headless] CGVirtualDisplay is unavailable on this macOS\n");
            return -1;
        }

        /* A GUI WindowServer connection is needed for a composited virtual
         * monitor. Keep this helper hidden, separate from the menu bar app. */
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        unsigned w, h;
        headlessResolution(configDirectory, &w, &h);
        MRVirtualDisplayDescriptor* descriptor =
            [(MRVirtualDisplayDescriptor*)[virtualClass("CGVirtualDisplayDescriptor") alloc] init];
        descriptor.name = @"MacRemote Headless";
        descriptor.vendorID = 0x4d52; /* MacRemote-only identity */
        descriptor.productID = 0x4844;
        descriptor.serialNum = 1;
        descriptor.serialNumber = 1;
        descriptor.maxPixelsWide = w;
        descriptor.maxPixelsHigh = h;
        descriptor.sizeInMillimeters = CGSizeMake(w * 25.4 / 110.0, h * 25.4 / 110.0);
        descriptor.redPrimary = CGPointMake(0.6797, 0.3203);
        descriptor.greenPrimary = CGPointMake(0.2559, 0.6983);
        descriptor.bluePrimary = CGPointMake(0.1494, 0.0557);
        descriptor.whitePoint = CGPointMake(0.3125, 0.3291);
        descriptor.queue = dispatch_get_main_queue();

        MRVirtualDisplay* display = [(MRVirtualDisplay*)[virtualClass("CGVirtualDisplay") alloc]
            initWithDescriptor:descriptor];
        if (!display)
        {
            fprintf(stderr, "[MacRemote headless] creating virtual display failed\n");
            return -1;
        }
        /* WindowServer registers the descriptor asynchronously. */
        (void)CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.15, false);
        MRVirtualDisplaySettings* settings =
            [(MRVirtualDisplaySettings*)[virtualClass("CGVirtualDisplaySettings") alloc] init];
        settings.hiDPI = 0;
        settings.rotation = 0;
        MRVirtualDisplayMode* mode = [(MRVirtualDisplayMode*)[virtualClass("CGVirtualDisplayMode") alloc]
            initWithWidth:w height:h refreshRate:60.0];
        settings.modes = @[mode];
        if (![display applySettings:settings])
        {
            fprintf(stderr, "[MacRemote headless] applying virtual display mode failed\n");
            return -1;
        }
        ownedDisplay = display;
        /* Wait for CoreGraphics enumeration before FreeRDP Shadow initializes. */
        bool registered = false;
        for (int i = 0; i < 40; i++)
        {
            const CGDirectDisplayID id = ownedDisplay.displayID;
            if (id != kCGNullDirectDisplay && CGDisplayIsActive(id))
            {
                registered = true;
                break;
            }
            (void)CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.10, false);
        }
        if (!registered)
        {
            fprintf(stderr, "[MacRemote headless] virtual display did not become active\n");
            ownedDisplay = nil;
            return -1;
        }
        fprintf(stderr, "[MacRemote headless] created owned display %u at %ux%u\n",
                (unsigned)ownedDisplay.displayID, w, h);
        return 1;
    }
}

void mr_headless_update(bool enabled, const char* configDirectory, bool hasClients)
{
    if (!enabled)
        return;
    if (ownedDisplay)
    {
        if (hasClients)
            return;
        CGDirectDisplayID displays[16] = {0};
        uint32_t count = 0;
        if (CGGetOnlineDisplayList(16, displays, &count) != kCGErrorSuccess)
            return;
        for (uint32_t i = 0; i < count; i++)
        {
            if (displays[i] != ownedDisplay.displayID &&
                CGDisplayIsActive(displays[i]) && !CGDisplayIsAsleep(displays[i]))
            {
                /* A physical or BetterDisplay desktop is back. Only release
                 * our own object and only between RDP sessions. */
                mr_headless_stop();
                return;
            }
        }
        return;
    }
    /* Physical/borrowed screens take priority; create only if none remain. */
    (void)mr_headless_start(true, configDirectory);
}

void mr_headless_stop(void)
{
    @autoreleasepool
    {
        if (ownedDisplay)
        {
            fprintf(stderr, "[MacRemote headless] released owned display %u\n",
                    (unsigned)ownedDisplay.displayID);
            ownedDisplay = nil;
        }
    }
}
