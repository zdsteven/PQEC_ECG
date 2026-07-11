#include "aes.h"

#include "common_func.h"
#include "dma.h"

static uint32_t load32_le(const uint8_t *src)
{
    return (uint32_t)src[0]
        | ((uint32_t)src[1] << 8)
        | ((uint32_t)src[2] << 16)
        | ((uint32_t)src[3] << 24);
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

static void invalidate_cache_lines(const void *buffer, uint32_t byte_length)
{
    uintptr_t address;
    uintptr_t first;
    uintptr_t last;
    uintptr_t line_bytes = (uintptr_t)1u << cache_offset_width;

    first = (uintptr_t)buffer & ~(line_bytes - 1u);
    last = ((uintptr_t)buffer + byte_length + line_bytes - 1u) & ~(line_bytes - 1u);
    for (address = first; address < last; address += line_bytes) {
        init_dcache_line((unsigned long)address);
    }
}

void AES_init_hardware(const uint8_t *key)
{
    uint32_t i;
    uint32_t ctrl = AES_CTRL_INIT;

    for (i = 0u; i < AES_KEYLEN / 4u; ++i) {
        RegWrite(AES_KEY_BASE_ADDR + i * 4u, load32_le(key + i * 4u));
    }

#if defined(AES256) && (AES256 == 1)
    ctrl |= AES_CTRL_KEYLEN_256;
#endif

    RegWrite(AES_CTRL_ADDR, ctrl);
    while ((RegRead(AES_STATUS_ADDR) & AES_STATUS_BUSY) != 0u) {
    }
}

void AES_set_nonce_hardware(const uint32_t nonce_key[2], uint32_t message_index)
{
    RegWrite(AES_NONCE_WORD_0_ADDR, nonce_key[0]);
    RegWrite(AES_NONCE_WORD_1_ADDR, nonce_key[1]);
    RegWrite(AES_NONCE_COUNTER_ADDR, message_index);
}

int AES_CTR_hardware(uint32_t data[AES_DATA_WORDS])
{
    int result;

    flush_cache_lines(data, AES_DATA_BYTES);
    result = DMA_Transfer_Blocking((uint32_t)(uintptr_t)data, AES_DATA_BASE_ADDR, AES_DATA_BYTES, 0u);
    if (result != 0) {
        return result;
    }

    RegWrite(AES_CTRL_ADDR, AES_CTRL_START);
    return 0;
}

int AES_read_result_hardware(uint32_t data[AES_DATA_WORDS])
{
    while ((RegRead(AES_STATUS_ADDR) & AES_STATUS_BUSY) != 0u) {
    }

    invalidate_cache_lines(data, AES_DATA_BYTES);
    return DMA_Transfer_Blocking(AES_DATA_BASE_ADDR, (uint32_t)(uintptr_t)data, AES_DATA_BYTES, 0u);
}
