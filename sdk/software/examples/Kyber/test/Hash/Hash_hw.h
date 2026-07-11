#ifndef HASH_HW_H
#define HASH_HW_H

#include "common_func.h"
#include "Hash_sw.h"

#define HASH_HW_BASE_ADDR       0xbf600000u
#define HASH_HW_CTRL_ADDR       (HASH_HW_BASE_ADDR + 0x000u)
#define HASH_HW_STATUS_ADDR     (HASH_HW_BASE_ADDR + 0x004u)
#define HASH_HW_DATA_BASE_ADDR  (HASH_HW_BASE_ADDR + 0x300u)

#define HASH_HW_CTRL_RESET_DATA  (1u << 3)
#define HASH_HW_CTRL_ITERATE     (1u << 4)

#define HASH_HW_MODE_NORMAL      0u
#define HASH_HW_MODE_REJECTION   1u
#define HASH_HW_MODE_CBD2        2u
#define HASH_HW_MODE_CBD3        3u

void KeccakF1600_StateReset_hw(void);
void KeccakF1600_StatePermute_hw(void);
void KeccakF1600_StateRead_hw(uint64_t state[25]);
unsigned long Hash_hw_GetCycles(void);
void hash_g_hw(uint8_t output[64], const uint8_t *input, size_t input_length);
void hash_h_hw(uint8_t output[32], const uint8_t input[KYBER_PUBLICKEYBYTES]);
void gen_matrix_hw(polyvec *a, const uint8_t seed[KYBER_SYMBYTES], int transposed);
void poly_getnoise_eta1_hw(poly *r, const uint8_t seed[KYBER_SYMBYTES], uint8_t nonce);
void poly_getnoise_eta2_hw(poly *r, const uint8_t seed[KYBER_SYMBYTES], uint8_t nonce);
void rkprf_hw(uint8_t output[KYBER_SSBYTES],
                const uint8_t key[KYBER_SYMBYTES],
                const uint8_t input[KYBER_CIPHERTEXTBYTES]);

#endif
