#include "matmul_dma.h"

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
    (void)argc;
    (void)argv;

    /* DMA starts from its fixed evaluation defaults at reset release. */
    (void)MatMulDMA_Wait(0u);

    while (1) {
    }

    return 0;
}
