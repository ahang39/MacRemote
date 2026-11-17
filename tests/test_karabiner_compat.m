#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import "../src/input/karabiner_compat.h"
#import <IOKit/hidsystem/IOLLEvent.h>
#import <stdio.h>
#import <unistd.h>

static NSUInteger posts;
static CGEventType lastPostedType;
static CGKeyCode lastPostedCode;
static CGEventFlags lastPostedFlags;

/* Prevent any disconnect cleanup keyup from reaching the real desktop. */
void CGEventPost(CGEventTapLocation location, CGEventRef e)
{
    if (location != kCGHIDEventTap) abort();
    posts++;
    lastPostedType = CGEventGetType(e);
    lastPostedCode = (CGKeyCode)CGEventGetIntegerValueField(e,kCGKeyboardEventKeycode);
    lastPostedFlags = CGEventGetFlags(e);
}

#define REQUIRE(expr) do {if(!(expr)) {fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#expr);exit(1);}}while(0)

static CGEventRef key(CGKeyCode code, BOOL down, CGEventFlags flags)
{
    CGEventRef e=CGEventCreateKeyboardEvent(NULL,code,down);
    REQUIRE(e!=NULL);
    CGEventSetFlags(e,flags);
    return e;
}
static CGEventRef filter(CGEventRef e)
{
    return mr_compat_filter_event(e); /* filter owns input, output is retained */
}

static CGEventRef modifier(CGKeyCode code, BOOL down, CGEventFlags mask)
{
    CGEventRef e=key(code,down,down ? mask : 0);
    CGEventSetType(e,kCGEventFlagsChanged);
    return e;
}
static NSString *write_rules(NSString *path, NSArray *manips)
{
    NSDictionary *json=@{@"profiles":@[@{@"selected":@YES,@"complex_modifications":@{@"rules":@[@{@"manipulators":manips}]}}]};
    NSData *data=[NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
    REQUIRE(data!=nil);
    NSString *newPath=[path stringByAppendingString:@".new"];
    REQUIRE([data writeToFile:newPath atomically:YES]);
    REQUIRE([[NSFileManager defaultManager] replaceItemAtURL:[NSURL fileURLWithPath:path]
                       withItemAtURL:[NSURL fileURLWithPath:newPath]
                       backupItemName:nil options:0 resultingItemURL:nil error:NULL]
            || (rename(newPath.fileSystemRepresentation,path.fileSystemRepresentation)==0));
    return path;
}

int main(void)
{
 @autoreleasepool {
    NSString *tmp=[NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"macremote-karabiner-test-%d",getpid()]];
    REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:tmp
                           withIntermediateDirectories:YES attributes:nil error:NULL]);
    NSString *path=[tmp stringByAppendingPathComponent:@"karabiner.json"];
    const void *client=(void *)0x1234;
    CGEventFlags ctrl=kCGEventFlagMaskControl|NX_DEVICELCTLKEYMASK;
    CGEventFlags cmd=kCGEventFlagMaskCommand|NX_DEVICELCMDKEYMASK;

    mr_compat_initialize(path.UTF8String);
    mr_compat_set_client(client);
    char status[220];
    mr_compat_status(status,sizeof(status));
    REQUIRE(strstr(status,"absent")!=NULL);
    CGEventRef input=key(kVK_ANSI_C,YES,ctrl);
    CGEventRef passed=filter(input);
    REQUIRE(input==passed);
    CFRelease(passed);
    posts=0;
    mr_compat_client_disconnected(client);
    REQUIRE(posts==1);
    REQUIRE(lastPostedType==kCGEventKeyUp && lastPostedCode==kVK_ANSI_C);

    /* A client can disconnect mid-drag with no Karabiner profile. */
    CGEventRef heldMouse = CGEventCreateMouseEvent(
        NULL, kCGEventLeftMouseDown, CGPointMake(220, 180), kCGMouseButtonLeft);
    REQUIRE(heldMouse!=NULL);
    REQUIRE(filter(heldMouse)==heldMouse);
    CFRelease(heldMouse);
    posts=0;
    mr_compat_client_disconnected(client);
    REQUIRE(posts==1);
    REQUIRE(lastPostedType==kCGEventLeftMouseUp);

    NSDictionary *copy=@{@"type":@"basic",
       @"from":@{@"key_code":@"c",
                 @"modifiers":@{@"mandatory":@[@"control"],@"optional":@[@"any"]}},
       @"to":@[@{@"key_code":@"v",@"modifiers":@[@"left_command"]}]};
    NSDictionary *insert=@{@"type":@"basic",
       @"from":@{@"key_code":@"insert", @"modifiers":@{@"optional":@[@"any"]}},
       @"to":@[]};
    NSDictionary *mouse=@{@"type":@"basic",
       @"from":@{@"pointing_button":@"button1",
                 @"modifiers":@{@"mandatory":@[@"control"]}},
       @"to":@[@{@"pointing_button":@"button2"}]};
    NSDictionary *launcher=@{@"type":@"basic",
       @"from":@{@"key_code":@"f2"},@"to":@[@{@"key_code":@"launchpad"}]};
    NSDictionary *power=@{@"type":@"basic",
       @"from":@{@"key_code":@"f3"},@"to":@[@{@"key_code":@"power",
                                                   @"modifiers":@[@"left_control",@"left_shift"]}]};
    NSDictionary *unknownCondition=@{@"type":@"basic",
       @"from":@{@"key_code":@"y"},
       @"to":@[@{@"key_code":@"z"}],
       @"conditions":@[@{@"type":@"variable_if",@"name":@"x",@"value":@1}]};
    write_rules(path,@[copy,insert,mouse,launcher,power,unknownCondition]);
    usleep(400000);
    mr_compat_status(status,sizeof(status));
    REQUIRE(strstr(status,"rules: 5")!=NULL);
    REQUIRE(strstr(status,"unsupported: 1")!=NULL);

    CGEventRef out=filter(key(kVK_ANSI_C,YES,ctrl));
    REQUIRE(out!=NULL);
    REQUIRE(CGEventGetIntegerValueField(out,kCGKeyboardEventKeycode)==kVK_ANSI_V);
    REQUIRE((CGEventGetFlags(out)&cmd)==cmd);
    REQUIRE((CGEventGetFlags(out)&ctrl)==0);
    CFRelease(out);
    out=filter(key(kVK_ANSI_C,NO,kCGEventFlagMaskShift));
    REQUIRE(out!=NULL);
    REQUIRE(CGEventGetIntegerValueField(out,kCGKeyboardEventKeycode)==kVK_ANSI_V);
    REQUIRE((CGEventGetFlags(out)&cmd)==cmd); /* mapped release survives modifier change */
    CFRelease(out);

    REQUIRE(filter(key(kVK_Help,YES,0))==NULL);
    REQUIRE(filter(key(kVK_Help,NO,0))==NULL);

    /* Pure mouse moves must bypass the keyboard rule machinery unchanged. */
    CGEventRef pointerMove=CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,
                                                   CGPointMake(280,320),kCGMouseButtonLeft);
    REQUIRE(pointerMove!=NULL);
    CGEventRef unmodifiedMove=filter(pointerMove);
    REQUIRE(unmodifiedMove==pointerMove);
    REQUIRE(CGEventGetType(unmodifiedMove)==kCGEventMouseMoved);
    CFRelease(unmodifiedMove);

    CGEventRef click=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseDown,
                                             CGPointMake(350,420),kCGMouseButtonLeft);
    CGEventSetFlags(click,ctrl);
    out=filter(click);
    REQUIRE(out!=NULL);
    REQUIRE(CGEventGetType(out)==kCGEventRightMouseDown);
    REQUIRE((CGEventGetFlags(out)&ctrl)==0);
    CFRelease(out);
    click=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseDragged,
                                  CGPointMake(360,430),kCGMouseButtonLeft);
    out=filter(click);
    REQUIRE(out!=NULL);
    REQUIRE(CGEventGetType(out)==kCGEventRightMouseDragged);
    CFRelease(out);
    click=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseUp,
                                  CGPointMake(365,435),kCGMouseButtonLeft);
    out=filter(click);
    REQUIRE(out!=NULL);
    REQUIRE(CGEventGetType(out)==kCGEventRightMouseUp);
    CFRelease(out);

    out=filter(key(kVK_F2,YES,0));
    REQUIRE(out!=NULL);
    REQUIRE(CGEventGetType(out)==(CGEventType)NX_SYSDEFINED);
    CFRelease(out);
    out=filter(key(kVK_F2,NO,0));
    REQUIRE(out!=NULL);
    CFRelease(out);
    out=filter(key(kVK_F3,YES,0));
    REQUIRE(out!=NULL);
    REQUIRE(CGEventGetType(out)==(CGEventType)NX_SYSDEFINED);
    CFRelease(out);
    out=filter(key(kVK_F3,NO,0));
    REQUIRE(out!=NULL);
    CFRelease(out);

    /* key hold should preserve the mapping across config reload. */
    out=filter(key(kVK_ANSI_C,YES,ctrl));
    REQUIRE(out!=NULL); CFRelease(out);
    NSDictionary *other=@{@"type":@"basic",
       @"from":@{@"key_code":@"c",
                 @"modifiers":@{@"mandatory":@[@"control"],@"optional":@[@"any"]}},
       @"to":@[@{@"key_code":@"x",@"modifiers":@[@"left_command"]}]};
    write_rules(path,@[other]);
    usleep(420000);
    out=filter(key(kVK_ANSI_C,NO,0));
    REQUIRE(out!=NULL);
    REQUIRE(CGEventGetIntegerValueField(out,kCGKeyboardEventKeycode)==kVK_ANSI_V);
    CFRelease(out);
    out=filter(key(kVK_ANSI_C,YES,ctrl));
    REQUIRE(out!=NULL);
    REQUIRE(CGEventGetIntegerValueField(out,kCGKeyboardEventKeycode)==kVK_ANSI_X);
    CFRelease(out);

    posts=0;
    mr_compat_client_disconnected(client);
    REQUIRE(posts==1);
    REQUIRE(lastPostedType==kCGEventKeyUp && lastPostedCode==kVK_ANSI_X);
    REQUIRE((lastPostedFlags&cmd)==cmd);

    /* The if/unless predicates are evaluated as an AND across conditions. */
    NSDictionary *appConditional=@{@"type":@"basic",
        @"from":@{@"key_code":@"f5"},
        @"to":@[@{@"key_code":@"f6"}],
        @"conditions":@[
            @{@"type":@"frontmost_application_if", @"bundle_identifiers":@[@".*"]},
            @{@"type":@"frontmost_application_unless",
              @"bundle_identifiers":@[@"^com\\.example\\.excluded$"]}
        ]};
    NSString *shellPath=[tmp stringByAppendingPathComponent:@"commands.txt"];
    NSString *command=[NSString stringWithFormat:@"printf 'x\\n' >> '%@'",shellPath];
    NSDictionary *shell=@{@"type":@"basic",
        @"from":@{@"key_code":@"f4"},
        @"to":@[@{@"shell_command":command}]};
    write_rules(path,@[appConditional,shell]);
    usleep(410000);
    out=filter(key(kVK_F5,YES,0));
    REQUIRE(out!=NULL);
    REQUIRE(CGEventGetIntegerValueField(out,kCGKeyboardEventKeycode)==kVK_F6);
    CFRelease(out);
    out=filter(key(kVK_F5,NO,0));
    REQUIRE(out!=NULL);CFRelease(out);
    REQUIRE(filter(key(kVK_F4,YES,0))==NULL);
    REQUIRE(filter(key(kVK_F4,YES,0))==NULL); /* held repeat must not run twice */
    REQUIRE(filter(key(kVK_F4,NO,0))==NULL);
    BOOL executed=NO;
    for (int i=0; i<60; i++) {
        usleep(50000);
        NSString *contents=[NSString stringWithContentsOfFile:shellPath
                                     encoding:NSUTF8StringEncoding error:NULL];
        if (contents) {
            REQUIRE([contents isEqualToString:@"x\n"]);
            executed=YES;
            break;
        }
    }
    REQUIRE(executed);
    NSDictionary *never=@{@"type":@"basic",
        @"from":@{@"key_code":@"f5"},
        @"to":@[@{@"key_code":@"f6"}],
        @"conditions":@[
          @{@"type":@"frontmost_application_if",
            @"bundle_identifiers":@[@"^org\\.not\\.installed$"]}
        ]};
    write_rules(path,@[never]);
    usleep(390000);
    out=filter(key(kVK_F5,YES,0));
    REQUIRE(out!=NULL);
    REQUIRE(CGEventGetIntegerValueField(out,kCGKeyboardEventKeycode)==kVK_F5);
    CFRelease(out);
    out=filter(key(kVK_F5,NO,0));
    REQUIRE(out!=NULL);CFRelease(out);

    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    usleep(320000);
    mr_compat_status(status,sizeof(status));
    REQUIRE(strstr(status,"absent")!=NULL);
    out=filter(key(kVK_ANSI_C,YES,ctrl));
    REQUIRE(out!=NULL);
    REQUIRE(CGEventGetIntegerValueField(out,kCGKeyboardEventKeycode)==kVK_ANSI_C);
    CFRelease(out);

    /* A Unicode keyboard event has Apple keycode 0 but represents text,
     * not the physical A key. Never apply Karabiner physical-key rules. */
    NSDictionary *rawA=@{@"type":@"basic",
       @"from":@{@"key_code":@"a"},
       @"to":@[@{@"key_code":@"x"}]};
    write_rules(path,@[rawA]);
    usleep(410000);
    mr_compat_set_unicode_input(true);
    input=key(kVK_ANSI_A,YES,0);
    UniChar textCharacter='Q';
    CGEventKeyboardSetUnicodeString(input,1,&textCharacter);
    passed=filter(input);
    REQUIRE(passed==input);
    CFRelease(passed);
    mr_compat_set_unicode_input(false);
    out=filter(key(kVK_ANSI_A,YES,0));
    REQUIRE(out!=NULL);
    REQUIRE(CGEventGetIntegerValueField(out,kCGKeyboardEventKeycode)==kVK_ANSI_X);
    CFRelease(out);
    out=filter(key(kVK_ANSI_A,NO,0));
    REQUIRE(out!=NULL); CFRelease(out);

    // Malformed JSON fields cannot crash the loader or broaden a rule.
    NSDictionary *unsupportedFrom = @{@"type": @"basic",
        @"from": @{@"key_code": @"a", @"unknown": @YES},
        @"to": @[@{@"key_code": @"x"}]};
    NSDictionary *malformed = @{@"profiles": @[
        @{@"selected": NSNull.null},
        @{@"selected": @YES, @"complex_modifications": @{@"rules": @[
            @{@"enabled": NSNull.null, @"manipulators": @[rawA]},
            @{@"manipulators": @[unsupportedFrom]}
        ]}}
    ]};
    NSData *json = [NSJSONSerialization dataWithJSONObject:malformed options:0 error:nil];
    REQUIRE([json writeToFile:path atomically:YES]);
    mr_compat_initialize(path.UTF8String);
    out = filter(key(kVK_ANSI_A, YES, 0));
    REQUIRE(out != NULL);
    REQUIRE(CGEventGetIntegerValueField(out, kCGKeyboardEventKeycode) == kVK_ANSI_A);
    CFRelease(out);

    /* Two RDP clients can hold the same Control key concurrently. Releasing
     * one must not clear Control for the other. */
    write_rules(path,@[copy]);
    mr_compat_initialize(path.UTF8String);
    const void *clientA=(void *)0x2001, *clientB=(void *)0x2002;
    mr_compat_set_client(clientA);
    out=filter(modifier(kVK_Control,YES,ctrl));
    REQUIRE(out!=NULL); CFRelease(out);
    mr_compat_set_client(clientB);
    out=filter(modifier(kVK_Control,YES,ctrl));
    REQUIRE(out!=NULL); CFRelease(out);
    mr_compat_set_client(clientA);
    out=filter(modifier(kVK_Control,NO,ctrl));
    REQUIRE(out!=NULL);
    REQUIRE((CGEventGetFlags(out)&ctrl)==ctrl);
    CFRelease(out);
    mr_compat_set_client(clientB);
    out=filter(key(kVK_ANSI_C,YES,0)); /* The original FreeRDP state is stale. */
    REQUIRE(out!=NULL);
    REQUIRE(CGEventGetIntegerValueField(out,kCGKeyboardEventKeycode)==kVK_ANSI_V);
    REQUIRE((CGEventGetFlags(out)&cmd)==cmd);
    CFRelease(out);
    out=filter(key(kVK_ANSI_C,NO,0));
    REQUIRE(out!=NULL);CFRelease(out);
    out=filter(modifier(kVK_Control,NO,ctrl));
    REQUIRE(out!=NULL);
    REQUIRE((CGEventGetFlags(out)&ctrl)==0);
    CFRelease(out);
    mr_compat_client_disconnected(clientA);
    mr_compat_client_disconnected(clientB);

    /* Real profile is only inspected, never edited. */
    mr_compat_initialize(NULL);
    mr_compat_status(status,sizeof(status));
    printf("current-profile: %s\n",status);
    /* User-specific Karabiner profiles are optional. Behavior is verified
     * above using deterministic fixtures, not the developer's machine. */
    REQUIRE(strstr(status,"Karabiner config:")!=NULL);
    mr_compat_set_client(NULL);
    mr_compat_shutdown();
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
    puts("PASS: optional config, mapping, modifiers, mouse, specials, reload, disconnect");
    return 0;
 }
}
