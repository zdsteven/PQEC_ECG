#include "axi_dma.h"

static U32 g_axi_dma_base = AXI_DMA_BASE_ADDR;

static U32 axi_dma_reg(U32 offset)
{
    return g_axi_dma_base + offset;
}

void AXIDMA_Set_Base(U32 base_addr)
{
    g_axi_dma_base = base_addr;
}

U32 AXIDMA_Get_Base(void)
{
    return g_axi_dma_base;
}

U32 AXIDMA_Get_Status(void)
{
    return RegRead(axi_dma_reg(0x04u));
}

U32 AXIDMA_Get_Done_Bytes(void)
{
    return RegRead(axi_dma_reg(0x18u));
}

void AXIDMA_Clear_Status(void)
{
    RegWrite(axi_dma_reg(0x04u), AXI_DMA_STATUS_DONE | AXI_DMA_STATUS_ERROR);
}

void AXIDMA_Enable_IRQ(int enable)
{
    RegWrite(axi_dma_reg(0x1cu), enable ? 1u : 0u);
}

int AXIDMA_Start(U32 src_phys, U32 dst_phys, U32 len_bytes)
{
    return AXIDMA_Start_Burst(src_phys, dst_phys, len_bytes,
                              AXI_DMA_DEFAULT_BURST_WORDS);
}

int AXIDMA_Start_Burst(U32 src_phys, U32 dst_phys, U32 len_bytes, U32 burst_words)
{
    U32 status = AXIDMA_Get_Status();

    if ((status & AXI_DMA_STATUS_BUSY) != 0u)
        return -1;
    if (len_bytes == 0u)
        return -2;
    if (((src_phys | dst_phys | len_bytes) & 3u) != 0u)
        return -3;
    if ((burst_words == 0u) || (burst_words > 256u))
        return -4;

    AXIDMA_Clear_Status();
    RegWrite(axi_dma_reg(0x08u), src_phys);
    RegWrite(axi_dma_reg(0x0cu), dst_phys);
    RegWrite(axi_dma_reg(0x10u), len_bytes);
    RegWrite(axi_dma_reg(0x14u), burst_words);
    RegWrite(axi_dma_reg(0x00u), AXI_DMA_CTRL_START);
    return 0;
}

int AXIDMA_Wait(U32 timeout_polls)
{
    U32 polls = 0u;
    U32 status;

    for (;;) {
        status = AXIDMA_Get_Status();
        if ((status & AXI_DMA_STATUS_DONE) != 0u)
            return ((status & AXI_DMA_STATUS_ERROR) != 0u) ? -2 : 0;

        if ((timeout_polls != 0u) && (++polls >= timeout_polls))
            return -1;
    }
}
