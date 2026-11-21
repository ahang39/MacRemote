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

static void expectLiveAudioBitrate(unsigned bps)
{
    for (unsigned attempt = 0; attempt < 200; ++attempt) {
        if (mr_remote_audio_bitrate() == bps)
            return;
        usleep(5000);
    }
    assert(mr_remote_audio_bitrate() == bps);
}

static NSDictionary *sessionResult(void)
{
    NSData *data = [NSData dataWithContentsOfFile:sessionStatePath];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
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
static size_t lastPacketBytes;
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
    assert(size > 0 && size <= 640);
    assert(opus_packet_get_nb_channels(buffer) == 2);
    assert(opus_decode_float(decoder, buffer, (opus_int32)size, decoded, 960, 0) == 960);
    lastPacketBytes = size;
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
    assert(fabsf(peaks[0] - left) < 0.05f);
    assert(fabsf(peaks[1] - right) < 0.05f);
}

int main(void)
{
    @autoreleasepool {
        char folder[] = "/tmp/macremote-client-preferences.XXXXXXXX";
        assert(mkdtemp(folder));
        mr_client_preferences_init(folder);
        mr_client_preferences_default_bandwidth(MR_BANDWIDTH_HIGH);
        assert(mr_remote_audio_volume() == 0);
        assert(mr_remote_audio_bitrate() == 128000);
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
        assert(freerdp_settings_set_uint32(first.context.settings, FreeRDP_ColorDepth, 32));
        assert(freerdp_settings_set_uint32(second.context.settings, FreeRDP_ColorDepth, 16));

        /* New/unconfigured device defaults to High (LAN) mode. */
        writeProfiles(@{firstKey: @{@"logicalWidth": @1920}});
        mr_client_preferences_connect(&first);
        assert([restoredProfile[@"logicalWidth"] isEqual:@1920]);
        assert(mr_remote_audio_volume() == 100);
        assert(mr_remote_audio_bitrate() == 128000);
        assert(([publishedClient() isEqual:[NSString stringWithFormat:@"%@\n%d\n", firstKey, getpid()]]));

        ShadowStreamProfile profile = { 0 };
        assert(mr_client_preferences_stream_profile(&first, &profile));
        assert(profile.bitrate == 100000000 && profile.maxFps == 60 && profile.pacerBytesPerSec == 0);
        assert(mr_client_preferences_capture_max_fps() == 60);
        assert([sessionResult()[@"mode"] isEqual:@"high"]);
        assert([sessionResult()[@"colorDepth"] intValue] == 32);

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
        assert(format->wFormatTag == WAVE_FORMAT_OPUS && format->nAvgBytesPerSec == 16000);
        RdpsndServerContext rdpsnd = { 0 };
        rdpsnd.clientVersion = 8;
        rdpsnd.SendSamples2 = sendWave2;
        soundChannel = first.rdpsnd = &rdpsnd;
        mr_remote_audio_attach(&first);

        int decoderError;
        decoder = opus_decoder_create(48000, 2, &decoderError);
        assert(decoder && decoderError == OPUS_OK);
        /* High mode: 128 kbps CBR -> 320 bytes per 20 ms packet. */
        expectLevels(0.6f, 0.15f);
        assert(packetsSent == 8 && lastPacketBytes == 320 && bytesSent == 8 * 320);

        /* Switch first client to Low mode live: 48 kbps Opus (120 B/pkt) + 15 fps + byte pacer. */
        writeProfiles(@{firstKey: @{@"audioVolume": @25, @"bandwidthMode": @"low"},
                        secondKey: @{@"audioVolume": @70, @"bandwidthMode": @"high"}});
        expectLiveVolume(25);
        expectLiveAudioBitrate(48000);
        assert(mr_client_preferences_stream_profile(&first, &profile));
        assert(profile.bitrate == 1050000 && profile.maxFps == 15 && profile.pacerBytesPerSec == 155000);
        assert(mr_client_preferences_capture_max_fps() == 15);
        assert([sessionResult()[@"mode"] isEqual:@"low"]);

        expectLevels(0.15f, 0.0375f);
        assert(lastPacketBytes == 120);

        /* Observe 1 Hz telemetry: combines video rate + audio bytes sent + optional ACK RTT. */
        ShadowStreamStats stats = {
            .codec = "h264",
            .colorDepth = 32,
            .videoBytesPerSec = 132000,
            .videoFps = 14,
            .refineFrames = 1,
            .ackRttP50Ms = 78,
            .ackRttP95Ms = 92,
            .hasAckRtt = 1,
            .inFlightMax = 2
        };
        mr_client_preferences_observe_stats(&first, &stats);
        NSDictionary *session = sessionResult();
        assert([session[@"mode"] isEqual:@"low"]);
        assert([session[@"codec"] isEqual:@"h264"]);
        assert([session[@"videoBytesPerSec"] intValue] == 132000);
        assert([session[@"audioBytesPerSec"] intValue] > 0);
        assert([session[@"fps"] intValue] == 14);
        assert([session[@"ackRttMs"] intValue] == 78);
        assert([session[@"ackRttP95Ms"] intValue] == 92);

        /* Second client connects in High mode -> capture FPS raises to 60 for second client. */
        mr_client_preferences_connect(&second);
        assert(mr_remote_audio_volume() == 25);
        assert(mr_client_preferences_capture_max_fps() == 60);
        assert(mr_client_preferences_stream_profile(&second, &profile));
        assert(profile.maxFps == 60 && profile.pacerBytesPerSec == 0);

        /* Strict mute discards queued packet and stops sending bytes. */
        holdPacket = true;
        captureFrames(960);
        captureFrames(480);
        holdPacket = false;
        assert(queuedPacket);

        writeProfiles(@{firstKey: @{@"audioVolume": @25, @"audioMuted": @YES, @"bandwidthMode": @"low"},
                        secondKey: @{@"audioVolume": @70, @"bandwidthMode": @"high"}});
        expectLiveVolume(0);
        const size_t mutedBytes = bytesSent;
        const unsigned mutedPackets = packetsSent;
        assert(soundChannel->SendSamples(soundChannel, queuedPacket->buf, queuedPacket->nFrames,
                                         queuedPacket->wTimestamp) == CHANNEL_RC_OK);
        for (unsigned i = 0; i < 300; ++i)
            captureFrames(960);
        assert(bytesSent == mutedBytes && packetsSent == mutedPackets);

        /* Unmute resumes cleanly with generation check discarding old queued packet. */
        writeProfiles(@{firstKey: @{@"audioVolume": @25, @"audioMuted": @NO, @"bandwidthMode": @"low"},
                        secondKey: @{@"audioVolume": @70, @"bandwidthMode": @"high"}});
        expectLiveVolume(25);
        deliverPacket(queuedPacket);
        queuedPacket = NULL;
        captureFrames(480);
        assert(bytesSent == mutedBytes && packetsSent == mutedPackets);
        captureFrames(480);
        assert(bytesSent == mutedBytes + 120 && packetsSent == mutedPackets + 1);

        /* Disconnect primary -> second client becomes primary (High mode, 128k audio, 16bpp). */
        ShadowStreamStats legacyStats = {
            .codec = "bitmap", .colorDepth = 16, .videoBytesPerSec = 40000,
            .videoFps = 10, .hasAckRtt = 0, .inFlightMax = 0
        };
        mr_client_preferences_observe_stats(&second, &legacyStats);
        mr_client_preferences_disconnect(&first);
        assert(mr_remote_audio_volume() == 70);
        assert(mr_remote_audio_bitrate() == 128000);
        session = sessionResult();
        assert([session[@"mode"] isEqual:@"high"]);
        assert([session[@"codec"] isEqual:@"bitmap"]);
        assert([session[@"colorDepth"] intValue] == 16);
        assert(session[@"ackRttMs"] == nil);
        expectLevels(0.42f, 0.105f);
        assert(lastPacketBytes == 320);

        mr_client_preferences_disconnect(&second);
        assert(mr_remote_audio_volume() == 0);
        assert([publishedClient() isEqual:secondKey]);
        assert(!sessionResult());

        mr_client_preferences_shutdown();
        opus_decoder_destroy(decoder);
        entry.Free(subsystem);
        ArrayList_Free(server.clients);
        freerdp_settings_free(first.context.settings);
        freerdp_settings_free(second.context.settings);
        assert([[NSFileManager defaultManager] removeItemAtPath:directory error:nil]);
        puts("PASS: per-client bandwidth profiles, dynamic 128k/48k Opus audio, strict mute and session telemetry");
    }
    return 0;
}
