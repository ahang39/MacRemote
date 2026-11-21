#include "../src/device/client_preferences.m"
#include "mac_shadow.h"
#include <ApplicationServices/ApplicationServices.h>
#include <AudioToolbox/AudioToolbox.h>
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

static void expectLiveAudioMode(unsigned bps, bool preferLossless)
{
    for (unsigned attempt = 0; attempt < 200; ++attempt) {
        if (mr_remote_audio_bitrate() == bps &&
            mr_remote_audio_prefer_lossless() == preferLossless)
            return;
        usleep(5000);
    }
    assert(mr_remote_audio_bitrate() == bps);
    assert(mr_remote_audio_prefer_lossless() == preferLossless);
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
static OpusDecoder *opusDecoder;
static AudioConverterRef aacDecoder;
static UINT16 expectedFormatIndex;
static UINT16 expectedFormatTag;
static size_t bytesSent;
static size_t lastPacketBytes;
static unsigned packetsSent;
static bool holdPacket;
static float decoded[1024 * 2];
static size_t decodedFrames;
static double capturePhaseL;
static double capturePhaseR;

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

typedef struct {
    const uint8_t *data;
    UInt32 size;
    bool consumed;
    AudioStreamPacketDescription desc;
} AacDecodeInput;

static OSStatus provideAacDecodeInput(AudioConverterRef conv, UInt32 *ioPackets,
                                      AudioBufferList *ioData,
                                      AudioStreamPacketDescription **outDesc, void *ud)
{
    (void)conv;
    AacDecodeInput *in = (AacDecodeInput *)ud;
    if (in->consumed) {
        *ioPackets = 0;
        ioData->mBuffers[0].mDataByteSize = 0;
        return 0x6D6F7265;
    }
    in->consumed = true;
    ioData->mBuffers[0].mData = (void *)in->data;
    ioData->mBuffers[0].mDataByteSize = in->size;
    ioData->mBuffers[0].mNumberChannels = 2;
    in->desc.mStartOffset = 0;
    in->desc.mVariableFramesInPacket = 0;
    in->desc.mDataByteSize = in->size;
    if (outDesc) *outDesc = &in->desc;
    *ioPackets = 1;
    return noErr;
}

static UINT sendWave2(RdpsndServerContext *channel, UINT16 format, const void *buffer,
                      size_t size, UINT16 timestamp, UINT32 audioTimestamp)
{
    assert(channel == soundChannel && format == expectedFormatIndex &&
           timestamp == (UINT16)audioTimestamp);
    if (expectedFormatTag == WAVE_FORMAT_OPUS) {
        assert(size > 0 && size <= 640);
        assert(opus_packet_get_nb_channels(buffer) == 2);
        assert(opus_decode_float(opusDecoder, buffer, (opus_int32)size, decoded, 960, 0) == 960);
        decodedFrames = 960;
    } else if (expectedFormatTag == WAVE_FORMAT_AAC_MS) {
        assert(size > 0 && size <= 2048);
        AacDecodeInput in = { .data = (const uint8_t *)buffer, .size = (UInt32)size };
        AudioBufferList abl = {
            .mNumberBuffers = 1,
            .mBuffers = {{ 2, sizeof(decoded), decoded }},
        };
        UInt32 io = 1024;
        OSStatus status = AudioConverterFillComplexBuffer(
            aacDecoder, provideAacDecodeInput, &in, &io, &abl, NULL);
        assert(status == noErr && io == 1024);
        decodedFrames = io;
    } else if (expectedFormatTag == WAVE_FORMAT_PCM) {
        assert(size == 960 * 2 * sizeof(int16_t));
        const int16_t *pcm16 = (const int16_t *)buffer;
        for (size_t i = 0; i < 960 * 2; ++i)
            decoded[i] = (float)pcm16[i] / 32767.0f;
        decodedFrames = 960;
    } else {
        assert(!"unexpected format tag");
    }
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
    assert(audio->nFrames == 960 && audio->audio_format->wFormatTag == WAVE_FORMAT_PCM);
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
        input[i * 2] = 0.6f * sinf((float)capturePhaseL);
        input[i * 2 + 1] = 0.15f * sinf((float)capturePhaseR);
        capturePhaseL += 2.0 * M_PI * 1000.0 / 48000.0;
        capturePhaseR += 2.0 * M_PI * 2000.0 / 48000.0;
    }
    captureConfig.onAudio(captureConfig.context, input, frames, 2, 48000);
}

static void expectLevels(float left, float right)
{
    for (unsigned i = 0; i < 12; ++i)
        captureFrames(960);
    assert(decodedFrames > 0);
    float peaks[2] = { 0 };
    for (size_t i = 0; i < decodedFrames * 2; ++i)
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
        assert(mr_remote_audio_prefer_lossless());
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

        /* New/unconfigured device defaults to High (LAN) mode -> lossless PCM preferred. */
        writeProfiles(@{firstKey: @{@"logicalWidth": @1920}});
        mr_client_preferences_connect(&first);
        assert([restoredProfile[@"logicalWidth"] isEqual:@1920]);
        assert(mr_remote_audio_volume() == 100);
        assert(mr_remote_audio_bitrate() == 128000);
        assert(mr_remote_audio_prefer_lossless());
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
        assert(subsystem->nRdpsndFormats == 3);
        assert(subsystem->rdpsndFormats[0].wFormatTag == WAVE_FORMAT_OPUS &&
               subsystem->rdpsndFormats[0].nSamplesPerSec == 48000 &&
               subsystem->rdpsndFormats[0].nAvgBytesPerSec == 16000);
        assert(subsystem->rdpsndFormats[1].wFormatTag == WAVE_FORMAT_AAC_MS &&
               subsystem->rdpsndFormats[1].nSamplesPerSec == 44100 &&
               subsystem->rdpsndFormats[1].nBlockAlign == 4);
        assert(subsystem->rdpsndFormats[2].wFormatTag == WAVE_FORMAT_PCM &&
               subsystem->rdpsndFormats[2].nSamplesPerSec == 48000 &&
               subsystem->rdpsndFormats[2].wBitsPerSample == 16);

        /* 1. Opus+PCM client (FreeRDP): High -> lossless PCM (3840 B), Low -> 48k Opus (120 B). */
        AUDIO_FORMAT opusClientFormats[] = {
            { WAVE_FORMAT_OPUS, 2, 48000, 16000, 1, 16, 0, NULL },
            { WAVE_FORMAT_PCM, 2, 48000, 192000, 4, 16, 0, NULL },
        };
        RdpsndServerContext rdpsnd = { 0 };
        rdpsnd.clientVersion = 8;
        rdpsnd.client_formats = opusClientFormats;
        rdpsnd.num_client_formats = 2;
        rdpsnd.SendSamples2 = sendWave2;
        soundChannel = first.rdpsnd = &rdpsnd;
        expectedFormatIndex = 1; /* High mode selects lossless PCM even if Opus is index 0. */
        expectedFormatTag = WAVE_FORMAT_PCM;
        mr_remote_audio_attach(&first);

        int decoderError;
        opusDecoder = opus_decoder_create(48000, 2, &decoderError);
        assert(opusDecoder && decoderError == OPUS_OK);
        expectLevels(0.6f, 0.15f);
        assert(packetsSent == 12 && lastPacketBytes == 3840 && bytesSent == 12 * 3840);

        /* Switch first client to Low mode live: switches seamlessly to 48 kbps Opus (120 B/pkt). */
        writeProfiles(@{firstKey: @{@"audioVolume": @25, @"bandwidthMode": @"low"},
                        secondKey: @{@"audioVolume": @70, @"bandwidthMode": @"high"}});
        expectLiveVolume(25);
        expectLiveAudioMode(48000, false);
        assert(mr_client_preferences_stream_profile(&first, &profile));
        assert(profile.bitrate == 1050000 && profile.maxFps == 15 && profile.pacerBytesPerSec == 155000);
        assert(mr_client_preferences_capture_max_fps() == 15);
        assert([sessionResult()[@"mode"] isEqual:@"low"]);

        expectedFormatIndex = 0; /* Low mode switches live to Opus at index 0. */
        expectedFormatTag = WAVE_FORMAT_OPUS;
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
        mr_remote_audio_detach(&first);

        /* 2. Windows mstsc client (AAC-MS at idx 0, PCM at idx 1):
         * High mode -> lossless 48 kHz PCM (idx 1, 3840 B/pkt);
         * Low mode -> live switch to 64 kbps AudioToolbox AAC-LC (idx 0);
         * High mode again -> live switch back to lossless PCM. */
        AudioStreamBasicDescription aacDesc = {
            .mSampleRate = 44100.0, .mFormatID = kAudioFormatMPEG4AAC,
            .mFormatFlags = kMPEG4Object_AAC_LC, .mFramesPerPacket = 1024, .mChannelsPerFrame = 2
        };
        AudioStreamBasicDescription pcm44Desc = {
            .mSampleRate = 44100.0, .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            .mBytesPerPacket = 8, .mFramesPerPacket = 1, .mBytesPerFrame = 8,
            .mChannelsPerFrame = 2, .mBitsPerChannel = 32
        };
        assert(AudioConverterNew(&aacDesc, &pcm44Desc, &aacDecoder) == noErr && aacDecoder);

        AUDIO_FORMAT mstscFormats[] = {
            { WAVE_FORMAT_AAC_MS, 2, 44100, 16000, 4, 16, 0, NULL },
            { WAVE_FORMAT_PCM, 2, 48000, 192000, 4, 16, 0, NULL },
        };
        RdpsndServerContext aacRdpsnd = { 0 };
        aacRdpsnd.clientVersion = 8;
        aacRdpsnd.client_formats = mstscFormats;
        aacRdpsnd.num_client_formats = 2;
        aacRdpsnd.SendSamples2 = sendWave2;
        second.rdpsnd = soundChannel = &aacRdpsnd;
        mr_remote_audio_attach(&second);

        /* Disconnect primary -> second client becomes primary (High mode, lossless PCM, 16bpp). */
        ShadowStreamStats legacyStats = {
            .codec = "bitmap", .colorDepth = 16, .videoBytesPerSec = 40000,
            .videoFps = 10, .hasAckRtt = 0, .inFlightMax = 0
        };
        mr_client_preferences_observe_stats(&second, &legacyStats);
        mr_client_preferences_disconnect(&first);
        assert(mr_remote_audio_volume() == 70);
        assert(mr_remote_audio_bitrate() == 128000);
        assert(mr_remote_audio_prefer_lossless());
        session = sessionResult();
        assert([session[@"mode"] isEqual:@"high"]);
        assert([session[@"codec"] isEqual:@"bitmap"]);
        assert([session[@"colorDepth"] intValue] == 16);
        assert(session[@"ackRttMs"] == nil);

        bytesSent = 0;
        packetsSent = 0;
        expectedFormatIndex = 1; /* High mode -> lossless PCM at index 1. */
        expectedFormatTag = WAVE_FORMAT_PCM;
        expectLevels(0.42f, 0.105f);
        assert(packetsSent == 12 && lastPacketBytes == 3840);

        /* Switch mstsc client to Low mode: live switch to 64 kbps AudioToolbox AAC-LC (idx 0). */
        writeProfiles(@{secondKey: @{@"audioVolume": @70, @"bandwidthMode": @"low"}});
        expectLiveAudioMode(48000, false);
        packetsSent = 0;
        expectedFormatIndex = 0;
        expectedFormatTag = WAVE_FORMAT_AAC_MS;
        expectLevels(0.42f, 0.105f);
        assert(packetsSent >= 8 && lastPacketBytes > 0 && lastPacketBytes < 300);

        /* Switch mstsc client back to High mode: live switch back to lossless PCM (idx 1). */
        writeProfiles(@{secondKey: @{@"audioVolume": @70, @"bandwidthMode": @"high"}});
        expectLiveAudioMode(128000, true);
        expectedFormatIndex = 1;
        expectedFormatTag = WAVE_FORMAT_PCM;
        expectLevels(0.42f, 0.105f);
        assert(lastPacketBytes == 3840);
        mr_remote_audio_detach(&second);

        mr_client_preferences_disconnect(&second);
        assert(mr_remote_audio_volume() == 0);
        assert([publishedClient() isEqual:secondKey]);
        assert(!sessionResult());

        mr_client_preferences_shutdown();
        opus_decoder_destroy(opusDecoder);
        AudioConverterDispose(aacDecoder);
        entry.Free(subsystem);
        ArrayList_Free(server.clients);
        freerdp_settings_free(first.context.settings);
        freerdp_settings_free(second.context.settings);
        assert([[NSFileManager defaultManager] removeItemAtPath:directory error:nil]);
        puts("PASS: per-client bandwidth profiles, High lossless PCM <-> Low Opus/AAC-MS live switch, strict mute and telemetry");
    }
    return 0;
}
