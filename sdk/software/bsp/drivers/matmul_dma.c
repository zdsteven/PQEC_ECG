#include "matmul_dma.h"

U32 MATMUL_DMA_Get_Status(void)
{
    return RegRead(MATMUL_DMA_STATUS_ADDR);
}

U32 MATMUL_DMA_Get_CRC32(void)
{
    return RegRead(MATMUL_DMA_CRC32_ADDR);
}

U32 MATMUL_DMA_Get_Read_Groups(void)
{
    return RegRead(MATMUL_DMA_READ_GROUPS_ADDR);
}

int MATMUL_DMA_Start(U32 src_phys, U32 dst_phys, U32 groups)
{
    U32 status = MATMUL_DMA_Get_Status();

    if ((status & MATMUL_DMA_STATUS_BUSY) != 0u)
        return -1;
    if ((groups == 0u) || (groups > MATMUL_DMA_MAX_GROUPS))
        return -2;
    if (((src_phys | dst_phys) & 3u) != 0u)
        return -3;

    RegWrite(MATMUL_DMA_STATUS_ADDR, MATMUL_DMA_STATUS_DONE | MATMUL_DMA_STATUS_ERROR);
    RegWrite(MATMUL_DMA_SRC_BASE_ADDR, src_phys);
    RegWrite(MATMUL_DMA_DST_BASE_ADDR, dst_phys);
    RegWrite(MATMUL_DMA_GROUP_NUM_ADDR, groups);
    RegWrite(MATMUL_DMA_CTRL_ADDR, 1u);
    return 0;
}

int MATMUL_DMA_Wait(U32 timeout_polls)
{
    U32 polls = 0u;
    U32 status;

    for (;;) {
        status = MATMUL_DMA_Get_Status();
        if ((status & MATMUL_DMA_STATUS_DONE) != 0u)
            return ((status & MATMUL_DMA_STATUS_ERROR) != 0u) ? -2 : 0;

        if ((timeout_polls != 0u) && (++polls >= timeout_polls))
            return -1;
    }
}
