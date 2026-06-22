#ifndef HASH_HW_H
#define HASH_HW_H

#include "Hash_sw.h"

void KeccakF1600_StateReset_hw(void);
void KeccakF1600_StatePermute_hw(void);
void KeccakF1600_StateRead_hw(uint64_t state[25]);
void hash_g_hw(uint8_t output[64], const uint8_t *input, size_t input_length);
void hash_h_hw(uint8_t output[32], const uint8_t input[KYBER_PUBLICKEYBYTES]);
void gen_matrix_hw(polyvec *a, const uint8_t seed[KYBER_SYMBYTES], int transposed);
void poly_getnoise_eta1_hw(poly *r, const uint8_t seed[KYBER_SYMBYTES], uint8_t nonce);
void poly_getnoise_eta2_hw(poly *r, const uint8_t seed[KYBER_SYMBYTES], uint8_t nonce);
void rkprf_hw(uint8_t output[KYBER_SSBYTES],
              const uint8_t key[KYBER_SYMBYTES],
              const uint8_t input[KYBER_CIPHERTEXTBYTES]);

#endif
