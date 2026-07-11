#ifndef NTT_INTT_HW_H
#define NTT_INTT_HW_H

#include "NTT_INTT_sw.h"

#define NTT_INTT_HW_BASE_ADDR       0xbf600000u
#define NTT_INTT_HW_CTRL_ADDR       (NTT_INTT_HW_BASE_ADDR + 0x000u)
#define NTT_INTT_HW_STATUS_ADDR     (NTT_INTT_HW_BASE_ADDR + 0x004u)
#define NTT_INTT_HW_DATA_BASE_ADDR  (NTT_INTT_HW_BASE_ADDR + 0x100u)

#define NTT_INTT_HW_WORD_COUNT      128u
#define NTT_INTT_HW_POLY_BYTES      (NTT_INTT_HW_WORD_COUNT * 4u)

#define NTT_INTT_HW_CTRL_START      (1u << 0)
#define NTT_INTT_HW_CTRL_MODE_NTT   (1u << 2)

unsigned long run_hw_ntt(const S16 input[KYBER_N], S16 output[KYBER_N]);
unsigned long run_hw_intt(const S16 input[KYBER_N], S16 output[KYBER_N]);

#endif
