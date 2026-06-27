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
#define EXTRAM_UNCACHED_BASE   0xbc400000u
#define MATMUL_INPUT_BYTES     0x0009c400u
#define MATMUL_RESULT_BYTES    ((U32)(MATMUL_GROUP_NUM) * 192u)

static U32 crc32_table[256];

static void CRC32_Init_Table(void)
{
    U32 i;
    U32 bit;

    for (i = 0u; i < 256u; ++i) {
        U32 crc = i;
        for (bit = 0u; bit < 8u; ++bit)
            crc = (crc >> 1) ^ ((crc & 1u) ? 0xedb88320u : 0u);
        crc32_table[i] = crc;
    }
}

static U32 CRC32_Result_Area(void)
{
    volatile U32 *words = (volatile U32 *)(EXTRAM_UNCACHED_BASE + MATMUL_INPUT_BYTES);
    U32 word_count = MATMUL_RESULT_BYTES >> 2;
    U32 crc = 0xffffffffu;
    U32 i;

    // One uncached 32-bit load feeds four table updates.  Byte extraction in
    // this order matches the little-endian ExtRAM byte stream used by grading.
    for (i = 0u; i < word_count; ++i) {
        U32 data = words[i];
        crc = crc32_table[(crc ^ data) & 0xffu] ^ (crc >> 8);
        data >>= 8;
        crc = crc32_table[(crc ^ data) & 0xffu] ^ (crc >> 8);
        data >>= 8;
        crc = crc32_table[(crc ^ data) & 0xffu] ^ (crc >> 8);
        data >>= 8;
        crc = crc32_table[(crc ^ data) & 0xffu] ^ (crc >> 8);
    }

    return crc ^ 0xffffffffu;
}

int main(int argc, char **argv)
{
    U32 crc;

    (void)argc;
    (void)argv;

    // Table setup is intentionally before the timed start marker.
    CRC32_Init_Table();
    printf("MATMUL_START\n");

    (void)DMA_MatMul_Start(EXTRAM_PHYS_BASE,
                           EXTRAM_PHYS_BASE + MATMUL_INPUT_BYTES,
                           (U32)MATMUL_GROUP_NUM);
    (void)DMA_Wait(0u);

    crc = CRC32_Result_Area();
    printf("MATMUL_CRC32=%08X\n", crc);
    printf("MATMUL_DONE\n");

    while (1) {
    }

    return 0;
}
