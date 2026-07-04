#ifndef NTT_INTT_SW_H
#define NTT_INTT_SW_H

#include "common_func.h"

#define KYBER_N        256
#define KYBER_Q        3329
#define KYBER_Q_HALF   1664

void ntt_ref(S16 r[KYBER_N]);
void invntt_ref(S16 r[KYBER_N]);

#endif
