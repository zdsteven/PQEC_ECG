#include "dma.h"

static uint32_t DMA_To_Bus_Addr(uint32_t addr)
{
    /* CPU uses cached/uncached aliases; DMA master needs the physical AXI view. */
    return addr & 0x1fffffffU;
}

static int DMA_Is_Aligned_Config(uint32_t src_addr, uint32_t dst_addr, uint32_t byte_len)
{
    if ((byte_len == 0) ||
        ((src_addr & 0x3) != 0) ||
        ((dst_addr & 0x3) != 0) ||
        ((byte_len & 0x3) != 0)) {
        return 0;
    }

    return 1;
}

void DMA_Set_Source(uint32_t src_addr)
{
    RegWrite(DMA_SRC_ADDR, DMA_To_Bus_Addr(src_addr));
}

void DMA_Set_Destination(uint32_t dst_addr)
{
    RegWrite(DMA_DST_ADDR, DMA_To_Bus_Addr(dst_addr));
}

void DMA_Set_Length(uint32_t byte_len)
{
    RegWrite(DMA_LEN_ADDR, byte_len);
}

uint32_t DMA_Get_Status(void)
{
    return RegRead(DMA_STATUS_ADDR);
}

uint32_t DMA_Is_Busy(void)
{
    return DMA_Get_Status() & DMA_STATUS_BUSY;
}

uint32_t DMA_Is_Done(void)
{
    return (DMA_Get_Status() & DMA_STATUS_DONE) != 0;
}

uint32_t DMA_Has_Error(void)
{
    return (DMA_Get_Status() & DMA_STATUS_ERROR) != 0;
}

void DMA_Clear_Done(void)
{
    RegWrite(DMA_CTRL_ADDR, DMA_CTRL_CLEARDONE);
}

int DMA_Start(void)
{
    uint32_t src_addr = RegRead(DMA_SRC_ADDR);
    uint32_t dst_addr = RegRead(DMA_DST_ADDR);
    uint32_t byte_len = RegRead(DMA_LEN_ADDR);

    if (!DMA_Is_Aligned_Config(src_addr, dst_addr, byte_len)) {
        return -1;
    }

    DMA_Clear_Done();
    RegWrite(DMA_CTRL_ADDR, DMA_CTRL_START);
    return 0;
}

int DMA_Transfer_Async(uint32_t src_addr, uint32_t dst_addr, uint32_t byte_len)
{
    if (!DMA_Is_Aligned_Config(src_addr, dst_addr, byte_len)) {
        return -1;
    }

    DMA_Set_Source(src_addr);
    DMA_Set_Destination(dst_addr);
    DMA_Set_Length(byte_len);
    return DMA_Start();
}

int DMA_Transfer_Blocking(uint32_t src_addr, uint32_t dst_addr, uint32_t byte_len, uint32_t timeout_cycles)
{
    if (DMA_Transfer_Async(src_addr, dst_addr, byte_len) != 0) {
        return -1;
    }

    if (timeout_cycles == 0) {
        while (DMA_Is_Busy()) {
        }
    }
    else {
        while (DMA_Is_Busy() && timeout_cycles--) {
        }
        if (DMA_Is_Busy()) {
            return -2;
        }
    }

    if (DMA_Has_Error()) {
        return -3;
    }

    return 0;
}

uint32_t DMA_Get_Matmul_CRC(void)
{
    return RegRead(DMA_MATMUL_CRC_ADDR);
}

int DMA_Matmul_Compute_Blocking(uint32_t src_addr, uint32_t dst_addr, uint32_t group_num, uint32_t timeout_cycles)
{
    uint32_t src_bus = DMA_To_Bus_Addr(src_addr);
    uint32_t dst_bus = DMA_To_Bus_Addr(dst_addr);

    if ((group_num == 0) || ((src_bus & 0x3) != 0) || ((dst_bus & 0x3) != 0)) {
        return -1;
    }

    /*
     * Specialized mode contract:
     *   SRC = ExtRAM input area, A[16] then B[16] per group.
     *   DST = ExtRAM result area, 48 packed words per group.
     *   LEN = group count, not byte count.
     */
    DMA_Set_Source(src_bus);
    DMA_Set_Destination(dst_bus);
    DMA_Set_Length(group_num);
    DMA_Clear_Done();
    RegWrite(DMA_CTRL_ADDR, DMA_CTRL_START | DMA_CTRL_MATMUL);

    if (timeout_cycles == 0) {
        while (DMA_Is_Busy()) {
        }
    }
    else {
        while (DMA_Is_Busy() && timeout_cycles--) {
        }
        if (DMA_Is_Busy()) {
            return -2;
        }
    }

    if (DMA_Has_Error()) {
        return -3;
    }

    return 0;
}
