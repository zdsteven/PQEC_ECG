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
#define UART_TX_ADDR           (UART_BASE + 0u)
#define UART_LSR_ADDR          (UART_BASE + 5u)
#define UART_LSR_THRE          0x20u

static void UART_Send_Fixed(const char *data, U32 length)
{
    U32 sent = 0u;

    while (sent < length) {
        while ((*(volatile U8 *)UART_LSR_ADDR & UART_LSR_THRE) == 0u) {
        }
        *(volatile U8 *)UART_TX_ADDR = (U8)data[sent];
        ++sent;
    }
}

int main(int argc, char **argv)
{
    U32 crc;
    U32 i;
    char finish_text[34];
    static const char start_text[13] = "MATMUL_START\n";
    static const char hex[16] = "0123456789ABCDEF";
    static const char crc_prefix[13] = "MATMUL_CRC32=";
    static const char done_suffix[13] = "\nMATMUL_DONE\n";

    (void)argc;
    (void)argv;

    (void)DMA_MatMul_Start(EXTRAM_PHYS_BASE,
                           EXTRAM_PHYS_BASE + MATMUL_INPUT_BYTES,
                           (U32)MATMUL_GROUP_NUM);
    UART_Send_Fixed(start_text, 13u);
    (void)DMA_Wait(0u);

    // CRC is accumulated by hardware from the exact words accepted on AXI W.
    // This avoids a second 960000-byte uncached scan of ExtRAM.
    crc = DMA_Get_CRC32();
    for (i = 0u; i < 13u; ++i)
        finish_text[i] = crc_prefix[i];
    for (i = 0u; i < 8u; ++i)
        finish_text[13u + i] = hex[(crc >> (28u - (i << 2))) & 0x0fu];
    for (i = 0u; i < 13u; ++i)
        finish_text[21u + i] = done_suffix[i];
    UART_Send_Fixed(finish_text, 34u);

    while (1) {
    }

    return 0;
}
