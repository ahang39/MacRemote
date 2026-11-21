#import "client_preferences.h"
#import "../display/device_display.h"
#include "../audio/remote_audio.h"
#include <CommonCrypto/CommonDigest.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <freerdp/settings.h>
#include <winpr/sysinfo.h>
#include <math.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

static pthread_mutex_t preferencesLock = PTHREAD_MUTEX_INITIALIZER;
static NSString *directory;
static NSString *preferencesPath;
static NSString *activeClientPath;
static NSString *sessionStatePath;
static NSMutableArray<NSValue *> *connectedClients;
static NSMutableDictionary<NSValue *, NSMutableDictionary *> *sessionByClient;
static NSMutableDictionary<NSValue *, NSNumber *> *bandwidthByClient;
static NSString *activeKey;
static struct stat preferencesVersion;
static MRBandwidthMode defaultBandwidth = MR_BANDWIDTH_HIGH;
static MRBandwidthMode activeBandwidth = MR_BANDWIDTH_HIGH;
static UINT64 lastAudioSampleTick;
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

static NSString *keyForClient(const rdpShadowClient *client)
{
    if (!client || !client->context.settings)
        return nil;
    const char *hostname =
        freerdp_settings_get_string(client->context.settings, FreeRDP_ClientHostname);
    NSString *name = hostname ? [NSString stringWithUTF8String:hostname] : nil;
    if (name.length) return clientKey([@"host:" stringByAppendingString:name]);

    const char *address = client->context.peer ? client->context.peer->hostname : NULL;
    NSString *ip = address ? [NSString stringWithUTF8String:address] : nil;
    return ip.length ? clientKey([@"ip:" stringByAppendingString:ip]) : nil;
}

static NSDictionary *loadAllProfiles(void)
{
    NSData *data = [NSData dataWithContentsOfFile:preferencesPath];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

static NSDictionary *profileForKey(NSDictionary *all, NSString *key)
{
    if (!all || !key) return @{};
    id entry = all[key];
    return [entry isKindOfClass:NSDictionary.class] ? entry : @{};
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

static MRBandwidthMode effectiveBandwidth(NSDictionary *profile)
{
    id raw = profile[@"bandwidthMode"];
    if ([raw isKindOfClass:NSString.class]) {
        MRBandwidthMode parsed = defaultBandwidth;
        if (mr_bandwidth_parse([(NSString *)raw UTF8String], &parsed))
            return parsed;
    }
    return defaultBandwidth;
}

static void publishClient(NSString *key, BOOL connected)
{
    NSString *state = connected ? [NSString stringWithFormat:@"%@\n%d\n", key, getpid()] : key;
    if (![state writeToFile:activeClientPath atomically:YES encoding:NSUTF8StringEncoding error:nil] ||
        chmod(activeClientPath.fileSystemRepresentation, 0600) != 0)
        fprintf(stderr, "[MacRemote preferences] could not publish client selection\n");
}

static void publishSessionState(rdpShadowClient *client)
{
    if (!activeKey || !sessionStatePath || !client) return;
    NSMutableDictionary *state = [sessionByClient[[NSValue valueWithPointer:client]] mutableCopy];
    if (!state) return;
    state[@"key"] = activeKey;
    state[@"pid"] = @(getpid());
    state[@"mode"] = [NSString stringWithUTF8String:mr_bandwidth_name(activeBandwidth)];
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    if (data && [data writeToFile:sessionStatePath atomically:YES])
        (void)chmod(sessionStatePath.fileSystemRepresentation, 0600);
}

static struct stat profileVersion(void)
{
    struct stat version = { 0 };
    (void)stat(preferencesPath.fileSystemRepresentation, &version);
    return version;
}

static void refreshClientBandwidths(NSDictionary *all)
{
    for (NSValue *identity in connectedClients) {
        const rdpShadowClient *client = identity.pointerValue;
        NSString *key = keyForClient(client);
        NSDictionary *profile = profileForKey(all, key);
        bandwidthByClient[identity] = @(effectiveBandwidth(profile));
    }
}

static void applyPrimaryPreferences(NSDictionary *profile, bool connected)
{
    activeBandwidth = connected ? effectiveBandwidth(profile) : defaultBandwidth;
    const MRStreamProfile *stream = mr_stream_profile_get(activeBandwidth);
    mr_remote_audio_set_bitrate(stream->audioBitrate);
    mr_remote_audio_set_prefer_lossless(stream->audioPreferLossless);
    mr_remote_audio_set_volume(connected ? effectiveVolume(profile) : 0);
}

static void selectPrimary(bool restoreDisplay)
{
    NSString *previousKey = activeKey;
    rdpShadowClient *client = connectedClients.firstObject.pointerValue;
    activeKey = client ? keyForClient(client) : nil;

    if (sessionStatePath)
        (void)[NSFileManager.defaultManager removeItemAtPath:sessionStatePath error:nil];
    (void)mr_remote_audio_take_bytes_sent();
    lastAudioSampleTick = GetTickCount64();

    preferencesVersion = profileVersion();
    NSDictionary *all = activeKey ? loadAllProfiles() : nil;
    NSDictionary *profile = activeKey ? profileForKey(all, activeKey) : nil;
    refreshClientBandwidths(all);
    applyPrimaryPreferences(profile, client != NULL);

    if (restoreDisplay)
        mr_device_display_restore(directory, profile);
    else if (!client)
        mr_device_display_clear_capture(directory);

    if (activeKey) {
        publishSessionState(client);
        publishClient(activeKey, YES);
    } else if (previousKey) {
        publishClient(previousKey, NO);
    }
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
                NSDictionary *all = version.st_ino ? loadAllProfiles() : @{};
                if (all) {
                    refreshClientBandwidths(all);
                    applyPrimaryPreferences(profileForKey(all, activeKey), true);
                    publishSessionState(connectedClients.firstObject.pointerValue);
                }
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
        sessionStatePath = [directory stringByAppendingPathComponent:@"rdp-session.json"];
        connectedClients = [NSMutableArray array];
        sessionByClient = [NSMutableDictionary dictionary];
        bandwidthByClient = [NSMutableDictionary dictionary];
        lastAudioSampleTick = GetTickCount64();
        mr_device_display_clear_capture(directory);
        watchProfiles(configPath);
    }
}

void mr_client_preferences_default_bandwidth(MRBandwidthMode mode)
{
    pthread_mutex_lock(&preferencesLock);
    defaultBandwidth = mode == MR_BANDWIDTH_LOW ? MR_BANDWIDTH_LOW : MR_BANDWIDTH_HIGH;
    if (connectedClients.count == 0) {
        activeBandwidth = defaultBandwidth;
        const MRStreamProfile *stream = mr_stream_profile_get(defaultBandwidth);
        mr_remote_audio_set_bitrate(stream->audioBitrate);
        mr_remote_audio_set_prefer_lossless(stream->audioPreferLossless);
    }
    pthread_mutex_unlock(&preferencesLock);
}

void mr_client_preferences_connect(rdpShadowClient *client)
{
    @autoreleasepool {
        pthread_mutex_lock(&preferencesLock);
        NSValue *identity = [NSValue valueWithPointer:client];
        [connectedClients addObject:identity];
        const UINT32 depth =
            freerdp_settings_get_uint32(client->context.settings, FreeRDP_ColorDepth);
        sessionByClient[identity] = [@{
            @"colorDepth": @(depth),
            @"videoBytesPerSec": @0,
            @"audioBytesPerSec": @0,
            @"fps": @0,
            @"inFlightMax": @0
        } mutableCopy];
        if (connectedClients.count == 1) {
            selectPrimary(true);
        } else {
            NSDictionary *all = loadAllProfiles();
            NSString *key = keyForClient(client);
            bandwidthByClient[identity] = @(effectiveBandwidth(profileForKey(all, key)));
        }
        pthread_mutex_unlock(&preferencesLock);
    }
}

void mr_client_preferences_disconnect(rdpShadowClient *client)
{
    @autoreleasepool {
        pthread_mutex_lock(&preferencesLock);
        NSValue *identity = [NSValue valueWithPointer:client];
        BOOL wasPrimary = connectedClients.firstObject.pointerValue == client;
        [connectedClients removeObject:identity];
        [sessionByClient removeObjectForKey:identity];
        [bandwidthByClient removeObjectForKey:identity];
        if (wasPrimary)
            selectPrimary(false);
        pthread_mutex_unlock(&preferencesLock);
    }
}

BOOL mr_client_preferences_stream_profile(const rdpShadowClient *client, ShadowStreamProfile *out)
{
    if (!out)
        return FALSE;
    pthread_mutex_lock(&preferencesLock);
    MRBandwidthMode mode = defaultBandwidth;
    if (client) {
        NSNumber *saved = bandwidthByClient[[NSValue valueWithPointer:client]];
        if (saved)
            mode = (MRBandwidthMode)[saved intValue];
        else if (connectedClients.firstObject.pointerValue == client)
            mode = activeBandwidth;
    }
    pthread_mutex_unlock(&preferencesLock);

    const MRStreamProfile *src = mr_stream_profile_get(mode);
    out->bitrate = src->h264Bitrate;
    out->maxFps = src->maxFps;
    out->maxInFlight = src->maxInFlight;
    out->pacerBytesPerSec = src->pacerBytesPerSec;
    out->pacerBurstBytes = src->pacerBurstBytes;
    out->refineDelayMs = src->refineDelayMs;
    out->refineFrames = src->refineFrames;
    return TRUE;
}

UINT32 mr_client_preferences_capture_max_fps(void)
{
    pthread_mutex_lock(&preferencesLock);
    UINT32 maxFps = 0;
    for (NSValue *identity in connectedClients) {
        NSNumber *saved = bandwidthByClient[identity];
        const MRBandwidthMode mode = saved ? (MRBandwidthMode)[saved intValue] : defaultBandwidth;
        const UINT32 fps = mr_stream_profile_get(mode)->maxFps;
        if (fps > maxFps)
            maxFps = fps;
    }
    if (maxFps == 0)
        maxFps = mr_stream_profile_get(defaultBandwidth)->maxFps;
    pthread_mutex_unlock(&preferencesLock);
    return maxFps;
}

void mr_client_preferences_observe_stats(const rdpShadowClient *client,
                                         const ShadowStreamStats *stats)
{
    if (!client || !stats)
        return;
    @autoreleasepool {
        pthread_mutex_lock(&preferencesLock);
        NSValue *identity = [NSValue valueWithPointer:client];
        NSMutableDictionary *state = sessionByClient[identity];
        if (state) {
            const BOOL isPrimary = connectedClients.firstObject.pointerValue == client;
            UINT32 audioBps = 0;
            if (isPrimary) {
                const UINT64 now = GetTickCount64();
                const uint64_t audioBytes = mr_remote_audio_take_bytes_sent();
                const UINT64 elapsed = now > lastAudioSampleTick ? now - lastAudioSampleTick : 1000;
                lastAudioSampleTick = now;
                audioBps = (UINT32)((audioBytes * 1000u) / elapsed);
            }
            if (stats->codec)
                state[@"codec"] = [NSString stringWithUTF8String:stats->codec];
            if (stats->colorDepth > 0)
                state[@"colorDepth"] = @(stats->colorDepth);
            state[@"videoBytesPerSec"] = @(stats->videoBytesPerSec);
            state[@"audioBytesPerSec"] = @(audioBps);
            state[@"fps"] = @(stats->videoFps);
            state[@"refineFrames"] = @(stats->refineFrames);
            state[@"inFlightMax"] = @(stats->inFlightMax);
            if (stats->hasAckRtt) {
                state[@"ackRttMs"] = @(stats->ackRttP50Ms);
                state[@"ackRttP95Ms"] = @(stats->ackRttP95Ms);
            } else {
                [state removeObjectForKey:@"ackRttMs"];
                [state removeObjectForKey:@"ackRttP95Ms"];
            }
            if (isPrimary)
                publishSessionState(connectedClients.firstObject.pointerValue);
        }
        pthread_mutex_unlock(&preferencesLock);
    }
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
            [sessionByClient removeAllObjects];
            [bandwidthByClient removeAllObjects];
            selectPrimary(false);
        }
        pthread_mutex_unlock(&preferencesLock);
    }
}
