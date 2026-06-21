#include "matmul.h"

void MATMul_Write_A(const uint32_t *a)
{
    uint32_t i;
    for (i = 0; i < MATMUL_MATRIX_WORDS; i++) {
        RegWrite(MATMUL_A_BASE_ADDR + (i << 2), a[i]);
    }
}

void MATMul_Write_B(const uint32_t *b)
{
    uint32_t i;
    for (i = 0; i < MATMUL_MATRIX_WORDS; i++) {
        RegWrite(MATMUL_B_BASE_ADDR + (i << 2), b[i]);
    }
}

void MATMul_Read_C(uint32_t *c)
{
    uint32_t i;
    for (i = 0; i < MATMUL_RESULT_WORDS; i++) {
        c[i] = RegRead(MATMUL_C_BASE_ADDR + (i << 2));
    }
}

void MATMul_Start(void)
{
    RegWrite(MATMUL_CTRL_ADDR, MATMUL_CTRL_START);
}

void MATMul_Clear_Done(void)
{
    RegWrite(MATMUL_CTRL_ADDR, MATMUL_CTRL_CLEARDONE);
}

uint32_t MATMul_Is_Busy(void)
{
    return RegRead(MATMUL_STATUS_ADDR) & MATMUL_STATUS_BUSY;
}

uint32_t MATMul_Is_Done(void)
{
    return (RegRead(MATMUL_STATUS_ADDR) & MATMUL_STATUS_DONE) != 0;
}

uint32_t MATMul_Has_Error(void)
{
    return (RegRead(MATMUL_STATUS_ADDR) & MATMUL_STATUS_ERROR) != 0;
}

void MATMul_Compute(const uint32_t *a, const uint32_t *b, uint32_t *c)
{
    MATMul_Write_A(a);
    MATMul_Write_B(b);
    MATMul_Start();
    while (MATMul_Is_Busy()) {
    }
    MATMul_Read_C(c);
}
