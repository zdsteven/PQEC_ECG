#ifndef HASH_SW_H
#define HASH_SW_H

#include <stddef.h>
#include <stdint.h>

#define KYBER_K                 2
#define KYBER_N                 256
#define KYBER_Q                 3329
#define KYBER_SYMBYTES          32
#define KYBER_SSBYTES           32
#define KYBER_ETA1              3
#define KYBER_ETA2              2
#define KYBER_PUBLICKEYBYTES    800
#define KYBER_CIPHERTEXTBYTES   768

#define SHAKE128_RATE           168
#define SHAKE256_RATE           136
#define SHA3_256_RATE           136
#define SHA3_512_RATE           72
#define XOF_BLOCKBYTES          SHAKE128_RATE

typedef struct {
    int16_t coeffs[KYBER_N];
} poly;

typedef struct {
    poly vec[KYBER_K];
} polyvec;

typedef struct {
    uint64_t s[25];
    unsigned int pos;
} keccak_state;

typedef keccak_state xof_state;

void KeccakF1600_StatePermute(uint64_t state[25]);
void shake128_init(keccak_state *state);
void shake128_absorb(keccak_state *state, const uint8_t *in, size_t inlen);
void shake128_finalize(keccak_state *state);
void shake128_squeeze(uint8_t *out, size_t outlen, keccak_state *state);
void shake128_absorb_once(keccak_state *state, const uint8_t *in, size_t inlen);
void shake128_squeezeblocks(uint8_t *out, size_t nblocks, keccak_state *state);
void shake256_init(keccak_state *state);
void shake256_absorb(keccak_state *state, const uint8_t *in, size_t inlen);
void shake256_finalize(keccak_state *state);
void shake256_squeeze(uint8_t *out, size_t outlen, keccak_state *state);
void shake256_absorb_once(keccak_state *state, const uint8_t *in, size_t inlen);
void shake256_squeezeblocks(uint8_t *out, size_t nblocks, keccak_state *state);
void shake128(uint8_t *out, size_t outlen, const uint8_t *in, size_t inlen);
void shake256(uint8_t *out, size_t outlen, const uint8_t *in, size_t inlen);
void sha3_256(uint8_t h[32], const uint8_t *in, size_t inlen);
void sha3_512(uint8_t h[64], const uint8_t *in, size_t inlen);

void kyber_shake128_absorb(keccak_state *state,
                           const uint8_t seed[KYBER_SYMBYTES],
                           uint8_t x, uint8_t y);
void kyber_shake256_prf(uint8_t *out, size_t outlen,
                        const uint8_t key[KYBER_SYMBYTES], uint8_t nonce);
void kyber_shake256_rkprf(uint8_t out[KYBER_SSBYTES],
                          const uint8_t key[KYBER_SYMBYTES],
                          const uint8_t input[KYBER_CIPHERTEXTBYTES]);

#define hash_h(OUT, IN, INBYTES) sha3_256(OUT, IN, INBYTES)
#define hash_g(OUT, IN, INBYTES) sha3_512(OUT, IN, INBYTES)
#define xof_absorb(STATE, SEED, X, Y) kyber_shake128_absorb(STATE, SEED, X, Y)
#define xof_squeezeblocks(OUT, BLOCKS, STATE) shake128_squeezeblocks(OUT, BLOCKS, STATE)
#define prf(OUT, OUTBYTES, KEY, NONCE) kyber_shake256_prf(OUT, OUTBYTES, KEY, NONCE)
#define rkprf(OUT, KEY, INPUT) kyber_shake256_rkprf(OUT, KEY, INPUT)

void gen_matrix(polyvec *a, const uint8_t seed[KYBER_SYMBYTES], int transposed);
void poly_getnoise_eta1(poly *r, const uint8_t seed[KYBER_SYMBYTES], uint8_t nonce);
void poly_getnoise_eta2(poly *r, const uint8_t seed[KYBER_SYMBYTES], uint8_t nonce);

#endif
