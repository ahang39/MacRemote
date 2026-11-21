#pragma once
#include <freerdp/server/shadow.h>
#include <stdbool.h>
#include <stdint.h>

int mr_remote_audio_shadow_entry(RDP_SHADOW_ENTRY_POINTS *entry);
void mr_remote_audio_attach(rdpShadowClient *client);
void mr_remote_audio_detach(rdpShadowClient *client);
void mr_remote_audio_set_volume(unsigned percent);
unsigned mr_remote_audio_volume(void);
void mr_remote_audio_set_bitrate(unsigned bps);
unsigned mr_remote_audio_bitrate(void);
void mr_remote_audio_set_prefer_lossless(bool preferLossless);
bool mr_remote_audio_prefer_lossless(void);
uint64_t mr_remote_audio_take_bytes_sent(void);
