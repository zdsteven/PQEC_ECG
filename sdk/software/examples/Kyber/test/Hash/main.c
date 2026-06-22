#include <stdio.h>

#include "Hash_hw.h"
#include "Hash_sw.h"
#include "Kyber.h"
#include "confreg_time.h"

unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#define CONFREG_TIMER_CMP_OFFSET 0x4u
#define CONFREG_TIMER_EN_OFFSET  0x8u

static uint8_t g_hash_g_input_33[KYBER_SYMBYTES + 1] __attribute__((aligned(64)));
static uint8_t g_hash_g_input_64[2 * KYBER_SYMBYTES] __attribute__((aligned(64)));
static uint8_t g_hash_h_input[KYBER_PUBLICKEYBYTES] __attribute__((aligned(64)));
static uint8_t g_rkprf_key[KYBER_SYMBYTES] __attribute__((aligned(64)));
static uint8_t g_rkprf_input[KYBER_CIPHERTEXTBYTES] __attribute__((aligned(64)));
static uint8_t g_seed[KYBER_SYMBYTES] __attribute__((aligned(64)));

static uint64_t g_sw_keccak[25];
static uint64_t g_hw_keccak[25] __attribute__((aligned(64)));
static uint8_t g_sw_hash[2][64];
static uint8_t g_hw_hash[2][64] __attribute__((aligned(64)));
static polyvec g_sw_matrix[KYBER_K];
static polyvec g_hw_matrix[KYBER_K] __attribute__((aligned(64)));
static polyvec g_sw_matrix_t[KYBER_K];
static polyvec g_hw_matrix_t[KYBER_K] __attribute__((aligned(64)));
static poly g_sw_poly;
static poly g_hw_poly __attribute__((aligned(64)));

static void init_confreg_timer(void)
{
    RegWrite((uint32_t)(CONFREG_TIMER_BASE + CONFREG_TIMER_CMP_OFFSET), 0xffffffffu);
    RegWrite((uint32_t)(CONFREG_TIMER_BASE + CONFREG_TIMER_EN_OFFSET), 1u);
}

static unsigned long cycles_to_us(unsigned long cycles)
{
    return (unsigned long)(((uint64_t)cycles * 1000000ULL) / (uint64_t)CONFREG_CLOCKS_PER_SEC);
}

static void print_perf(const char *name, const char *implementation, unsigned long cycles)
{
    printf("%s %s: %lu cycles, about %lu us\n", name, implementation, cycles, cycles_to_us(cycles));
}

static void print_bytes(const char *name, const uint8_t *data,
                        unsigned int length)
{
    unsigned int i;

    printf("%s:", name);
    for (i = 0; i < length; ++i) {
        if ((i & 15u) == 0u) {
            printf("\n");
        }
        printf("%02x", (unsigned int)data[i]);
    }
    printf("\n");
}

static void print_poly_head(const char *name, const poly *value)
{
    unsigned int i;

    printf("%s first 16:", name);
    for (i = 0; i < 16u; ++i) {
        printf(" %d", (int)value->coeffs[i]);
    }
    printf("\n");
}

static void print_keccak_head(const char *name, const uint64_t state[25])
{
    unsigned int i;

    printf("%s first 4 lanes:\n", name);
    for (i = 0; i < 4u; ++i) {
        printf("  S[%u]=%08x%08x\n", i,
               (unsigned int)(state[i] >> 32),
               (unsigned int)state[i]);
    }
}

static unsigned int compare_keccak(const uint64_t hardware[25],
                                   const uint64_t software[25])
{
    unsigned int i;
    unsigned int errors = 0;

    for (i = 0; i < 25u; ++i) {
        if (hardware[i] != software[i]) {
            if (errors < 8u) {
                printf("Keccak mismatch @%u: hw=%08x%08x sw=%08x%08x\n",
                       i,
                       (unsigned int)(hardware[i] >> 32),
                       (unsigned int)hardware[i],
                       (unsigned int)(software[i] >> 32),
                       (unsigned int)software[i]);
            }
            ++errors;
        }
    }
    printf("KeccakF1600_StatePermute compare %s",
           errors == 0u ? "PASS\n" : "FAIL\n");
    return errors;
}

static unsigned int compare_bytes(const char *name, const uint8_t *hardware,
                                    const uint8_t *software,
                                    unsigned int length)
{
    unsigned int i;
    unsigned int errors = 0;

    for (i = 0; i < length; ++i) {
        if (hardware[i] != software[i]) {
            if (errors < 8u) {
                printf("%s mismatch @%u: hw=%02x sw=%02x\n",
                        name, i, (unsigned int)hardware[i], (unsigned int)software[i]);
            }
            ++errors;
        }
    }
    printf("%s %s", name, errors == 0u ? "PASS\n" : "FAIL\n");
    return errors;
}

static unsigned int compare_poly(const char *name, const poly *hardware,
                                 const poly *software)
{
    unsigned int i;
    unsigned int errors = 0;

    for (i = 0; i < KYBER_N; ++i) {
        if (hardware->coeffs[i] != software->coeffs[i]) {
            if (errors < 8u) {
                printf("%s mismatch @%u: hw=%d sw=%d\n",
                        name, i, (int)hardware->coeffs[i],
                        (int)software->coeffs[i]);
            }
            ++errors;
        }
    }
    printf("%s %s", name, errors == 0u ? "PASS\n" : "FAIL\n");
    return errors;
}

static unsigned int compare_matrix(const char *name, const polyvec *hardware,
                                   const polyvec *software)
{
    unsigned int i;
    unsigned int j;
    unsigned int k;
    unsigned int errors = 0;

    for (i = 0; i < KYBER_K; ++i) {
        for (j = 0; j < KYBER_K; ++j) {
            for (k = 0; k < KYBER_N; ++k) {
                if (hardware[i].vec[j].coeffs[k]
                    != software[i].vec[j].coeffs[k]) {
                    if (errors < 8u) {
                        printf("%s mismatch [%u][%u][%u]: hw=%d sw=%d\n",
                                name, i, j, k,
                                (int)hardware[i].vec[j].coeffs[k],
                                (int)software[i].vec[j].coeffs[k]);
                    }
                    ++errors;
                }
            }
        }
    }
    printf("%s %s", name, errors == 0u ? "PASS\n" : "FAIL\n");
    return errors;
}

static void generate_inputs(void)
{
    unsigned int i;

    for (i = 0; i < 25u; ++i) {
        g_sw_keccak[i] = 0;
        g_hw_keccak[i] = 0;
    }
    for (i = 0; i < sizeof(g_hash_g_input_33); ++i) {
        g_hash_g_input_33[i] = (uint8_t)(i * 23u + 0x41u);
    }
    for (i = 0; i < sizeof(g_hash_g_input_64); ++i) {
        g_hash_g_input_64[i] = (uint8_t)(i * 29u + 7u);
    }
    for (i = 0; i < sizeof(g_hash_h_input); ++i) {
        g_hash_h_input[i] = (uint8_t)(i * 17u + (i >> 3) + 0x31u);
    }
    for (i = 0; i < sizeof(g_rkprf_key); ++i) {
        g_rkprf_key[i] = (uint8_t)(i * 11u + 0x53u);
        g_seed[i] = (uint8_t)(i * 37u + 0x19u);
    }
    for (i = 0; i < sizeof(g_rkprf_input); ++i) {
        g_rkprf_input[i] = (uint8_t)(i * 13u + (i >> 2) + 0xa5u);
    }
}

int main(int argc, char **argv)
{
    unsigned long start_cycles;
    unsigned long sw_cycles;
    unsigned long hw_cycles;
    unsigned int errors = 0;

    (void)argc;
    (void)argv;

    printf("ML-KEM-512 Hash accelerator test start\n");
    init_confreg_timer();
    generate_inputs();

    printf("\n[1] single KeccakF1600_StatePermute\n");
    start_cycles = get_confreg_clock_count();
    KeccakF1600_StatePermute(g_sw_keccak);
    sw_cycles = get_confreg_clock_count() - start_cycles;
    print_perf("KeccakF1600_StatePermute", "software", sw_cycles);

    KeccakF1600_StateReset_hw();
    start_cycles = get_confreg_clock_count();
    KeccakF1600_StatePermute_hw();
    hw_cycles = get_confreg_clock_count() - start_cycles;
    KeccakF1600_StateRead_hw(g_hw_keccak);
    print_perf("KeccakF1600_StatePermute", "hardware", hw_cycles);
    print_keccak_head("Keccak software", g_sw_keccak);
    print_keccak_head("Keccak hardware", g_hw_keccak);
    errors += compare_keccak(g_hw_keccak, g_sw_keccak);

    printf("\n[2] hash_g / SHA3-512 (33-byte and 64-byte inputs)\n");
    start_cycles = get_confreg_clock_count();
    hash_g(g_sw_hash[0], g_hash_g_input_33, sizeof(g_hash_g_input_33));
    hash_g(g_sw_hash[1], g_hash_g_input_64, sizeof(g_hash_g_input_64));
    sw_cycles = get_confreg_clock_count() - start_cycles;
    print_perf("hash_g x2", "software", sw_cycles);
    start_cycles = get_confreg_clock_count();
    hash_g_hw(g_hw_hash[0], g_hash_g_input_33, sizeof(g_hash_g_input_33));
    hash_g_hw(g_hw_hash[1], g_hash_g_input_64, sizeof(g_hash_g_input_64));
    hw_cycles = get_confreg_clock_count() - start_cycles;
    print_perf("hash_g x2", "hardware", hw_cycles);
    print_bytes("hash_g(33) software", g_sw_hash[0], 64u);
    print_bytes("hash_g(33) hardware", g_hw_hash[0], 64u);
    errors += compare_bytes("hash_g(33) compare", g_hw_hash[0], g_sw_hash[0], 64u);
    errors += compare_bytes("hash_g(64) compare", g_hw_hash[1], g_sw_hash[1], 64u);

    printf("\n[3] gen_matrix / SHAKE128 + rejection sampling\n");
    start_cycles = get_confreg_clock_count();
    gen_matrix(g_sw_matrix, g_seed, 0);
    gen_matrix(g_sw_matrix_t, g_seed, 1);
    sw_cycles = get_confreg_clock_count() - start_cycles;
    print_perf("gen_matrix(A and AT)", "software", sw_cycles);
    start_cycles = get_confreg_clock_count();
    gen_matrix_hw(g_hw_matrix, g_seed, 0);
    gen_matrix_hw(g_hw_matrix_t, g_seed, 1);
    hw_cycles = get_confreg_clock_count() - start_cycles;
    print_perf("gen_matrix(A and AT)", "hardware", hw_cycles);
    print_poly_head("gen_matrix software A[0][0]", &g_sw_matrix[0].vec[0]);
    print_poly_head("gen_matrix hardware A[0][0]", &g_hw_matrix[0].vec[0]);
    errors += compare_matrix("gen_matrix A compare", g_hw_matrix, g_sw_matrix);
    errors += compare_matrix("gen_matrix AT compare", g_hw_matrix_t, g_sw_matrix_t);

    printf("\n[4] poly_getnoise_eta1 / SHAKE256 + CBD eta=3\n");
    start_cycles = get_confreg_clock_count();
    poly_getnoise_eta1(&g_sw_poly, g_seed, 0x42u);
    sw_cycles = get_confreg_clock_count() - start_cycles;
    print_perf("poly_getnoise_eta1", "software", sw_cycles);
    start_cycles = get_confreg_clock_count();
    poly_getnoise_eta1_hw(&g_hw_poly, g_seed, 0x42u);
    hw_cycles = get_confreg_clock_count() - start_cycles;
    print_perf("poly_getnoise_eta1", "hardware", hw_cycles);
    print_poly_head("eta1 software", &g_sw_poly);
    print_poly_head("eta1 hardware", &g_hw_poly);
    errors += compare_poly("poly_getnoise_eta1 compare", &g_hw_poly, &g_sw_poly);

    printf("\n[5] poly_getnoise_eta2 / SHAKE256 + CBD eta=2\n");
    start_cycles = get_confreg_clock_count();
    poly_getnoise_eta2(&g_sw_poly, g_seed, 0x27u);
    sw_cycles = get_confreg_clock_count() - start_cycles;
    print_perf("poly_getnoise_eta2", "software", sw_cycles);
    start_cycles = get_confreg_clock_count();
    poly_getnoise_eta2_hw(&g_hw_poly, g_seed, 0x27u);
    hw_cycles = get_confreg_clock_count() - start_cycles;
    print_perf("poly_getnoise_eta2", "hardware", hw_cycles);
    print_poly_head("eta2 software", &g_sw_poly);
    print_poly_head("eta2 hardware", &g_hw_poly);
    errors += compare_poly("poly_getnoise_eta2 compare", &g_hw_poly, &g_sw_poly);

    printf("\n[6] hash_h / SHA3-256(public key)\n");
    start_cycles = get_confreg_clock_count();
    hash_h(g_sw_hash[0], g_hash_h_input, sizeof(g_hash_h_input));
    sw_cycles = get_confreg_clock_count() - start_cycles;
    print_perf("hash_h", "software", sw_cycles);
    start_cycles = get_confreg_clock_count();
    hash_h_hw(g_hw_hash[0], g_hash_h_input);
    hw_cycles = get_confreg_clock_count() - start_cycles;
    print_perf("hash_h", "hardware", hw_cycles);
    print_bytes("hash_h software", g_sw_hash[0], 32u);
    print_bytes("hash_h hardware", g_hw_hash[0], 32u);
    errors += compare_bytes("hash_h compare", g_hw_hash[0], g_sw_hash[0], 32u);

    printf("\n[7] rkprf / SHAKE256(key || ciphertext)\n");
    start_cycles = get_confreg_clock_count();
    rkprf(g_sw_hash[0], g_rkprf_key, g_rkprf_input);
    sw_cycles = get_confreg_clock_count() - start_cycles;
    print_perf("rkprf", "software", sw_cycles);
    start_cycles = get_confreg_clock_count();
    rkprf_hw(g_hw_hash[0], g_rkprf_key, g_rkprf_input);
    hw_cycles = get_confreg_clock_count() - start_cycles;
    print_perf("rkprf", "hardware", hw_cycles);
    print_bytes("rkprf software", g_sw_hash[0], KYBER_SSBYTES);
    print_bytes("rkprf hardware", g_hw_hash[0], KYBER_SSBYTES);
    errors += compare_bytes("rkprf compare", g_hw_hash[0], g_sw_hash[0], KYBER_SSBYTES);

    if (errors == 0u) {
        printf("\nAll ML-KEM-512 Hash accelerator checks PASS\n");
    } else {
        printf("\nML-KEM-512 Hash accelerator checks FAIL, mismatches=%u\n", errors);
    }

    while (1) {
    }

    return 0;
}
