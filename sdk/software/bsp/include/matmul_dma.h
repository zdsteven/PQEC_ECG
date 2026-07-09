#ifndef MATMUL_DMA_H
#define MATMUL_DMA_H

#include "common_func.h"

#define MATMUL_DMA_BASE_ADDR          0xbf300000u
#define MATMUL_DMA_CTRL_ADDR          (MATMUL_DMA_BASE_ADDR + 0x00u)
#define MATMUL_DMA_STATUS_ADDR        (MATMUL_DMA_BASE_ADDR + 0x04u)
#define MATMUL_DMA_SRC_BASE_ADDR      (MATMUL_DMA_BASE_ADDR + 0x08u)
#define MATMUL_DMA_DST_BASE_ADDR      (MATMUL_DMA_BASE_ADDR + 0x0cu)
#define MATMUL_DMA_GROUP_NUM_ADDR     (MATMUL_DMA_BASE_ADDR + 0x10u)
#define MATMUL_DMA_CRC32_ADDR         (MATMUL_DMA_BASE_ADDR + 0x20u)

#define MATMUL_DMA_STATUS_BUSY        0x00000001u
#define MATMUL_DMA_STATUS_DONE        0x00000002u
#define MATMUL_DMA_STATUS_ERROR       0x00000004u
#define MATMUL_DMA_MAX_GROUPS         5000u

int MATMUL_DMA_Start(U32 src_phys, U32 dst_phys, U32 groups);
int MATMUL_DMA_Wait(U32 timeout_polls);
U32 MATMUL_DMA_Get_Status(void);
U32 MATMUL_DMA_Get_CRC32(void);

#endif
