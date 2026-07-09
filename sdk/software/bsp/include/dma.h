#ifndef MATMUL_DMA_H
#define MATMUL_DMA_H

#include "common_func.h"

#define DMA_BASE_ADDR          0xbf300000u
#define DMA_CTRL_ADDR          (DMA_BASE_ADDR + 0x00u)
#define DMA_STATUS_ADDR        (DMA_BASE_ADDR + 0x04u)
#define DMA_SRC_BASE_ADDR      (DMA_BASE_ADDR + 0x08u)
#define DMA_DST_BASE_ADDR      (DMA_BASE_ADDR + 0x0cu)
#define DMA_GROUP_NUM_ADDR     (DMA_BASE_ADDR + 0x10u)
#define DMA_READ_COUNT_ADDR    (DMA_BASE_ADDR + 0x14u)
#define DMA_CALC_COUNT_ADDR    (DMA_BASE_ADDR + 0x18u)
#define DMA_WRITE_COUNT_ADDR   (DMA_BASE_ADDR + 0x1cu)
#define DMA_CRC32_ADDR         (DMA_BASE_ADDR + 0x20u)

#define DMA_STATUS_BUSY        0x00000001u
#define DMA_STATUS_DONE        0x00000002u
#define DMA_STATUS_ERROR       0x00000004u
#define DMA_MAX_GROUPS         5000u

int DMA_MatMul_Start(U32 src_phys, U32 dst_phys, U32 groups);
int DMA_Wait(U32 timeout_polls);
U32 DMA_Get_Status(void);
U32 DMA_Get_Read_Count(void);
U32 DMA_Get_Calc_Count(void);
U32 DMA_Get_Write_Count(void);
U32 DMA_Get_CRC32(void);

#endif
