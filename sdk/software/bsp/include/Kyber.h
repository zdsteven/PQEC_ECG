#ifndef KYBER_H
#define KYBER_H

#include "common_func.h"

#define KYBER_BASEADDR      0xbf600000u

#define KYBER_CTRL_ADDR     (KYBER_BASEADDR + 0x0)
#define KYBER_STATUS_ADDR   (KYBER_BASEADDR + 0x4)
#define KYBER_DATA_BASE_ADDR (KYBER_BASEADDR + 0x100)

#define KYBER_WORD_COUNT    128u
#define KYBER_POLY_BYTES    (KYBER_WORD_COUNT * 4u)

//#define KYBER_UNCACHED_BASE 0xa0000000u
//#define KYBER_ADDR_MASK     0x1fffffffu
//#define KYBER_TO_UNCACHED_ADDR(addr) ((((uint32_t)(addr)) & KYBER_ADDR_MASK) | KYBER_UNCACHED_BASE)

#define KYBER_CTRL_START      0x1u
#define KYBER_CTRL_CLEARDONE  0x2u
#define KYBER_CTRL_MODE_NTT   0x4u

void Kyber_WriteWord(uint32_t index, S16 low, S16 high);
void Kyber_ReadWord(uint32_t index, S16 *low, S16 *high);
void Kyber_WritePoly(const S16 *coeffs);
void Kyber_ReadPoly(S16 *coeffs);
void Kyber_ClearDone(void);
void Kyber_StartNTT(void);
void Kyber_StartINTT(void);
uint32_t Kyber_ReadStatus(void);
uint32_t Kyber_IsDone(void);
uint32_t Kyber_GetModeBit(void);

#endif
