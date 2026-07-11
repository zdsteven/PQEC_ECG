#include "Kem_api.h"

#include <string.h>

static void unpack_poly(poly *value, const uint8_t input[KYBER_POLYBYTES])
{
    unsigned int i;

    for (i = 0; i < KYBER_N / 2; ++i) {
        value->coeffs[2 * i] =
            ((uint16_t)input[3 * i] |
             ((uint16_t)input[3 * i + 1] << 8)) & 0x0fffu;
        value->coeffs[2 * i + 1] =
            (((uint16_t)input[3 * i + 1] >> 4) |
             ((uint16_t)input[3 * i + 2] << 4)) & 0x0fffu;
    }
}

static void pack_poly(uint8_t r[KYBER_POLYBYTES], const poly *value)
{
    unsigned int i;
    uint16_t t0;
    uint16_t t1;

    for (i = 0; i < KYBER_N / 2; ++i) {
        t0 = value->coeffs[2 * i];
        t0 += ((int16_t)t0 >> 15) & KYBER_Q;
        t1 = value->coeffs[2 * i + 1];
        t1 += ((int16_t)t1 >> 15) & KYBER_Q;
        r[3 * i] = (uint8_t)t0;
        r[3 * i + 1] = (uint8_t)((t0 >> 8) | (t1 << 4));
        r[3 * i + 2] = (uint8_t)(t1 >> 4);
    }
}

void kem_unpack_pk  (polyvec *pk,
                    uint8_t seed[KYBER_SYMBYTES],
                    const uint8_t packed_pk[KYBER_INDCPA_PUBLICKEYBYTES])
{
    unsigned int i;

    for (i = 0; i < KYBER_K; ++i) {
        unpack_poly(&pk->vec[i], packed_pk + i * KYBER_POLYBYTES);
    }
    memcpy(seed, packed_pk + KYBER_POLYVECBYTES, KYBER_SYMBYTES);
}

void kem_unpack_sk (polyvec *sk,
                    const uint8_t packed_sk[KYBER_INDCPA_SECRETKEYBYTES])
{
    unsigned int i;

    for (i = 0; i < KYBER_K; ++i) {
        unpack_poly(&sk->vec[i], packed_sk + i * KYBER_POLYBYTES);
    }
}

void kem_pack_sk(uint8_t r[KYBER_INDCPA_SECRETKEYBYTES], const polyvec *sk)
{
    unsigned int i;

    for (i = 0; i < KYBER_K; ++i) {
        pack_poly(r + i * KYBER_POLYBYTES, &sk->vec[i]);
    }
}

void kem_pack_pk  (uint8_t r[KYBER_INDCPA_PUBLICKEYBYTES],
                const polyvec *pk,
                const uint8_t seed[KYBER_SYMBYTES])
{
    unsigned int i;

    for (i = 0; i < KYBER_K; ++i) {
        pack_poly(r + i * KYBER_POLYBYTES, &pk->vec[i]);
    }
    memcpy(r + KYBER_POLYVECBYTES, seed, KYBER_SYMBYTES);
}

void kem_compress_polyvec_component(uint8_t *output, const poly *value)
{
    unsigned int i;
    unsigned int j;
    uint64_t scaled;

#if KYBER_POLYVECCOMPRESSEDBYTES == (KYBER_K * 352)
    uint16_t compressed[8];

    for (i = 0; i < KYBER_N / 8; ++i) {
        for (j = 0; j < 8; ++j) {
            scaled = value->coeffs[8 * i + j];
            scaled <<= 11;
            scaled += 1664;
            scaled *= 645084;
            scaled >>= 31;
            compressed[j] = (uint16_t)scaled & 0x07ffu;
        }

        output[0] = (uint8_t)compressed[0];
        output[1] = (uint8_t)((compressed[0] >> 8) | (compressed[1] << 3));
        output[2] = (uint8_t)((compressed[1] >> 5) | (compressed[2] << 6));
        output[3] = (uint8_t)(compressed[2] >> 2);
        output[4] = (uint8_t)((compressed[2] >> 10) | (compressed[3] << 1));
        output[5] = (uint8_t)((compressed[3] >> 7) | (compressed[4] << 4));
        output[6] = (uint8_t)((compressed[4] >> 4) | (compressed[5] << 7));
        output[7] = (uint8_t)(compressed[5] >> 1);
        output[8] = (uint8_t)((compressed[5] >> 9) | (compressed[6] << 2));
        output[9] = (uint8_t)((compressed[6] >> 6) | (compressed[7] << 5));
        output[10] = (uint8_t)(compressed[7] >> 3);
        output += 11;
    }
#elif KYBER_POLYVECCOMPRESSEDBYTES == (KYBER_K * 320)
    uint16_t compressed[4];

    for (i = 0; i < KYBER_N / 4; ++i) {
        for (j = 0; j < 4; ++j) {
            scaled = value->coeffs[4 * i + j];
            scaled <<= 10;
            scaled += 1665;
            scaled *= 1290167;
            scaled >>= 32;
            compressed[j] = (uint16_t)scaled & 0x03ffu;
        }

        output[0] = (uint8_t)compressed[0];
        output[1] = (uint8_t)((compressed[0] >> 8) | (compressed[1] << 2));
        output[2] = (uint8_t)((compressed[1] >> 6) | (compressed[2] << 4));
        output[3] = (uint8_t)((compressed[2] >> 4) | (compressed[3] << 6));
        output[4] = (uint8_t)(compressed[3] >> 2);
        output += 5;
    }
#else
#error "Unsupported KYBER_POLYVECCOMPRESSEDBYTES"
#endif
}

void kem_compress_poly(uint8_t output[KYBER_POLYCOMPRESSEDBYTES],
                       const poly *value)
{
    unsigned int i;
    unsigned int j;
    uint32_t scaled;
    uint8_t compressed[8];

#if KYBER_POLYCOMPRESSEDBYTES == 128
    for (i = 0; i < KYBER_N / 8; ++i) {
        for (j = 0; j < 8; ++j) {
            scaled = (uint32_t)value->coeffs[8 * i + j] << 4;
            scaled += 1665;
            scaled *= 80635;
            scaled >>= 28;
            compressed[j] = (uint8_t)scaled & 0x0fu;
        }
        output[0] = compressed[0] | (compressed[1] << 4);
        output[1] = compressed[2] | (compressed[3] << 4);
        output[2] = compressed[4] | (compressed[5] << 4);
        output[3] = compressed[6] | (compressed[7] << 4);
        output += 4;
    }
#elif KYBER_POLYCOMPRESSEDBYTES == 160
    for (i = 0; i < KYBER_N / 8; ++i) {
        for (j = 0; j < 8; ++j) {
            scaled = (uint32_t)value->coeffs[8 * i + j] << 5;
            scaled += 1664;
            scaled *= 40318;
            scaled >>= 27;
            compressed[j] = (uint8_t)scaled & 0x1fu;
        }
        output[0] = (compressed[0] >> 0) | (compressed[1] << 5);
        output[1] = (compressed[1] >> 3) |
                    (compressed[2] << 2) |
                    (compressed[3] << 7);
        output[2] = (compressed[3] >> 1) | (compressed[4] << 4);
        output[3] = (compressed[4] >> 4) |
                    (compressed[5] << 1) |
                    (compressed[6] << 6);
        output[4] = (compressed[6] >> 2) | (compressed[7] << 3);
        output += 5;
    }
#else
#error "Unsupported KYBER_POLYCOMPRESSEDBYTES"
#endif
}

static void decompress_polyvec_component(poly *value, const uint8_t *input)
{
    unsigned int i;
    unsigned int j;

#if KYBER_POLYVECCOMPRESSEDBYTES == (KYBER_K * 352)
    uint16_t compressed[8];

    for (i = 0; i < KYBER_N / 8; ++i) {
        compressed[0] = (input[0] >> 0) | ((uint16_t)input[1] << 8);
        compressed[1] = (input[1] >> 3) | ((uint16_t)input[2] << 5);
        compressed[2] = (input[2] >> 6) |
                        ((uint16_t)input[3] << 2) |
                        ((uint16_t)input[4] << 10);
        compressed[3] = (input[4] >> 1) | ((uint16_t)input[5] << 7);
        compressed[4] = (input[5] >> 4) | ((uint16_t)input[6] << 4);
        compressed[5] = (input[6] >> 7) |
                        ((uint16_t)input[7] << 1) |
                        ((uint16_t)input[8] << 9);
        compressed[6] = (input[8] >> 2) | ((uint16_t)input[9] << 6);
        compressed[7] = (input[9] >> 5) | ((uint16_t)input[10] << 3);
        input += 11;

        for (j = 0; j < 8; ++j) {
            value->coeffs[8 * i + j] =
                ((uint32_t)(compressed[j] & 0x07ffu) * KYBER_Q + 1024) >> 11;
        }
    }
#elif KYBER_POLYVECCOMPRESSEDBYTES == (KYBER_K * 320)
    uint16_t compressed[4];

    for (i = 0; i < KYBER_N / 4; ++i) {
        compressed[0] = input[0] | ((uint16_t)input[1] << 8);
        compressed[1] = (input[1] >> 2) | ((uint16_t)input[2] << 6);
        compressed[2] = (input[2] >> 4) | ((uint16_t)input[3] << 4);
        compressed[3] = (input[3] >> 6) | ((uint16_t)input[4] << 2);
        input += 5;

        for (j = 0; j < 4; ++j) {
            value->coeffs[4 * i + j] =
                ((uint32_t)(compressed[j] & 0x03ffu) * KYBER_Q + 512) >> 10;
        }
    }
#else
#error "Unsupported KYBER_POLYVECCOMPRESSEDBYTES"
#endif
}

static void decompress_poly(poly *value, const uint8_t *input)
{
    unsigned int i;

#if KYBER_POLYCOMPRESSEDBYTES == 128
    for (i = 0; i < KYBER_N / 2; ++i) {
        value->coeffs[2 * i] =
            ((uint16_t)(input[i] & 0x0fu) * KYBER_Q + 8) >> 4;
        value->coeffs[2 * i + 1] =
            ((uint16_t)(input[i] >> 4) * KYBER_Q + 8) >> 4;
    }
#elif KYBER_POLYCOMPRESSEDBYTES == 160
    unsigned int j;
    uint8_t compressed[8];

    for (i = 0; i < KYBER_N / 8; ++i) {
        compressed[0] = input[0] >> 0;
        compressed[1] = (input[0] >> 5) | (input[1] << 3);
        compressed[2] = input[1] >> 2;
        compressed[3] = (input[1] >> 7) | (input[2] << 1);
        compressed[4] = (input[2] >> 4) | (input[3] << 4);
        compressed[5] = input[3] >> 1;
        compressed[6] = (input[3] >> 6) | (input[4] << 2);
        compressed[7] = input[4] >> 3;
        input += 5;

        for (j = 0; j < 8; ++j) {
            value->coeffs[8 * i + j] =
                ((uint32_t)(compressed[j] & 0x1fu) * KYBER_Q + 16) >> 5;
        }
    }
#else
#error "Unsupported KYBER_POLYCOMPRESSEDBYTES"
#endif
}

void kem_pack_ciphertext(uint8_t output[KYBER_INDCPA_BYTES], const polyvec *b, const poly *v)
{
    unsigned int i;
    const uint32_t compressed_polyvec_bytes =
        KYBER_POLYVECCOMPRESSEDBYTES / KYBER_K;

    for (i = 0; i < KYBER_K; ++i) {
        kem_compress_polyvec_component(
            output + i * compressed_polyvec_bytes, &b->vec[i]);
    }
    kem_compress_poly(output + KYBER_POLYVECCOMPRESSEDBYTES, v);
}

void kem_unpack_ciphertext (polyvec *b,
                            poly *v,
                            const uint8_t input[KYBER_INDCPA_BYTES])
{
    unsigned int i;
    const uint32_t compressed_polyvec_bytes =
        KYBER_POLYVECCOMPRESSEDBYTES / KYBER_K;

    for (i = 0; i < KYBER_K; ++i) {
        decompress_polyvec_component(
            &b->vec[i], input + i * compressed_polyvec_bytes);
    }
    decompress_poly(v, input + KYBER_POLYVECCOMPRESSEDBYTES);
}

void kem_poly_frommsg(poly *value, const uint8_t message[KYBER_INDCPA_MSGBYTES])
{
    unsigned int i;
    unsigned int j;

    for (i = 0; i < KYBER_N / 8; ++i) {
        for (j = 0; j < 8; ++j) {
            value->coeffs[8 * i + j] =
                ((uint16_t)0u - ((message[i] >> j) & 1u)) &
                ((KYBER_Q + 1) / 2);
        }
    }
}

void kem_poly_tomsg(uint8_t message[KYBER_INDCPA_MSGBYTES],
                    const poly *value)
{
    unsigned int i;
    unsigned int j;
    uint32_t bit;

    for (i = 0; i < KYBER_N / 8; ++i) {
        message[i] = 0;
        for (j = 0; j < 8; ++j) {
            bit = (uint32_t)value->coeffs[8 * i + j] << 1;
            bit += 1665;
            bit *= 80635;
            bit >>= 28;
            message[i] |= (uint8_t)(bit & 1u) << j;
        }
    }
}

static uint16_t add_modq(uint16_t left, uint16_t right)
{
    uint16_t sum = left + right;
    return sum >= KYBER_Q ? sum - KYBER_Q : sum;
}

void kem_poly_add_modq(poly *result, const poly *left, const poly *right)
{
    unsigned int i;

    for (i = 0; i < KYBER_N; ++i) {
        result->coeffs[i] = add_modq(left->coeffs[i], right->coeffs[i]);
    }
}

void kem_poly_add3_modq(poly *result,
                        const poly *first,
                        const poly *second,
                        const poly *third)
{
    unsigned int i;

    for (i = 0; i < KYBER_N; ++i) {
        result->coeffs[i] =
            add_modq(add_modq(first->coeffs[i], second->coeffs[i]),
                    third->coeffs[i]);
    }
}

int kem_verify(const uint8_t *left, const uint8_t *right, uint32_t length)
{
    uint32_t i;
    uint8_t difference = 0;

    for (i = 0; i < length; ++i) {
        difference |= left[i] ^ right[i];
    }
    return (int)((0u - (uint32_t)difference) >> 31);
}

void kem_cmov  (uint8_t *result,
                const uint8_t *source,
                uint32_t length,
                uint8_t condition)
{
    uint32_t i;
    uint8_t mask = (uint8_t)(0u - condition);

    for (i = 0; i < length; ++i) {
        result[i] ^= mask & (result[i] ^ source[i]);
    }
}

