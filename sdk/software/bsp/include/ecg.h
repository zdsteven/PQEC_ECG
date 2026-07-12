#ifndef ECG_H
#define ECG_H

#include "common_func.h"

#define ECG_BASE_ADDR 0xbf400000

#define ECG_CTRL_ADDR (ECG_BASE_ADDR + 0x000u)
#define ECG_STATUS_ADDR (ECG_BASE_ADDR + 0x004u)
#define ECG_RESULT_ADDR_0 (ECG_BASE_ADDR + 0x008u)
#define ECG_RESULT_ADDR_1 (ECG_BASE_ADDR + 0x00cu)
#define ECG_DATA_BASE_ADDR (ECG_BASE_ADDR + 0x100u)

#define ECG_IS_BUSY (RegRead(ECG_STATUS_ADDR) & 0x1u)

void ecg_load(U8 *ecg_data);
void ecg_start(void);
U8 ecg_read_result(U8 result[5]);




#endif
