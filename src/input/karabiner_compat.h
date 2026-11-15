#ifndef MACREMOTE_KARABINER_COMPAT_H
#define MACREMOTE_KARABINER_COMPAT_H

#include <CoreGraphics/CoreGraphics.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* An optional mapping layer inside the MacRemote RDP server.
 * An absent/unreadable Karabiner configuration always passes raw events through.
 * The filter takes ownership of event and returns an owned event or NULL. */
void mr_compat_initialize(const char *config_path);
void mr_compat_shutdown(void);
void mr_compat_set_client(const void *client);
void mr_compat_set_unicode_input(bool enabled);
void mr_compat_client_disconnected(const void *client);
CGEventRef mr_compat_filter_event(CGEventRef event);
void mr_compat_status(char *output, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
