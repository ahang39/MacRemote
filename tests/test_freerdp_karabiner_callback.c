#include <ApplicationServices/ApplicationServices.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <freerdp/input.h>
#include <freerdp/server/shadow.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include "../src/input/karabiner_compat.h"

/* Link-time strong symbol override. This test NEVER posts to WindowServer.
 * Verify nm shows this executable defines _CGEventPost before executing. */
static struct {
  unsigned count;
  CGEventTapLocation location;
  CGEventType type;
  CGKeyCode code;
  CGEventFlags flags;
} captured;

void CGEventPost(CGEventTapLocation location, CGEventRef event) {
  captured.count++;
  captured.location=location;
  captured.type=CGEventGetType(event);
  captured.code=(CGKeyCode)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
  captured.flags=CGEventGetFlags(event);
}

#define CHECK(c) do { if(!(c)) {fprintf(stderr,"FAIL %s:%d %s (count=%u key=0x%x flags=0x%llx type=%d)\n",\
 __FILE__,__LINE__,#c,captured.count,(unsigned)captured.code,(unsigned long long)captured.flags,(int)captured.type);return 1;} } while(0)

extern int ShadowSubsystemEntry(RDP_SHADOW_ENTRY_POINTS *entryPoints);
extern void mac_shadow_set_input_filter(CGEventRef (*filter)(CGEventRef));

static int check_event(rdpShadowSubsystem *sub, UINT16 flags, UINT8 code, CGEventType type,
                CGKeyCode expectedCode, CGEventFlags expectedFlags, CGEventFlags mask)
{
 memset(&captured,0,sizeof(captured));
 rdpShadowClient *client=(rdpShadowClient *)(uintptr_t)1; /* callback only checks non-NULL */
 CHECK(sub->KeyboardEvent(sub,client,flags,code) == TRUE);
 CHECK(captured.count==1);
 CHECK(captured.location==kCGHIDEventTap);
 CHECK(captured.type==type);
 CHECK(captured.code==expectedCode);
 CHECK((captured.flags&mask)==expectedFlags);
 return 0;
}
static int pair(rdpShadowSubsystem* sub, UINT16 leftflags, UINT8 leftscan,
                UINT16 rightflags, UINT8 rightscan,
                CGKeyCode leftkey, CGKeyCode rightkey,
                CGEventFlags left, CGEventFlags right, CGEventFlags group)
{
  const CGEventFlags mask=left|right|group;
  CHECK(check_event(sub,leftflags,leftscan,kCGEventFlagsChanged,leftkey,left|group,mask)==0);
  CHECK(check_event(sub,rightflags,rightscan,kCGEventFlagsChanged,rightkey,left|right|group,mask)==0);
  CHECK(check_event(sub,leftflags|KBD_FLAGS_RELEASE,leftscan,kCGEventFlagsChanged,leftkey,right|group,mask)==0);
  CHECK(check_event(sub,rightflags|KBD_FLAGS_RELEASE,rightscan,kCGEventFlagsChanged,rightkey,0,mask)==0);
  return 0;
}
int main(void) {
 RDP_SHADOW_ENTRY_POINTS ep={0};
 CHECK(ShadowSubsystemEntry(&ep) > 0);
 CHECK(ep.New && ep.Free);
 rdpShadowSubsystem *sub=ep.New();
 CHECK(sub && sub->KeyboardEvent);
 CHECK(pair(sub,0,0x1d,KBD_FLAGS_EXTENDED,0x1d,
       0x3b,0x3e,NX_DEVICELCTLKEYMASK,NX_DEVICERCTLKEYMASK,kCGEventFlagMaskControl)==0);
 CHECK(pair(sub,0,0x2a,0,0x36,
       0x38,0x3c,NX_DEVICELSHIFTKEYMASK,NX_DEVICERSHIFTKEYMASK,kCGEventFlagMaskShift)==0);
 CHECK(pair(sub,0,0x38,KBD_FLAGS_EXTENDED,0x38,
       0x3a,0x3d,NX_DEVICELALTKEYMASK,NX_DEVICERALTKEYMASK,kCGEventFlagMaskAlternate)==0);
 CHECK(pair(sub,KBD_FLAGS_EXTENDED,0x5b,KBD_FLAGS_EXTENDED,0x5c,
       0x37,0x36,NX_DEVICELCMDKEYMASK,NX_DEVICERCMDKEYMASK,kCGEventFlagMaskCommand)==0);
 CHECK(check_event(sub,0,0x1d,kCGEventFlagsChanged,0x3b,
       NX_DEVICELCTLKEYMASK|kCGEventFlagMaskControl,
       NX_DEVICELCTLKEYMASK|kCGEventFlagMaskControl)==0);
 CHECK(check_event(sub,0,0x2e,kCGEventKeyDown,0x08,
       NX_DEVICELCTLKEYMASK|kCGEventFlagMaskControl,
       NX_DEVICELCTLKEYMASK|kCGEventFlagMaskControl)==0);
 CHECK(check_event(sub,KBD_FLAGS_RELEASE,0x2e,kCGEventKeyUp,0x08,
       NX_DEVICELCTLKEYMASK|kCGEventFlagMaskControl,
       NX_DEVICELCTLKEYMASK|kCGEventFlagMaskControl)==0);
 CHECK(check_event(sub,KBD_FLAGS_RELEASE,0x1d,kCGEventFlagsChanged,0x3b,0,
       NX_DEVICELCTLKEYMASK|kCGEventFlagMaskControl)==0);
 CHECK(check_event(sub,KBD_FLAGS_EXTENDED,0x52,kCGEventKeyDown,0x72,0,0)==0);
 CHECK(check_event(sub,KBD_FLAGS_EXTENDED|KBD_FLAGS_RELEASE,0x52,kCGEventKeyUp,0x72,0,0)==0);
 CHECK(check_event(sub,KBD_FLAGS_EXTENDED,0x37,kCGEventKeyDown,0x69,0,0)==0);
 CHECK(check_event(sub,KBD_FLAGS_EXTENDED|KBD_FLAGS_RELEASE,0x37,kCGEventKeyUp,0x69,0,0)==0);
 CHECK(check_event(sub,0,0x3c,kCGEventKeyDown,0x78,0,0)==0);
 CHECK(check_event(sub,KBD_FLAGS_RELEASE,0x3c,kCGEventKeyUp,0x78,0,0)==0);
 /* Fully integrated production CGEvent filter, without a live desktop post. */
 char config[]="/tmp/macremote-rules-hook-XXXXXX";
 int fd=mkstemp(config);
 CHECK(fd>=0);
 const char *json="{\"profiles\":[{\"selected\":true,\"complex_modifications\":{\"rules\":[{\"manipulators\":[{\"type\":\"basic\",\"from\":{\"key_code\":\"c\",\"modifiers\":{\"mandatory\":[\"control\"]}},\"to\":[{\"key_code\":\"v\",\"modifiers\":[\"left_command\"]}]}]}]}}]}";
 CHECK(write(fd,json,strlen(json))==(ssize_t)strlen(json));
 close(fd);
 mr_compat_initialize(config);
 mac_shadow_set_input_filter(mr_compat_filter_event);
 rdpShadowClient *client=(rdpShadowClient *)(uintptr_t)1;
 mr_compat_set_client(client);
 CHECK(check_event(sub,0,0x1d,kCGEventFlagsChanged,0x3b,
       NX_DEVICELCTLKEYMASK|kCGEventFlagMaskControl,
       NX_DEVICELCTLKEYMASK|kCGEventFlagMaskControl)==0);
 CHECK(check_event(sub,0,0x2e,kCGEventKeyDown,0x09,
       NX_DEVICELCMDKEYMASK|kCGEventFlagMaskCommand,
       NX_DEVICELCMDKEYMASK|kCGEventFlagMaskCommand|
       NX_DEVICELCTLKEYMASK|kCGEventFlagMaskControl)==0);
 CHECK(check_event(sub,KBD_FLAGS_RELEASE,0x2e,kCGEventKeyUp,0x09,
       NX_DEVICELCMDKEYMASK|kCGEventFlagMaskCommand,
       NX_DEVICELCMDKEYMASK|kCGEventFlagMaskCommand)==0);
 CHECK(check_event(sub,KBD_FLAGS_RELEASE,0x1d,kCGEventFlagsChanged,0x3b,0,
       NX_DEVICELCTLKEYMASK|kCGEventFlagMaskControl)==0);
 mr_compat_client_disconnected(client);
 mr_compat_set_client(NULL);
 mac_shadow_set_input_filter(NULL);
 mr_compat_shutdown();
 unlink(config);
 ep.Free(sub);
 puts("PASS: production FreeRDP -> in-process Karabiner rule filter -> Quartz output without desktop injection");
 return 0;
}
