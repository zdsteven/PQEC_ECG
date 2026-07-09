#ifndef AXI_DMA_H
#define AXI_DMA_H

#include "common_func.h"

#ifndef AXI_DMA_BASE_ADDR
#define AXI_DMA_BASE_ADDR              0xbf700000u
#endif

#define AXI_DMA_CTRL_ADDR              (AXI_DMA_BASE_ADDR + 0x00u)
#define AXI_DMA_STATUS_ADDR            (AXI_DMA_BASE_ADDR + 0x04u)
#define AXI_DMA_SRC_ADDR               (AXI_DMA_BASE_ADDR + 0x08u)
#define AXI_DMA_DST_ADDR               (AXI_DMA_BASE_ADDR + 0x0cu)
#define AXI_DMA_LEN_BYTES_ADDR         (AXI_DMA_BASE_ADDR + 0x10u)
#define AXI_DMA_BURST_WORDS_ADDR       (AXI_DMA_BASE_ADDR + 0x14u)
#define AXI_DMA_DONE_BYTES_ADDR        (AXI_DMA_BASE_ADDR + 0x18u)
#define AXI_DMA_IRQ_ENABLE_ADDR        (AXI_DMA_BASE_ADDR + 0x1cu)

#define AXI_DMA_CTRL_START             0x00000001u

#define AXI_DMA_STATUS_BUSY            0x00000001u
#define AXI_DMA_STATUS_DONE            0x00000002u
#define AXI_DMA_STATUS_ERROR           0x00000004u

#define AXI_DMA_DEFAULT_BURST_WORDS    16u

void AXIDMA_Set_Base(U32 base_addr);
U32  AXIDMA_Get_Base(void);

int  AXIDMA_Start(U32 src_phys, U32 dst_phys, U32 len_bytes);
int  AXIDMA_Start_Burst(U32 src_phys, U32 dst_phys, U32 len_bytes, U32 burst_words);
int  AXIDMA_Wait(U32 timeout_polls);

void AXIDMA_Clear_Status(void);
void AXIDMA_Enable_IRQ(int enable);

U32  AXIDMA_Get_Status(void);
U32  AXIDMA_Get_Done_Bytes(void);

#endif
