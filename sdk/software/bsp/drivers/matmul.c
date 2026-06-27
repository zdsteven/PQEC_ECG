#include "matmul.h"

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
