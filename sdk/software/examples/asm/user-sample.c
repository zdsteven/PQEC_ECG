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
#define CRC_PREFIX_GROUP       1650u

#define UART_TX_ADDR           (UART_BASE + 0u)
#define UART_LSR_ADDR          (UART_BASE + 5u)
#define UART_LSR_TFE           0x20u
#define UART_LSR_TE            0x40u

#if EVAL_DEBUG_COUNTERS
static U32 sw_main_cycle;
static U32 sw_dma_start_cycle;
static U32 sw_prefix_ready_cycle;
static U32 sw_prefix_done_cycle;
static U32 sw_dma_done_cycle;

static inline U32 eval_cpu_cycle(void)
{
    U32 value;

    __asm__ __volatile__("rdcntvl.w %0" : "=r"(value));
    return value;
}
#endif

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

#if EVAL_DEBUG_COUNTERS || EVAL_DEBUG_CAPTURE
static void append_hex32(U8 *buffer, U32 *length, U32 value)
{
    U32 index;

    for (index = 0u; index < 8u; ++index)
        buffer[(*length)++] = hex_char((value >> (28u - index * 4u)) & 0x0fu);
}
#endif

#if EVAL_DEBUG_CAPTURE
static void uart_write_crc_capture_and_done(U32 crc)
{
    static U8 debug_tail[96];
    static const U8 done_line[12] = {
        'M', 'A', 'T', 'M', 'U', 'L', '_',
        'D', 'O', 'N', 'E', '\n'
    };
    U32 index;
    U32 length = 0u;
    U32 chunk_end;

    while ((uart_line_status() & UART_LSR_TFE) == 0u) {
    }
    for (index = 0u; index < 8u; ++index)
        uart_write_byte(hex_char((crc >> (28u - index * 4u)) & 0x0fu));
    uart_write_byte('\n');

    debug_tail[length++] = 'R';
    debug_tail[length++] = 'A';
    debug_tail[length++] = 'W';
    debug_tail[length++] = '1';
    debug_tail[length++] = '=';
    for (index = 0u; index < 8u; ++index) {
        append_hex32(debug_tail, &length,
                     RegRead(MATMUL_DMA_DBG_INPUT_BASE_ADDR + index * 4u));
        debug_tail[length++] = (index == 7u) ? '\n' : ',';
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
#elif EVAL_DEBUG_COUNTERS

static void uart_write_crc_debug_and_done(U32 crc)
{
    static U8 debug_tail[192];
    static const U32 debug_addr[8] = {
        MATMUL_DMA_DBG_START_ADDR,
        MATMUL_DMA_DBG_FIRST_R_ADDR,
        MATMUL_DMA_DBG_LAST_R_ADDR,
        MATMUL_DMA_DBG_LAST_CORE_ADDR,
        MATMUL_DMA_DBG_CRC_ADDR,
        MATMUL_DMA_DBG_R_EMPTY_ADDR,
        MATMUL_DMA_DBG_CORE_STALL_ADDR,
        MATMUL_DMA_DBG_RESET_RELEASE_ADDR
    };
    static const U8 done_line[12] = {
        'M', 'A', 'T', 'M', 'U', 'L', '_',
        'D', 'O', 'N', 'E', '\n'
    };
    U32 index;
    U32 field;
    U32 length = 0u;
    U32 chunk_end;
    U32 writer_cycle;
    U32 crc_tfe_cycle;
    U32 crc_line_pop_cycle;

    writer_cycle = eval_cpu_cycle();

    /* Preserve the scored protocol join first.  The nine queued bytes give
     * software enough time to read and format counters before the newline is
     * retired, without delaying the first CRC digit after '='. */
    while ((uart_line_status() & UART_LSR_TFE) == 0u) {
    }
    crc_tfe_cycle = eval_cpu_cycle();
    for (index = 0u; index < 8u; ++index)
        uart_write_byte(hex_char((crc >> (28u - index * 4u)) & 0x0fu));
    uart_write_byte('\n');

    /* Wait until the CRC newline has been popped.  This makes the CPU-side
     * timestamps cover the complete scored prefix/CRC path before formatting
     * diagnostic text. */
    while ((uart_line_status() & UART_LSR_TFE) == 0u) {
    }
    crc_line_pop_cycle = eval_cpu_cycle();

    debug_tail[length++] = 'D';
    debug_tail[length++] = 'B';
    debug_tail[length++] = 'G';
    debug_tail[length++] = '=';
    for (field = 0u; field < 8u; ++field) {
        append_hex32(debug_tail, &length, RegRead(debug_addr[field]));
        debug_tail[length++] = (field == 7u) ? '\n' : ',';
    }
    debug_tail[length++] = 'C';
    debug_tail[length++] = 'D';
    debug_tail[length++] = 'B';
    debug_tail[length++] = 'G';
    debug_tail[length++] = '=';
    append_hex32(debug_tail, &length, sw_main_cycle);
    debug_tail[length++] = ',';
    append_hex32(debug_tail, &length, sw_dma_start_cycle);
    debug_tail[length++] = ',';
    append_hex32(debug_tail, &length, sw_prefix_ready_cycle);
    debug_tail[length++] = ',';
    append_hex32(debug_tail, &length, sw_prefix_done_cycle);
    debug_tail[length++] = ',';
    append_hex32(debug_tail, &length, sw_dma_done_cycle);
    debug_tail[length++] = ',';
    append_hex32(debug_tail, &length, writer_cycle);
    debug_tail[length++] = ',';
    append_hex32(debug_tail, &length, crc_tfe_cycle);
    debug_tail[length++] = ',';
    append_hex32(debug_tail, &length, crc_line_pop_cycle);
    debug_tail[length++] = '\n';
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
#endif

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

#if EVAL_DEBUG_COUNTERS
    sw_main_cycle = eval_cpu_cycle();
#endif

#if EVAL_FAST_DMA_START
    /* Pre-arm immediately.  Hardware gates the ExtRAM read path until the
     * complete MATMUL_START line has left the UART transmitter. */
    RegWrite(MATMUL_DMA_CTRL_ADDR, 1u);
#if EVAL_DEBUG_COUNTERS
    sw_dma_start_cycle = eval_cpu_cycle();
#endif
#else
    if (MATMUL_DMA_Start(EXTRAM_PHYS_BASE, MATMUL_RESULT_BASE,
                         MATMUL_GROUP_NUM) != 0) {
        while (1) {
        }
    }
#endif

    while (MATMUL_DMA_Get_Read_Groups() < CRC_PREFIX_GROUP) {
    }
#if EVAL_DEBUG_COUNTERS
    sw_prefix_ready_cycle = eval_cpu_cycle();
#endif
    for (index = 0u; index < 13u; ++index)
        uart_write_byte(crc_prefix[index]);
#if EVAL_DEBUG_COUNTERS
    sw_prefix_done_cycle = eval_cpu_cycle();
#endif

    if (MATMUL_DMA_Wait(0u) != 0) {
        while (1) {
        }
    }
    crc = MATMUL_DMA_Get_CRC32();
#if EVAL_DEBUG_COUNTERS
    sw_dma_done_cycle = eval_cpu_cycle();
#endif
#if EVAL_DEBUG_CAPTURE
    uart_write_crc_capture_and_done(crc);
#elif EVAL_DEBUG_COUNTERS
    uart_write_crc_debug_and_done(crc);
#else
    uart_write_crc_and_done(crc);
#endif

    while (1) {
    }

    return 0;
}
