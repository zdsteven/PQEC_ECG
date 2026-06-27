#ifndef MATMUL_H
#define MATMUL_H

#include "common_func.h"

#define MATMUL_BASE_ADDR       0xbf500000u
#define MATMUL_CTRL_ADDR       (MATMUL_BASE_ADDR + 0x00u)
#define MATMUL_STATUS_ADDR     (MATMUL_BASE_ADDR + 0x04u)
#define MATMUL_A_BASE_ADDR     (MATMUL_BASE_ADDR + 0x20u)
#define MATMUL_B_BASE_ADDR     (MATMUL_BASE_ADDR + 0x60u)
#define MATMUL_C_BASE_ADDR     (MATMUL_BASE_ADDR + 0xa0u)

#define MATMUL_STATUS_BUSY     0x00000001u
#define MATMUL_STATUS_DONE     0x00000002u
#define MATMUL_STATUS_ERROR    0x00000004u

void MATMul_Write_A(const U32 *matrix);
void MATMul_Write_B(const U32 *matrix);
void MATMul_Start(void);
int MATMul_Wait(U32 timeout_polls);
void MATMul_Read_C(U32 *packed_result);

#endif
