#ifndef DMA_H
#define DMA_H

#include "common_func.h"

#define DMA_BASEADDR 0xbf300000

#define DMA_CTRL_ADDR      (DMA_BASEADDR + 0x00)
#define DMA_STATUS_ADDR    (DMA_BASEADDR + 0x04)
#define DMA_SRC_ADDR       (DMA_BASEADDR + 0x08)
#define DMA_DST_ADDR       (DMA_BASEADDR + 0x0c)
#define DMA_LEN_ADDR       (DMA_BASEADDR + 0x10)
#define DMA_CUR_SRC_ADDR   (DMA_BASEADDR + 0x14)
#define DMA_CUR_DST_ADDR   (DMA_BASEADDR + 0x18)
#define DMA_REMAIN_ADDR    (DMA_BASEADDR + 0x1c)
#define DMA_VERSION_ADDR   (DMA_BASEADDR + 0x20)
/* Final CRC32 produced by DMA matmul batch mode. */
#define DMA_MATMUL_CRC_ADDR (DMA_BASEADDR + 0x24)

#define DMA_CTRL_START      0x1
#define DMA_CTRL_CLEARDONE  0x2
/* Selects the specialized ExtRAM -> matmul -> ExtRAM batch engine. */
#define DMA_CTRL_MATMUL     0x4

#define DMA_STATUS_BUSY     0x1
#define DMA_STATUS_DONE     0x2
#define DMA_STATUS_ERROR    0x4

void DMA_Set_Source(uint32_t src_addr);
void DMA_Set_Destination(uint32_t dst_addr);
void DMA_Set_Length(uint32_t byte_len);
uint32_t DMA_Get_Status(void);
uint32_t DMA_Is_Busy(void);
uint32_t DMA_Is_Done(void);
uint32_t DMA_Has_Error(void);
void DMA_Clear_Done(void);
int DMA_Start(void);
int DMA_Transfer_Async(uint32_t src_addr, uint32_t dst_addr, uint32_t byte_len);
int DMA_Transfer_Blocking(uint32_t src_addr, uint32_t dst_addr, uint32_t byte_len, uint32_t timeout_cycles);
uint32_t DMA_Get_Matmul_CRC(void);
/* In matmul mode, group_num is written to DMA_LEN instead of a byte length. */
int DMA_Matmul_Compute_Blocking(uint32_t src_addr, uint32_t dst_addr, uint32_t group_num, uint32_t timeout_cycles);

#endif
