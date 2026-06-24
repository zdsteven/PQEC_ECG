#ifndef MATMUL_H
#define MATMUL_H

#include "common_func.h"

#define MATMUL_BASEADDR 0xbf500000u

#define MATMUL_CTRL_ADDR       (MATMUL_BASEADDR + 0x00)
#define MATMUL_STATUS_ADDR     (MATMUL_BASEADDR + 0x04)
#define MATMUL_SRC_BASE_ADDR   (MATMUL_BASEADDR + 0x08)
#define MATMUL_DST_BASE_ADDR   (MATMUL_BASEADDR + 0x0c)
#define MATMUL_GROUP_NUM_ADDR  (MATMUL_BASEADDR + 0x10)
#define MATMUL_A_BASE_ADDR     (MATMUL_BASEADDR + 0x20)
#define MATMUL_B_BASE_ADDR     (MATMUL_BASEADDR + 0x60)
#define MATMUL_C_BASE_ADDR     (MATMUL_BASEADDR + 0xa0)

#define MATMUL_CTRL_START      0x1u
#define MATMUL_CTRL_CLEARDONE  0x2u

#define MATMUL_STATUS_BUSY     0x1u
#define MATMUL_STATUS_DONE     0x2u
#define MATMUL_STATUS_ERROR    0x4u

#define MATMUL_MATRIX_WORDS    16u
#define MATMUL_RESULT_WORDS    48u

void MATMul_Write_A(const uint32_t *a);
void MATMul_Write_B(const uint32_t *b);
void MATMul_Read_C(uint32_t *c);
void MATMul_Start(void);
void MATMul_Clear_Done(void);
uint32_t MATMul_Is_Busy(void);
uint32_t MATMul_Is_Done(void);
uint32_t MATMul_Has_Error(void);
/* Single-group register-window path, useful for bring-up and debugging. */
void MATMul_Compute(const uint32_t *a, const uint32_t *b, uint32_t *c);
/* Fast benchmark path: DMA reads all groups, computes, writes results, and CRCs. */
int MATMul_Compute_Batch_DMA(uint32_t src_addr, uint32_t dst_addr, uint32_t group_num, uint32_t timeout_cycles);
uint32_t MATMul_Get_Batch_CRC(void);

#endif
