#include "matmul.h"

// =============================================================================
//  矩阵乘法加速器 HAL 驱动实现
// =============================================================================

void MATMul_Start(void)
{
    RegWrite(MATMUL_CTRL_ADDR, 1);
}

uint32_t MATMul_Is_Busy(void)
{
    return RegRead(MATMUL_STATUS_ADDR) & MATMUL_STATUS_BUSY;
}

uint32_t MATMul_Is_Done(void)
{
    return (RegRead(MATMUL_STATUS_ADDR) & MATMUL_STATUS_DONE) >> 1;
}

void MATMul_Wait_Done(void)
{
    while (!MATMul_Is_Done())
        ;
}

void MATMul_Write_A(volatile uint32_t *a)
{
    volatile uint32_t *reg = (volatile uint32_t *)MATMUL_A_DATA_BASE;
    int i;
    for (i = 0; i < 16; i++) {
        reg[i] = a[i];
    }
}

void MATMul_Write_B(volatile uint32_t *b)
{
    volatile uint32_t *reg = (volatile uint32_t *)MATMUL_B_DATA_BASE;
    int i;
    for (i = 0; i < 16; i++) {
        reg[i] = b[i];
    }
}

void MATMul_Read_C(volatile uint32_t *c)
{
    volatile uint32_t *reg = (volatile uint32_t *)MATMUL_C_DATA_BASE;
    int i;
    for (i = 0; i < 48; i++) {
        c[i] = reg[i];
    }
}

void MATMul_Compute(volatile uint32_t *a, volatile uint32_t *b, volatile uint32_t *c)
{
    MATMul_Write_A(a);
    MATMul_Write_B(b);
    MATMul_Start();
    MATMul_Wait_Done();
    MATMul_Read_C(c);
}
