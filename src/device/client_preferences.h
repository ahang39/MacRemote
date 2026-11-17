#pragma once
#include <freerdp/server/shadow.h>

void mr_client_preferences_init(const char *configPath);
void mr_client_preferences_connect(rdpShadowClient *client);
void mr_client_preferences_disconnect(rdpShadowClient *client);
void mr_client_preferences_shutdown(void);
UINT32 mr_client_preferences_video_bitrate(const rdpShadowClient *client);
