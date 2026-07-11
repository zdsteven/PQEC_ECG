#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "aes.h"
#include "common_func.h"
#include "confreg_time.h"

unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#define CONFREG_TIMER_CMP_ADDR (CONFREG_TIMER_BASE + 0x4u)
#define CONFREG_TIMER_EN_ADDR  (CONFREG_TIMER_BASE + 0x8u)
#define CONFREG_CYCLES_PER_US  (CONFREG_CLOCKS_PER_SEC / 1000000ul)
#define AES_BUFFER_WORDS       64u

static uint32_t software_data[AES_BUFFER_WORDS] __attribute__((aligned(64)));
static uint32_t hardware_data[AES_BUFFER_WORDS] __attribute__((aligned(64)));

static const uint8_t aes_key[AES_KEYLEN] = {
#if defined(AES256) && (AES256 == 1)
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f
#else
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f
#endif
};

static const uint32_t nonce_key[2] = {
    0x03020100u,
    0x07060504u
};

static const uint32_t message_index = 0x11223344u;

static unsigned long cycles_to_us(unsigned long cycles)
{
    return cycles / CONFREG_CYCLES_PER_US;
}

static void init_timer(void)
{
    RegWrite(CONFREG_TIMER_EN_ADDR, 0u);
    RegWrite(CONFREG_TIMER_CMP_ADDR, 0xffffffffu);
    RegWrite(CONFREG_TIMER_EN_ADDR, 1u);
}

static void prepare_input(void)
{
    uint8_t *software_bytes = (uint8_t *)software_data;
    uint32_t i;

    for (i = 0u; i < AES_DATA_BYTES; ++i) {
        software_bytes[i] = (uint8_t)(i * 29u + 7u);
    }
    memcpy(hardware_data, software_data, AES_DATA_BYTES);
}

static void build_software_iv(uint8_t iv[AES_BLOCKLEN])
{
    const uint8_t *nonce_bytes = (const uint8_t *)nonce_key;

    memcpy(iv, nonce_bytes, 8u);
    iv[8] = (uint8_t)(message_index >> 24);
    iv[9] = (uint8_t)(message_index >> 16);
    iv[10] = (uint8_t)(message_index >> 8);
    iv[11] = (uint8_t)message_index;
    iv[12] = 0u;
    iv[13] = 0u;
    iv[14] = 0u;
    iv[15] = 2u;
}

int main(int argc, char **argv)
{
    struct AES_ctx software_ctx;
    uint8_t software_iv[AES_BLOCKLEN];
    unsigned long software_start;
    unsigned long software_cycles;
    unsigned long hardware_start;
    unsigned long hardware_cycles;
    uint32_t mismatch_word = AES_DATA_WORDS;
    uint32_t i;
    int dma_result;

    (void)argc;
    (void)argv;

    init_timer();
    prepare_input();
    build_software_iv(software_iv);

    software_start = get_confreg_clock_count();
    AES_init_ctx_iv_software(&software_ctx, aes_key, software_iv);
    AES_CTR_software(&software_ctx, (uint8_t *)software_data, AES_DATA_BYTES);
    software_cycles = get_confreg_clock_count() - software_start;

    hardware_start = get_confreg_clock_count();
    AES_init_hardware(aes_key);
    AES_set_nonce_hardware(nonce_key, message_index);
    dma_result = AES_CTR_hardware(hardware_data);
    if (dma_result == 0) {
        dma_result = AES_read_result_hardware(hardware_data);
    }
    hardware_cycles = get_confreg_clock_count() - hardware_start;

    if (dma_result == 0) {
        for (i = 0u; i < AES_DATA_WORDS; ++i) {
            if (software_data[i] != hardware_data[i]) {
                mismatch_word = i;
                break;
            }
        }
    }

    printf("AES-%u CTR, data=%u bytes\n", AES_KEYLEN * 8u, (unsigned)AES_DATA_BYTES);
    printf("software: cycles=%lu us=%lu\n", software_cycles, cycles_to_us(software_cycles));
    printf("hardware: cycles=%lu us=%lu dma_result=%d\n", hardware_cycles, cycles_to_us(hardware_cycles), dma_result);

    if (dma_result != 0) {
        printf("AES hardware test FAIL: DMA error %d\n", dma_result);
    } else if (mismatch_word != AES_DATA_WORDS) {
        printf("AES hardware test FAIL at word %u: sw=%08x hw=%08x\n",
                mismatch_word,
                software_data[mismatch_word],
                hardware_data[mismatch_word]);
    } else {
        printf("AES hardware test PASS\n");
    }

    while (1) {
    }

    return 0;
}
