#pragma once
#include <freerdp/server/shadow.h>

int mr_remote_audio_shadow_entry(RDP_SHADOW_ENTRY_POINTS *entry);
void mr_remote_audio_attach(rdpShadowClient *client);
void mr_remote_audio_set_volume(unsigned percent);
unsigned mr_remote_audio_volume(void);
