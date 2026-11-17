#import "client_preferences.h"
#import "../display/device_display.h"
#include "../audio/remote_audio.h"
#include <CommonCrypto/CommonDigest.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <freerdp/settings.h>
#include <math.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

static pthread_mutex_t preferencesLock = PTHREAD_MUTEX_INITIALIZER;
static NSString *directory;
static NSString *preferencesPath;
static NSString *activeClientPath;
static NSMutableArray<NSValue *> *connectedClients;
static NSString *activeKey;
static struct stat preferencesVersion;
static UINT32 videoBitrate;
static dispatch_source_t profileChanges;

static NSString *clientKey(NSString *identifier)
{
    NSString *normalized = [[identifier stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    NSData *data = [normalized dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *key = [NSMutableString stringWithCapacity:64];
    for (size_t i = 0; i < sizeof(digest); ++i)
        [key appendFormat:@"%02x", digest[i]];
    return key;
}

static NSString *keyForClient(rdpShadowClient *client)
{
    const char *hostname = freerdp_settings_get_string(client->context.settings, FreeRDP_ClientHostname);
    NSString *name = hostname ? [NSString stringWithUTF8String:hostname] : nil;
    if (name.length) return clientKey([@"host:" stringByAppendingString:name]);

    const char *address = client->context.peer ? client->context.peer->hostname : NULL;
    NSString *ip = address ? [NSString stringWithUTF8String:address] : nil;
    return ip.length ? clientKey([@"ip:" stringByAppendingString:ip]) : nil;
}

static NSDictionary *loadProfile(void)
{
    NSData *data = [NSData dataWithContentsOfFile:preferencesPath];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:NSDictionary.class])
        return nil;
    id profile = json[activeKey];
    return [profile isKindOfClass:NSDictionary.class] ? profile : @{};
}

static unsigned effectiveVolume(NSDictionary *profile)
{
    id muted = profile[@"audioMuted"];
    if (muted && CFGetTypeID((__bridge CFTypeRef)muted) == CFBooleanGetTypeID() && [muted boolValue])
        return 0;

    id volume = profile[@"audioVolume"];
    if (![volume isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)volume) == CFBooleanGetTypeID())
        return 100;
    return (unsigned)fmin(100, fmax(0, [volume doubleValue]));
}

static void updateLivePreferences(NSDictionary *profile, bool connected)
{
    mr_remote_audio_set_volume(connected ? effectiveVolume(profile) : 0);
    id target = profile[@"videoBitrate"];
    videoBitrate = 0;
    if ([target isKindOfClass:NSNumber.class]) {
        double value = [target doubleValue];
        if (value == 1400000 || value == 2000000 || value == 4000000)
            videoBitrate = (UINT32)value;
    }
}

static void publishClient(NSString *key, BOOL connected)
{
    NSString *state = connected ? [NSString stringWithFormat:@"%@\n%d\n", key, getpid()] : key;
    if (![state writeToFile:activeClientPath atomically:YES encoding:NSUTF8StringEncoding error:nil] ||
        chmod(activeClientPath.fileSystemRepresentation, 0600) != 0)
        fprintf(stderr, "[MacRemote preferences] could not publish client selection\n");
}

static struct stat profileVersion(void)
{
    struct stat version = { 0 };
    (void)stat(preferencesPath.fileSystemRepresentation, &version);
    return version;
}

static void selectPrimary(bool restoreDisplay)
{
    NSString *previousKey = activeKey;
    rdpShadowClient *client = connectedClients.firstObject.pointerValue;
    activeKey = client ? keyForClient(client) : nil;

    preferencesVersion = profileVersion();
    NSDictionary *profile = activeKey ? loadProfile() : nil;
    updateLivePreferences(profile, client != NULL);

    if (restoreDisplay)
        mr_device_display_restore(directory, profile);
    else if (!client)
        mr_device_display_clear_capture(directory);

    if (activeKey)
        publishClient(activeKey, YES);
    else if (previousKey)
        publishClient(previousKey, NO);
}

static void reloadProfileIfChanged(void)
{
    @autoreleasepool {
        pthread_mutex_lock(&preferencesLock);
        if (activeKey) {
            struct stat version = profileVersion();
            if (version.st_ino != preferencesVersion.st_ino ||
                version.st_mtimespec.tv_sec != preferencesVersion.st_mtimespec.tv_sec ||
                version.st_mtimespec.tv_nsec != preferencesVersion.st_mtimespec.tv_nsec) {
                preferencesVersion = version;
                NSDictionary *profile = version.st_ino ? loadProfile() : @{};
                if (profile)
                    updateLivePreferences(profile, true);
            }
        }
        pthread_mutex_unlock(&preferencesLock);
    }
}

static void watchProfiles(const char *configPath)
{
    // Atomic writes replace the JSON inode. Watch the containing directory.
    int fd = open(configPath, O_EVTONLY | O_CLOEXEC);
    if (fd >= 0) {
        profileChanges = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd,
            DISPATCH_VNODE_WRITE, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
        if (profileChanges) {
            dispatch_source_set_event_handler(profileChanges, ^{ reloadProfileIfChanged(); });
            dispatch_source_set_cancel_handler(profileChanges, ^{ close(fd); });
            dispatch_activate(profileChanges);
            return;
        }
        close(fd);
    }
    fprintf(stderr, "[MacRemote preferences] could not watch profile changes\n");
}

void mr_client_preferences_init(const char *configPath)
{
    @autoreleasepool {
        directory = [NSString stringWithUTF8String:configPath];
        preferencesPath = [directory stringByAppendingPathComponent:@"display-by-client.json"];
        activeClientPath = [directory stringByAppendingPathComponent:@"rdp-active-client.key"];
        connectedClients = [NSMutableArray array];
        mr_device_display_clear_capture(directory);
        watchProfiles(configPath);
    }
}

void mr_client_preferences_connect(rdpShadowClient *client)
{
    @autoreleasepool {
        pthread_mutex_lock(&preferencesLock);
        [connectedClients addObject:[NSValue valueWithPointer:client]];
        if (connectedClients.count == 1)
            selectPrimary(true);
        pthread_mutex_unlock(&preferencesLock);
    }
}

void mr_client_preferences_disconnect(rdpShadowClient *client)
{
    @autoreleasepool {
        pthread_mutex_lock(&preferencesLock);
        BOOL wasPrimary = connectedClients.firstObject.pointerValue == client;
        [connectedClients removeObject:[NSValue valueWithPointer:client]];
        if (wasPrimary)
            selectPrimary(false);
        pthread_mutex_unlock(&preferencesLock);
    }
}

UINT32 mr_client_preferences_video_bitrate(const rdpShadowClient *client)
{
    pthread_mutex_lock(&preferencesLock);
    const UINT32 target = connectedClients.firstObject.pointerValue == client ? videoBitrate : 0;
    pthread_mutex_unlock(&preferencesLock);
    return target;
}

void mr_client_preferences_shutdown(void)
{
    @autoreleasepool {
        if (profileChanges) {
            dispatch_source_cancel(profileChanges);
            profileChanges = nil;
        }
        pthread_mutex_lock(&preferencesLock);
        if (directory) {
            [connectedClients removeAllObjects];
            selectPrimary(false);
        }
        pthread_mutex_unlock(&preferencesLock);
    }
}
