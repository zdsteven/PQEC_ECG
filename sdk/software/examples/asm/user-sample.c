#include <stdio.h>
#include "matmul.h"
#include "confreg_time.h"
#include "core_time.h"

unsigned long UART_BASE              = 0xbf000000;
unsigned long CONFREG_TIMER_BASE     = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC    = 33000000L;

#ifndef MATMUL_GROUP_NUM
#define MATMUL_GROUP_NUM 5000
#endif

#define EXTRAM_BASE       0x1c400000u
#define INPUT_OFFSET      0x00000000u
#define RESULT_OFFSET     0x0009c400u

int main(int argc, char **argv)
{
    uint32_t crc;
    int rc;
    (void)argc;
    (void)argv;

    printf("MATMUL_START\n");

    /*
     * Keep the timed section short: one hardware command handles all groups,
     * writes the full result area, and computes the exact CRC32 over it.
     */
    rc = MATMul_Compute_Batch_DMA(EXTRAM_BASE + INPUT_OFFSET,
                                  EXTRAM_BASE + RESULT_OFFSET,
                                  MATMUL_GROUP_NUM,
                                  0);
    crc = (rc == 0) ? MATMul_Get_Batch_CRC() : 0u;

    printf("MATMUL_CRC32=%08x\n", crc);
    printf("MATMUL_DONE\n");

    while (1) {
    }
}
