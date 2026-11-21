#include "remote_audio.h"
#include "mac_shadow.h"

#include <AudioToolbox/AudioToolbox.h>
#include <freerdp/server/rdpsnd.h>
#include <winpr/sysinfo.h>
#include <math.h>
#include <opus.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    sampleRate = 48000,
    aacSampleRate = 44100,
    channels = 2,
    defaultBitrate = 128000,
    minBitrate = 24000,
    maxBitrate = 256000,
    framesPerPacket = sampleRate / 50,
    maxOpusBytes = maxBitrate / 8 / 50,
    maxAacBytes = 2048,
    pcmFrameBytes = channels * sizeof(int16_t),
    pcmPacketBytes = framesPerPacket * pcmFrameBytes,
    fadeFrames = sampleRate / 200,
    wave2Version = 8,
    aacNeedMoreInput = 0x6D6F7265 /* 'more' */
};

typedef struct {
    unsigned volume;
    unsigned bitrate;
    bool preferLossless;
    uint64_t generation;
} AudioSettings;

typedef struct {
    SHADOW_MSG_OUT_AUDIO_OUT_SAMPLES message;
    uint64_t generation;
    unsigned bitrate;
    bool preferLossless;
    UINT32 timestamp;
    float pcm[framesPerPacket * channels];
} AudioPacket;

typedef struct {
    bool present;
    UINT16 index;
    UINT16 tag;
    UINT32 rate;
} ResolvedFormat;

typedef struct ClientAudioStream {
    RdpsndServerContext *channel;
    psRdpsndServerSendSamples fallbackSendSamples;
    bool formatsResolved;
    ResolvedFormat lossless;
    ResolvedFormat compressed;
    UINT16 activeFormatTag;
    UINT16 activeFormatIndex;
    uint64_t generation;
    unsigned bitrate;
    OpusEncoder *opus;
    AudioConverterRef aac;
    struct ClientAudioStream *next;
} ClientAudioStream;

typedef struct {
    const float *pcm;
    UInt32 totalFrames;
    UInt32 offset;
} AacInputContext;

static AUDIO_FORMAT pcmSourceFormat = {
    WAVE_FORMAT_PCM, channels, sampleRate, sampleRate * pcmFrameBytes, pcmFrameBytes, 16, 0, NULL
};

/* Offered to clients during rdpsnd handshake:
 * - WAVE_FORMAT_OPUS (48 kHz stereo): compressed mode for FreeRDP/Opus clients
 * - WAVE_FORMAT_AAC_MS (44.1 kHz stereo): compressed mode for Windows mstsc.exe
 * - WAVE_FORMAT_PCM (48 kHz stereo 16-bit): lossless LAN mode & mandatory fallback
 * Because each SNDC_WAVE2 PDU carries wFormatNo, MacRemote switches seamlessly
 * between lossless PCM (High / LAN) and Opus/AAC (Low / WAN) without reconnecting. */
static const AUDIO_FORMAT offeredFormats[] = {
    { WAVE_FORMAT_OPUS, channels, sampleRate, defaultBitrate / 8, 1, 16, 0, NULL },
    { WAVE_FORMAT_AAC_MS, channels, aacSampleRate, defaultBitrate / 8, 4, 16, 0, NULL },
    { WAVE_FORMAT_PCM, channels, sampleRate, sampleRate * pcmFrameBytes, pcmFrameBytes, 16, 0,
      NULL },
};

static pfnShadowSubsystemInit shadowInit;
static pfnShadowSubsystemFree shadowFree;
static pthread_mutex_t settingsLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t streamsLock = PTHREAD_MUTEX_INITIALIZER;
static AudioSettings settings = {
    .volume = 0,
    .bitrate = defaultBitrate,
    .preferLossless = true,
    .generation = 0,
};
static _Atomic uint64_t audioBytesSent;
static ClientAudioStream *streams;

static struct {
    uint64_t generation;
    size_t frames;
    float gain;
    UINT64 lastAudible;
    float pcm[framesPerPacket * channels];
} capture;

static unsigned clampBitrate(unsigned bps)
{
    if (bps < minBitrate) return minBitrate;
    if (bps > maxBitrate) return maxBitrate;
    return bps;
}

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

unsigned mr_remote_audio_bitrate(void)
{
    return readSettings().bitrate;
}

void mr_remote_audio_set_bitrate(unsigned bps)
{
    const unsigned clamped = clampBitrate(bps);
    pthread_mutex_lock(&settingsLock);
    settings.bitrate = clamped;
    pthread_mutex_unlock(&settingsLock);
}

bool mr_remote_audio_prefer_lossless(void)
{
    return readSettings().preferLossless;
}

void mr_remote_audio_set_prefer_lossless(bool preferLossless)
{
    pthread_mutex_lock(&settingsLock);
    settings.preferLossless = preferLossless;
    pthread_mutex_unlock(&settingsLock);
}

uint64_t mr_remote_audio_take_bytes_sent(void)
{
    return atomic_exchange_explicit(&audioBytesSent, 0, memory_order_relaxed);
}

static void destroyStreamEncoders(ClientAudioStream *stream)
{
    if (stream->opus) {
        opus_encoder_destroy(stream->opus);
        stream->opus = NULL;
    }
    if (stream->aac) {
        AudioConverterDispose(stream->aac);
        stream->aac = NULL;
    }
}

static void freeAllStreams(void)
{
    pthread_mutex_lock(&streamsLock);
    ClientAudioStream *node = streams;
    streams = NULL;
    pthread_mutex_unlock(&streamsLock);

    while (node) {
        ClientAudioStream *next = node->next;
        destroyStreamEncoders(node);
        free(node);
        node = next;
    }
}

static ClientAudioStream *findOrCreateStream(RdpsndServerContext *channel,
                                             psRdpsndServerSendSamples fallback)
{
    pthread_mutex_lock(&streamsLock);
    for (ClientAudioStream *node = streams; node; node = node->next) {
        if (node->channel == channel) {
            if (fallback && !node->fallbackSendSamples)
                node->fallbackSendSamples = fallback;
            pthread_mutex_unlock(&streamsLock);
            return node;
        }
    }
    ClientAudioStream *created = calloc(1, sizeof(*created));
    if (created) {
        created->channel = channel;
        created->fallbackSendSamples = fallback;
        created->next = streams;
        streams = created;
    }
    pthread_mutex_unlock(&streamsLock);
    return created;
}

static bool formatMatches(const AUDIO_FORMAT *fmt, UINT16 tag, UINT32 rate, UINT16 ch)
{
    if (!fmt || fmt->wFormatTag != tag || fmt->nChannels != ch || fmt->nSamplesPerSec != rate)
        return false;
    if (tag == WAVE_FORMAT_PCM && fmt->wBitsPerSample != 16)
        return false;
    return true;
}

static const char *formatTagName(UINT16 tag)
{
    switch (tag) {
    case WAVE_FORMAT_OPUS:
        return "WAVE_FORMAT_OPUS";
    case WAVE_FORMAT_AAC_MS:
        return "WAVE_FORMAT_AAC_MS";
    case WAVE_FORMAT_PCM:
        return "WAVE_FORMAT_PCM";
    default:
        return "UNKNOWN";
    }
}

static bool resolveClientFormats(ClientAudioStream *stream, RdpsndServerContext *channel)
{
    if (stream->formatsResolved)
        return stream->lossless.present || stream->compressed.present;

    if (!channel->client_formats || channel->num_client_formats == 0)
        return false;

    const bool supportsWave2 = channel->clientVersion >= wave2Version;

    for (size_t i = 0; i < channel->num_client_formats; ++i) {
        const AUDIO_FORMAT *fmt = &channel->client_formats[i];
        if (!stream->lossless.present && formatMatches(fmt, WAVE_FORMAT_PCM, sampleRate, channels)) {
            stream->lossless = (ResolvedFormat){
                .present = true,
                .index = (UINT16)i,
                .tag = WAVE_FORMAT_PCM,
                .rate = sampleRate,
            };
        }
        if (supportsWave2 && formatMatches(fmt, WAVE_FORMAT_OPUS, sampleRate, channels)) {
            stream->compressed = (ResolvedFormat){
                .present = true,
                .index = (UINT16)i,
                .tag = WAVE_FORMAT_OPUS,
                .rate = sampleRate,
            };
        } else if (supportsWave2 && !stream->compressed.present &&
                   formatMatches(fmt, WAVE_FORMAT_AAC_MS, aacSampleRate, channels)) {
            stream->compressed = (ResolvedFormat){
                .present = true,
                .index = (UINT16)i,
                .tag = WAVE_FORMAT_AAC_MS,
                .rate = aacSampleRate,
            };
        }
    }

    stream->formatsResolved = true;
    if (!stream->lossless.present && !stream->compressed.present) {
        fprintf(stderr,
                "[MacRemote audio] no compatible format in %u client formats (clientVer=%u)\n",
                (unsigned)channel->num_client_formats, (unsigned)channel->clientVersion);
        return false;
    }
    return true;
}

static const ResolvedFormat *selectFormatForPacket(const ClientAudioStream *stream,
                                                   bool preferLossless)
{
    if (preferLossless) {
        if (stream->lossless.present)
            return &stream->lossless;
        if (stream->compressed.present)
            return &stream->compressed;
    } else {
        if (stream->compressed.present)
            return &stream->compressed;
        if (stream->lossless.present)
            return &stream->lossless;
    }
    return NULL;
}

static UInt32 selectApplicableAacBitrate(AudioConverterRef converter, unsigned targetBps)
{
    UInt32 propSize = 0;
    if (AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates,
                                      &propSize, NULL) != noErr ||
        propSize < sizeof(AudioValueRange)) {
        return targetBps < 64000u ? 64000u : targetBps;
    }

    AudioValueRange *ranges = malloc(propSize);
    if (!ranges)
        return targetBps < 64000u ? 64000u : targetBps;

    UInt32 chosen = 0;
    if (AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates,
                                  &propSize, ranges) == noErr) {
        const size_t count = propSize / sizeof(AudioValueRange);
        double bestDiff = 1e18;
        for (size_t i = 0; i < count; ++i) {
            const double lo = ranges[i].mMinimum;
            const double hi = ranges[i].mMaximum >= lo ? ranges[i].mMaximum : lo;
            if (lo <= 0.0)
                continue;
            double candidate = (double)targetBps;
            if (candidate < lo)
                candidate = lo;
            else if (candidate > hi)
                candidate = hi;
            const double diff = fabs(candidate - (double)targetBps);
            if (diff < bestDiff) {
                bestDiff = diff;
                chosen = (UInt32)llround(candidate);
            }
        }
    }
    free(ranges);
    return chosen ? chosen : (targetBps < 64000u ? 64000u : targetBps);
}

static bool ensureOpusEncoder(ClientAudioStream *stream, unsigned bitrate)
{
    if (!stream->opus) {
        int error = OPUS_OK;
        stream->opus = opus_encoder_create(sampleRate, channels, OPUS_APPLICATION_AUDIO, &error);
        if (!stream->opus || error != OPUS_OK) {
            if (stream->opus) {
                opus_encoder_destroy(stream->opus);
                stream->opus = NULL;
            }
            return false;
        }
        if (opus_encoder_ctl(stream->opus, OPUS_SET_BITRATE((opus_int32)bitrate)) != OPUS_OK ||
            opus_encoder_ctl(stream->opus, OPUS_SET_VBR(0)) != OPUS_OK) {
            opus_encoder_destroy(stream->opus);
            stream->opus = NULL;
            return false;
        }
        stream->bitrate = bitrate;
        return true;
    }
    if (stream->bitrate != bitrate) {
        if (opus_encoder_ctl(stream->opus, OPUS_SET_BITRATE((opus_int32)bitrate)) == OPUS_OK)
            stream->bitrate = bitrate;
    }
    return true;
}

static bool ensureAacEncoder(ClientAudioStream *stream, UINT32 rate, unsigned bitrate)
{
    if (!stream->aac) {
        AudioStreamBasicDescription inDesc = {
            .mSampleRate = (Float64)sampleRate,
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            .mBytesPerPacket = channels * sizeof(float),
            .mFramesPerPacket = 1,
            .mBytesPerFrame = channels * sizeof(float),
            .mChannelsPerFrame = channels,
            .mBitsPerChannel = 32,
        };
        AudioStreamBasicDescription outDesc = {
            .mSampleRate = (Float64)rate,
            .mFormatID = kAudioFormatMPEG4AAC,
            .mFormatFlags = kMPEG4Object_AAC_LC,
            .mFramesPerPacket = 1024,
            .mChannelsPerFrame = channels,
        };
        OSStatus status = AudioConverterNew(&inDesc, &outDesc, &stream->aac);
        if (status != noErr || !stream->aac) {
            fprintf(stderr, "[MacRemote audio] AudioConverterNew(AAC-LC) failed: %d\n",
                    (int)status);
            stream->aac = NULL;
            return false;
        }
        UInt32 aacBitrate = selectApplicableAacBitrate(stream->aac, bitrate);
        status = AudioConverterSetProperty(stream->aac, kAudioConverterEncodeBitRate,
                                           sizeof(aacBitrate), &aacBitrate);
        if (status != noErr) {
            fprintf(stderr, "[MacRemote audio] AudioConverterSetProperty(bitrate=%u) failed: %d\n",
                    (unsigned)aacBitrate, (int)status);
            AudioConverterDispose(stream->aac);
            stream->aac = NULL;
            return false;
        }
        stream->bitrate = bitrate;
        return true;
    }
    if (stream->bitrate != bitrate) {
        UInt32 aacBitrate = selectApplicableAacBitrate(stream->aac, bitrate);
        if (AudioConverterSetProperty(stream->aac, kAudioConverterEncodeBitRate,
                                      sizeof(aacBitrate), &aacBitrate) == noErr)
            stream->bitrate = bitrate;
    }
    return true;
}

static OSStatus provideAacInput(AudioConverterRef converter, UInt32 *ioNumberDataPackets,
                                AudioBufferList *ioData,
                                AudioStreamPacketDescription **outDataPacketDescription,
                                void *inUserData)
{
    (void)converter;
    (void)outDataPacketDescription;
    AacInputContext *ctx = (AacInputContext *)inUserData;
    const UInt32 available = ctx->totalFrames - ctx->offset;
    if (available == 0) {
        *ioNumberDataPackets = 0;
        ioData->mBuffers[0].mDataByteSize = 0;
        return aacNeedMoreInput;
    }
    const UInt32 take = *ioNumberDataPackets < available ? *ioNumberDataPackets : available;
    ioData->mBuffers[0].mData = (void *)(ctx->pcm + ctx->offset * channels);
    ioData->mBuffers[0].mDataByteSize = take * channels * sizeof(float);
    ioData->mBuffers[0].mNumberChannels = channels;
    ctx->offset += take;
    *ioNumberDataPackets = take;
    return noErr;
}

static UINT submitWave2Locked(RdpsndServerContext *channel, UINT16 formatIndex,
                              uint64_t packetGeneration, const void *payload, size_t length,
                              UINT16 timestamp, UINT32 audioTimestamp)
{
    UINT result = CHANNEL_RC_OK;
    pthread_mutex_lock(&settingsLock);
    if (settings.volume && packetGeneration == settings.generation &&
        channel->clientVersion >= wave2Version && channel->SendSamples2 && length > 0) {
        result = channel->SendSamples2(channel, formatIndex, payload, length, timestamp,
                                       audioTimestamp);
        if (result == CHANNEL_RC_OK)
            atomic_fetch_add_explicit(&audioBytesSent, length, memory_order_relaxed);
    }
    pthread_mutex_unlock(&settingsLock);
    return result;
}

static void convertFloatToPcm16(const float *src, int16_t *dst, size_t sampleCount)
{
    for (size_t i = 0; i < sampleCount; ++i) {
        float v = src[i];
        if (v > 1.0f) v = 1.0f;
        else if (v < -1.0f) v = -1.0f;
        dst[i] = (int16_t)lrintf(v * 32767.0f);
    }
}

static UINT sendPacket(RdpsndServerContext *channel, const void *buffer, size_t frames,
                       UINT16 timestamp)
{
    (void)frames;
    const AudioPacket *packet = buffer;
    if (!channel || !packet)
        return CHANNEL_RC_OK;

    const AudioSettings current = readSettings();
    if (!current.volume || packet->generation != current.generation)
        return CHANNEL_RC_OK;

    ClientAudioStream *stream = findOrCreateStream(channel, NULL);
    if (!stream || !resolveClientFormats(stream, channel))
        return CHANNEL_RC_OK;

    const ResolvedFormat *chosen = selectFormatForPacket(stream, packet->preferLossless);
    if (!chosen)
        return CHANNEL_RC_OK;

    const bool generationChanged = stream->generation != packet->generation;
    const bool formatChanged =
        stream->activeFormatTag != chosen->tag || stream->activeFormatIndex != chosen->index;
    if (generationChanged || formatChanged) {
        if (stream->opus)
            (void)opus_encoder_ctl(stream->opus, OPUS_RESET_STATE);
        if (stream->aac)
            (void)AudioConverterReset(stream->aac);
        stream->generation = packet->generation;
        if (formatChanged) {
            stream->activeFormatTag = chosen->tag;
            stream->activeFormatIndex = chosen->index;
            fprintf(stderr,
                    "[MacRemote audio] active format=%s rate=%u ch=%u clientIdx=%u "
                    "mode=%s clientVer=%u (clientFormats=%u)\n",
                    formatTagName(chosen->tag), (unsigned)chosen->rate, (unsigned)channels,
                    (unsigned)chosen->index, packet->preferLossless ? "lossless" : "compressed",
                    (unsigned)channel->clientVersion, (unsigned)channel->num_client_formats);
        }
    }

    if (chosen->tag == WAVE_FORMAT_OPUS) {
        if (!ensureOpusEncoder(stream, packet->bitrate))
            return CHANNEL_RC_OK;
        BYTE encoded[maxOpusBytes];
        const size_t expectedBytes = stream->bitrate / 8 / 50;
        const opus_int32 maxBytes =
            expectedBytes > 0 && expectedBytes <= sizeof(encoded)
                ? (opus_int32)expectedBytes
                : (opus_int32)sizeof(encoded);
        const int length = opus_encode_float(stream->opus, packet->pcm, framesPerPacket,
                                             encoded, maxBytes);
        if (length <= 0 || (size_t)length > sizeof(encoded))
            return CHANNEL_RC_OK;
        return submitWave2Locked(channel, chosen->index, packet->generation,
                                 encoded, (size_t)length, timestamp, packet->timestamp);
    }

    if (chosen->tag == WAVE_FORMAT_AAC_MS) {
        if (!ensureAacEncoder(stream, chosen->rate, packet->bitrate))
            return CHANNEL_RC_OK;
        AacInputContext input = {
            .pcm = packet->pcm,
            .totalFrames = framesPerPacket,
            .offset = 0,
        };
        while (true) {
            BYTE encoded[maxAacBytes];
            AudioBufferList outBuffers = {
                .mNumberBuffers = 1,
                .mBuffers = {{
                    .mNumberChannels = channels,
                    .mDataByteSize = sizeof(encoded),
                    .mData = encoded,
                }},
            };
            AudioStreamPacketDescription pktDesc = { 0 };
            UInt32 ioPackets = 1;
            const OSStatus status = AudioConverterFillComplexBuffer(
                stream->aac, provideAacInput, &input, &ioPackets, &outBuffers, &pktDesc);
            if (ioPackets > 0 && pktDesc.mDataByteSize > 0 &&
                pktDesc.mDataByteSize <= sizeof(encoded)) {
                const UINT rc = submitWave2Locked(channel, chosen->index,
                                                  packet->generation, encoded,
                                                  (size_t)pktDesc.mDataByteSize,
                                                  timestamp, packet->timestamp);
                if (rc != CHANNEL_RC_OK)
                    return rc;
            }
            if (status != noErr) {
                if (status != aacNeedMoreInput)
                    (void)AudioConverterReset(stream->aac);
                break;
            }
        }
        return CHANNEL_RC_OK;
    }

    if (chosen->tag == WAVE_FORMAT_PCM) {
        int16_t pcm16[framesPerPacket * channels];
        convertFloatToPcm16(packet->pcm, pcm16, framesPerPacket * channels);
        if (channel->clientVersion >= wave2Version) {
            return submitWave2Locked(channel, chosen->index, packet->generation,
                                     pcm16, sizeof(pcm16), timestamp, packet->timestamp);
        }
        UINT result = CHANNEL_RC_OK;
        pthread_mutex_lock(&settingsLock);
        if (settings.volume && packet->generation == settings.generation &&
            stream->fallbackSendSamples) {
            channel->selected_client_format = chosen->index;
            result = stream->fallbackSendSamples(channel, pcm16, framesPerPacket, timestamp);
            if (result == CHANNEL_RC_OK)
                atomic_fetch_add_explicit(&audioBytesSent, sizeof(pcm16), memory_order_relaxed);
        }
        pthread_mutex_unlock(&settingsLock);
        return result;
    }

    return CHANNEL_RC_OK;
}

void mr_remote_audio_attach(rdpShadowClient *client)
{
    if (!client || !client->rdpsnd)
        return;
    psRdpsndServerSendSamples fallback =
        client->rdpsnd->SendSamples == sendPacket ? NULL : client->rdpsnd->SendSamples;
    (void)findOrCreateStream(client->rdpsnd, fallback);
    client->rdpsnd->SendSamples = sendPacket;
}

void mr_remote_audio_detach(rdpShadowClient *client)
{
    if (!client || !client->rdpsnd)
        return;
    ClientAudioStream *removed = NULL;
    pthread_mutex_lock(&streamsLock);
    ClientAudioStream **cursor = &streams;
    while (*cursor) {
        if ((*cursor)->channel == client->rdpsnd) {
            removed = *cursor;
            *cursor = removed->next;
            break;
        }
        cursor = &(*cursor)->next;
    }
    pthread_mutex_unlock(&streamsLock);
    if (removed) {
        destroyStreamEncoders(removed);
        free(removed);
    }
}

static void freePacket(UINT32 id, SHADOW_MSG_OUT *message)
{
    (void)id;
    free(message);
}

static void emitPacket(rdpShadowServer *server, AudioSettings current)
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
        for (size_t ch = 0; ch < channels; ++ch)
            capture.pcm[frame * channels + ch] *= gain;
    }
    capture.gain = target;

    AudioPacket *packet = calloc(1, sizeof(*packet));
    if (!packet)
        return;
    packet->generation = current.generation;
    packet->bitrate = current.bitrate;
    packet->preferLossless = current.preferLossless;
    packet->timestamp = (UINT32)now;
    memcpy(packet->pcm, capture.pcm, sizeof(packet->pcm));
    packet->message.common.Free = freePacket;
    packet->message.audio_format = &pcmSourceFormat;
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
        capture.generation = current.generation;
        capture.frames = 0;
        capture.gain = 0;
        capture.lastAudible = 0;
    }
    while (frames) {
        const size_t remaining = framesPerPacket - capture.frames;
        const size_t copy = frames < remaining ? frames : remaining;
        memcpy(capture.pcm + capture.frames * channels, samples,
               copy * channels * sizeof(*samples));
        capture.frames += copy;
        frames -= copy;
        samples += copy * channels;
        if (capture.frames == framesPerPacket) {
            emitPacket(mac->common.server, current);
            capture.frames = 0;
        }
    }
}

static int configureAudio(rdpShadowSubsystem *subsystem)
{
    const int result = shadowInit(subsystem);
    if (result < 0)
        return result;

    atomic_store_explicit(&audioBytesSent, 0, memory_order_relaxed);

    const size_t formatCount = sizeof(offeredFormats) / sizeof(offeredFormats[0]);
    AUDIO_FORMAT *formats = audio_formats_new(formatCount);
    if (!formats)
        return -1;
    memcpy(formats, offeredFormats, sizeof(offeredFormats));
    audio_formats_free(subsystem->rdpsndFormats, subsystem->nRdpsndFormats);
    subsystem->rdpsndFormats = formats;
    subsystem->nRdpsndFormats = formatCount;

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
    freeAllStreams();
    memset(&capture, 0, sizeof(capture));
    atomic_store_explicit(&audioBytesSent, 0, memory_order_relaxed);
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
