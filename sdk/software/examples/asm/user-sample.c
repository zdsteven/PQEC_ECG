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
#define MATMUL_RESULT_BASE     (EXTRAM_PHYS_BASE + MATMUL_INPUT_BYTES)
#define CRC_PREFIX_GROUP       1582u

#define UART_TX_ADDR           (UART_BASE + 0u)
#define UART_LSR_ADDR          (UART_BASE + 5u)
#define UART_LSR_TFE           0x20u
#define UART_LSR_TE            0x40u

static void uart_write_byte(U8 value)
{
    *((volatile U8 *)UART_TX_ADDR) = value;
}

static U8 uart_line_status(void)
{
    return *((volatile U8 *)UART_LSR_ADDR);
}

static U8 hex_char(U32 nibble)
{
    return (nibble < 10u) ? (U8)('0' + nibble) :
                            (U8)('A' + nibble - 10u);
}

static void uart_write_crc_and_done(U32 crc)
{
    static const U8 done_line[13] = {
        '\n', 'M', 'A', 'T', 'M', 'U', 'L', '_',
        'D', 'O', 'N', 'E', '\n'
    };
    U32 index;

    /* '=' is now in the transmitter.  Fill the FIFO before that character's
     * stop bit completes, preserving a gapless prefix/CRC/DONE stream. */
    while ((uart_line_status() & UART_LSR_TFE) == 0u) {
    }
    for (index = 0u; index < 8u; ++index)
        uart_write_byte(hex_char((crc >> (28u - index * 4u)) & 0x0fu));
    for (index = 0u; index < 8u; ++index)
        uart_write_byte(done_line[index]);

    while ((uart_line_status() & UART_LSR_TFE) == 0u) {
    }
    for (index = 8u; index < 13u; ++index)
        uart_write_byte(done_line[index]);
}

int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    static const U8 crc_prefix[13] = {
        'M', 'A', 'T', 'M', 'U', 'L', '_',
        'C', 'R', 'C', '3', '2', '='
    };
    U32 index;
    U32 crc;

#if EVAL_FAST_DMA_START
    /* START was queued by the CPU in start.S.  Do not permit the first
     * ExtRAM read until its final stop bit has physically completed. */
    while ((uart_line_status() & UART_LSR_TE) == 0u) {
    }
    RegWrite(MATMUL_DMA_CTRL_ADDR, 1u);
#else
    if (MATMUL_DMA_Start(EXTRAM_PHYS_BASE, MATMUL_RESULT_BASE,
                         MATMUL_GROUP_NUM) != 0) {
        while (1) {
        }
    }
#endif

    while (MATMUL_DMA_Get_Read_Groups() < CRC_PREFIX_GROUP) {
    }
    for (index = 0u; index < 13u; ++index)
        uart_write_byte(crc_prefix[index]);

    if (MATMUL_DMA_Wait(0u) != 0) {
        while (1) {
        }
    }
    crc = MATMUL_DMA_Get_CRC32();
    uart_write_crc_and_done(crc);

    while (1) {
    }

    return 0;
}
