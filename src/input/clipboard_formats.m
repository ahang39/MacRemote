#import "clipboard_formats.h"

NSString *mr_clipboard_mac_lines(NSString *text)
{
    if (!text) return nil;
    NSString *normalized = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    return [normalized stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
}

NSString *mr_clipboard_windows_lines(NSString *text)
{
    if (!text) return nil;
    return [mr_clipboard_mac_lines(text) stringByReplacingOccurrencesOfString:@"\n"
                                                                  withString:@"\r\n"];
}

NSData *mr_clipboard_encode_unicode(NSString *text)
{
    NSData *encoded = [mr_clipboard_windows_lines(text ?: @"")
        dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    NSMutableData *payload = [NSMutableData dataWithData:encoded ?: NSData.data];
    const uint8_t terminator[] = {0, 0};
    [payload appendBytes:terminator length:sizeof(terminator)];
    return payload;
}

NSString *mr_clipboard_decode_unicode(const uint8_t *bytes, size_t length)
{
    if (!bytes || length < 2 || (length % 2)) return nil;
    size_t end = length;
    for (size_t i = 0; i + 1 < length; i += 2) {
        if (bytes[i] == 0 && bytes[i + 1] == 0) {
            end = i;
            break;
        }
    }
    NSData *data = [NSData dataWithBytes:bytes length:end];
    NSString *text = [[NSString alloc] initWithData:data
                                             encoding:NSUTF16LittleEndianStringEncoding];
    return mr_clipboard_mac_lines(text);
}

NSData *mr_clipboard_png_from_pasteboard(NSPasteboard *pasteboard)
{
    NSData *png = [pasteboard dataForType:NSPasteboardTypePNG];
    if (png) return png;
    NSData *tiff = [pasteboard dataForType:NSPasteboardTypeTIFF];
    if (!tiff) return nil;
    NSBitmapImageRep *image = [NSBitmapImageRep imageRepWithData:tiff];
    return [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static uint32_t read32(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static void write32(uint8_t *bytes, uint32_t value)
{
    for (int i = 0; i < 4; i++)
        bytes[i] = (uint8_t)(value >> (8 * i));
}

NSData *mr_clipboard_dib_from_png(NSData *png)
{
    if (!png) return nil;
    NSBitmapImageRep *image = [NSBitmapImageRep imageRepWithData:png];
    NSData *bmp = [image representationUsingType:NSBitmapImageFileTypeBMP properties:@{}];
    if (bmp.length <= 54) return nil;
    const uint8_t *bytes = bmp.bytes;
    if (bytes[0] != 'B' || bytes[1] != 'M') return nil;
    return [bmp subdataWithRange:NSMakeRange(14, bmp.length - 14)];
}

NSData *mr_clipboard_png_from_dib(const uint8_t *bytes, size_t length)
{
    if (!bytes || length < 40 || length > UINT32_MAX - 14) return nil;
    const uint32_t headerSize = read32(bytes);
    if (headerSize < 40 || headerSize > length) return nil;
    const uint16_t depth = (uint16_t)(bytes[14] | ((uint16_t)bytes[15] << 8));
    const uint32_t colors = read32(bytes + 32);
    uint64_t offset = headerSize;
    if (depth <= 8)
        offset += (uint64_t)(colors ? colors : (1u << depth)) * 4;
    else if (headerSize == 40 && read32(bytes + 16) == 3)
        offset += 12;
    if (offset > length) return nil;

    NSMutableData *bmp = [NSMutableData dataWithLength:14];
    uint8_t *header = bmp.mutableBytes;
    header[0] = 'B';
    header[1] = 'M';
    write32(header + 2, (uint32_t)length + 14);
    write32(header + 10, (uint32_t)offset + 14);
    [bmp appendBytes:bytes length:length];

    NSBitmapImageRep *image = [NSBitmapImageRep imageRepWithData:bmp];
    return [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
