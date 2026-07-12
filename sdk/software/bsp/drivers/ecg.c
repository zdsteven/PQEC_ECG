#include "ecg.h"
#include "dma.h"
#include <stdint.h>

static void flush_cache_lines(const void *buffer, uint32_t byte_length)
{
    uintptr_t address;
    uintptr_t first;
    uintptr_t last;
    uintptr_t line_bytes = (uintptr_t)1u << cache_offset_width;

    first = (uintptr_t)buffer & ~(line_bytes - 1u);
    last = ((uintptr_t)buffer + byte_length + line_bytes - 1u) & ~(line_bytes - 1u);
    for (address = first; address < last; address += line_bytes) {
        flush_dcache_line((unsigned long)address);
    }
}

void ecg_load(U8 *ecg_data)
{
    flush_cache_lines(ecg_data, 200u);
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)ecg_data, ECG_DATA_BASE_ADDR, 200u, 0);
}

void ecg_start(void)
{
    RegWrite(ECG_CTRL_ADDR, 0x1u);
}

U8 ecg_read_result(U8 result[5])
{
    uint32_t result_reg0;
    uint32_t result_reg1;

    while (ECG_IS_BUSY);

    result_reg0 = RegRead(ECG_RESULT_ADDR_0);
    result_reg1 = RegRead(ECG_RESULT_ADDR_1);

    if (result != 0) {
        result[0] = (U8)(result_reg0 >> 8);
        result[1] = (U8)(result_reg0 >> 16);
        result[2] = (U8)(result_reg0 >> 24);
        result[3] = (U8)result_reg1;
        result[4] = (U8)(result_reg1 >> 8);
    }

    return (U8)(result_reg0 & 0x7u);
}
