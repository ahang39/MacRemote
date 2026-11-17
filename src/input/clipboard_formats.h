#ifndef MACREMOTE_CLIPBOARD_FORMATS_H
#define MACREMOTE_CLIPBOARD_FORMATS_H

#import <AppKit/AppKit.h>

NSString *mr_clipboard_mac_lines(NSString *text);
NSString *mr_clipboard_windows_lines(NSString *text);
NSData *mr_clipboard_encode_unicode(NSString *text);
NSString *mr_clipboard_decode_unicode(const uint8_t *bytes, size_t length);
NSData *mr_clipboard_png_from_pasteboard(NSPasteboard *pasteboard);
NSData *mr_clipboard_dib_from_png(NSData *png);
NSData *mr_clipboard_png_from_dib(const uint8_t *bytes, size_t length);

#endif
