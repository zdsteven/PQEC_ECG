#include <stdio.h>
#include "matmul.h"
#include "dma.h"
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

#define DMA_CTRL_REG   (DMA_BASEADDR + 0x00)
#define DMA_STATUS_REG (DMA_BASEADDR + 0x04)
#define DMA_SRC_REG    (DMA_BASEADDR + 0x08)
#define DMA_DST_REG    (DMA_BASEADDR + 0x0c)
#define DMA_LEN_REG    (DMA_BASEADDR + 0x10)

#define MATMUL_AB_BUS_ADDR  (MATMUL_A_BASE_ADDR & 0x1fffffffu)
#define GROUP_BYTES         128u

/* CRC32 lookup table — generated at startup to avoid 1KB in binary */
static unsigned int crc_tab[256];

static void crc_init(void)
{
    unsigned int i, j, c;
    for (i = 0; i < 256; i++) {
        c = i;
        for (j = 0; j < 8; j++)
            c = (c >> 1) ^ (0xedb88320u & (-(c & 1)));
        crc_tab[i] = c;
    }
}

static inline unsigned int crc32_word(unsigned int crc, unsigned int word)
{
    crc = crc_tab[(crc ^ word) & 0xff] ^ (crc >> 8);
    crc = crc_tab[(crc ^ (word >> 8)) & 0xff] ^ (crc >> 8);
    crc = crc_tab[(crc ^ (word >> 16)) & 0xff] ^ (crc >> 8);
    return crc_tab[(crc ^ (word >> 24)) & 0xff] ^ (crc >> 8);
}

static inline void dma_fast(unsigned int src, unsigned int dst, unsigned int len)
{
    RegWrite(DMA_SRC_REG, src);
    RegWrite(DMA_DST_REG, dst);
    RegWrite(DMA_LEN_REG, len);
    RegWrite(DMA_CTRL_REG, 0x2);
    RegWrite(DMA_CTRL_REG, 0x1);
    while (RegRead(DMA_STATUS_REG) & 0x1) {}
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

    crc_init();

    printf("MATMUL_START\n");

    crc = 0xffffffffu;

    for (group = 0; group < MATMUL_GROUP_NUM; group++) {
        unsigned int grp_bus_addr = (unsigned int)(unsigned long)input_base + (group << 7);
        volatile unsigned int *grp_out = result_base + (group * 48);
        volatile unsigned int *mm_c    = (volatile unsigned int *)MATMUL_C_BASE_ADDR;

        /* DMA burst: A[16]+B[16] → matmul registers */
        dma_fast(grp_bus_addr, MATMUL_AB_BUS_ADDR, GROUP_BYTES);

        /* Compute */
        *(volatile unsigned int *)MATMUL_CTRL_ADDR = MATMUL_CTRL_START;
        while (*(volatile unsigned int *)MATMUL_STATUS_ADDR & MATMUL_STATUS_BUSY) {}

        /* Read results + CRC (merge to avoid separate CRC pass) */
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
