#ifndef MACREMOTE_CLIPBOARD_H
#define MACREMOTE_CLIPBOARD_H
#include <freerdp/server/shadow.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Starts per-client RDP cliprdr, backed by macOS NSPasteboard; no helper process. */
UINT mr_clipboard_client_connect(rdpShadowClient *client);
void mr_clipboard_client_disconnect(rdpShadowClient *client);
void mr_clipboard_shutdown(void);
/* Allocated result: canonical Windows CRLF on BOTH sides of the sync. */
char *mr_clipboard_crlf_utf8(const char *text);
#ifdef __cplusplus
}
#endif
#endif
