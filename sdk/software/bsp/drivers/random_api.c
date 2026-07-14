#include "random_api.h"

#include <stdint.h>

#include "confreg_time.h"

__attribute__((weak)) int application_trng_read(uint8_t *output, size_t length)
{
    (void)output;
    (void)length;
    return -1;
}

static uint32_t xorshift32(uint32_t value)
{
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    return value;
}

static void demo_random_bytes(uint8_t *output, size_t length)
{
    static uint32_t invocation_counter;
    uint32_t state = (uint32_t)get_cpu_clock_count();
    size_t i;

    state ^= (uint32_t)(uintptr_t)output;
    state ^= ++invocation_counter * 0x9e3779b9U;
    for (i = 0U; i < length; ++i) {
        state ^= (uint32_t)get_cpu_clock_count() + (uint32_t)i;
        state = xorshift32(state);
        output[i] = (uint8_t)state;
    }
}

int random_bytes(uint8_t *output, size_t length)
{
    if (application_trng_read(output, length) == 0) {
        return 0;
    }

    /* Functional fallback only; replace it before security evaluation. */
    demo_random_bytes(output, length);
    return 0;
}
