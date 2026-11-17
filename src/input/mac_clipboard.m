#import "mac_clipboard.h"
#import "clipboard_formats.h"

#import <AppKit/AppKit.h>
#import <freerdp/server/cliprdr.h>
#import <winpr/user.h>
#import <dispatch/dispatch.h>
#include <strings.h>

#define MR_CLIPBOARD_PNG_FORMAT 0xC001

typedef struct {
    UINT32 text;
    UINT32 image;
} MRClipboardFormats;

@interface MRClipboardSession : NSObject
@property(nonatomic,assign) CliprdrServerContext *channel;
@property(nonatomic,assign) BOOL closing;
@property(nonatomic,assign) BOOL ready;
@property(nonatomic,assign) NSInteger lastChange;
@property(nonatomic,copy) NSString *snapshot;
@property(nonatomic,strong) NSData *imageSnapshot;
@property(nonatomic,assign) UINT32 pendingRemoteFormat;
@property(nonatomic,assign) MRClipboardFormats remoteFormats;
@property(nonatomic,assign) BOOL discardResponse;
@property(nonatomic,assign) NSInteger remoteOfferChange;
@property(nonatomic,copy) NSString *receivedText;
@end
@implementation MRClipboardSession
@end

static NSRecursiveLock *mr_clipboard_lock;
static NSMutableDictionary<NSValue*,MRClipboardSession*> *mr_clipboard_sessions;
static dispatch_source_t mr_clipboard_timer;
static NSInteger mr_clipboard_last_seen = -1;
static NSPasteboard *mr_clipboard_pasteboard;
static NSPasteboard *mr_board(void)
{
    return mr_clipboard_pasteboard ?: NSPasteboard.generalPasteboard;
}

static void mr_clipboard_offer(MRClipboardSession *session, NSString *text, NSData *png)
{
    if (!session.ready) return;
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
    NSString *text = [pb stringForType:NSPasteboardTypeString];
    NSData *png = mr_clipboard_png_from_pasteboard(pb);
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
        NSPasteboard *board = mr_board();
        session.ready = YES;
        session.lastChange = board.changeCount;
        mr_clipboard_offer(session, [board stringForType:NSPasteboardTypeString],
                           mr_clipboard_png_from_pasteboard(board));
    }
    [mr_clipboard_lock unlock];
    return CHANNEL_RC_OK;
}

// CLIPRDR responses carry no format ID. Keep one request in flight and retain
// only the latest offer while waiting for a superseded response to drain.
static UINT mr_request_next_format(MRClipboardSession *session)
{
    MRClipboardFormats formats = session.remoteFormats;
    UINT32 format;
    if (formats.text) {
        format = formats.text;
        formats.text = 0;
    } else {
        format = formats.image;
        formats.image = 0;
    }
    if (!format) return CHANNEL_RC_OK;

    session.remoteFormats = formats;
    session.pendingRemoteFormat = format;
    CLIPRDR_FORMAT_DATA_REQUEST request = {0};
    request.common.msgType = CB_FORMAT_DATA_REQUEST;
    request.requestedFormatId = format;
    CliprdrServerContext *channel = session.channel;
    return channel->ServerFormatDataRequest(channel, &request);
}

static UINT mr_client_format_list(CliprdrServerContext *channel,
                                 const CLIPRDR_FORMAT_LIST *list)
{
    CLIPRDR_FORMAT_LIST_RESPONSE response = {0};
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    UINT rc = channel->ServerFormatListResponse(channel, &response);
    if (rc != CHANNEL_RC_OK) return rc;

    UINT32 png = 0, dib = 0, text = 0;
    for (UINT32 i = 0; i < list->numFormats; i++) {
        const CLIPRDR_FORMAT *format = &list->formats[i];
        if (format->formatId == CF_UNICODETEXT) text = format->formatId;
        if (format->formatId == CF_DIB) dib = format->formatId;
        if (format->formatName && strcasecmp(format->formatName, "PNG") == 0)
            png = format->formatId;
    }

    MRClipboardSession *session = mr_session(channel);
    [mr_clipboard_lock lock];
    if (!session.closing) {
        session.remoteFormats = (MRClipboardFormats){text, png ? png : dib};
        session.remoteOfferChange = mr_board().changeCount;
        session.receivedText = nil;
        session.discardResponse = session.pendingRemoteFormat != 0;
        if (!session.discardResponse)
            rc = mr_request_next_format(session);
    }
    [mr_clipboard_lock unlock];
    return rc;
}

static void mr_commit_remote_clipboard(MRClipboardSession *session,
                                      NSString *text, NSData *png)
{
    NSPasteboard *board = mr_board();
    if ((!text && !png) || board.changeCount != session.remoteOfferChange)
        return;

    NSString *existingText = [board stringForType:NSPasteboardTypeString];
    NSData *existingPNG = mr_clipboard_png_from_pasteboard(board);
    BOOL sameText = text == existingText || [text isEqualToString:existingText];
    BOOL sameImage = png == existingPNG || [png isEqualToData:existingPNG];
    if (board.changeCount != session.remoteOfferChange)
        return;
    if (!sameText || !sameImage) {
        [board clearContents];
        if (text) [board setString:text forType:NSPasteboardTypeString];
        if (png) [board setData:png forType:NSPasteboardTypePNG];
    }

    NSInteger change = board.changeCount;
    mr_clipboard_last_seen = change;
    session.lastChange = change;
    for (MRClipboardSession *other in mr_clipboard_sessions.allValues) {
        if (other == session) continue;
        other.lastChange = change;
        mr_clipboard_offer(other, text, png);
    }
}

static UINT mr_client_data_response(CliprdrServerContext *channel,
                                    const CLIPRDR_FORMAT_DATA_RESPONSE *response)
{
    MRClipboardSession *session = mr_session(channel);
    [mr_clipboard_lock lock];
    UINT rc = CHANNEL_RC_OK;
    UINT32 format = session.pendingRemoteFormat;
    if (session.closing || !format) {
        [mr_clipboard_lock unlock];
        return rc;
    }

    session.pendingRemoteFormat = 0;
    if (session.discardResponse) {
        session.discardResponse = NO;
        rc = mr_request_next_format(session);
        [mr_clipboard_lock unlock];
        return rc;
    }

    NSString *text = session.receivedText;
    NSData *png = nil;
    if (response->common.msgFlags & CB_RESPONSE_OK) {
        const BYTE *data = response->requestedFormatData;
        size_t length = response->common.dataLen;
        if (format == CF_UNICODETEXT)
            text = mr_clipboard_decode_unicode(data, length);
        else if (format == CF_DIB)
            png = mr_clipboard_png_from_dib(data, length);
        else if (data) {
            NSData *encoded = [NSData dataWithBytes:data length:length];
            if ([NSBitmapImageRep imageRepWithData:encoded])
                png = encoded;
        }
    }

    if (session.remoteFormats.image) {
        session.receivedText = text;
        rc = mr_request_next_format(session);
    } else {
        session.receivedText = nil;
        mr_commit_remote_clipboard(session, text, png);
    }
    [mr_clipboard_lock unlock];
    return rc;
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
            payload=session.snapshot ? mr_clipboard_encode_unicode(session.snapshot) : nil;
        else if (request->requestedFormatId==MR_CLIPBOARD_PNG_FORMAT)
            payload=session.imageSnapshot;
        else if (request->requestedFormatId==CF_DIB)
            payload=mr_clipboard_dib_from_png(session.imageSnapshot);
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
        if (session) {
            session.channel->Stop(session.channel);
            cliprdr_server_context_free(session.channel);
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
