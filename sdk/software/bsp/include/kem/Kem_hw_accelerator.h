#ifndef KEM_HW_ACCELERATOR_H
#define KEM_HW_ACCELERATOR_H

#include <stdint.h>

#include "common_func.h"
#include "Kem_types.h"

#define KYBER_BASEADDR                0xbf600000u
#define KYBER_CTRL_ADDR               (KYBER_BASEADDR + 0x000u)
#define KYBER_STATUS_ADDR             (KYBER_BASEADDR + 0x004u)
#define KYBER_NTT_INTT_BASE_ADDR      (KYBER_BASEADDR + 0x100u)
#define KYBER_HASH_DATA_BASE_ADDR     (KYBER_BASEADDR + 0x300u)
#define KYBER_BASEMUL_BASE_ADDR       (KYBER_BASEADDR + 0x500u)
#define KYBER_POLYVEC_BASE_ADDR       (KYBER_BASEADDR + 0x700u)

#define SHAKE128_RATE           168
#define SHAKE256_RATE           136
#define SHA3_256_RATE           136
#define SHA3_512_RATE           72
#define XOF_BLOCKBYTES          SHAKE128_RATE

#define KYBER_POLY_BYTES_HW     512u
#define KYBER_POLYVEC_RESET_NUM KYBER_K - 2

#define KYBER_NTT_INTT_IS_BUZY (RegRead(KYBER_STATUS_ADDR) & 0x1u)
#define KYBER_HASH_IS_BUZY (RegRead(KYBER_STATUS_ADDR) & 0x2u)
#define KYBER_POLYVEC_RESET_IS_BUZY (RegRead(KYBER_STATUS_ADDR) & 0x4u)
#define KYBER_POLYVEC_IS_BUZY (RegRead(KYBER_STATUS_ADDR) & 0x8u)

#define HASH_MODE_NORMAL      0u
#define HASH_MODE_REJECTION   1u
#define HASH_MODE_CBD2        2u
#define HASH_MODE_CBD3        3u
#define HASH_MODE_PRF2        HASH_MODE_CBD2
#if KYBER_ETA1 == 3
#define HASH_MODE_PRF1        HASH_MODE_CBD3
#else
#define HASH_MODE_PRF1        HASH_MODE_CBD2
#endif

void hash_g_33(uint8_t output[64], const uint8_t *input);
void hash_g_64(uint8_t output[64], const uint8_t *input);
void hash_h(uint8_t output[32], const uint8_t input[KYBER_PUBLICKEYBYTES]);
void rkprf(uint8_t output[KYBER_SSBYTES],
            const uint8_t key[KYBER_SYMBYTES], 
            const uint8_t input[KYBER_CIPHERTEXTBYTES]);






#endif
