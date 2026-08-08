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

static uint32_t load32_be(const uint8_t *src)
{
    return ((uint32_t)src[0] << 24)
        | ((uint32_t)src[1] << 16)
        | ((uint32_t)src[2] << 8)
        | (uint32_t)src[3];
}

static void clean_cache_lines(const void *buffer, uint32_t byte_length)
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
    uint32_t ctrl = AES_CTRL_INIT;
    uint32_t i;

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

void AES_set_nonce_hardware(const uint8_t nonce[AES_GCM_NONCE_BYTES])
{
    RegWrite(AES_NONCE_WORD_0_ADDR, load32_le(nonce));
    RegWrite(AES_NONCE_WORD_1_ADDR, load32_le(nonce + 4u));
    RegWrite(AES_NONCE_WORD_2_ADDR, load32_be(nonce + 8u));
}

static int AES_GCM_start_and_authenticate(uint32_t data[AES_GCM_INPUT_WORDS])
{
    uint32_t status;
    int result;

    clean_cache_lines(data, AES_GCM_INPUT_BYTES);
    result = DMA_Transfer_Blocking((uint32_t)(uintptr_t)data, AES_DATA_BASE_ADDR, AES_GCM_INPUT_BYTES, 0u);
    if (result != 0) {
        return result;
    }

    RegWrite(AES_CTRL_ADDR, AES_CTRL_START);
    do {
        status = RegRead(AES_STATUS_ADDR);
    } while ((status & AES_STATUS_BUSY) != 0u);

    if ((status & AES_STATUS_AUTH_OK) == 0u) {
        return AES_GCM_AUTHENTICATION_ERROR;
    }

    return AES_GCM_SUCCESS;
}

int AES_GCM_decrypt_hardware(uint32_t data[AES_GCM_INPUT_WORDS])
{
    int result = AES_GCM_start_and_authenticate(data);

    if (result != AES_GCM_SUCCESS) {
        return result;
    }

    invalidate_cache_lines(data, AES_DATA_BYTES);
    return DMA_Transfer_Blocking(AES_DATA_BASE_ADDR, (uint32_t)(uintptr_t)data, AES_DATA_BYTES, 0u);
}

int AES_GCM_decrypt_to_peripheral_hardware(
    uint32_t data[AES_GCM_INPUT_WORDS],
    uint32_t destination_address,
    uint32_t byte_length)
{
    int result;

    if (byte_length > AES_DATA_BYTES) {
        return -1;
    }

    result = AES_GCM_start_and_authenticate(data);
    if (result != AES_GCM_SUCCESS) {
        return result;
    }

    return DMA_Transfer_Blocking(AES_DATA_BASE_ADDR, destination_address, byte_length, 0u);
}
