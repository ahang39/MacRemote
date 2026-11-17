#ifndef MACREMOTE_CLIPBOARD_H
#define MACREMOTE_CLIPBOARD_H
#include <freerdp/server/shadow.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Starts per-client RDP cliprdr, backed by macOS NSPasteboard; no helper process. */
UINT mr_clipboard_client_connect(rdpShadowClient *client);
void mr_clipboard_client_disconnect(rdpShadowClient *client);
void mr_clipboard_shutdown(void);
#ifdef __cplusplus
}
#endif
#endif
