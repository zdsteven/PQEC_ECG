#include <Kem_api.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "dma.h"

unsigned long UART_BASE = 0xbf000000;

#define GOLDEN_PK_CRC32 0xba07bb72u
#define GOLDEN_SK_CRC32 0x94640e4cu
#define GOLDEN_CT_CRC32 0xbef30be0u
#define GOLDEN_SS_CRC32 0xc21434c3u
#define GOLDEN_HASH_G33_CRC32 0xbe35ff79u
#define GOLDEN_PUBLICSEED_CRC32 0xf6f1f033u
#define GOLDEN_NOISESEED_CRC32 0x769723b1u
#define GOLDEN_PKPV_CRC32 0x9e125d5au
#define GOLDEN_SKPV_CRC32 0x6fe6318fu
#define GOLDEN_HPK_CRC32 0xad35fe30u
#define GOLDEN_Z_CRC32 0x586253a5u
#define GOLDEN_SAMPLE_S0_CRC32 0x416cf98cu
#define GOLDEN_NTT_S0_CRC32 0x822303f2u

static void flush_debug_cache_lines(const void *buffer, uint32_t byte_length)
{
    uintptr_t address;
    uintptr_t first;
    uintptr_t last;
    uintptr_t line_bytes = (uintptr_t)1u << cache_offset_width;

    first = (uintptr_t)buffer & ~(line_bytes - 1u);
    last = ((uintptr_t)buffer + byte_length + line_bytes - 1u) &
           ~(line_bytes - 1u);
    for (address = first; address < last; address += line_bytes) {
        flush_dcache_line((unsigned long)address);
    }
}

static uint32_t crc32(const uint8_t *data, size_t length)
{
    uint32_t crc = 0xffffffffu;

    while (length-- != 0u) {
        crc ^= *data++;
        for (unsigned int bit = 0; bit < 8u; ++bit) {
            uint32_t mask = 0u - (crc & 1u);
            crc = (crc >> 1) ^ (0xedb88320u & mask);
        }
    }

    return ~crc;
}

static void print_prefix(const uint8_t *data, size_t length)
{
    size_t prefix_length = length < 16u ? length : 16u;

    printf("  first %lu bytes:", (unsigned long)prefix_length);
    for (size_t i = 0; i < prefix_length; ++i) {
        printf(" %02x", data[i]);
    }
    printf("\n");
}

static int check_crc32(const char *name, const uint8_t *data, size_t length,
                       uint32_t expected)
{
    uint32_t actual = crc32(data, length);
    int passed = (actual == expected);

    printf("%-10s actual=%08lx expected=%08lx  %s\n",
           name, (unsigned long)actual, (unsigned long)expected,
           passed ? "PASS" : "FAIL");
    if (!passed) {
        print_prefix(data, length);
    }

    return passed;
}

int main(void)
{
#if KYBER_K != 2
    printf("This golden vector is only for ML-KEM-512 (KYBER_K=2).\n");
    return 1;
#else
    static const uint8_t encaps_coins[KYBER_SYMBYTES]
        __attribute__((aligned(4))) = {
        0x32, 0xf2, 0x32, 0x72, 0x12, 0x12, 0x12, 0x12,
        0x72, 0x32, 0xf2, 0x32, 0x12, 0x12, 0x12, 0x12,
        0x32, 0x72, 0x32, 0xf2, 0x12, 0x12, 0x12, 0x12,
        0x15, 0x43, 0x7a, 0xb1, 0xab, 0x3b, 0x83, 0xc1
    };
    uint8_t keypair_coins[2 * KYBER_SYMBYTES] __attribute__((aligned(4)));
    uint8_t pk[KYBER_PUBLICKEYBYTES] __attribute__((aligned(4)));
    uint8_t sk[KYBER_SECRETKEYBYTES] __attribute__((aligned(4)));
    uint8_t ct[KYBER_CIPHERTEXTBYTES] __attribute__((aligned(4)));
    uint8_t encaps_ss[KYBER_SSBYTES] __attribute__((aligned(4)));
    uint8_t decaps_ss[KYBER_SSBYTES] __attribute__((aligned(4)));
    uint8_t hash_g33_input[48] __attribute__((aligned(16)));
    uint8_t hash_g33[2 * KYBER_SYMBYTES] __attribute__((aligned(16)));
    uint16_t sample_s0[KYBER_N] __attribute__((aligned(16)));
    uint16_t ntt_s0[KYBER_N] __attribute__((aligned(16)));
    const char *first_failure = NULL;
    int passed;
    int pkpv_passed;
    int skpv_passed;
    int dec_result;

    for (unsigned int i = 0; i < KYBER_SYMBYTES; ++i) {
        keypair_coins[i] = (uint8_t)i;
        keypair_coins[KYBER_SYMBYTES + i] =
            (uint8_t)(2u * KYBER_SYMBYTES - i);
    }

    printf("ML-KEM-512 hardware/reference debug start\n");
    crypto_kem_init();

    printf("\n[0] SHA3-512 d || k\n");
    memset(hash_g33_input, 0, sizeof(hash_g33_input));
    memcpy(hash_g33_input, keypair_coins, KYBER_SYMBYTES);
    hash_g33_input[KYBER_SYMBYTES] = KYBER_K;
    flush_debug_cache_lines(hash_g33_input, KYBER_SYMBYTES + 1u);
    flush_debug_cache_lines(hash_g33, sizeof(hash_g33));
    hash_g_33(hash_g33, hash_g33_input);
    passed = check_crc32("hash_g_33", hash_g33, sizeof(hash_g33),
                         GOLDEN_HASH_G33_CRC32);
    if (!passed) {
        first_failure = "hash_g_33: SHA3-512 output";
    }
    check_crc32("publicseed", hash_g33, KYBER_SYMBYTES,
                GOLDEN_PUBLICSEED_CRC32);
    check_crc32("noiseseed", hash_g33 + KYBER_SYMBYTES, KYBER_SYMBYTES,
                GOLDEN_NOISESEED_CRC32);

    printf("\n[0.5] direct CBD3(s0) -> NTT(s0)\n");
    RegWrite(KYBER_CTRL_ADDR, 1u << 3);
    flush_debug_cache_lines(hash_g33 + KYBER_SYMBYTES, KYBER_SYMBYTES);
    DMA_Transfer_Blocking(
        (uint32_t)(uintptr_t)(hash_g33 + KYBER_SYMBYTES),
        KYBER_HASH_DATA_BASE_ADDR, KYBER_SYMBYTES, 0u);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 8u * 4u, 0x00001f00u);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 33u * 4u, 0x80000000u);
    RegWrite(KYBER_CTRL_ADDR, (1u << 4) | (HASH_MODE_PRF1 << 5));
    while (KYBER_HASH_IS_BUZY) {
    }

    flush_debug_cache_lines(sample_s0, sizeof(sample_s0));
    DMA_Transfer_Blocking(KYBER_HASH_DATA_BASE_ADDR,
                          (uint32_t)(uintptr_t)sample_s0,
                          sizeof(sample_s0), 0u);
    passed = check_crc32("sample s0", (const uint8_t *)sample_s0,
                         sizeof(sample_s0), GOLDEN_SAMPLE_S0_CRC32);
    if (!passed && first_failure == NULL) {
        first_failure = "CBD3: sampled secret s0";
    }

    flush_debug_cache_lines(sample_s0, sizeof(sample_s0));
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)sample_s0,
                          KYBER_NTT_INTT_BASE_ADDR,
                          sizeof(sample_s0), 0u);
    RegWrite(KYBER_CTRL_ADDR, 5u);
    while (KYBER_NTT_INTT_IS_BUZY) {
    }
    flush_debug_cache_lines(ntt_s0, sizeof(ntt_s0));
    DMA_Transfer_Blocking(KYBER_NTT_INTT_BASE_ADDR,
                          (uint32_t)(uintptr_t)ntt_s0,
                          sizeof(ntt_s0), 0u);
    passed = check_crc32("ntt s0", (const uint8_t *)ntt_s0,
                         sizeof(ntt_s0), GOLDEN_NTT_S0_CRC32);
    if (!passed && first_failure == NULL) {
        first_failure = "NTT: transformed secret s0";
    }

    printf("\n[1] keypair\n");
    crypto_kem_keypair_derand(pk, sk, keypair_coins);
    check_crc32("pk", pk, sizeof(pk), GOLDEN_PK_CRC32);
    pkpv_passed = check_crc32("pkpv", pk, KYBER_POLYVECBYTES,
                              GOLDEN_PKPV_CRC32);
    passed = check_crc32("pk seed", pk + KYBER_POLYVECBYTES,
                         KYBER_SYMBYTES, GOLDEN_PUBLICSEED_CRC32);
    if (!passed && first_failure == NULL) {
        first_failure = "keypair: publicseed packing";
    }

    check_crc32("sk", sk, sizeof(sk), GOLDEN_SK_CRC32);
    skpv_passed = check_crc32("skpv", sk, KYBER_INDCPA_SECRETKEYBYTES,
                              GOLDEN_SKPV_CRC32);
    if (first_failure == NULL) {
        if (!skpv_passed) {
            first_failure = "keypair: integrated s_hat path/scheduling";
        } else if (!pkpv_passed) {
            first_failure = "keypair: t_hat = A_hat * s_hat + e_hat";
        }
    }
    passed = check_crc32("sk.pk", sk + KYBER_INDCPA_SECRETKEYBYTES,
                         KYBER_PUBLICKEYBYTES, GOLDEN_PK_CRC32);
    if (!passed && first_failure == NULL) {
        first_failure = "keypair: embedded public key";
    }
    passed = check_crc32("H(pk)",
                         sk + KYBER_SECRETKEYBYTES - 2 * KYBER_SYMBYTES,
                         KYBER_SYMBYTES, GOLDEN_HPK_CRC32);
    if (!passed && first_failure == NULL) {
        first_failure = "keypair: H(pk)";
    }
    passed = check_crc32("z", sk + KYBER_SECRETKEYBYTES - KYBER_SYMBYTES,
                         KYBER_SYMBYTES, GOLDEN_Z_CRC32);
    if (!passed && first_failure == NULL) {
        first_failure = "keypair: rejection seed z";
    }

    printf("\n[2] encapsulation\n");
    crypto_kem_enc_derand(ct, encaps_ss, pk, encaps_coins);
    passed = check_crc32("ct", ct, sizeof(ct), GOLDEN_CT_CRC32);
    if (!passed && first_failure == NULL) {
        first_failure = "encapsulation: ciphertext";
    }
    passed = check_crc32("encaps ss", encaps_ss, sizeof(encaps_ss),
                         GOLDEN_SS_CRC32);
    if (!passed && first_failure == NULL) {
        first_failure = "encapsulation: shared secret";
    }

    printf("\n[3] decapsulation\n");
    dec_result = crypto_kem_dec(decaps_ss, ct, sk);
    printf("dec return actual=%d expected=0  %s\n", dec_result,
           dec_result == 0 ? "PASS" : "FAIL");
    if (dec_result != 0 && first_failure == NULL) {
        first_failure = "decapsulation: ciphertext verification";
    }
    passed = check_crc32("decaps ss", decaps_ss, sizeof(decaps_ss),
                         GOLDEN_SS_CRC32);
    if (!passed && first_failure == NULL) {
        first_failure = "decapsulation: shared secret";
    }

    passed = (memcmp(encaps_ss, decaps_ss, KYBER_SSBYTES) == 0);
    printf("ss compare actual=%s expected=equal  %s\n",
           passed ? "equal" : "different", passed ? "PASS" : "FAIL");
    if (!passed && first_failure == NULL) {
        first_failure = "decapsulation: encaps/decaps mismatch";
    }

    if (first_failure != NULL) {
        printf("\nFIRST FAILURE: %s\n", first_failure);
        return 1;
    }

    printf("\nAll ML-KEM-512 reference golden checks passed.\n");
    return 0;
#endif
}
