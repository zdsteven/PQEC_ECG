#include "Hash_hw.h"
#include "Kyber.h"

#define HASH_DATA_BASE_ADDR      (KYBER_BASEADDR + 0x300u)
#define HASH_CTRL_RESET_DATA     (1u << 3)
#define HASH_CTRL_ITERATE        (1u << 4)
#define HASH_MODE_NORMAL         0u
#define HASH_MODE_REJECTION      1u
#define HASH_MODE_CBD2           2u
#define HASH_MODE_CBD3           3u

static inline uint32_t load32(const uint8_t *input)
{
    return (uint32_t)input[0]
         | ((uint32_t)input[1] << 8)
         | ((uint32_t)input[2] << 16)
         | ((uint32_t)input[3] << 24);
}

static inline void store32(uint8_t *output, uint32_t value)
{
    output[0] = (uint8_t)value;
    output[1] = (uint8_t)(value >> 8);
    output[2] = (uint8_t)(value >> 16);
    output[3] = (uint8_t)(value >> 24);
}

static inline void hash_reset(void)
{
    RegWrite(KYBER_CTRL_ADDR, HASH_CTRL_RESET_DATA);
}

static inline void hash_iterate(uint32_t mode)
{
    RegWrite(KYBER_CTRL_ADDR, HASH_CTRL_ITERATE | (mode << 5));
    while (!Kyber_IsDone()) {
    }
}

static inline int16_t centered_coefficient(uint16_t value)
{
    return value > KYBER_Q / 2 ? (int16_t)(value - KYBER_Q) : (int16_t)value;
}

void KeccakF1600_StateReset_hw(void)
{
    hash_reset();
}

void KeccakF1600_StatePermute_hw(void)
{
    hash_iterate(HASH_MODE_NORMAL);
}

void KeccakF1600_StateRead_hw(uint64_t state[25])
{
    uint32_t i;
    uint32_t low;
    uint32_t high;

    for (i = 0; i < 25u; ++i) {
        low = RegRead(HASH_DATA_BASE_ADDR + ((2u * i) << 2));
        high = RegRead(HASH_DATA_BASE_ADDR + ((2u * i + 1u) << 2));
        state[i] = (uint64_t)low | ((uint64_t)high << 32);
    }
}

void hash_g_hw(uint8_t output[64], const uint8_t *input, size_t input_length)
{
    uint32_t i;
    uint32_t value;

    hash_reset();
    if (input_length == KYBER_SYMBYTES + 1u) {
        for (i = 0; i < 8u; ++i) {
            RegWrite(HASH_DATA_BASE_ADDR + (i << 2), load32(input + 4u * i));
        }
        RegWrite(HASH_DATA_BASE_ADDR + 8u * 4u, (uint32_t)input[32] | 0x00000600u);
    } else {
        for (i = 0; i < 16u; ++i) {
            RegWrite(HASH_DATA_BASE_ADDR + (i << 2), load32(input + 4u * i));
        }
        RegWrite(HASH_DATA_BASE_ADDR + 16u * 4u, 0x00000006u);
    }
    RegWrite(HASH_DATA_BASE_ADDR + 17u * 4u, 0x80000000u);
    hash_iterate(HASH_MODE_NORMAL);

    for (i = 0; i < 16u; ++i) {
        value = RegRead(HASH_DATA_BASE_ADDR + (i << 2));
        store32(output + 4u * i, value);
    }
}

void hash_h_hw(uint8_t output[32], const uint8_t input[KYBER_PUBLICKEYBYTES])
{
    uint32_t block;
    uint32_t i;
    uint32_t value;

    hash_reset();
    for (block = 0; block < 5u; ++block) {
        for (i = 0; i < SHA3_256_RATE / 4u; ++i) {
            RegWrite(HASH_DATA_BASE_ADDR + (i << 2), load32(input + block * SHA3_256_RATE + 4u * i));
        }
        hash_iterate(HASH_MODE_NORMAL);
    }

    input += 5u * SHA3_256_RATE;
    for (i = 0; i < 30u; ++i) {
        RegWrite(HASH_DATA_BASE_ADDR + (i << 2), load32(input + 4u * i));
    }
    RegWrite(HASH_DATA_BASE_ADDR + 30u * 4u, 0x00000006u);
    RegWrite(HASH_DATA_BASE_ADDR + 33u * 4u, 0x80000000u);
    hash_iterate(HASH_MODE_NORMAL);

    for (i = 0; i < 8u; ++i) {
        value = RegRead(HASH_DATA_BASE_ADDR + (i << 2));
        store32(output + 4u * i, value);
    }
}

void gen_matrix_hw(polyvec *a, const uint8_t seed[KYBER_SYMBYTES], int transposed)
{
    uint32_t i;
    uint32_t j;
    uint32_t k;
    uint32_t value;
    uint32_t suffix;

    for (i = 0; i < KYBER_K; ++i) {
        for (j = 0; j < KYBER_K; ++j) {
            hash_reset();
            for (k = 0; k < 8u; ++k) {
                RegWrite(HASH_DATA_BASE_ADDR + (k << 2), load32(seed + 4u * k));
            }
            if (transposed) {
                suffix = i | (j << 8);
            } else {
                suffix = j | (i << 8);
            }
            RegWrite(HASH_DATA_BASE_ADDR + 8u * 4u, suffix | 0x001f0000u);
            RegWrite(HASH_DATA_BASE_ADDR + 41u * 4u, 0x80000000u);
            hash_iterate(HASH_MODE_REJECTION);

            for (k = 0; k < KYBER_N / 2u; ++k) {
                value = RegRead(HASH_DATA_BASE_ADDR + (k << 2));
                a[i].vec[j].coeffs[2u * k] = (int16_t)(value & 0x0fffu);
                a[i].vec[j].coeffs[2u * k + 1u] = (int16_t)((value >> 16) & 0x0fffu);
            }
        }
    }
}

void poly_getnoise_eta1_hw(poly *r,
                           const uint8_t seed[KYBER_SYMBYTES],
                           uint8_t nonce)
{
    uint32_t i;
    uint32_t value;

    hash_reset();
    for (i = 0; i < 8u; ++i) {
        RegWrite(HASH_DATA_BASE_ADDR + (i << 2), load32(seed + 4u * i));
    }
    RegWrite(HASH_DATA_BASE_ADDR + 8u * 4u, (uint32_t)nonce | 0x00001f00u);
    RegWrite(HASH_DATA_BASE_ADDR + 33u * 4u, 0x80000000u);
    hash_iterate(HASH_MODE_CBD3);

    for (i = 0; i < KYBER_N / 2u; ++i) {
        value = RegRead(HASH_DATA_BASE_ADDR + (i << 2));
        r->coeffs[2u * i] = centered_coefficient((uint16_t)(value & 0x0fffu));
        r->coeffs[2u * i + 1u] = centered_coefficient((uint16_t)((value >> 16) & 0x0fffu));
    }
}

void poly_getnoise_eta2_hw(poly *r,
                           const uint8_t seed[KYBER_SYMBYTES],
                           uint8_t nonce)
{
    uint32_t i;
    uint32_t value;

    hash_reset();
    for (i = 0; i < 8u; ++i) {
        RegWrite(HASH_DATA_BASE_ADDR + (i << 2), load32(seed + 4u * i));
    }
    RegWrite(HASH_DATA_BASE_ADDR + 8u * 4u, (uint32_t)nonce | 0x00001f00u);
    RegWrite(HASH_DATA_BASE_ADDR + 33u * 4u, 0x80000000u);
    hash_iterate(HASH_MODE_CBD2);

    for (i = 0; i < KYBER_N / 2u; ++i) {
        value = RegRead(HASH_DATA_BASE_ADDR + (i << 2));
        r->coeffs[2u * i] = centered_coefficient((uint16_t)(value & 0x0fffu));
        r->coeffs[2u * i + 1u] =
            centered_coefficient((uint16_t)((value >> 16) & 0x0fffu));
    }
}

void rkprf_hw(uint8_t output[KYBER_SSBYTES],
              const uint8_t key[KYBER_SYMBYTES],
              const uint8_t input[KYBER_CIPHERTEXTBYTES])
{
    uint32_t block;
    uint32_t i;
    uint32_t value;

    hash_reset();
    for (i = 0; i < 8u; ++i) {
        RegWrite(HASH_DATA_BASE_ADDR + (i << 2), load32(key + 4u * i));
    }
    for (i = 0; i < 26u; ++i) {
        RegWrite(HASH_DATA_BASE_ADDR + ((i + 8u) << 2), load32(input + 4u * i));
    }
    hash_iterate(HASH_MODE_NORMAL);

    for (block = 0; block < 4u; ++block) {
        for (i = 0; i < SHAKE256_RATE / 4u; ++i) {
            RegWrite(HASH_DATA_BASE_ADDR + (i << 2), load32(input + 104u + block * SHAKE256_RATE + 4u * i));
        }
        hash_iterate(HASH_MODE_NORMAL);
    }

    input += 648u;
    for (i = 0; i < 30u; ++i) {
        RegWrite(HASH_DATA_BASE_ADDR + (i << 2), load32(input + 4u * i));
    }
    RegWrite(HASH_DATA_BASE_ADDR + 30u * 4u, 0x0000001fu);
    RegWrite(HASH_DATA_BASE_ADDR + 33u * 4u, 0x80000000u);
    hash_iterate(HASH_MODE_NORMAL);

    for (i = 0; i < 8u; ++i) {
        value = RegRead(HASH_DATA_BASE_ADDR + (i << 2));
        store32(output + 4u * i, value);
    }
}
