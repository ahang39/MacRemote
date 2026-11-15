#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <stdio.h>

#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
        return 1; \
    } \
} while (0)

/* The side bits and group masks must match Karabiner v16.3's
 * event_tap_utility_details::get_modifier_event_type logic. */
static int verify_pair(CGKeyCode left, CGKeyCode right, CGEventFlags side_left,
                       CGEventFlags side_right, CGEventFlags group)
{
    CGEventFlags f = 0;
    const CGKeyCode keys[] = {left, right, left, right};
    const CGEventFlags sides[] = {side_left, side_right, side_left, side_right};
    const bool presses[] = {true, true, false, false};
    for (int i = 0; i < 4; i++) {
        if (presses[i]) f |= sides[i];
        else f &= ~sides[i];
        if (f & (side_left | side_right)) f |= group;
        else f &= ~group;

        CGEventRef e = CGEventCreateKeyboardEvent(NULL, keys[i], presses[i]);
        CHECK(e != NULL);
        CGEventSetType(e, kCGEventFlagsChanged);
        CGEventSetFlags(e, f);
        const CGEventFlags actual = CGEventGetFlags(e);
        CHECK((actual & (side_left | side_right | group)) == f);
        CHECK(((actual & sides[i]) != 0) == presses[i]);
        CHECK(((actual & group) != 0) == (i < 3));
        CFRelease(e);
    }
    CHECK(f == 0);
    return 0;
}

int main(void)
{
    CHECK(verify_pair(0x3b,0x3e,NX_DEVICELCTLKEYMASK,NX_DEVICERCTLKEYMASK,
                      kCGEventFlagMaskControl) == 0);
    CHECK(verify_pair(0x38,0x3c,NX_DEVICELSHIFTKEYMASK,NX_DEVICERSHIFTKEYMASK,
                      kCGEventFlagMaskShift) == 0);
    CHECK(verify_pair(0x3a,0x3d,NX_DEVICELALTKEYMASK,NX_DEVICERALTKEYMASK,
                      kCGEventFlagMaskAlternate) == 0);
    CHECK(verify_pair(0x37,0x36,NX_DEVICELCMDKEYMASK,NX_DEVICERCMDKEYMASK,
                      kCGEventFlagMaskCommand) == 0);
    puts("PASS: left/right modifier CGEvent flags survive a keyboard event");
    return 0;
}
