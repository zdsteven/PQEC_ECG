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

static uint32_t plaintext[AES_DATA_WORDS] __attribute__((aligned(64)));
static uint32_t ciphertext[AES_DATA_WORDS] __attribute__((aligned(64)));
static uint32_t software_result[AES_DATA_WORDS] __attribute__((aligned(64)));
static uint32_t hardware_result[AES_GCM_INPUT_WORDS] __attribute__((aligned(64)));

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

static const uint8_t nonce[AES_GCM_NONCE_BYTES] = {
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
    0x06, 0x07, 0x11, 0x22, 0x33, 0x44
};

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

static void prepare_plaintext(void)
{
    uint8_t *bytes = (uint8_t *)plaintext;
    uint32_t i;

    for (i = 0u; i < AES_DATA_BYTES; ++i) {
        bytes[i] = (uint8_t)(i * 29u + 7u);
    }
}

static uint32_t first_mismatch(const uint32_t *left, const uint32_t *right)
{
    uint32_t i;

    for (i = 0u; i < AES_DATA_WORDS; ++i) {
        if (left[i] != right[i]) {
            return i;
        }
    }
    return AES_DATA_WORDS;
}

int main(int argc, char **argv)
{
    uint8_t tag[AES_GCM_TAG_BYTES];
    uint8_t bad_tag[AES_GCM_TAG_BYTES];
    unsigned long encrypt_cycles;
    unsigned long hardware_cycles;
    unsigned long software_cycles;
    unsigned long start;
    uint32_t mismatch;
    int hardware_auth_test;
    int hardware_status;
    int software_status;

    (void)argc;
    (void)argv;

    init_timer();
    prepare_plaintext();

    AES_GCM_encrypt_software(aes_key, nonce, 0, 0u, plaintext, AES_DATA_BYTES, ciphertext, tag);

    start = get_confreg_clock_count();
    software_status = AES_GCM_decrypt_software(aes_key, nonce, 0, 0u,
                                                ciphertext, AES_DATA_BYTES,
                                                tag, software_result);
    software_cycles = get_confreg_clock_count() - start;

    memcpy(hardware_result, ciphertext, AES_DATA_BYTES);
    memcpy(&hardware_result[AES_DATA_WORDS], tag, AES_GCM_TAG_BYTES);
    start = get_confreg_clock_count();
    AES_init_hardware(aes_key);
    AES_set_nonce_hardware(nonce);
    hardware_status = AES_GCM_decrypt_hardware(hardware_result);
    hardware_cycles = get_confreg_clock_count() - start;

    printf("AES-%u GCM, 198 bytes ECG data processing\n", (unsigned)(AES_KEYLEN * 8u));
    printf("software decrypt: cycles=%lu us=%lu\n", software_cycles, cycles_to_us(software_cycles));
    printf("hardware decrypt: cycles=%lu us=%lu\n", hardware_cycles, cycles_to_us(hardware_cycles));

    mismatch = first_mismatch(software_result, plaintext);
    if (software_status != AES_GCM_SUCCESS) {
        printf("AES-GCM software test FAIL: authentication error\n");
    } else if (mismatch != AES_DATA_WORDS) {
        printf("AES-GCM software test FAIL at word %u\n", mismatch);
    } else {
        printf("AES-GCM software test PASS\n");
    }

    mismatch = first_mismatch(hardware_result, plaintext);
    if (hardware_status != AES_GCM_SUCCESS) {
        printf("AES-GCM hardware test FAIL: status=%d\n", hardware_status);
    } else if (mismatch != AES_DATA_WORDS) {
        printf("AES-GCM hardware test FAIL at word %u: expected=%08x actual=%08x\n",
                mismatch, plaintext[mismatch], hardware_result[mismatch]);
    } else {
        printf("AES-GCM hardware test PASS\n");
    }

    memcpy(bad_tag, tag, sizeof(bad_tag));
    bad_tag[0] ^= 1u;
    memcpy(hardware_result, ciphertext, AES_DATA_BYTES);
    memcpy(&hardware_result[AES_DATA_WORDS], bad_tag, AES_GCM_TAG_BYTES);
    AES_set_nonce_hardware(nonce);
    hardware_auth_test = AES_GCM_decrypt_hardware(hardware_result);
    printf("AES-GCM hardware bad-tag test %s\n",
            hardware_auth_test == AES_GCM_AUTHENTICATION_ERROR ? "PASS" : "FAIL");

    while (1) {
    }

    return 0;
}
