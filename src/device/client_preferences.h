#pragma once
#include <freerdp/server/shadow.h>
#include "shadow_stream_control.h"
#include "../stream/stream_profile.h"

void mr_client_preferences_init(const char *configPath);
void mr_client_preferences_default_bandwidth(MRBandwidthMode mode);
void mr_client_preferences_connect(rdpShadowClient *client);
void mr_client_preferences_disconnect(rdpShadowClient *client);
void mr_client_preferences_shutdown(void);

BOOL mr_client_preferences_stream_profile(const rdpShadowClient *client, ShadowStreamProfile *out);
UINT32 mr_client_preferences_capture_max_fps(void);
void mr_client_preferences_observe_stats(const rdpShadowClient *client,
                                         const ShadowStreamStats *stats);
