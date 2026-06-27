#include "dma.h"

U32 DMA_Get_Status(void)
{
    return RegRead(DMA_STATUS_ADDR);
}

U32 DMA_Get_Read_Count(void)
{
    return RegRead(DMA_READ_COUNT_ADDR);
}

U32 DMA_Get_Calc_Count(void)
{
    return RegRead(DMA_CALC_COUNT_ADDR);
}

U32 DMA_Get_Write_Count(void)
{
    return RegRead(DMA_WRITE_COUNT_ADDR);
}

int DMA_MatMul_Start(U32 src_phys, U32 dst_phys, U32 groups)
{
    U32 status = DMA_Get_Status();

    if ((status & DMA_STATUS_BUSY) != 0u)
        return -1;
    if ((groups == 0u) || (groups > DMA_MAX_GROUPS))
        return -2;
    if (((src_phys | dst_phys) & 3u) != 0u)
        return -3;

    RegWrite(DMA_STATUS_ADDR, DMA_STATUS_DONE | DMA_STATUS_ERROR);
    RegWrite(DMA_SRC_BASE_ADDR, src_phys);
    RegWrite(DMA_DST_BASE_ADDR, dst_phys);
    RegWrite(DMA_GROUP_NUM_ADDR, groups);
    RegWrite(DMA_CTRL_ADDR, 1u);
    return 0;
}

int DMA_Wait(U32 timeout_polls)
{
    U32 polls = 0u;
    U32 status;

    for (;;) {
        status = DMA_Get_Status();
        if ((status & DMA_STATUS_DONE) != 0u)
            return ((status & DMA_STATUS_ERROR) != 0u) ? -2 : 0;

        if ((timeout_polls != 0u) && (++polls >= timeout_polls))
            return -1;
    }
}
