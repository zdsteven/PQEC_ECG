#ifndef MATMUL_H
#define MATMUL_H

#include "common_func.h"

#define MATMUL_BASE_ADDR       0xbf500000u
#define MATMUL_CTRL_ADDR       (MATMUL_BASE_ADDR + 0x00u)
#define MATMUL_STATUS_ADDR     (MATMUL_BASE_ADDR + 0x04u)
#define MATMUL_A_BASE_ADDR     (MATMUL_BASE_ADDR + 0x20u)
#define MATMUL_B_BASE_ADDR     (MATMUL_BASE_ADDR + 0x60u)
#define MATMUL_C_BASE_ADDR     (MATMUL_BASE_ADDR + 0xa0u)
#define MATMUL_INPUT_PHYS_ADDR 0x1f500020u
#define MATMUL_RESULT_PHYS_ADDR 0x1f5000a0u
#define MATMUL_INPUT_WORDS     32u
#define MATMUL_RESULT_WORDS    48u

#define MATMUL_STATUS_BUSY     0x00000001u
#define MATMUL_STATUS_DONE     0x00000002u
#define MATMUL_STATUS_ERROR    0x00000004u

/* Low-level stream sequence: Start, Write_A, Write_B, Wait, Read_C. */
void MATMul_Write_A(const U32 *matrix);
void MATMul_Write_B(const U32 *matrix);
void MATMul_Start(void);
int MATMul_Wait(U32 timeout_polls);
void MATMul_Read_C(U32 *packed_result);

/* All inputs use the stream order A[0..15], then B[0..15]. */
int MATMul_Compute_CPU(const U32 *matrix_a, const U32 *matrix_b,
                       U32 *packed_result, U32 timeout_polls);

/* Generic-DMA mode: matrix_words must contain A[16] followed by B[16]. */
int MATMul_Compute_DMA(const U32 *matrix_words, U32 *packed_result,
                       U32 dma_timeout_polls, U32 matmul_timeout_polls);

#endif
