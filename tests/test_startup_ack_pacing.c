#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "shadow_startup_pacing.h"

int main(void)
{
    assert(shadow_startup_ack_budget(8, 0) == 2);
    assert(shadow_startup_ack_budget(8, 1) == 8);
    assert(shadow_startup_ack_budget(2, 0) == 2);
    assert(shadow_startup_ack_budget(1, 0) == 1);
    assert(shadow_startup_ack_budget(0, 0) == 0);
    assert(shadow_startup_ack_budget(0, 1) == 0);
    assert(shadow_startup_ack_drain_batch(10, 0) == 1);
    assert(shadow_startup_ack_drain_batch(10, 1) == 5);
    assert(shadow_startup_ack_drain_batch(3, 1) == 3);
    assert(shadow_startup_ack_drain_batch(0, 1) == 0);
    puts("PASS: first ACK gates startup frames; existing limits restored after ACK");
    return 0;
}
