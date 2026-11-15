#import "mac_clipboard.h"

#import <AppKit/AppKit.h>
#import <freerdp/server/cliprdr.h>
#import <winpr/user.h>
#import <dispatch/dispatch.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>

#define MR_CLIPBOARD_TEXT_FORMAT CF_UNICODETEXT
#define MR_CLIPBOARD_PNG_FORMAT 0xC001

/* A single native clipboard is shared by all RDP clients. Their cliprdr
 * channels remain independent; the RDP server and AppKit are the only
 * runtime components. */
@interface MRClipboardSession : NSObject
@property(nonatomic,assign) rdpShadowClient *client;
@property(nonatomic,assign) CliprdrServerContext *channel;
@property(nonatomic,assign) BOOL closing;
@property(nonatomic,assign) BOOL ready;
@property(nonatomic,assign) BOOL textOffered;
@property(nonatomic,assign) NSInteger lastChange;
@property(nonatomic,copy) NSString *snapshot;
@property(nonatomic,strong) NSData *imageSnapshot;
@property(nonatomic,assign) UINT32 pendingRemoteFormat;
@end
@implementation MRClipboardSession
@end

static NSRecursiveLock *mr_clipboard_lock;
static NSMutableDictionary<NSValue*,MRClipboardSession*> *mr_clipboard_sessions;
static dispatch_source_t mr_clipboard_timer;
static NSInteger mr_clipboard_last_seen = -1;
/* Tests use an isolated pasteboard; production always uses the system board. */
static NSPasteboard *mr_clipboard_test_pasteboard;
static NSPasteboard *mr_board(void)
{
    return mr_clipboard_test_pasteboard ?: [NSPasteboard generalPasteboard];
}


char *mr_clipboard_crlf_utf8(const char *text)
{
    if (!text) return NULL;
    size_t size = strlen(text);
    if (size > (SIZE_MAX - 1)/2) return NULL;
    char *out = malloc(size * 2 + 1);
    if (!out) return NULL;
    size_t w=0;
    for (size_t i=0; i<size; i++) {
        char c=text[i];
        if (c == '\r') {
            if (i+1<size && text[i+1]=='\n') i++;
            out[w++]='\r';
            out[w++]='\n';
        } else if (c == '\n') {
            out[w++]='\r';
            out[w++]='\n';
        } else {
            out[w++]=c;
        }
    }
    out[w]='\0';
    return out;
}

static NSString *mr_windows_lines(NSString *text)
{
    if (!text) return nil;
    /* Replacing CRLF before solitary CR/LF makes this transformation
     * idempotent; output is always Windows CRLF, even on the Mac pasteboard. */
    NSString *s=[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    s=[s stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    return [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\r\n"];
}

static NSString *mr_mac_text(void)
{
    return mr_windows_lines([mr_board() stringForType:NSPasteboardTypeString]);
}

/* CoreGraphics/AppKit already understands BMP/PNG/TIFF; RDP's CF_DIB is
 * precisely BMP with its 14-byte BITMAPFILEHEADER removed. */
static NSData *mr_mac_png(void)
{
    NSPasteboard *pb=mr_board();
    NSData *png=[pb dataForType:NSPasteboardTypePNG];
    if (png) return png;
    NSData *tiff=[pb dataForType:NSPasteboardTypeTIFF];
    if (!tiff) return nil;
    NSBitmapImageRep *rep=[NSBitmapImageRep imageRepWithData:tiff];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static uint32_t mr_le32(const uint8_t *p)
{
    return ((uint32_t)p[0])|((uint32_t)p[1]<<8)|
           ((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);
}
static void mr_put32(uint8_t *p, uint32_t value)
{
    for (NSUInteger i=0;i<4;i++) p[i]=(uint8_t)(value >> (8*i));
}
static NSData *mr_png_to_dib(NSData *png)
{
    if (!png) return nil;
    NSBitmapImageRep *rep=[NSBitmapImageRep imageRepWithData:png];
    NSData *bmp=[rep representationUsingType:NSBitmapImageFileTypeBMP properties:@{}];
    const uint8_t *bytes=bmp.bytes;
    if (bmp.length<=54 || bytes[0]!='B' || bytes[1]!='M') return nil;
    return [bmp subdataWithRange:NSMakeRange(14,bmp.length-14)];
}
static NSData *mr_dib_to_png(const uint8_t *bytes, size_t count)
{
    if (!bytes || count<40 || count>UINT32_MAX-14) return nil;
    uint32_t headerSize=mr_le32(bytes);
    if (headerSize<40 || headerSize>count) return nil;
    uint16_t bits=(uint16_t)(bytes[14]|((uint16_t)bytes[15]<<8));
    uint32_t colors=mr_le32(bytes+32);
    uint32_t offset=headerSize;
    if (bits<=8) offset += (colors ? colors : (1u<<bits))*4u;
    else if (headerSize==40 && mr_le32(bytes+16)==3) offset+=12;
    if (offset>count) return nil;
    NSMutableData *bmp=[NSMutableData dataWithLength:14];
    uint8_t *head=bmp.mutableBytes;
    head[0]='B';head[1]='M';
    mr_put32(head+2,(uint32_t)count+14);
    mr_put32(head+10,offset+14);
    [bmp appendBytes:bytes length:count];
    NSBitmapImageRep *rep=[NSBitmapImageRep imageRepWithData:bmp];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static NSData *mr_utf16le_with_nul(NSString *text)
{
    NSData *utf16 = [mr_windows_lines(text ?: @"") dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    NSMutableData *data=[NSMutableData dataWithData:utf16 ?: NSData.data];
    uint8_t nul[2]={0,0};
    [data appendBytes:nul length:2];
    return data;
}

static NSString *mr_parse_utf16le(const BYTE *bytes, size_t length)
{
    if (!bytes || length < 2 || (length % 2)) return nil;
    size_t end=length;
    for (size_t i=0;i+1<length;i+=2)
        if (bytes[i]==0 && bytes[i+1]==0) { end=i;break; }
    NSData *data=[NSData dataWithBytes:bytes length:end];
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF16LittleEndianStringEncoding];
    return mr_windows_lines(text);
}

static void mr_clipboard_offer(MRClipboardSession *session, NSString *text, NSData *png)
{
    if (!session || session.closing || !session.ready || !session.channel) return;
    CLIPRDR_FORMAT formats[3]={0};
    UINT32 count=0;
    if (text) {
        formats[count++].formatId=CF_UNICODETEXT;
    }
    if (png) {
        formats[count++].formatId=CF_DIB;
        formats[count].formatId=MR_CLIPBOARD_PNG_FORMAT;
        formats[count++].formatName="PNG";
    }
    CLIPRDR_FORMAT_LIST list={0};
    list.common.msgType=CB_FORMAT_LIST;
    list.numFormats=count;
    list.formats=count ? formats : NULL;
    session.snapshot=[text copy];
    session.imageSnapshot=png;
    UINT rc=session.channel->ServerFormatList(session.channel,&list);
    if (rc != CHANNEL_RC_OK)
        fprintf(stderr,"MacRemote clipboard: send format list failed (%u)\n",rc);
}

static void mr_clipboard_poll(void)
{
    [mr_clipboard_lock lock];
    if (!mr_clipboard_sessions.count) {
        [mr_clipboard_lock unlock];
        return;
    }
    NSPasteboard *pb=mr_board();
    NSInteger change=pb.changeCount;
    if (mr_clipboard_last_seen==change) {
        [mr_clipboard_lock unlock];
        return;
    }
    mr_clipboard_last_seen=change;
    NSString *source=[pb stringForType:NSPasteboardTypeString];
    NSString *text=mr_windows_lines(source);
    if (source && ![source isEqualToString:text]) {
        /* Windows CRLF on the Mac pasteboard as well. Preserve other types. */
        if ([pb setString:text forType:NSPasteboardTypeString])
            mr_clipboard_last_seen=change=pb.changeCount;
    }
    NSData *png=mr_mac_png();
    for (MRClipboardSession *session in mr_clipboard_sessions.allValues) {
        if (session.lastChange==change) continue;
        session.lastChange=change;
        mr_clipboard_offer(session,text,png);
    }
    [mr_clipboard_lock unlock];
}

static void mr_clipboard_begin_polling(void)
{
    if (mr_clipboard_timer) return;
    dispatch_queue_t queue=dispatch_queue_create("dev.macremote.clipboard",DISPATCH_QUEUE_SERIAL);
    mr_clipboard_timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
    dispatch_source_set_timer(mr_clipboard_timer, dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),
                              250*NSEC_PER_MSEC,50*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(mr_clipboard_timer, ^{
        @autoreleasepool { mr_clipboard_poll(); }
    });
    dispatch_resume(mr_clipboard_timer);
}

static MRClipboardSession *mr_session(CliprdrServerContext *channel)
{
    return (__bridge MRClipboardSession *)channel->custom;
}

static UINT mr_client_capabilities(CliprdrServerContext *channel,
                                  const CLIPRDR_CAPABILITIES *caps)
{
    (void)caps;
    MRClipboardSession *session=mr_session(channel);
    [mr_clipboard_lock lock];
    if (!session.closing) {
        session.ready=YES;
        mr_clipboard_offer(session,mr_mac_text(),mr_mac_png());
    }
    [mr_clipboard_lock unlock];
    return CHANNEL_RC_OK;
}

static UINT mr_client_format_list(CliprdrServerContext *channel,
                                 const CLIPRDR_FORMAT_LIST *list)
{
    MRClipboardSession *session=mr_session(channel);
    CLIPRDR_FORMAT_LIST_RESPONSE response={0};
    response.common.msgType=CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags=CB_RESPONSE_OK;
    UINT rc=channel->ServerFormatListResponse(channel,&response);
    if (rc!=CHANNEL_RC_OK) return rc;

    UINT32 format=0;
    UINT32 png=0, dib=0, text=0;
    for (UINT32 i=0;i<list->numFormats;i++) {
        const CLIPRDR_FORMAT *f=&list->formats[i];
        if (f->formatId==CF_UNICODETEXT) text=f->formatId;
        if (f->formatId==CF_DIB) dib=f->formatId;
        if (f->formatName && strcasecmp(f->formatName,"PNG")==0)
            png=f->formatId;
    }
    /* Prefer native Unicode text for mixed rich content. When the source
     * is a screenshot/image, standard CF_DIB or negotiated PNG is used. */
    format=text ? text : png ? png : dib;
    [mr_clipboard_lock lock];
    session.textOffered=(format==CF_UNICODETEXT);
    session.pendingRemoteFormat=format;
    [mr_clipboard_lock unlock];
    if (format) {
        CLIPRDR_FORMAT_DATA_REQUEST request={0};
        request.common.msgType=CB_FORMAT_DATA_REQUEST;
        request.requestedFormatId=format;
        return channel->ServerFormatDataRequest(channel,&request);
    }
    return CHANNEL_RC_OK;
}

static UINT mr_client_data_response(CliprdrServerContext *channel,
                                    const CLIPRDR_FORMAT_DATA_RESPONSE *response)
{
    if (!(response->common.msgFlags & CB_RESPONSE_OK)) return CHANNEL_RC_OK;
    MRClipboardSession *session=mr_session(channel);
    [mr_clipboard_lock lock];
    if (session.closing) {
        [mr_clipboard_lock unlock];
        return CHANNEL_RC_OK;
    }
    UINT32 format=session.pendingRemoteFormat;
    NSString *text=nil;
    NSData *png=nil;
    if (format==CF_UNICODETEXT)
        text=mr_parse_utf16le(response->requestedFormatData,response->common.dataLen);
    else if (format==CF_DIB)
        png=mr_dib_to_png(response->requestedFormatData,response->common.dataLen);
    else if (format)
        png=[NSData dataWithBytes:response->requestedFormatData
                           length:response->common.dataLen];
    if (!text && !png) {
        [mr_clipboard_lock unlock];
        return CHANNEL_RC_OK;
    }
    NSPasteboard *pb=mr_board();
    NSString *existing=mr_mac_text();
    NSData *existingPNG=mr_mac_png();
    BOOL same=(text && [text isEqualToString:existing] && !existingPNG) ||
              (png && [png isEqualToData:existingPNG] && !existing);
    if (!same) {
        [pb clearContents];
        if (text) [pb setString:text forType:NSPasteboardTypeString];
        if (png) [pb setData:png forType:NSPasteboardTypePNG];
    }
    mr_clipboard_last_seen=pb.changeCount;
    session.lastChange=pb.changeCount;
    /* Notify all OTHER Windows connections, no clipboard echo to the source. */
    for (MRClipboardSession *other in mr_clipboard_sessions.allValues)
        if (other!=session) {
            other.lastChange=pb.changeCount;
            mr_clipboard_offer(other,text,png);
        }
    [mr_clipboard_lock unlock];
    return CHANNEL_RC_OK;
}

static UINT mr_client_data_request(CliprdrServerContext *channel,
                                   const CLIPRDR_FORMAT_DATA_REQUEST *request)
{
    MRClipboardSession *session=mr_session(channel);
    CLIPRDR_FORMAT_DATA_RESPONSE response={0};
    response.common.msgType=CB_FORMAT_DATA_RESPONSE;
    NSData *payload=nil;
    [mr_clipboard_lock lock];
    if (!session.closing) {
        if (request->requestedFormatId==CF_UNICODETEXT)
            payload=mr_utf16le_with_nul(session.snapshot ?: mr_mac_text());
        else if (request->requestedFormatId==MR_CLIPBOARD_PNG_FORMAT)
            payload=session.imageSnapshot ?: mr_mac_png();
        else if (request->requestedFormatId==CF_DIB)
            payload=mr_png_to_dib(session.imageSnapshot ?: mr_mac_png());
    }
    [mr_clipboard_lock unlock];
    if (payload && payload.length<=UINT32_MAX) {
        response.common.msgFlags=CB_RESPONSE_OK;
        response.common.dataLen=(UINT32)payload.length;
        response.requestedFormatData=payload.bytes;
    } else {
        response.common.msgFlags=CB_RESPONSE_FAIL;
    }
    return channel->ServerFormatDataResponse(channel,&response);
}

UINT mr_clipboard_client_connect(rdpShadowClient *client)
{
    @autoreleasepool {
        if (!client || !client->vcm) return ERROR_INVALID_PARAMETER;
        static dispatch_once_t once;
        dispatch_once(&once,^{
            mr_clipboard_lock=[NSRecursiveLock new];
            mr_clipboard_sessions=[NSMutableDictionary dictionary];
        });
        CliprdrServerContext *channel=cliprdr_server_context_new(client->vcm);
        if (!channel) return ERROR_NOT_ENOUGH_MEMORY;
        MRClipboardSession *session=[MRClipboardSession new];
        session.client=client;
        session.channel=channel;
        session.lastChange=-1;
        channel->custom=(__bridge void*)session;
        channel->rdpcontext=&client->context;
        channel->ClientCapabilities=mr_client_capabilities;
        channel->ClientFormatList=mr_client_format_list;
        channel->ClientFormatDataResponse=mr_client_data_response;
        channel->ClientFormatDataRequest=mr_client_data_request;

        [mr_clipboard_lock lock];
        mr_clipboard_sessions[[NSValue valueWithPointer:client]]=session;
        mr_clipboard_begin_polling();
        [mr_clipboard_lock unlock];

        UINT rc=channel->Start(channel);
        if (rc!=CHANNEL_RC_OK) {
            [mr_clipboard_lock lock];
            session.closing=YES;
            [mr_clipboard_sessions removeObjectForKey:[NSValue valueWithPointer:client]];
            [mr_clipboard_lock unlock];
            cliprdr_server_context_free(channel);
            return rc;
        }
        fprintf(stdout,"MacRemote clipboard: cliprdr channel started\n");
        fflush(stdout);
        return CHANNEL_RC_OK;
    }
}

void mr_clipboard_client_disconnect(rdpShadowClient *client)
{
    if (!mr_clipboard_lock || !client) return;
    @autoreleasepool {
        [mr_clipboard_lock lock];
        NSValue *key=[NSValue valueWithPointer:client];
        MRClipboardSession *session=mr_clipboard_sessions[key];
        if (session) {
            session.closing=YES;
            [mr_clipboard_sessions removeObjectForKey:key];
        }
        [mr_clipboard_lock unlock];
        if (session && session.channel) {
            session.channel->Stop(session.channel);
            cliprdr_server_context_free(session.channel);
            session.channel=NULL;
        }
    }
}

void mr_clipboard_shutdown(void)
{
    if (!mr_clipboard_lock) return;
    @autoreleasepool {
        [mr_clipboard_lock lock];
        NSArray *clients=[mr_clipboard_sessions.allKeys copy];
        [mr_clipboard_lock unlock];
        for (NSValue *key in clients) mr_clipboard_client_disconnect(key.pointerValue);
        [mr_clipboard_lock lock];
        if (mr_clipboard_timer) {
            dispatch_source_cancel(mr_clipboard_timer);
            mr_clipboard_timer=nil;
        }
        mr_clipboard_last_seen=-1;
        [mr_clipboard_lock unlock];
    }
}
