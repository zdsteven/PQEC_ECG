#ifndef KEM_TYPES_H
#define KEM_TYPES_H

#include <stdint.h>

#include "Kem_param.h"

typedef struct __attribute__((aligned(4))) {
    uint16_t coeffs[KYBER_N];
} poly;

typedef struct __attribute__((aligned(4))) {
    poly vec[KYBER_K];
} polyvec;

#endif
