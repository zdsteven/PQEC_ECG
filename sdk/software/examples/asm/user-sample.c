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
#define UART_DATA_ADDR         0xbf000000u
#define UART_LSR_ADDR          0xbf000005u
#define UART_LSR_TFE           0x20u

static void uart_send_byte(U8 value)
{
    while ((*(volatile U8 *)UART_LSR_ADDR & UART_LSR_TFE) == 0u) {
    }
    *(volatile U8 *)UART_DATA_ADDR = value;
}

static void uart_send_crc_and_done(U32 crc)
{
    static const char suffix[] = "\nMATMUL_DONE\n";
    U32 i;

    for (i = 0u; i < 8u; ++i) {
        U32 shift = 28u - (i << 2);
        U32 digit = (crc >> shift) & 0x0fu;
        uart_send_byte((U8)(digit < 10u ? ('0' + digit) : ('A' + digit - 10u)));
    }
    for (i = 0u; i < (U32)(sizeof(suffix) - 1u); ++i)
        uart_send_byte((U8)suffix[i]);
}

int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    /* DMA starts from its fixed evaluation defaults at reset release. */
    (void)MATMUL_DMA_Wait(0u);
    uart_send_crc_and_done(MATMUL_DMA_Get_CRC32());

    while (1) {
    }

    return 0;
}
