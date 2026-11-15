#import "karabiner_compat.h"

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#import <IOKit/hidsystem/ev_keymap.h>
#import <sys/stat.h>
#import <stdint.h>
#import <string.h>

static NSRecursiveLock *mr_lock;
static NSString *mr_path;
static NSArray<NSDictionary *> *mr_rules;
static NSMutableDictionary<NSNumber *, NSMutableDictionary<NSNumber *, id> *> *mr_held;
static NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *mr_modifiers;
static NSUInteger mr_skipped;
static NSUInteger mr_native_window_rules;
static struct stat mr_file_stat;
static BOOL mr_file_exists;
static BOOL mr_first_load;
static CFAbsoluteTime mr_next_check;
static _Thread_local const void *mr_client;
static _Thread_local BOOL mr_unicode_input;

static NSDictionary<NSString *, NSNumber *> *mr_keycodes(void)
{
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"a": @(kVK_ANSI_A), @"b": @(kVK_ANSI_B), @"c": @(kVK_ANSI_C),
            @"d": @(kVK_ANSI_D), @"e": @(kVK_ANSI_E), @"f": @(kVK_ANSI_F),
            @"g": @(kVK_ANSI_G), @"h": @(kVK_ANSI_H), @"i": @(kVK_ANSI_I),
            @"j": @(kVK_ANSI_J), @"k": @(kVK_ANSI_K), @"l": @(kVK_ANSI_L),
            @"m": @(kVK_ANSI_M), @"n": @(kVK_ANSI_N), @"o": @(kVK_ANSI_O),
            @"p": @(kVK_ANSI_P), @"q": @(kVK_ANSI_Q), @"r": @(kVK_ANSI_R),
            @"s": @(kVK_ANSI_S), @"t": @(kVK_ANSI_T), @"u": @(kVK_ANSI_U),
            @"v": @(kVK_ANSI_V), @"w": @(kVK_ANSI_W), @"x": @(kVK_ANSI_X),
            @"y": @(kVK_ANSI_Y), @"z": @(kVK_ANSI_Z),
            @"0": @(kVK_ANSI_0), @"1": @(kVK_ANSI_1), @"2": @(kVK_ANSI_2),
            @"3": @(kVK_ANSI_3), @"4": @(kVK_ANSI_4), @"5": @(kVK_ANSI_5),
            @"6": @(kVK_ANSI_6), @"7": @(kVK_ANSI_7), @"8": @(kVK_ANSI_8),
            @"9": @(kVK_ANSI_9),
            @"grave_accent_and_tilde": @(kVK_ANSI_Grave),
            @"hyphen": @(kVK_ANSI_Minus), @"equal_sign": @(kVK_ANSI_Equal),
            @"open_bracket": @(kVK_ANSI_LeftBracket),
            @"close_bracket": @(kVK_ANSI_RightBracket),
            @"backslash": @(kVK_ANSI_Backslash),
            @"semicolon": @(kVK_ANSI_Semicolon),
            @"quote": @(kVK_ANSI_Quote),
            @"comma": @(kVK_ANSI_Comma), @"period": @(kVK_ANSI_Period),
            @"slash": @(kVK_ANSI_Slash),
            @"spacebar": @(kVK_Space), @"tab": @(kVK_Tab),
            @"return_or_enter": @(kVK_Return),
            @"escape": @(kVK_Escape),
            @"delete_or_backspace": @(kVK_Delete),
            @"delete_forward": @(kVK_ForwardDelete),
            @"insert": @(kVK_Help), @"home": @(kVK_Home),
            @"end": @(kVK_End), @"page_up": @(kVK_PageUp),
            @"page_down": @(kVK_PageDown),
            @"left_arrow": @(kVK_LeftArrow), @"right_arrow": @(kVK_RightArrow),
            @"up_arrow": @(kVK_UpArrow), @"down_arrow": @(kVK_DownArrow),
            @"f1": @(kVK_F1), @"f2": @(kVK_F2), @"f3": @(kVK_F3),
            @"f4": @(kVK_F4), @"f5": @(kVK_F5), @"f6": @(kVK_F6),
            @"f7": @(kVK_F7), @"f8": @(kVK_F8), @"f9": @(kVK_F9),
            @"f10": @(kVK_F10), @"f11": @(kVK_F11), @"f12": @(kVK_F12),
            @"f13": @(kVK_F13), @"f14": @(kVK_F14), @"f15": @(kVK_F15),
            @"f16": @(kVK_F16), @"f17": @(kVK_F17), @"f18": @(kVK_F18),
            @"f19": @(kVK_F19), @"f20": @(kVK_F20),
            @"print_screen": @(kVK_F13),
            @"keypad_0": @(kVK_ANSI_Keypad0), @"keypad_1": @(kVK_ANSI_Keypad1),
            @"keypad_2": @(kVK_ANSI_Keypad2), @"keypad_3": @(kVK_ANSI_Keypad3),
            @"keypad_4": @(kVK_ANSI_Keypad4), @"keypad_5": @(kVK_ANSI_Keypad5),
            @"keypad_6": @(kVK_ANSI_Keypad6), @"keypad_7": @(kVK_ANSI_Keypad7),
            @"keypad_8": @(kVK_ANSI_Keypad8), @"keypad_9": @(kVK_ANSI_Keypad9),
            @"keypad_hyphen": @(kVK_ANSI_KeypadMinus),
            @"keypad_plus": @(kVK_ANSI_KeypadPlus),
            @"keypad_asterisk": @(kVK_ANSI_KeypadMultiply),
            @"keypad_slash": @(kVK_ANSI_KeypadDivide),
            @"keypad_period": @(kVK_ANSI_KeypadDecimal),
            @"keypad_equal_sign": @(kVK_ANSI_KeypadEquals),
            @"keypad_enter": @(kVK_ANSI_KeypadEnter),
            @"left_control": @(kVK_Control), @"right_control": @(kVK_RightControl),
            @"left_shift": @(kVK_Shift), @"right_shift": @(kVK_RightShift),
            @"left_option": @(kVK_Option), @"right_option": @(kVK_RightOption),
            @"left_command": @(kVK_Command), @"right_command": @(kVK_RightCommand),
            @"caps_lock": @(kVK_CapsLock), @"fn": @(kVK_Function),
            @"launchpad": @(-13), @"power": @(-6)
        };
    });
    return map;
}

static NSString *mr_name_for_key(CGKeyCode key)
{
    static NSDictionary<NSNumber *, NSString *> *reverse;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (NSString *name in mr_keycodes()) {
            NSNumber *code = mr_keycodes()[name];
            if (code.intValue >= 0)
                m[code] = name;
        }
        /* F13 is used by the RDP Print Screen translator. */
        m[@(kVK_F13)] = @"print_screen";
        reverse = [m copy];
    });
    return reverse[@(key)];
}

static CGEventFlags mr_mask_for_modifier(NSString *name)
{
    if ([name isEqualToString:@"control"] || [name isEqualToString:@"left_control"])
        return kCGEventFlagMaskControl;
    if ([name isEqualToString:@"right_control"])
        return kCGEventFlagMaskControl;
    if ([name isEqualToString:@"shift"] || [name isEqualToString:@"left_shift"] ||
        [name isEqualToString:@"right_shift"])
        return kCGEventFlagMaskShift;
    if ([name isEqualToString:@"option"] || [name isEqualToString:@"left_option"] ||
        [name isEqualToString:@"right_option"])
        return kCGEventFlagMaskAlternate;
    if ([name isEqualToString:@"command"] || [name isEqualToString:@"left_command"] ||
        [name isEqualToString:@"right_command"])
        return kCGEventFlagMaskCommand;
    if ([name isEqualToString:@"caps_lock"])
        return kCGEventFlagMaskAlphaShift;
    if ([name isEqualToString:@"fn"])
        return kCGEventFlagMaskSecondaryFn;
    return 0;
}

static CGEventFlags mr_side_bit(NSString *name)
{
    if ([name isEqualToString:@"left_control"]) return NX_DEVICELCTLKEYMASK;
    if ([name isEqualToString:@"right_control"]) return NX_DEVICERCTLKEYMASK;
    if ([name isEqualToString:@"left_shift"]) return NX_DEVICELSHIFTKEYMASK;
    if ([name isEqualToString:@"right_shift"]) return NX_DEVICERSHIFTKEYMASK;
    if ([name isEqualToString:@"left_option"]) return NX_DEVICELALTKEYMASK;
    if ([name isEqualToString:@"right_option"]) return NX_DEVICERALTKEYMASK;
    if ([name isEqualToString:@"left_command"]) return NX_DEVICELCMDKEYMASK;
    if ([name isEqualToString:@"right_command"]) return NX_DEVICERCMDKEYMASK;
    return 0;
}

static CGEventFlags mr_sides_for_mask(CGEventFlags mask)
{
    CGEventFlags bits = 0;
    if (mask & kCGEventFlagMaskControl) bits |= NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK;
    if (mask & kCGEventFlagMaskShift) bits |= NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK;
    if (mask & kCGEventFlagMaskAlternate) bits |= NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK;
    if (mask & kCGEventFlagMaskCommand) bits |= NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK;
    return bits;
}

static CGEventFlags mr_modifier_union(void)
{
    CGEventFlags aggregate = 0;
    for (NSMutableSet<NSNumber *> *keys in mr_modifiers.allValues)
        for (NSNumber *key in keys) {
            NSString *name = mr_name_for_key((CGKeyCode)key.unsignedShortValue);
            aggregate |= mr_mask_for_modifier(name) | mr_side_bit(name);
        }
    return aggregate;
}

/* FreeRDP stores modifiers in the macOS Shadow subsystem globally.
 * Build an independent union from actual RDP clients so one client releasing
 * Control cannot clear Control that a second client still holds. */
static CGEventFlags mr_update_rdp_modifiers(NSNumber *session,
                                             CGEventType type,
                                             CGKeyCode code,
                                             CGEventFlags incoming)
{
    if (type == kCGEventFlagsChanged) {
        NSString *name = mr_name_for_key(code);
        CGEventFlags side = mr_side_bit(name);
        CGEventFlags mask = side ? side : mr_mask_for_modifier(name);
        if (mask && ![name isEqual:@"caps_lock"]) {
            NSMutableSet<NSNumber *> *set = mr_modifiers[session];
            if (!set) {
                set = [NSMutableSet set];
                mr_modifiers[session] = set;
            }
            if (incoming & mask) [set addObject:@(code)];
            else [set removeObject:@(code)];
        }
    }
    /* Some RDP clients only synchronize a modifier through event flags.
     * Until a dedicated modifier transition has been observed, preserve the
     * source flags rather than discarding a valid Ctrl/Command shortcut. */
    if (!mr_modifiers.count && type != kCGEventFlagsChanged)
        return incoming;
    CGEventFlags groups = kCGEventFlagMaskControl | kCGEventFlagMaskShift |
                          kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand |
                          kCGEventFlagMaskSecondaryFn;
    return (incoming & ~(groups | mr_sides_for_mask(groups))) | mr_modifier_union();
}

static BOOL mr_valid_string_array(id value)
{
    if (![value isKindOfClass:NSArray.class]) return NO;
    for (id obj in value)
        if (![obj isKindOfClass:NSString.class]) return NO;
    return YES;
}

static NSArray<NSRegularExpression *> *mr_regexes(id value)
{
    if (!mr_valid_string_array(value)) return nil;
    NSMutableArray *regexes = [NSMutableArray array];
    for (NSString *pattern in value) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                              options:0 error:nil];
        if (!regex) return nil;
        [regexes addObject:regex];
    }
    return regexes;
}


typedef NS_ENUM(NSInteger, MRNativeWindowAction) {
    MRWindowNone = 0,
    MRWindowMaximize = 1,
    MRWindowMinimize = 2,
    MRWindowLeftHalf = 3,
    MRWindowRightHalf = 4
};

/* The existing Karabiner profile uses four Hammerspoon shell commands for
 * Win+arrows. Recognize their meaning, not a particular binary installation,
 * and run the equivalent operation using AppKit + Accessibility in-process. */
static MRNativeWindowAction mr_native_window_action(NSString *command)
{
    if (![command containsString:@"hs -c"]) return MRWindowNone;
    if ([command containsString:@"w:maximize()"]) return MRWindowMaximize;
    if ([command containsString:@"w:minimize()"]) return MRWindowMinimize;
    if ([command containsString:@"halfScreen(\"left\")"]) return MRWindowLeftHalf;
    if ([command containsString:@"halfScreen(\"right\")"]) return MRWindowRightHalf;
    return MRWindowNone;
}

static void mr_run_native_window_action(MRNativeWindowAction action)
{
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!front || action == MRWindowNone) return;
    AXUIElementRef app = AXUIElementCreateApplication(front.processIdentifier);
    if (!app) return;
    AXUIElementRef window = NULL;
    AXError err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute,
                                                (CFTypeRef *)&window);
    CFRelease(app);
    if (err != kAXErrorSuccess || !window) return;

    if (action == MRWindowMinimize) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute, kCFBooleanTrue);
        CFRelease(window);
        return;
    }

    CFTypeRef positionValue = NULL, sizeValue = NULL;
    CGPoint position = CGPointZero;
    CGSize size = CGSizeZero;
    if (AXUIElementCopyAttributeValue(window, kAXPositionAttribute,
                                       &positionValue) != kAXErrorSuccess ||
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute,
                                       &sizeValue) != kAXErrorSuccess ||
        !positionValue || !sizeValue ||
        !AXValueGetValue(positionValue, kAXValueCGPointType, &position) ||
        !AXValueGetValue(sizeValue, kAXValueCGSizeType, &size)) {
        if (positionValue) CFRelease(positionValue);
        if (sizeValue) CFRelease(sizeValue);
        CFRelease(window);
        return;
    }
    CFRelease(positionValue);
    CFRelease(sizeValue);
    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (!screens.count) {
        CFRelease(window);
        return;
    }
    CGFloat top = NSMaxY(NSScreen.mainScreen.frame);
    NSRect current = NSMakeRect(position.x, top - position.y - size.height,
                                size.width, size.height);
    NSScreen *chosen = screens[0];
    CGFloat best = -1;
    for (NSScreen *screen in screens) {
        NSRect intersection = NSIntersectionRect(current, screen.frame);
        CGFloat area = NSIsEmptyRect(intersection) ? 0 :
                         intersection.size.width * intersection.size.height;
        if (area > best) {
            best = area;
            chosen = screen;
        }
    }
    NSRect target = chosen.visibleFrame;
    if (action == MRWindowLeftHalf || action == MRWindowRightHalf) {
        target.size.width /= 2.0;
        if (action == MRWindowRightHalf)
            target.origin.x += target.size.width;
    }
    CGPoint targetPosition = CGPointMake(target.origin.x, top - NSMaxY(target));
    CGSize targetSize = CGSizeMake(target.size.width, target.size.height);
    AXValueRef pos = AXValueCreate(kAXValueCGPointType, &targetPosition);
    AXValueRef dim = AXValueCreate(kAXValueCGSizeType, &targetSize);
    if (pos) AXUIElementSetAttributeValue(window, kAXPositionAttribute, pos);
    if (dim) AXUIElementSetAttributeValue(window, kAXSizeAttribute, dim);
    if (pos) CFRelease(pos);
    if (dim) CFRelease(dim);
    CFRelease(window);
}

static NSDictionary *mr_make_rule(NSDictionary *manipulator)
{
    if (![manipulator[@"type"] isEqual:@"basic"]) return nil;
    NSSet *supported = [NSSet setWithArray:@[@"type", @"from", @"to", @"conditions"]];
    for (NSString *field in manipulator) if (![supported containsObject:field]) return nil;

    id from = manipulator[@"from"];
    if (![from isKindOfClass:NSDictionary.class]) return nil;
    NSString *source = from[@"key_code"];
    NSString *sourceButton = from[@"pointing_button"];
    if (source && sourceButton) return nil;
    if (![source isKindOfClass:NSString.class] && ![sourceButton isKindOfClass:NSString.class])
        return nil;
    if (source && !mr_keycodes()[source]) return nil;
    if (sourceButton && ![sourceButton isEqual:@"button1"]) return nil;
    NSDictionary *modifiers = from[@"modifiers"] ?: @{};
    if (![modifiers isKindOfClass:NSDictionary.class]) return nil;
    NSArray *mandatory = modifiers[@"mandatory"] ?: @[];
    NSArray *optional = modifiers[@"optional"] ?: @[];
    if (!mr_valid_string_array(mandatory) || !mr_valid_string_array(optional)) return nil;
    for (NSString *name in [mandatory arrayByAddingObjectsFromArray:optional])
        if (![name isEqual:@"any"] && !mr_mask_for_modifier(name)) return nil;
    if ([(NSDictionary *)from count] > (source || sourceButton ? 2 : 1)) return nil;

    NSArray *destinations = manipulator[@"to"] ?: @[];
    if (![destinations isKindOfClass:NSArray.class] || destinations.count > 1) return nil;
    NSDictionary *dest = destinations.count ? destinations[0] : @{};
    if (![dest isKindOfClass:NSDictionary.class]) return nil;
    NSString *targetKey = dest[@"key_code"];
    NSString *targetMouse = dest[@"pointing_button"];
    NSString *command = dest[@"shell_command"];
    if ([targetKey isKindOfClass:NSString.class]) {
        if (!mr_keycodes()[targetKey]) return nil;
    } else if (targetKey) return nil;
    if (targetMouse && ![targetMouse isEqual:@"button1"] &&
        ![targetMouse isEqual:@"button2"]) return nil;
    if (command && ![command isKindOfClass:NSString.class]) return nil;
    if ((targetKey != nil) + (targetMouse != nil) + (command != nil) > 1) return nil;
    NSArray *toMods = dest[@"modifiers"] ?: @[];
    if (!mr_valid_string_array(toMods)) return nil;
    for (NSString *name in toMods)
        if (!mr_mask_for_modifier(name)) return nil;
    for (NSString *field in dest)
        if (![@[@"key_code", @"pointing_button", @"shell_command", @"modifiers"] containsObject:field])
            return nil;
    NSArray *conditions = manipulator[@"conditions"] ?: @[];
    if (![conditions isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *checks = [NSMutableArray array];
    for (id item in conditions) {
        if (![item isKindOfClass:NSDictionary.class]) return nil;
        NSString *type = item[@"type"];
        if (![type isEqual:@"frontmost_application_if"] &&
            ![type isEqual:@"frontmost_application_unless"]) return nil;
        NSArray *regexes = mr_regexes(item[@"bundle_identifiers"]);
        if (!regexes) return nil;
        [checks addObject:@{@"type": type, @"patterns": regexes}];
    }
    NSString *kind = command ? @"shell" : targetMouse ? @"mouse" : targetKey ? @"key" : @"none";
    return @{
        @"source": source ?: @"button1", @"mouseSource": @(sourceButton != nil),
        @"mandatory": mandatory, @"optional": optional, @"conditions": checks,
        @"kind": kind, @"targetKey": targetKey ?: @"",
        @"targetMouse": targetMouse ?: @"", @"command": command ?: @"",
        @"nativeWindowAction": @(mr_native_window_action(command ?: @"")),
        @"toModifiers": toMods
    };
}

static void mr_reload_if_needed(BOOL force)
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!force && now < mr_next_check) return;
    mr_next_check = now + 0.25;
    if (!mr_path) return;
    struct stat st;
    BOOL exists = stat(mr_path.fileSystemRepresentation, &st) == 0;
    if (!force && mr_first_load && exists == mr_file_exists &&
        (!exists || (st.st_ino == mr_file_stat.st_ino &&
                      st.st_size == mr_file_stat.st_size &&
                      st.st_mtimespec.tv_sec == mr_file_stat.st_mtimespec.tv_sec &&
                      st.st_mtimespec.tv_nsec == mr_file_stat.st_mtimespec.tv_nsec)))
        return;
    mr_first_load = YES;
    mr_file_exists = exists;
    if (!exists) {
        mr_rules = @[];
        mr_skipped = 0;
        mr_native_window_rules = 0;
        return;
    }
    NSData *data = [NSData dataWithContentsOfFile:mr_path options:0 error:nil];
    id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![root isKindOfClass:NSDictionary.class])
        return; /* Keep the last good snapshot during an atomic editor update. */
    NSArray *profiles = root[@"profiles"];
    if (![profiles isKindOfClass:NSArray.class])
        return;
    NSDictionary *selected = nil;
    for (id p in profiles)
        if ([p isKindOfClass:NSDictionary.class] && [p[@"selected"] boolValue]) {
            selected = p;
            break;
        }
    if (!selected && profiles.count && [profiles[0] isKindOfClass:NSDictionary.class])
        selected = profiles[0];
    id modifications = selected[@"complex_modifications"];
    NSDictionary *complex = [modifications isKindOfClass:NSDictionary.class]
                                ? modifications : @{};
    NSArray *rules = complex[@"rules"];
    if (![rules isKindOfClass:NSArray.class]) rules = @[];
    NSMutableArray *all = [NSMutableArray array];
    NSUInteger skipped = 0;
    for (id rule in rules) {
        if (![rule isKindOfClass:NSDictionary.class]) continue;
        if (rule[@"enabled"] && ![rule[@"enabled"] boolValue]) continue;
        id manipulators = rule[@"manipulators"];
        if (![manipulators isKindOfClass:NSArray.class]) {
            skipped++;
            continue;
        }
        for (id manip in (NSArray *)manipulators) {
            NSDictionary *parsed = [manip isKindOfClass:NSDictionary.class]
                ? mr_make_rule(manip) : nil;
            if (parsed) [all addObject:parsed];
            else skipped++;
        }
    }
    mr_rules = [all copy];
    mr_skipped = skipped;
    mr_native_window_rules = 0;
    for (NSDictionary *rule in mr_rules)
        if ([rule[@"nativeWindowAction"] integerValue] != MRWindowNone)
            mr_native_window_rules++;
    mr_file_stat = st;
}

static BOOL mr_modifiers_match(NSDictionary *rule, CGEventFlags flags)
{
    NSArray<NSString *> *mandatory = rule[@"mandatory"];
    NSArray<NSString *> *optional = rule[@"optional"];
    CGEventFlags accepted = 0, required = 0;
    for (NSString *name in mandatory) {
        CGEventFlags mask = mr_mask_for_modifier(name);
        CGEventFlags side = mr_side_bit(name);
        if (side ? !(flags & side) : !(flags & mask)) return NO;
        required |= mask;
        accepted |= mask;
    }
    if ([optional containsObject:@"any"]) return YES;
    for (NSString *name in optional) accepted |= mr_mask_for_modifier(name);
    CGEventFlags all = kCGEventFlagMaskControl | kCGEventFlagMaskShift |
        kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand |
        kCGEventFlagMaskSecondaryFn | kCGEventFlagMaskAlphaShift;
    return ((flags & all) & ~accepted) == 0 && (flags & required) == required;
}

static BOOL mr_conditions_match(NSArray *checks, NSString *bundle)
{
    for (NSDictionary *check in checks) {
        BOOL matched = NO;
        for (NSRegularExpression *regex in check[@"patterns"]) {
            if ([regex firstMatchInString:bundle ?: @"" options:0
                                    range:NSMakeRange(0, (bundle ?: @"").length)]) {
                matched = YES;
                break;
            }
        }
        if ([check[@"type"] isEqual:@"frontmost_application_if"] && !matched) return NO;
        if ([check[@"type"] isEqual:@"frontmost_application_unless"] && matched) return NO;
    }
    return YES;
}

static CGEventFlags mr_output_flags(NSDictionary *rule, CGEventFlags input)
{
    CGEventFlags consumed = 0;
    for (NSString *name in rule[@"mandatory"])
        consumed |= mr_mask_for_modifier(name);
    CGEventFlags output = input & ~(consumed | mr_sides_for_mask(consumed));
    for (NSString *name in rule[@"toModifiers"]) {
        CGEventFlags mask = mr_mask_for_modifier(name);
        CGEventFlags side = mr_side_bit(name);
        output |= mask | side;
        /* Generic names without side specificity mean the left modifier. */
        if (!side) {
            if ([name isEqual:@"command"]) output |= NX_DEVICELCMDKEYMASK;
            if ([name isEqual:@"shift"]) output |= NX_DEVICELSHIFTKEYMASK;
            if ([name isEqual:@"control"]) output |= NX_DEVICELCTLKEYMASK;
            if ([name isEqual:@"option"]) output |= NX_DEVICELALTKEYMASK;
        }
    }
    return output;
}

static CGEventRef mr_convert_event(CGEventRef input, NSDictionary *active,
                                   BOOL down, BOOL dragging)
{
    NSString *kind = active[@"kind"];
    if ([kind isEqual:@"none"] || [kind isEqual:@"shell"]) {
        CFRelease(input);
        return NULL;
    }
    CGEventFlags flags = (CGEventFlags)[active[@"outputFlags"] unsignedLongLongValue];
    CGEventRef output = input;
    if ([kind isEqual:@"key"]) {
        NSInteger code = [mr_keycodes()[active[@"targetKey"]] integerValue];
        if (code < 0) {
            /* System-defined media keys, including Power and Launchpad. */
            int subtype = NX_SUBTYPE_AUX_CONTROL_BUTTONS;
            int keyType = code == -6 ? NX_POWER_KEY : NX_KEYTYPE_LAUNCH_PANEL;
            int state = down ? 0x0a : 0x0b;
            NSEvent *native = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                      location:NSZeroPoint modifierFlags:0 timestamp:0
                      windowNumber:0 context:nil subtype:subtype
                      data1:(keyType << 16) | (state << 8) data2:-1];
            output = native.CGEvent ? (CGEventRef)CFRetain(native.CGEvent) : NULL;
        } else if (CGEventGetType(input) == kCGEventKeyDown ||
                   CGEventGetType(input) == kCGEventKeyUp) {
            CGEventSetIntegerValueField(input, kCGKeyboardEventKeycode, code);
        } else {
            output = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)code, down);
        }
    } else if ([kind isEqual:@"mouse"]) {
        CGMouseButton button = [active[@"targetMouse"] isEqual:@"button2"]
                               ? kCGMouseButtonRight : kCGMouseButtonLeft;
        CGEventType type = dragging ? (button == kCGMouseButtonRight
                                  ? kCGEventRightMouseDragged : kCGEventLeftMouseDragged)
                            : (down ? (button == kCGMouseButtonRight
                                  ? kCGEventRightMouseDown : kCGEventLeftMouseDown)
                            : (button == kCGMouseButtonRight
                                  ? kCGEventRightMouseUp : kCGEventLeftMouseUp));
        output = CGEventCreateMouseEvent(NULL, type, CGEventGetLocation(input), button);
        if (output) CGEventSetIntegerValueField(output, kCGMouseEventClickState,
                  CGEventGetIntegerValueField(input, kCGMouseEventClickState));
    }
    if (output && ![kind isEqual:@"none"])
        CGEventSetFlags(output, flags);
    if (output != input) CFRelease(input);
    return output;
}

void mr_compat_initialize(const char *config_path)
{
    @autoreleasepool {
        if (!mr_lock) mr_lock = [NSRecursiveLock new];
        [mr_lock lock];
        mr_path = config_path ? [NSString stringWithUTF8String:config_path]
                 : [NSHomeDirectory() stringByAppendingPathComponent:
                    @".config/karabiner/karabiner.json"];
        mr_rules = @[];
        mr_held = [NSMutableDictionary dictionary];
        mr_modifiers = [NSMutableDictionary dictionary];
        mr_skipped = 0;
        mr_native_window_rules = 0;
        mr_first_load = NO;
        mr_next_check = 0;
        mr_reload_if_needed(YES);
        [mr_lock unlock];
    }
}

void mr_compat_set_client(const void *client)
{
    mr_client = client;
}

void mr_compat_set_unicode_input(bool enabled)
{
    mr_unicode_input = enabled;
}

void mr_compat_status(char *output, size_t capacity)
{
    if (!output || !capacity) return;
    @autoreleasepool {
        if (!mr_lock) mr_compat_initialize(NULL);
        [mr_lock lock];
        mr_reload_if_needed(NO);
        snprintf(output, capacity,
                 "Karabiner config: %s | rules: %lu | unsupported: %lu | native window actions: %lu",
                 mr_file_exists ? "loaded" : "absent (Quartz passthrough)",
                 (unsigned long)mr_rules.count, (unsigned long)mr_skipped,
                 (unsigned long)mr_native_window_rules);
        [mr_lock unlock];
    }
}

CGEventRef mr_compat_filter_event(CGEventRef event)
{
    if (!event) return NULL;
    if (mr_unicode_input) return event; /* Unicode text is not a physical A scancode. */
    /* High-frequency pointer movement never participates in Karabiner's
     * key/left-button rules. Avoid lock, reload timer, and autorelease pool
     * work in the hottest path of every RDP mouse movement. */
    const CGEventType type = CGEventGetType(event);
    const BOOL isMouse = type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp ||
                         type == kCGEventLeftMouseDragged;
    const BOOL isKey = type == kCGEventKeyDown || type == kCGEventKeyUp ||
                       type == kCGEventFlagsChanged;
    if (!isKey && !isMouse) return event;
    @autoreleasepool {
        if (!mr_lock) return event;
        [mr_lock lock];
        mr_reload_if_needed(NO);
        BOOL dragging = type == kCGEventLeftMouseDragged;

        CGKeyCode code = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags flags = CGEventGetFlags(event);
        if (mr_rules.count || mr_held.count || mr_modifiers.count) {
            flags = mr_update_rdp_modifiers(@((uintptr_t)mr_client), type, code, flags);
            CGEventSetFlags(event, flags);
        }
        BOOL down = type == kCGEventKeyDown || type == kCGEventLeftMouseDown || dragging;
        if (type == kCGEventFlagsChanged) {
            NSString *name = mr_name_for_key(code);
            CGEventFlags mask = mr_side_bit(name);
            if (!mask) mask = mr_mask_for_modifier(name);
            if (!mask) {
                [mr_lock unlock];
                return event;
            }
            down = (flags & mask) != 0;
        }

        uintptr_t keyValue = isMouse ? (uintptr_t)0x10000 : (uintptr_t)code;
        NSNumber *key = @(keyValue);
        NSNumber *session = @((uintptr_t)mr_client);
        NSMutableDictionary<NSNumber *, id> *held = mr_held[session];
        if (!held) {
            held = [NSMutableDictionary dictionary];
            mr_held[session] = held;
        }
        id previous = held[key];

        if (dragging && !previous) {
            [mr_lock unlock];
            return event;
        }
        if (previous && previous != NSNull.null) {
            NSDictionary *active = previous;
            if (!down && !dragging) [held removeObjectForKey:key];
            if (dragging && ![active[@"kind"] isEqual:@"mouse"]) {
                CFRelease(event);
                [mr_lock unlock];
                return NULL;
            }
            if (dragging) {
                CGPoint point = CGEventGetLocation(event);
                NSMutableDictionary *moving = [active mutableCopy];
                moving[@"mouseX"] = @(point.x);
                moving[@"mouseY"] = @(point.y);
                active = [moving copy];
                held[key] = active;
            }
            CGEventRef result = mr_convert_event(event, active, down, dragging);
            [mr_lock unlock];
            return result;
        }
        if (previous == NSNull.null) {
            if (!down && !dragging) [held removeObjectForKey:key];
            [mr_lock unlock];
            return event;
        }
        if (!down || !mr_rules.count) {
            if (down) held[key] = NSNull.null; /* Track original keys for disconnect cleanup. */
            [mr_lock unlock];
            return event;
        }
        NSString *keyName = isMouse ? @"button1" : mr_name_for_key(code);
        if (!keyName) {
            [mr_lock unlock];
            return event;
        }

        NSDictionary *matching = nil;
        NSString *bundle = nil;
        BOOL bundleLoaded = NO;
        for (NSDictionary *rule in mr_rules) {
            if ([rule[@"mouseSource"] boolValue] != isMouse ||
                ![rule[@"source"] isEqual:keyName] ||
                !mr_modifiers_match(rule, flags)) continue;
            if (!bundleLoaded) {
                bundle = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
                bundleLoaded = YES;
            }
            if (mr_conditions_match(rule[@"conditions"], bundle)) {
                matching = rule;
                break;
            }
        }
        if (!matching) {
            held[key] = NSNull.null;
            [mr_lock unlock];
            return event;
        }

        NSMutableDictionary *active = [matching mutableCopy];
        active[@"outputFlags"] = @((unsigned long long)mr_output_flags(matching, flags));
        if (isMouse) {
            CGPoint point = CGEventGetLocation(event);
            active[@"mouseX"] = @(point.x);
            active[@"mouseY"] = @(point.y);
        }
        held[key] = [active copy];
        if ([active[@"kind"] isEqual:@"shell"]) {
            NSString *command = active[@"command"];
            MRNativeWindowAction nativeAction =
                (MRNativeWindowAction)[active[@"nativeWindowAction"] integerValue];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                @autoreleasepool {
                    if (nativeAction != MRWindowNone) {
                        mr_run_native_window_action(nativeAction);
                    } else {
                        NSTask *task = [NSTask new];
                        task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
                        task.arguments = @[@"-c", command];
                        [task launchAndReturnError:nil];
                    }
                }
            });
        }
        CGEventRef result = mr_convert_event(event, active, YES, NO);
        [mr_lock unlock];
        return result;
    }
}

void mr_compat_client_disconnected(const void *client)
{
    if (!mr_lock) return;
    @autoreleasepool {
        [mr_lock lock];
        NSNumber *session = @((uintptr_t)client);
        NSDictionary<NSNumber *, id> *held = [mr_held[session] copy];
        NSSet<NSNumber *> *modifiers = [mr_modifiers[session] copy];
        [mr_held removeObjectForKey:session];
        [mr_modifiers removeObjectForKey:session];
        CGEventFlags remaining = mr_modifier_union();

        /* Send key-up for this client's pending keyboard/mouse outputs. */
        for (NSNumber *key in held) {
            id rule = held[key];
            BOOL mouse = (key.unsignedLongLongValue & 0x10000) != 0;
            if (rule == NSNull.null) {
                CGEventRef released = NULL;
                if (mouse) {
                    CGEventRef location = CGEventCreate(NULL);
                    CGPoint at = CGEventGetLocation(location);
                    CFRelease(location);
                    released = CGEventCreateMouseEvent(
                        NULL, kCGEventLeftMouseUp, at, kCGMouseButtonLeft);
                } else {
                    CGKeyCode code = key.unsignedShortValue;
                    if ([modifiers containsObject:@(code)]) continue;
                    released = CGEventCreateKeyboardEvent(NULL, code, false);
                    NSString *name = mr_name_for_key(code);
                    if (released && mr_mask_for_modifier(name))
                        CGEventSetType(released, kCGEventFlagsChanged);
                }
                if (released) {
                    CGEventSetFlags(released, remaining);
                    CGEventPost(kCGHIDEventTap, released);
                    CFRelease(released);
                }
                continue;
            }
            NSDictionary *active = rule;
            NSString *kind = active[@"kind"];
            if ([kind isEqual:@"shell"] || [kind isEqual:@"none"]) continue;
            CGPoint at = CGPointMake([active[@"mouseX"] doubleValue],
                                      [active[@"mouseY"] doubleValue]);
            CGEventRef placeholder = mouse
                 ? CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, at, kCGMouseButtonLeft)
                 : CGEventCreateKeyboardEvent(NULL, (CGKeyCode)key.unsignedShortValue, false);
            if (placeholder) {
                CGEventRef released = mr_convert_event(placeholder, active, NO, NO);
                if (released) {
                    CGEventPost(kCGHIDEventTap, released);
                    CFRelease(released);
                }
            }
        }

        /* Last owner of each modifier is the only one that emits key-up. */
        for (NSNumber *key in modifiers) {
            NSString *name = mr_name_for_key((CGKeyCode)key.unsignedShortValue);
            CGEventFlags mask = mr_side_bit(name);
            if (!mask) mask = mr_mask_for_modifier(name);
            if (!mask || (remaining & mask)) continue;
            CGEventRef released = CGEventCreateKeyboardEvent(NULL, key.unsignedShortValue, false);
            if (released) {
                CGEventSetType(released, kCGEventFlagsChanged);
                CGEventSetFlags(released, remaining);
                CGEventPost(kCGHIDEventTap, released);
                CFRelease(released);
            }
        }
        [mr_lock unlock];
    }
}

void mr_compat_shutdown(void)
{
    if (!mr_lock) return;
    @autoreleasepool {
        [mr_lock lock];
        mr_rules = @[];
        [mr_held removeAllObjects];
        [mr_modifiers removeAllObjects];
        mr_path = nil;
        mr_file_exists = NO;
        [mr_lock unlock];
    }
}
