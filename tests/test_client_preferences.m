#include "../src/device/client_preferences.m"
#include "mac_shadow.h"
#include <ApplicationServices/ApplicationServices.h>
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <freerdp/server/rdpsnd.h>
#include <opus.h>

static NSDictionary *restoredProfile;

void mr_device_display_restore(NSString *path, NSDictionary *profile)
{
    assert(path);
    restoredProfile = profile;
}

void mr_device_display_clear_capture(NSString *path)
{
    assert(path);
    restoredProfile = nil;
}

static void writeProfiles(NSDictionary *profiles)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:profiles options:0 error:nil];
    assert([data writeToFile:preferencesPath atomically:YES]);
}

static void expectLiveVolume(unsigned volume)
{
    for (unsigned attempt = 0; attempt < 200; ++attempt) {
        if (mr_remote_audio_volume() == volume)
            return;
        usleep(5000);
    }
    assert(mr_remote_audio_volume() == volume);
}

static NSString *publishedClient(void)
{
    return [NSString stringWithContentsOfFile:activeClientPath encoding:NSUTF8StringEncoding error:nil];
}

/* Inject stereo samples and capture the bytes submitted to rdpsnd Wave2. */
static macCaptureConfig captureConfig;
static RdpsndServerContext *soundChannel;
static SHADOW_MSG_OUT_AUDIO_OUT_SAMPLES *queuedPacket;
static OpusDecoder *decoder;
static size_t bytesSent;
static unsigned packetsSent;
static bool holdPacket;
static float decoded[960 * 2];

BOOL mac_capture_check_access(void) { return TRUE; }
Boolean AXIsProcessTrustedWithOptions(CFDictionaryRef options)
{
    (void)options;
    return true;
}
macCapture *mac_capture_new(const macCaptureConfig *config)
{
    captureConfig = *config;
    return (macCapture *)&captureConfig;
}
void mac_capture_free(macCapture *capture) { (void)capture; }
BOOL mac_capture_start(macCapture *capture) { return capture != NULL; }
void mac_capture_stop(macCapture *capture) { (void)capture; }

static UINT sendWave2(RdpsndServerContext *channel, UINT16 format, const void *buffer,
                      size_t size, UINT16 timestamp, UINT32 audioTimestamp)
{
    assert(channel == soundChannel && format == 0 && timestamp == (UINT16)audioTimestamp);
    assert(size == 640);
    assert(opus_packet_get_nb_channels(buffer) == 2);
    assert(opus_decode_float(decoder, buffer, (opus_int32)size, decoded, 960, 0) == 960);
    bytesSent += size;
    ++packetsSent;
    return CHANNEL_RC_OK;
}

static void deliverPacket(SHADOW_MSG_OUT_AUDIO_OUT_SAMPLES *audio)
{
    assert(soundChannel->SendSamples(soundChannel, audio->buf, audio->nFrames,
                                    audio->wTimestamp) == CHANNEL_RC_OK);
    audio->common.Free(SHADOW_MSG_OUT_AUDIO_OUT_SAMPLES_ID, &audio->common);
}

int shadow_client_boardcast_msg(rdpShadowServer *server, void *context, UINT32 type,
                                SHADOW_MSG_OUT *message, void *parameter)
{
    assert(server && !context && !parameter && type == SHADOW_MSG_OUT_AUDIO_OUT_SAMPLES_ID);
    SHADOW_MSG_OUT_AUDIO_OUT_SAMPLES *audio = (SHADOW_MSG_OUT_AUDIO_OUT_SAMPLES *)message;
    assert(audio->nFrames == 960 && audio->audio_format->wFormatTag == WAVE_FORMAT_OPUS);
    if (holdPacket) {
        assert(!queuedPacket);
        queuedPacket = audio;
    } else
        deliverPacket(audio);
    return 1;
}

static void captureFrames(size_t frames)
{
    float input[960 * 2];
    for (size_t i = 0; i < frames; ++i) {
        input[i * 2] = 0.6f * sinf(2 * M_PI * i / 48);
        input[i * 2 + 1] = 0.15f * sinf(2 * M_PI * i / 24);
    }
    captureConfig.onAudio(captureConfig.context, input, frames, 2, 48000);
}

static void expectLevels(float left, float right)
{
    for (unsigned i = 0; i < 8; ++i)
        captureFrames(960);
    float peaks[2] = { 0 };
    for (size_t i = 0; i < 960 * 2; ++i)
        peaks[i % 2] = fmaxf(peaks[i % 2], fabsf(decoded[i]));
    assert(fabsf(peaks[0] - left) < 0.04f);
    assert(fabsf(peaks[1] - right) < 0.04f);
}

int main(void)
{
    @autoreleasepool {
        char folder[] = "/tmp/macremote-client-preferences.XXXXXXXX";
        assert(mkdtemp(folder));
        mr_client_preferences_init(folder);
        assert(mr_remote_audio_volume() == 0);
        assert(!publishedClient());

        NSString *firstKey = clientKey(@"host:first");
        NSString *secondKey = clientKey(@"host:second");
        assert(firstKey.length == 64 && [firstKey isEqualToString:clientKey(@"HOST:First")]);
        assert(![firstKey isEqualToString:secondKey]);
        rdpShadowClient first = { 0 }, second = { 0 };
        first.context.settings = freerdp_settings_new(0);
        second.context.settings = freerdp_settings_new(0);
        assert(first.context.settings && second.context.settings);
        assert(freerdp_settings_set_string(first.context.settings, FreeRDP_ClientHostname, "First"));
        assert(freerdp_settings_set_string(second.context.settings, FreeRDP_ClientHostname, "Second"));

        writeProfiles(@{firstKey: @{@"logicalWidth": @1920}});
        mr_client_preferences_connect(&first);
        assert([restoredProfile[@"logicalWidth"] isEqual:@1920]);
        assert(mr_remote_audio_volume() == 100);
        assert(([publishedClient() isEqual:[NSString stringWithFormat:@"%@\n%d\n", firstKey, getpid()]]));

        assert(mr_client_preferences_video_bitrate(&first) == 0);

        RDP_SHADOW_ENTRY_POINTS entry = { 0 };
        assert(mr_remote_audio_shadow_entry(&entry) > 0);
        rdpShadowSubsystem *subsystem = entry.New();
        rdpShadowServer server = { 0 };
        server.clients = ArrayList_New(FALSE);
        assert(subsystem && server.clients && ArrayList_Append(server.clients, &first));
        subsystem->server = &server;
        assert(entry.Init(subsystem) > 0 && captureConfig.onAudio);
        assert(captureConfig.audioRate == 48000 && captureConfig.audioChannels == 2);
        assert(subsystem->nRdpsndFormats == 1);
        AUDIO_FORMAT *format = subsystem->rdpsndFormats;
        assert(format->wFormatTag == WAVE_FORMAT_OPUS && format->nAvgBytesPerSec == 32000);
        RdpsndServerContext rdpsnd = { 0 };
        rdpsnd.clientVersion = 8;
        rdpsnd.SendSamples2 = sendWave2;
        soundChannel = first.rdpsnd = &rdpsnd;
        mr_remote_audio_attach(&first);

        int decoderError;
        decoder = opus_decoder_create(48000, 2, &decoderError);
        assert(decoder && decoderError == OPUS_OK);
        expectLevels(0.6f, 0.15f);
        assert(packetsSent == 8 && bytesSent == 5120);

        writeProfiles(@{firstKey: @{@"audioVolume": @25, @"videoBitrate": @1400000},
                        secondKey: @{@"audioVolume": @70, @"videoBitrate": @2000000}});
        expectLiveVolume(25);
        assert(mr_client_preferences_video_bitrate(&first) == 1400000);
        assert(mr_client_preferences_video_bitrate(&second) == 0);
        expectLevels(0.15f, 0.0375f);
        mr_client_preferences_connect(&second);
        assert(mr_remote_audio_volume() == 25);

        holdPacket = true;
        captureFrames(960);
        captureFrames(480);
        holdPacket = false;
        assert(queuedPacket);

        writeProfiles(@{firstKey: @{@"audioVolume": @25, @"audioMuted": @YES},
                        secondKey: @{@"audioVolume": @70}});
        expectLiveVolume(0);
        const size_t mutedBytes = bytesSent;
        const unsigned mutedPackets = packetsSent;
        assert(soundChannel->SendSamples(soundChannel, queuedPacket->buf, queuedPacket->nFrames,
                                        queuedPacket->wTimestamp) == CHANNEL_RC_OK);
        for (unsigned i = 0; i < 3000; ++i)
            captureFrames(960);
        assert(bytesSent == mutedBytes && packetsSent == mutedPackets);

        writeProfiles(@{firstKey: @{@"audioVolume": @25, @"audioMuted": @NO},
                        secondKey: @{@"audioVolume": @70}});
        expectLiveVolume(25);
        deliverPacket(queuedPacket);
        queuedPacket = NULL;
        captureFrames(480);
        assert(bytesSent == mutedBytes && packetsSent == mutedPackets);
        captureFrames(480);
        assert(bytesSent == mutedBytes + 640 && packetsSent == mutedPackets + 1);
        expectLevels(0.15f, 0.0375f);

        mr_client_preferences_disconnect(&first);
        assert(mr_remote_audio_volume() == 70);
        expectLevels(0.42f, 0.105f);
        assert(([publishedClient() isEqual:[NSString stringWithFormat:@"%@\n%d\n", secondKey, getpid()]]));
        mr_client_preferences_connect(&first);
        assert(mr_remote_audio_volume() == 70);
        mr_client_preferences_disconnect(&first);
        assert(mr_remote_audio_volume() == 70);

        writeProfiles(@{firstKey: @{@"audioVolume": @25}, secondKey: @{@"audioVolume": @1}});
        expectLiveVolume(1);
        captureFrames(960);

        mr_client_preferences_disconnect(&second);
        assert(mr_remote_audio_volume() == 0);
        assert([publishedClient() isEqual:secondKey]);
        mr_client_preferences_connect(&first);
        assert(mr_remote_audio_volume() == 25);

        writeProfiles(@{firstKey: @{@"audioVolume": @1e200}});
        expectLiveVolume(100);
        writeProfiles(@{firstKey: @{@"audioVolume": @-20}});
        expectLiveVolume(0);
        const size_t zeroVolumeBytes = bytesSent;
        captureFrames(960);
        assert(bytesSent == zeroVolumeBytes);
        writeProfiles(@{firstKey: @{@"audioVolume": @YES, @"audioMuted": @1}});
        expectLiveVolume(100);

        mr_client_preferences_shutdown();
        assert(mr_remote_audio_volume() == 0 && [publishedClient() isEqual:firstKey]);
        opus_decoder_destroy(decoder);
        entry.Free(subsystem);
        ArrayList_Free(server.clients);
        freerdp_settings_free(first.context.settings);
        freerdp_settings_free(second.context.settings);
        assert([[NSFileManager defaultManager] removeItemAtPath:directory error:nil]);
        puts("client preferences and Opus-only audio: all checks passed");
    }
    return 0;
}
