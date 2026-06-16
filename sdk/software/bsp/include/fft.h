#ifndef FFT_H
#define FFT_H

#include "common_func.h"

#define FFT_BASEADDR 0xbf400000

#define FFT_CTRL_ADDR      (FFT_BASEADDR + 0x0)
#define FFT_STATUS_ADDR    (FFT_BASEADDR + 0x4)
#define FFT_POINTS_ADDR    (FFT_BASEADDR + 0x8)
#define FFT_SCALE_ADDR     (FFT_BASEADDR + 0xC)
#define FFT_DEBUG_ADDR     (FFT_BASEADDR + 0x10)
#define FFT_VERSION_ADDR   (FFT_BASEADDR + 0x14)
#define FFT_DATA_BASE_ADDR (FFT_BASEADDR + 0x100)

#define FFT_POINT_COUNT 256

#define FFT_CTRL_START     0x1
#define FFT_CTRL_CLEARDONE 0x2

void FFT_Write_Sample(uint32_t index, S16 real, S16 imag);
void FFT_Read_Sample(uint32_t index, S16 *real, S16 *imag);
void FFT_Start(void);
void FFT_Clear_Done(void);
uint32_t FFT_Is_Busy(void);
uint32_t FFT_Is_Done(void);
uint32_t FFT_Get_Point_Count(void);

#endif
