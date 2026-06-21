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

/* Precomputed CRC32 lookup table for single-byte values (only 0x00 entry needed
   for the CRC pass, but we compute on-the-fly to save code size) */
static unsigned int crc32_byte(unsigned int crc, unsigned char b)
{
    int j;
    crc ^= b;
    for (j = 0; j < 8; j++) {
        if (crc & 1)
            crc = (crc >> 1) ^ 0xedb88320u;
        else
            crc = crc >> 1;
    }
    return crc;
}

/* Inline helper: compute CRC32 for one 32-bit word */
static inline unsigned int crc32_word(unsigned int crc, unsigned int word)
{
    crc = crc32_byte(crc, (unsigned char)(word        & 0xff));
    crc = crc32_byte(crc, (unsigned char)((word >> 8)  & 0xff));
    crc = crc32_byte(crc, (unsigned char)((word >> 16) & 0xff));
    return crc32_byte(crc, (unsigned char)((word >> 24) & 0xff));
}

int main(int argc, char **argv)
{
    volatile unsigned int *input_base;
    volatile unsigned int *result_base;
    unsigned int group, w, crc;
    (void)argc;
    (void)argv;

    input_base  = (volatile unsigned int *)(EXTRAM_BASE + INPUT_OFFSET);
    result_base = (volatile unsigned int *)(EXTRAM_BASE + RESULT_OFFSET);

    printf("MATMUL_START\n");

    crc = 0xffffffffu;

    /* Main computation loop — inline register access, no intermediate copies */
    for (group = 0; group < MATMUL_GROUP_NUM; group++) {
        volatile unsigned int *grp_in  = input_base  + (group * 32);
        volatile unsigned int *grp_out = result_base + (group * 48);
        volatile unsigned int *mm_a    = (volatile unsigned int *)MATMUL_A_BASE_ADDR;
        volatile unsigned int *mm_b    = (volatile unsigned int *)MATMUL_B_BASE_ADDR;
        volatile unsigned int *mm_c    = (volatile unsigned int *)MATMUL_C_BASE_ADDR;

        /* Stream A[16] from ExtRAM directly to matmul A registers */
        for (w = 0; w < 16; w++) {
            mm_a[w] = grp_in[w];
        }
        /* Stream B[16] from ExtRAM directly to matmul B registers */
        for (w = 0; w < 16; w++) {
            mm_b[w] = grp_in[16 + w];
        }

        /* Start computation */
        *(volatile unsigned int *)MATMUL_CTRL_ADDR = MATMUL_CTRL_START;

        /* Wait for completion */
        while (*(volatile unsigned int *)MATMUL_STATUS_ADDR & MATMUL_STATUS_BUSY) {
        }

        /* Read C[48] from matmul registers, write to ExtRAM, and accumulate CRC32 */
        for (w = 0; w < 48; w++) {
            unsigned int val = mm_c[w];
            grp_out[w] = val;
            crc = crc32_word(crc, val);
        }
    }

    crc ^= 0xffffffffu;

    printf("MATMUL_CRC32=%08x\n", crc);
    printf("MATMUL_DONE\n");

    while (1) {
    }
}
