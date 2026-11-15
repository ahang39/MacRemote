#import <AppKit/AppKit.h>
#import <freerdp/server/cliprdr.h>
#import "../src/input/mac_clipboard.m"
#include <stdio.h>
#include <string.h>

#define MUST(x) do { if (!(x)) { \
    fprintf(stderr,"FAIL clipboard CRLF line %d: %s\n",__LINE__,#x);exit(1);} \
  } while(0)


static NSData *mockWire;
static UINT32 mockRequested;
static UINT32 mockOffered[4];
static UINT32 mockOfferedCount;
static UINT mock_response(CliprdrServerContext *ctx,
                          const CLIPRDR_FORMAT_DATA_RESPONSE *response)
{
    (void)ctx;
    MUST(response->common.msgFlags==CB_RESPONSE_OK);
    mockWire=[NSData dataWithBytes:response->requestedFormatData
                            length:response->common.dataLen];
    return CHANNEL_RC_OK;
}
static UINT mock_formats(CliprdrServerContext *ctx,const CLIPRDR_FORMAT_LIST *list)
{
    (void)ctx;
    mockOfferedCount=list->numFormats;
    for (UINT32 i=0;i<list->numFormats && i<4;i++)
        mockOffered[i]=list->formats[i].formatId;
    return CHANNEL_RC_OK;
}
static UINT mock_list_response(CliprdrServerContext *ctx,
                               const CLIPRDR_FORMAT_LIST_RESPONSE *response)
{
    (void)ctx;
    MUST(response->common.msgFlags==CB_RESPONSE_OK);
    return CHANNEL_RC_OK;
}
static UINT mock_request(CliprdrServerContext *ctx,
                         const CLIPRDR_FORMAT_DATA_REQUEST *request)
{
    (void)ctx;
    mockRequested=request->requestedFormatId;
    return CHANNEL_RC_OK;
}

int main(void) {
 @autoreleasepool {
    const char *examples[]={
        "", "single", "a\nb", "a\rb", "a\r\nb",
        "a\r\r\nb\n\nc\r", "\r\n", "\n\r",
        "你好\n世界", "a\n🦊\rb", NULL
    };
    const char *expected[]={
        "", "single", "a\r\nb", "a\r\nb", "a\r\nb",
        "a\r\n\r\nb\r\n\r\nc\r\n", "\r\n", "\r\n\r\n",
        "你好\r\n世界", "a\r\n🦊\r\nb"
    };
    for (int i=0;examples[i];i++) {
        char *got=mr_clipboard_crlf_utf8(examples[i]);
        MUST(got!=NULL && strcmp(got,expected[i])==0);
        char *again=mr_clipboard_crlf_utf8(got);
        MUST(again!=NULL && strcmp(got,again)==0);
        NSString *native=[NSString stringWithUTF8String:examples[i]];
        NSString *canon=mr_windows_lines(native);
        MUST([canon isEqualToString:[NSString stringWithUTF8String:expected[i]]]);
        NSData *wire=mr_utf16le_with_nul(canon);
        MUST(wire!=nil && wire.length>=2 && wire.length%2==0);
        const uint8_t *bytes=wire.bytes;
        MUST(bytes[wire.length-1]==0 && bytes[wire.length-2]==0);
        NSString *parsed=mr_parse_utf16le(bytes,wire.length);
        MUST([parsed isEqualToString:canon]);
        /* Isolate the pasteboard test from the user's real clipboard. */
        NSPasteboard *pb=[NSPasteboard pasteboardWithUniqueName];
        [pb clearContents];
        MUST([pb setString:canon forType:NSPasteboardTypeString]);
        MUST([[pb stringForType:NSPasteboardTypeString] isEqualToString:canon]);
        [pb releaseGlobally];
        free(got);free(again);
    }
    /* A Windows DIB round-trips via the Mac's native PNG pasteboard,
     * preserving dimensions and pixels without external conversion tools. */
    NSBitmapImageRep *image=[[NSBitmapImageRep alloc]
         initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:2 bitsPerSample:8
         samplesPerPixel:4 hasAlpha:YES isPlanar:NO
         colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    MUST(image!=nil);
    [image setColor:[NSColor redColor] atX:0 y:0];
    [image setColor:[NSColor greenColor] atX:1 y:0];
    [image setColor:[NSColor blueColor] atX:0 y:1];
    [image setColor:[NSColor whiteColor] atX:1 y:1];
    NSData *png=[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    MUST(png!=nil && png.length>0);
    NSData *dib=mr_png_to_dib(png);
    MUST(dib!=nil && dib.length>40);
    NSData *rebuilt=mr_dib_to_png(dib.bytes,dib.length);
    MUST(rebuilt!=nil);
    NSBitmapImageRep *converted=[NSBitmapImageRep imageRepWithData:rebuilt];
    MUST(converted.pixelsWide==2 && converted.pixelsHigh==2);
    NSPasteboard *pictureBoard=[NSPasteboard pasteboardWithUniqueName];
    [pictureBoard clearContents];
    MUST([pictureBoard setData:png forType:NSPasteboardTypePNG]);
    mr_clipboard_test_pasteboard=pictureBoard;
    MUST([mr_mac_png() isEqualToData:png]);
    mr_clipboard_test_pasteboard=nil;
    [pictureBoard releaseGlobally];

    /* Protocol callback-level integration. None of this accesses the
     * user's general pasteboard or requires an actual RDP connection. */
    NSPasteboard *remoteBoard=[NSPasteboard pasteboardWithUniqueName];
    [remoteBoard clearContents];
    mr_clipboard_test_pasteboard=remoteBoard;
    mr_clipboard_lock=[NSRecursiveLock new];
    mr_clipboard_sessions=[NSMutableDictionary dictionary];
    MRClipboardSession *session=[MRClipboardSession new];
    CliprdrServerContext channel={0};
    channel.custom=(__bridge void*)session;
    channel.ServerFormatList=mock_formats;
    channel.ServerFormatListResponse=mock_list_response;
    channel.ServerFormatDataRequest=mock_request;
    channel.ServerFormatDataResponse=mock_response;
    session.channel=&channel;
    session.ready=YES;
    session.client=(rdpShadowClient *)0x1234;
    mr_clipboard_sessions[[NSValue valueWithPointer:session.client]]=session;

    mr_clipboard_offer(session,@"你好\nWorld",png);
    MUST(mockOfferedCount==3);
    MUST(mockOffered[0]==CF_UNICODETEXT);
    MUST(mockOffered[1]==CF_DIB && mockOffered[2]==MR_CLIPBOARD_PNG_FORMAT);
    CLIPRDR_FORMAT_DATA_REQUEST req={0};
    req.requestedFormatId=CF_UNICODETEXT;
    MUST(mr_client_data_request(&channel,&req)==CHANNEL_RC_OK);
    MUST([mr_parse_utf16le(mockWire.bytes,mockWire.length)
          isEqualToString:@"你好\r\nWorld"]);
    req.requestedFormatId=CF_DIB;
    MUST(mr_client_data_request(&channel,&req)==CHANNEL_RC_OK);
    MUST(mockWire.length>40);
    req.requestedFormatId=MR_CLIPBOARD_PNG_FORMAT;
    MUST(mr_client_data_request(&channel,&req)==CHANNEL_RC_OK);
    MUST([mockWire isEqualToData:png]);

    CLIPRDR_FORMAT remoteFormat={0};
    remoteFormat.formatId=CF_UNICODETEXT;
    CLIPRDR_FORMAT_LIST remoteList={0};
    remoteList.numFormats=1;
    remoteList.formats=&remoteFormat;
    MUST(mr_client_format_list(&channel,&remoteList)==CHANNEL_RC_OK);
    MUST(mockRequested==CF_UNICODETEXT);
    NSData *remoteText=mr_utf16le_with_nul(@"Windows\nMac");
    CLIPRDR_FORMAT_DATA_RESPONSE response={0};
    response.common.msgFlags=CB_RESPONSE_OK;
    response.common.dataLen=(UINT32)remoteText.length;
    response.requestedFormatData=remoteText.bytes;
    MUST(mr_client_data_response(&channel,&response)==CHANNEL_RC_OK);
    MUST([[remoteBoard stringForType:NSPasteboardTypeString]
          isEqualToString:@"Windows\r\nMac"]);
    NSInteger change=remoteBoard.changeCount;
    MUST(mr_client_data_response(&channel,&response)==CHANNEL_RC_OK);
    MUST(remoteBoard.changeCount==change); /* no clipboard echo loop */
    MUST(mr_clipboard_last_seen==change);

    [remoteBoard clearContents];
    [remoteBoard setString:@"Mac\nnext" forType:NSPasteboardTypeString];
    mr_clipboard_poll();
    MUST([[remoteBoard stringForType:NSPasteboardTypeString]
          isEqualToString:@"Mac\r\nnext"]);
    MUST([session.snapshot isEqualToString:@"Mac\r\nnext"]);

    remoteFormat.formatId=CF_DIB;
    MUST(mr_client_format_list(&channel,&remoteList)==CHANNEL_RC_OK);
    MUST(mockRequested==CF_DIB);
    response.common.dataLen=(UINT32)dib.length;
    response.requestedFormatData=dib.bytes;
    MUST(mr_client_data_response(&channel,&response)==CHANNEL_RC_OK);
    MUST([remoteBoard dataForType:NSPasteboardTypePNG]!=nil);

    mr_clipboard_test_pasteboard=nil;
    [remoteBoard releaseGlobally];
    [mr_clipboard_sessions removeAllObjects];

    MUST(mr_clipboard_crlf_utf8(NULL)==NULL);
    MUST(mr_parse_utf16le((const uint8_t*)"\x00",1)==nil);
    puts("PASS: Mac and Windows clipboard text both use idempotent CRLF, UTF-16LE wire, UTF-8 and Unicode");
 }
 return 0;
}
