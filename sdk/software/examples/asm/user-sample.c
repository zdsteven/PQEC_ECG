#include <stdio.h>

#include "dma.h"

unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#ifndef MATMUL_GROUP_NUM
#define MATMUL_GROUP_NUM 5000u
#endif

#define EXTRAM_PHYS_BASE       0x1c400000u
#define MATMUL_INPUT_BYTES     0x0009c400u

int main(int argc, char **argv)
{
    U32 crc;

    (void)argc;
    (void)argv;

    printf("MATMUL_START\n");

    (void)DMA_MatMul_Start(EXTRAM_PHYS_BASE,
                           EXTRAM_PHYS_BASE + MATMUL_INPUT_BYTES,
                           (U32)MATMUL_GROUP_NUM);
    (void)DMA_Wait(0u);

    // CRC is accumulated by hardware from the exact words accepted on AXI W.
    // This avoids a second 960000-byte uncached scan of ExtRAM.
    crc = DMA_Get_CRC32();
    printf("MATMUL_CRC32=%08X\n", crc);
    printf("MATMUL_DONE\n");

    while (1) {
    }

    return 0;
}
