#include "Hash_hw.h"
#include "confreg_time.h"
#include "dma.h"

static unsigned long hash_hardware_cycles;
static unsigned long hash_start_cycles;

static inline void hash_reset(void)
{
    RegWrite(HASH_HW_CTRL_ADDR, HASH_HW_CTRL_RESET_DATA);
}

static inline uint32_t hash_is_buzy(void)
{
    return RegRead(HASH_HW_STATUS_ADDR) & 0x2u;
}

static inline void hash_timing_start(void)
{
    hash_start_cycles = get_confreg_clock_count();
}

static inline void hash_timing_stop(void)
{
    hash_hardware_cycles = get_confreg_clock_count() - hash_start_cycles;
}

static inline void hash_iterate(uint32_t mode)
{
    RegWrite(HASH_HW_CTRL_ADDR, HASH_HW_CTRL_ITERATE | (mode << 5));
    while (hash_is_buzy()) {
    }
}

static inline int16_t centered_coefficient(uint16_t value)
{
    return value > KYBER_Q / 2 ? (int16_t)(value - KYBER_Q) : (int16_t)value;
}

static void flush_cache_lines(const void *buffer, uint32_t byte_length)
{
    uintptr_t address;
    uintptr_t first;
    uintptr_t last;
    uintptr_t line_bytes = (uintptr_t)1u << cache_offset_width;

    first = (uintptr_t)buffer & ~(line_bytes - 1u);
    last = ((uintptr_t)buffer + byte_length + line_bytes - 1u) & ~(line_bytes - 1u);
    for (address = first; address < last; address += line_bytes) {
        flush_dcache_line((unsigned long)address);
    }
}

static inline void hash_dma_readback(uint32_t source, void *destination, uint32_t byte_length)
{
    flush_cache_lines(destination, byte_length);
    DMA_Transfer_Blocking(source, (uint32_t)(uintptr_t)destination, byte_length, 0);
}

void KeccakF1600_StateReset_hw(void)
{
    hash_reset();
}

void KeccakF1600_StatePermute_hw(void)
{
    hash_timing_start();
    hash_iterate(HASH_HW_MODE_NORMAL);
    hash_timing_stop();
}

unsigned long Hash_hw_GetCycles(void)
{
    return hash_hardware_cycles;
}

void KeccakF1600_StateRead_hw(uint64_t state[25])
{
    hash_dma_readback(HASH_HW_DATA_BASE_ADDR, state, 25u * 8u);
}

void hash_g_hw(uint8_t output[64], const uint8_t *input, size_t input_length)
{
    hash_reset();

    if (input_length == KYBER_SYMBYTES + 1u) {
        flush_cache_lines(input, 32u);
        hash_timing_start();
        DMA_Transfer_Blocking((uint32_t)(uintptr_t)input,
                              HASH_HW_DATA_BASE_ADDR, 32u, 0);
        RegWrite(HASH_HW_DATA_BASE_ADDR + 8u * 4u,
                 (uint32_t)input[32] | 0x00000600u);
    } else {
        flush_cache_lines(input, 64u);
        hash_timing_start();
        DMA_Transfer_Blocking((uint32_t)(uintptr_t)input,
                              HASH_HW_DATA_BASE_ADDR, 64u, 0);
        RegWrite(HASH_HW_DATA_BASE_ADDR + 16u * 4u, 0x00000006u);
    }
    RegWrite(HASH_HW_DATA_BASE_ADDR + 17u * 4u, 0x80000000u);
    hash_iterate(HASH_HW_MODE_NORMAL);
    hash_timing_stop();

    hash_dma_readback(HASH_HW_DATA_BASE_ADDR, output, 64u);
}

void hash_h_hw(uint8_t output[32], const uint8_t input[KYBER_PUBLICKEYBYTES])
{
    uint32_t block;

    hash_reset();
    flush_cache_lines(input, KYBER_PUBLICKEYBYTES);
    hash_timing_start();

    for (block = 0; block < 5u; ++block) {
        DMA_Transfer_Blocking(
            (uint32_t)(uintptr_t)(input + block * SHA3_256_RATE),
            HASH_HW_DATA_BASE_ADDR, SHA3_256_RATE, 0);
        hash_iterate(HASH_HW_MODE_NORMAL);
    }

    input += 5u * SHA3_256_RATE;
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)input,
                          HASH_HW_DATA_BASE_ADDR, 120u, 0);
    RegWrite(HASH_HW_DATA_BASE_ADDR + 30u * 4u, 0x00000006u);
    RegWrite(HASH_HW_DATA_BASE_ADDR + 33u * 4u, 0x80000000u);
    hash_iterate(HASH_HW_MODE_NORMAL);
    hash_timing_stop();

    hash_dma_readback(HASH_HW_DATA_BASE_ADDR, output, 32u);
}

void gen_matrix_hw(polyvec *a, const uint8_t seed[KYBER_SYMBYTES], int transposed)
{
    uint32_t i;
    uint32_t j;
    uint32_t suffix;

    flush_cache_lines(seed, KYBER_SYMBYTES);
    hash_timing_start();

    for (i = 0; i < KYBER_K; ++i) {
        for (j = 0; j < KYBER_K; ++j) {
            hash_reset();
            DMA_Transfer_Blocking((uint32_t)(uintptr_t)seed,
                                  HASH_HW_DATA_BASE_ADDR,
                                  KYBER_SYMBYTES, 0);
            if (transposed) {
                suffix = i | (j << 8);
            } else {
                suffix = j | (i << 8);
            }
            RegWrite(HASH_HW_DATA_BASE_ADDR + 8u * 4u,
                     suffix | 0x001f0000u);
            RegWrite(HASH_HW_DATA_BASE_ADDR + 41u * 4u, 0x80000000u);
            hash_iterate(HASH_HW_MODE_REJECTION);
            hash_dma_readback(HASH_HW_DATA_BASE_ADDR, &a[i].vec[j],
                              KYBER_N * sizeof(int16_t));
        }
    }
    hash_timing_stop();
}

void poly_getnoise_eta1_hw(poly *r,
                            const uint8_t seed[KYBER_SYMBYTES],
                            uint8_t nonce)
{
    uint32_t i;

    hash_reset();
    flush_cache_lines(seed, KYBER_SYMBYTES);
    hash_timing_start();

    DMA_Transfer_Blocking((uint32_t)(uintptr_t)seed,
                          HASH_HW_DATA_BASE_ADDR, KYBER_SYMBYTES, 0);
    RegWrite(HASH_HW_DATA_BASE_ADDR + 8u * 4u,
             (uint32_t)nonce | 0x00001f00u);
    RegWrite(HASH_HW_DATA_BASE_ADDR + 33u * 4u, 0x80000000u);
    hash_iterate(HASH_HW_MODE_CBD3);
    hash_timing_stop();

    hash_dma_readback(HASH_HW_DATA_BASE_ADDR, r,
                      KYBER_N * sizeof(int16_t));
    for (i = 0; i < KYBER_N; ++i) {
        r->coeffs[i] = centered_coefficient((uint16_t)r->coeffs[i] & 0x0fffu);
    }
}

void poly_getnoise_eta2_hw(poly *r,
                            const uint8_t seed[KYBER_SYMBYTES],
                            uint8_t nonce)
{
    uint32_t i;

    hash_reset();
    flush_cache_lines(seed, KYBER_SYMBYTES);
    hash_timing_start();

    DMA_Transfer_Blocking((uint32_t)(uintptr_t)seed,
                          HASH_HW_DATA_BASE_ADDR, KYBER_SYMBYTES, 0);
    RegWrite(HASH_HW_DATA_BASE_ADDR + 8u * 4u,
             (uint32_t)nonce | 0x00001f00u);
    RegWrite(HASH_HW_DATA_BASE_ADDR + 33u * 4u, 0x80000000u);
    hash_iterate(HASH_HW_MODE_CBD2);
    hash_timing_stop();

    hash_dma_readback(HASH_HW_DATA_BASE_ADDR, r,
                      KYBER_N * sizeof(int16_t));
    for (i = 0; i < KYBER_N; ++i) {
        r->coeffs[i] = centered_coefficient((uint16_t)r->coeffs[i] & 0x0fffu);
    }
}

void rkprf_hw(uint8_t output[KYBER_SSBYTES],
                const uint8_t key[KYBER_SYMBYTES],
                const uint8_t input[KYBER_CIPHERTEXTBYTES])
{
    uint32_t block;

    hash_reset();
    flush_cache_lines(key, KYBER_SYMBYTES);
    flush_cache_lines(input, KYBER_CIPHERTEXTBYTES);
    hash_timing_start();

    DMA_Transfer_Blocking((uint32_t)(uintptr_t)key,
                          HASH_HW_DATA_BASE_ADDR, KYBER_SYMBYTES, 0);
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)input,
                          HASH_HW_DATA_BASE_ADDR + KYBER_SYMBYTES, 104u, 0);
    hash_iterate(HASH_HW_MODE_NORMAL);

    for (block = 0; block < 4u; ++block) {
        DMA_Transfer_Blocking(
            (uint32_t)(uintptr_t)(input + 104u + block * SHAKE256_RATE),
            HASH_HW_DATA_BASE_ADDR, SHAKE256_RATE, 0);
        hash_iterate(HASH_HW_MODE_NORMAL);
    }

    input += 648u;
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)input,
                          HASH_HW_DATA_BASE_ADDR, 120u, 0);
    RegWrite(HASH_HW_DATA_BASE_ADDR + 30u * 4u, 0x0000001fu);
    RegWrite(HASH_HW_DATA_BASE_ADDR + 33u * 4u, 0x80000000u);
    hash_iterate(HASH_HW_MODE_NORMAL);
    hash_timing_stop();

    hash_dma_readback(HASH_HW_DATA_BASE_ADDR, output, KYBER_SSBYTES);
}
