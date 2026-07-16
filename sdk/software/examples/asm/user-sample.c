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

#define UART_TX_ADDR           (UART_BASE + 0u)
#define UART_LSR_ADDR          (UART_BASE + 5u)
#define UART_LSR_TFE           0x20u

static void uart_write_byte(U8 value)
{
    *((volatile U8 *)UART_TX_ADDR) = value;
}

static U8 uart_line_status(void)
{
    return *((volatile U8 *)UART_LSR_ADDR);
}

#if EVAL_DEBUG_COUNTERS
static U8 hex_char(U32 nibble)
{
    return (nibble < 10u) ? (U8)('0' + nibble) :
                            (U8)('A' + nibble - 10u);
}

static void append_hex32(U8 *buffer, U32 *length, U32 value)
{
    U32 index;

    for (index = 0u; index < 8u; ++index)
        buffer[(*length)++] = hex_char((value >> (28u - index * 4u)) & 0x0fu);
}

static void uart_write_debug_and_done(void)
{
    static U8 debug_tail[80];
    static const U32 debug_addr[7] = {
        MATMUL_DMA_DBG_START_ADDR,
        MATMUL_DMA_DBG_FIRST_R_ADDR,
        MATMUL_DMA_DBG_LAST_R_ADDR,
        MATMUL_DMA_DBG_LAST_CORE_ADDR,
        MATMUL_DMA_DBG_CRC_ADDR,
        MATMUL_DMA_DBG_R_EMPTY_ADDR,
        MATMUL_DMA_DBG_CORE_STALL_ADDR
    };
    static const U8 done_line[12] = {
        'M', 'A', 'T', 'M', 'U', 'L', '_',
        'D', 'O', 'N', 'E', '\n'
    };
    U32 index;
    U32 field;
    U32 length = 0u;
    U32 chunk_end;

    debug_tail[length++] = 'D';
    debug_tail[length++] = 'B';
    debug_tail[length++] = 'G';
    debug_tail[length++] = '=';
    for (field = 0u; field < 7u; ++field) {
        append_hex32(debug_tail, &length, RegRead(debug_addr[field]));
        debug_tail[length++] = (field == 6u) ? '\n' : ',';
    }
    for (index = 0u; index < 12u; ++index)
        debug_tail[length++] = done_line[index];

    index = 0u;
    while (index < length) {
        while ((uart_line_status() & UART_LSR_TFE) == 0u) {
        }
        chunk_end = index + 16u;
        if (chunk_end > length)
            chunk_end = length;
        while (index < chunk_end)
            uart_write_byte(debug_tail[index++]);
    }
}
#else
static void uart_write_done(void)
{
    static const U8 done_line[12] = {
        'M', 'A', 'T', 'M', 'U', 'L', '_',
        'D', 'O', 'N', 'E', '\n'
    };
    U32 index;

    /* The autonomous reporter has just queued its terminating newline.  The
     * twelve-byte DONE line fits behind it in the sixteen-entry TX FIFO. */
    for (index = 0u; index < 12u; ++index)
        uart_write_byte(done_line[index]);
}
#endif

int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;

#if EVAL_FAST_DMA_START
    /* The evaluation-only reset defaults already fix SRC, DST and 5000
     * groups. Avoid a status read and four redundant configuration writes so
     * the sole CTRL write starts DMA immediately after entering main. */
    RegWrite(MATMUL_DMA_CTRL_ADDR, 1u);
#else
    if (MATMUL_DMA_Start(EXTRAM_PHYS_BASE, MATMUL_RESULT_BASE,
                         MATMUL_GROUP_NUM) != 0) {
        while (1) {
        }
    }
#endif

    if (MATMUL_DMA_Wait(0u) != 0) {
        while (1) {
        }
    }
    while ((MATMUL_DMA_Get_Status() & MATMUL_DMA_STATUS_REPORT_DONE) == 0u) {
    }
#if EVAL_DEBUG_COUNTERS
    uart_write_debug_and_done();
#else
    uart_write_done();
#endif

    while (1) {
    }

    return 0;
}
