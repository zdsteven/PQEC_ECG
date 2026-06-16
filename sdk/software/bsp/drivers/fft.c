#include "fft.h"

void FFT_Write_Sample(uint32_t index, S16 real, S16 imag)
{
    if (index >= FFT_POINT_COUNT) {
        return;
    }

    RegWrite(FFT_DATA_BASE_ADDR + (index << 2),
             (((uint32_t)(U16)imag) << 16) | (uint32_t)(U16)real);
}

void FFT_Read_Sample(uint32_t index, S16 *real, S16 *imag)
{
    uint32_t value;

    if (index >= FFT_POINT_COUNT) {
        return;
    }

    value = RegRead(FFT_DATA_BASE_ADDR + (index << 2));

    if (real != 0) {
        *real = (S16)(value & 0xFFFF);
    }

    if (imag != 0) {
        *imag = (S16)(value >> 16);
    }
}

void FFT_Start(void)
{
    RegWrite(FFT_CTRL_ADDR, FFT_CTRL_START);
}

void FFT_Clear_Done(void)
{
    RegWrite(FFT_CTRL_ADDR, FFT_CTRL_CLEARDONE);
}

uint32_t FFT_Is_Busy(void)
{
    return RegRead(FFT_STATUS_ADDR) & 0x1;
}

uint32_t FFT_Is_Done(void)
{
    return (RegRead(FFT_STATUS_ADDR) >> 1) & 0x1;
}

uint32_t FFT_Get_Point_Count(void)
{
    return RegRead(FFT_POINTS_ADDR);
}
