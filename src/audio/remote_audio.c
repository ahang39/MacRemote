#include "remote_audio.h"
#include "mac_shadow.h"

#include <freerdp/server/rdpsnd.h>
#include <winpr/sysinfo.h>
#include <math.h>
#include <opus.h>
#include <pthread.h>

enum {
    sampleRate = 48000,
    channels = 2,
    bitrate = 256000,
    framesPerPacket = sampleRate / 50,
    bytesPerPacket = bitrate / 8 / 50,
    fadeFrames = sampleRate / 200,
    wave2Version = 8
};

typedef struct {
    unsigned volume;
    uint64_t generation;
} AudioSettings;

typedef struct {
    SHADOW_MSG_OUT_AUDIO_OUT_SAMPLES message;
    uint64_t generation;
    UINT32 timestamp;
    BYTE data[bytesPerPacket];
} AudioPacket;

static AUDIO_FORMAT opusFormat = {
    WAVE_FORMAT_OPUS, channels, sampleRate, bitrate / 8, 1, 16, 0, NULL
};
static pfnShadowSubsystemInit shadowInit;
static pfnShadowSubsystemFree shadowFree;
static pthread_mutex_t settingsLock = PTHREAD_MUTEX_INITIALIZER;
static AudioSettings settings;

static struct {
    OpusEncoder *encoder;
    uint64_t generation;
    size_t frames;
    float gain;
    UINT64 lastAudible;
    float pcm[framesPerPacket * channels];
} capture;

static AudioSettings readSettings(void)
{
    pthread_mutex_lock(&settingsLock);
    const AudioSettings current = settings;
    pthread_mutex_unlock(&settingsLock);
    return current;
}

unsigned mr_remote_audio_volume(void)
{
    return readSettings().volume;
}

void mr_remote_audio_set_volume(unsigned percent)
{
    pthread_mutex_lock(&settingsLock);
    if ((settings.volume == 0) != (percent == 0))
        ++settings.generation;
    settings.volume = percent;
    pthread_mutex_unlock(&settingsLock);
}

static UINT sendPacket(RdpsndServerContext *channel, const void *buffer, size_t frames,
                       UINT16 timestamp)
{
    (void)frames;
    const AudioPacket *packet = buffer;
    UINT result = CHANNEL_RC_OK;

    // Serialize the final rdpsnd write with applying mute of the same stream.
    pthread_mutex_lock(&settingsLock);
    if (settings.volume && packet->generation == settings.generation &&
        channel->clientVersion >= wave2Version) {
        result = channel->SendSamples2(channel, channel->selected_client_format, packet->data,
                                       sizeof(packet->data), timestamp, packet->timestamp);
    }
    pthread_mutex_unlock(&settingsLock);

    return result;
}

void mr_remote_audio_attach(rdpShadowClient *client)
{
    if (client->rdpsnd)
        client->rdpsnd->SendSamples = sendPacket;
}

static void freePacket(UINT32 id, SHADOW_MSG_OUT *message)
{
    (void)id;
    free(message);
}

static void encodePacket(rdpShadowServer *server, AudioSettings current)
{
    const UINT64 now = GetTickCount64();
    for (size_t i = 0; i < framesPerPacket * channels; ++i) {
        if (fabsf(capture.pcm[i]) >= 1.0f / 32768.0f) {
            capture.lastAudible = now;
            break;
        }
    }
    if (!capture.lastAudible || now - capture.lastAudible >= 200)
        return;

    const float target = current.volume / 100.0f;
    for (size_t frame = 0; frame < framesPerPacket; ++frame) {
        const float fraction = frame < fadeFrames ? (float)(frame + 1) / fadeFrames : 1.0f;
        const float gain = capture.gain + (target - capture.gain) * fraction;
        for (size_t channel = 0; channel < channels; ++channel)
            capture.pcm[frame * channels + channel] *= gain;
    }
    capture.gain = target;

    AudioPacket *packet = calloc(1, sizeof(*packet));
    if (!packet)
        return;
    const int length = opus_encode_float(capture.encoder, capture.pcm, framesPerPacket,
                                        packet->data, sizeof(packet->data));
    if (length != bytesPerPacket) {
        free(packet);
        return;
    }

    packet->generation = current.generation;
    packet->timestamp = (UINT32)now;
    packet->message.common.Free = freePacket;
    packet->message.audio_format = &opusFormat;
    packet->message.buf = packet;
    packet->message.nFrames = framesPerPacket;
    packet->message.wTimestamp = (UINT16)now;
    (void)shadow_client_boardcast_msg(server, NULL, SHADOW_MSG_OUT_AUDIO_OUT_SAMPLES_ID,
                                      &packet->message.common, NULL);
}

static void onAudio(void *context, const float *samples, size_t frames, UINT32 channelCount,
                    UINT32 rate)
{
    if (channelCount != channels || rate != sampleRate)
        return;

    macShadowSubsystem *mac = context;
    const AudioSettings current = readSettings();
    if (!current.volume)
        return;
    if (capture.generation != current.generation) {
        (void)opus_encoder_ctl(capture.encoder, OPUS_RESET_STATE);
        capture.generation = current.generation;
        capture.frames = 0;
        capture.gain = 0;
        capture.lastAudible = 0;
    }
    while (frames) {
        const size_t remaining = framesPerPacket - capture.frames;
        const size_t copy = frames < remaining ? frames : remaining;
        memcpy(capture.pcm + capture.frames * channels, samples, copy * channels * sizeof(*samples));
        capture.frames += copy;
        frames -= copy;
        samples += copy * channels;
        if (capture.frames == framesPerPacket) {
            encodePacket(mac->common.server, current);
            capture.frames = 0;
        }
    }
}

static int configureAudio(rdpShadowSubsystem *subsystem)
{
    const int result = shadowInit(subsystem);
    if (result < 0)
        return result;

    int error;
    capture.encoder = opus_encoder_create(sampleRate, channels, OPUS_APPLICATION_AUDIO, &error);
    if (!capture.encoder)
        return -1;
    if (opus_encoder_ctl(capture.encoder, OPUS_SET_BITRATE(bitrate)) != OPUS_OK ||
        opus_encoder_ctl(capture.encoder, OPUS_SET_VBR(0)) != OPUS_OK)
        return -1;

    AUDIO_FORMAT *formats = audio_formats_new(1);
    if (!formats)
        return -1;
    *formats = opusFormat;
    audio_formats_free(subsystem->rdpsndFormats, subsystem->nRdpsndFormats);
    subsystem->rdpsndFormats = formats;
    subsystem->nRdpsndFormats = 1;

    macShadowSubsystem *mac = (macShadowSubsystem *)subsystem;
    mac_capture_free(mac->capture);
    mac->config.audio = TRUE;
    mac->config.audioRate = sampleRate;
    mac->config.audioChannels = channels;
    mac->config.onAudio = onAudio;
    mac->capture = mac_capture_new(&mac->config);
    return mac->capture ? result : -1;
}

static void freeAudio(rdpShadowSubsystem *subsystem)
{
    shadowFree(subsystem);
    opus_encoder_destroy(capture.encoder);
    memset(&capture, 0, sizeof(capture));
}

extern int ShadowSubsystemEntry(RDP_SHADOW_ENTRY_POINTS *entry);

int mr_remote_audio_shadow_entry(RDP_SHADOW_ENTRY_POINTS *entry)
{
    const int result = ShadowSubsystemEntry(entry);
    if (result < 0)
        return result;

    shadowInit = entry->Init;
    shadowFree = entry->Free;
    entry->Init = configureAudio;
    entry->Free = freeAudio;
    return result;
}
