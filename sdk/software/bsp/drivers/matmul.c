#include "matmul.h"
#include "dma.h"

#define MATMUL_CACHE_LINE_BYTES 16u

static void MATMul_Cache_Sync(const U32 *buffer, U32 words)
{
    U32 begin = ((U32)buffer) & ~(MATMUL_CACHE_LINE_BYTES - 1u);
    U32 end = ((U32)(buffer + words) + MATMUL_CACHE_LINE_BYTES - 1u) &
              ~(MATMUL_CACHE_LINE_BYTES - 1u);
    U32 address;

    if ((((U32)buffer) & 0xe0000000u) == 0xa0000000u)
        return;
    for (address = begin; address < end;
         address += MATMUL_CACHE_LINE_BYTES)
        flush_dcache_line((unsigned long)address);
}

void MATMul_Write_A(const U32 *matrix)
{
    U32 i;
    for (i = 0u; i < 16u; ++i)
        RegWrite(MATMUL_A_BASE_ADDR + (i << 2), matrix[i]);
}

void MATMul_Write_B(const U32 *matrix)
{
    U32 i;
    for (i = 0u; i < 16u; ++i)
        RegWrite(MATMUL_B_BASE_ADDR + (i << 2), matrix[i]);
}

void MATMul_Start(void)
{
    RegWrite(MATMUL_STATUS_ADDR, MATMUL_STATUS_DONE | MATMUL_STATUS_ERROR);
    RegWrite(MATMUL_CTRL_ADDR, 1u);
}

int MATMul_Wait(U32 timeout_polls)
{
    U32 polls = 0u;
    U32 status;

    for (;;) {
        status = RegRead(MATMUL_STATUS_ADDR);
        if ((status & MATMUL_STATUS_DONE) != 0u)
            return ((status & MATMUL_STATUS_ERROR) != 0u) ? -2 : 0;
        if ((timeout_polls != 0u) && (++polls >= timeout_polls))
            return -1;
    }
}

void MATMul_Read_C(U32 *packed_result)
{
    U32 i;
    for (i = 0u; i < 48u; ++i)
        packed_result[i] = RegRead(MATMUL_C_BASE_ADDR + (i << 2));
}

int MATMul_Compute_CPU(const U32 *matrix_a, const U32 *matrix_b,
                       U32 *packed_result, U32 timeout_polls)
{
    int rc;

    if ((matrix_a == 0) || (matrix_b == 0) || (packed_result == 0))
        return -1;

    /* Start first: every subsequent input-window write is consumed directly
     * by the same stream interface used by the evaluation DMA. */
    MATMul_Start();
    MATMul_Write_A(matrix_a);
    MATMul_Write_B(matrix_b);
    rc = MATMul_Wait(timeout_polls);
    if (rc != 0)
        return -2;
    MATMul_Read_C(packed_result);
    return 0;
}

int MATMul_Compute_DMA(const U32 *matrix_words, U32 *packed_result,
                       U32 dma_timeout_polls, U32 matmul_timeout_polls)
{
    int rc;

    if ((matrix_words == 0) || (packed_result == 0) ||
        ((((U32)matrix_words) | ((U32)packed_result)) & 3u) != 0u)
        return -1;

    /* This API requires the generic AXI DMA selected in config.h. */
    if (RegRead(DMA_VERSION_ADDR) != 0x41584402u)
        return -2;

    MATMul_Cache_Sync(matrix_words, MATMUL_INPUT_WORDS);
    MATMul_Cache_Sync(packed_result, MATMUL_RESULT_WORDS);

    MATMul_Start();
    rc = DMA_Transfer_Blocking((U32)matrix_words, MATMUL_INPUT_PHYS_ADDR,
                               MATMUL_INPUT_WORDS * 4u, dma_timeout_polls);
    if (rc != 0)
        return -3;

    rc = MATMul_Wait(matmul_timeout_polls);
    if (rc != 0)
        return -4;

    rc = DMA_Transfer_Blocking(MATMUL_RESULT_PHYS_ADDR, (U32)packed_result,
                               MATMUL_RESULT_WORDS * 4u, dma_timeout_polls);
    if (rc != 0)
        return -5;

    MATMul_Cache_Sync(packed_result, MATMUL_RESULT_WORDS);
    return 0;
}
