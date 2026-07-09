#include <stdio.h>

#include "dma.h"
#include "led.h"

unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#define DMA_WORDS 64

static U32 src_buf[DMA_WORDS] __attribute__((aligned(64)));
static U32 dst_buf[DMA_WORDS] __attribute__((aligned(64)));

static void flush_buffer_lines(U32 *buf, U32 words)
{
    U32 i;
    for (i = 0; i < words; ++i) {
        flush_dcache_line((unsigned long)&buf[i]);
    }
}

int main(int argc, char **argv)
{
    U32 i;
    int rc;
    U32 status;
    U32 mismatch = 0;

    (void)argc;
    (void)argv;

    for (i = 0; i < DMA_WORDS; ++i) {
        src_buf[i] = 0x5a5a0000u + i;
        dst_buf[i] = 0;
    }

    flush_buffer_lines(src_buf, DMA_WORDS);
    flush_buffer_lines(dst_buf, DMA_WORDS);

    rc = DMA_Transfer_Blocking((U32)src_buf, (U32)dst_buf, DMA_WORDS * 4, 1000000);
    status = DMA_Get_Status();

    flush_buffer_lines(dst_buf, DMA_WORDS);

    for (i = 0; i < DMA_WORDS; ++i) {
        if (dst_buf[i] != src_buf[i]) {
            mismatch++;
        }
    }

    printf("dma_demo rc=%d status=0x%08x mismatch=%u\n", rc, status, mismatch);
    printf("dma_demo cur_src=0x%08x cur_dst=0x%08x remain=%u\n",
           RegRead(DMA_CUR_SRC_ADDR),
           RegRead(DMA_CUR_DST_ADDR),
           RegRead(DMA_REMAIN_ADDR));

    if ((rc == 0) && (mismatch == 0)) {
        setLedPin(0x00ff);
        printf("dma_demo PASS\n");
    }
    else {
        setLedPin(0xff00);
        printf("dma_demo FAIL\n");
    }

    while (1) {
    }

    return 0;
}
