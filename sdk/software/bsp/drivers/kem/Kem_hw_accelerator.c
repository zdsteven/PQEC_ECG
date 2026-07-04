#include "Kem_api.h"

#include "dma.h"

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

static inline void hash_reset(void)
{
    RegWrite(KYBER_CTRL_ADDR, (1u << 3));
}

static inline void hash_iterate(uint32_t mode)
{
    RegWrite(KYBER_CTRL_ADDR, (1u << 4) | (mode << 5));
    while (KYBER_HASH_IS_BUZY);
}

void hash_g_33(uint8_t output[64], const uint8_t *input)
{
    hash_reset();
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)input, KYBER_HASH_DATA_BASE_ADDR, 32u, 0);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 8u * 4u, (uint32_t)input[32] | 0x00000600u);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 17u * 4u, 0x80000000u);
    hash_iterate(HASH_MODE_NORMAL);
    DMA_Transfer_Blocking(KYBER_HASH_DATA_BASE_ADDR, (uint32_t)(uintptr_t)output, 64u, 0);
}

void hash_g_64(uint8_t output[64], const uint8_t *input)
{
    hash_reset();
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)input, KYBER_HASH_DATA_BASE_ADDR, 64u, 0);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 16u * 4u, 0x00000006u);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 17u * 4u, 0x80000000u);
    hash_iterate(HASH_MODE_NORMAL);
    DMA_Transfer_Blocking(KYBER_HASH_DATA_BASE_ADDR, (uint32_t)(uintptr_t)output, 64u, 0);
}

void hash_h(uint8_t output[32], const uint8_t input[KYBER_PUBLICKEYBYTES])
{
    uint32_t block;
    hash_reset();

    #if KYBER_K == 2
    for (block = 0; block < 5u; ++block) {
        DMA_Transfer_Blocking(
            (uint32_t)(uintptr_t)(input + block * SHA3_256_RATE),
            KYBER_HASH_DATA_BASE_ADDR, SHA3_256_RATE, 0);
        hash_iterate(HASH_MODE_NORMAL);
    }
    input += 5u * SHA3_256_RATE;
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)input, KYBER_HASH_DATA_BASE_ADDR, 120u, 0);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 30u * 4u, 0x00000006u);
    #elif KYBER_K == 3
    for (block = 0; block < 8u; ++block) {
        DMA_Transfer_Blocking(
            (uint32_t)(uintptr_t)(input + block * SHA3_256_RATE),
            KYBER_HASH_DATA_BASE_ADDR, SHA3_256_RATE, 0);
        hash_iterate(HASH_MODE_NORMAL);
    }
    input += 8u * SHA3_256_RATE;
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)input, KYBER_HASH_DATA_BASE_ADDR, 96u, 0);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 24u * 4u, 0x00000006u);
    #elif KYBER_K == 4
    for (block = 0; block < 11u; ++block) {
        DMA_Transfer_Blocking(
            (uint32_t)(uintptr_t)(input + block * SHA3_256_RATE),
            KYBER_HASH_DATA_BASE_ADDR, SHA3_256_RATE, 0);
        hash_iterate(HASH_MODE_NORMAL);
    }
    input += 11u * SHA3_256_RATE;
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)input, KYBER_HASH_DATA_BASE_ADDR, 72u, 0);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 18u * 4u, 0x00000006u);
    #else
    #error "KYBER_K must be 2, 3, or 4"
    #endif

    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 33u * 4u, 0x80000000u);
    hash_iterate(HASH_MODE_NORMAL);
    
    DMA_Transfer_Blocking(KYBER_HASH_DATA_BASE_ADDR, (uint32_t)(uintptr_t)output, 32u, 0);
}

void rkprf(uint8_t output[KYBER_SSBYTES],
                const uint8_t key[KYBER_SYMBYTES],
                const uint8_t input[KYBER_CIPHERTEXTBYTES])
{
    uint32_t block;
    hash_reset();
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)key, KYBER_HASH_DATA_BASE_ADDR, KYBER_SYMBYTES, 0);
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)input, KYBER_HASH_DATA_BASE_ADDR + KYBER_SYMBYTES, 104u, 0);
    hash_iterate(HASH_MODE_NORMAL);

    #if KYBER_K == 2
    for (block = 0; block < 4u; ++block) {
        DMA_Transfer_Blocking(
            (uint32_t)(uintptr_t)(input + 104u + block * SHAKE256_RATE),
            KYBER_HASH_DATA_BASE_ADDR, SHAKE256_RATE, 0);
        hash_iterate(HASH_MODE_NORMAL);
    }
    input += 648u;
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)input, KYBER_HASH_DATA_BASE_ADDR, 120u, 0);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 30u * 4u, 0x0000001fu);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 33u * 4u, 0x80000000u);
    hash_iterate(HASH_MODE_NORMAL);
    #elif KYBER_K == 3
    for (block = 0; block < 7u; ++block) {
        DMA_Transfer_Blocking(
            (uint32_t)(uintptr_t)(input + 104u + block * SHAKE256_RATE),
            KYBER_HASH_DATA_BASE_ADDR, SHAKE256_RATE, 0);
        hash_iterate(HASH_MODE_NORMAL);
    }
    input += 1056u;
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)input, KYBER_HASH_DATA_BASE_ADDR, 32u, 0);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 8u * 4u, 0x0000001fu);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 33u * 4u, 0x80000000u);
    hash_iterate(HASH_MODE_NORMAL);
    #elif KYBER_K == 4
    for (block = 0; block < 10u; ++block) {
        DMA_Transfer_Blocking(
            (uint32_t)(uintptr_t)(input + 104u + block * SHAKE256_RATE),
            KYBER_HASH_DATA_BASE_ADDR, SHAKE256_RATE, 0);
        hash_iterate(HASH_MODE_NORMAL);
    }
    input += 1464u;
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)input, KYBER_HASH_DATA_BASE_ADDR, 104u, 0);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 26u * 4u, 0x0000001fu);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 33u * 4u, 0x80000000u);
    hash_iterate(HASH_MODE_NORMAL);
    #else
    #error "KYBER_K must be 2, 3, or 4"
    #endif

    DMA_Transfer_Blocking(KYBER_HASH_DATA_BASE_ADDR, (uint32_t)(uintptr_t)output, KYBER_SSBYTES, 0);
}
