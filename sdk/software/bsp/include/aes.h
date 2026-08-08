#ifndef _AES_H_
#define _AES_H_

#include <stddef.h>
#include <stdint.h>

/* AES-256 is the default; define AES128=1 to select AES-128. */
#if !defined(AES128) && !defined(AES256)
#define AES256 1
#endif

#if defined(AES128) && (AES128 == 1) && defined(AES256) && (AES256 == 1)
#error "Select only one of AES128 or AES256"
#endif

#if defined(AES256) && (AES256 == 1)
#define AES_KEYLEN 32u
#else
#define AES_KEYLEN 16u
#endif

#define AES_BLOCKLEN        16u
#define AES_GCM_NONCE_BYTES 12u
#define AES_GCM_TAG_BYTES   16u

/* The hardware input window contains 50 data words followed by a 128-bit tag. */
#define AES_DATA_WORDS       50u
#define AES_DATA_BYTES       (AES_DATA_WORDS * sizeof(uint32_t))
#define AES_GCM_TAG_WORDS    (AES_GCM_TAG_BYTES / sizeof(uint32_t))
#define AES_GCM_INPUT_WORDS  (AES_DATA_WORDS + AES_GCM_TAG_WORDS)
#define AES_GCM_INPUT_BYTES  (AES_GCM_INPUT_WORDS * sizeof(uint32_t))

#define AES_CRYPTO_BASE_ADDR       0xbf600000u
#define AES_CTRL_ADDR              (AES_CRYPTO_BASE_ADDR + 0x000u)
#define AES_STATUS_ADDR            (AES_CRYPTO_BASE_ADDR + 0x004u)
#define AES_DATA_BASE_ADDR         (AES_CRYPTO_BASE_ADDR + 0x0f00u)
#define AES_EXPECTED_TAG_BASE_ADDR (AES_CRYPTO_BASE_ADDR + 0x0fc8u)
#define AES_KEY_BASE_ADDR          (AES_CRYPTO_BASE_ADDR + 0x1000u)
#define AES_NONCE_WORD_2_ADDR      (AES_CRYPTO_BASE_ADDR + 0x1020u)
#define AES_NONCE_WORD_1_ADDR      (AES_CRYPTO_BASE_ADDR + 0x1024u)
#define AES_NONCE_WORD_0_ADDR      (AES_CRYPTO_BASE_ADDR + 0x1028u)

#define AES_CTRL_INIT       (1u << 16)
#define AES_CTRL_KEYLEN_256 (1u << 17)
#define AES_CTRL_START      (1u << 18)
#define AES_STATUS_BUSY     (1u << 4)
#define AES_STATUS_AUTH_OK  (1u << 5)

enum aes_gcm_result {
    AES_GCM_SUCCESS = 0,
    AES_GCM_AUTHENTICATION_ERROR = 1
};

void AES_GCM_encrypt_software  (const uint8_t *key,
                                const uint8_t nonce[AES_GCM_NONCE_BYTES],
                                const void *aad, size_t aad_length,
                                const void *plaintext, size_t plaintext_length,
                                void *ciphertext,
                                uint8_t tag[AES_GCM_TAG_BYTES]);

int AES_GCM_decrypt_software   (const uint8_t *key,
                                const uint8_t nonce[AES_GCM_NONCE_BYTES],
                                const void *aad, size_t aad_length,
                                const void *ciphertext, size_t ciphertext_length,
                                const uint8_t tag[AES_GCM_TAG_BYTES],
                                void *plaintext);

void AES_init_hardware(const uint8_t *key);
void AES_set_nonce_hardware(const uint8_t nonce[AES_GCM_NONCE_BYTES]);

/*
 * Empty AAD and a fixed 200-byte message. data[0..49] holds ciphertext and
 * data[50..53] holds the expected tag; one DMA transfer loads both regions.
 * On success, data[0..49] is replaced with plaintext.
 */
int AES_GCM_decrypt_hardware(uint32_t data[AES_GCM_INPUT_WORDS]);

/* Authenticate/decrypt data, then DMA the plaintext directly to a peripheral. */
int AES_GCM_decrypt_to_peripheral_hardware(
    uint32_t data[AES_GCM_INPUT_WORDS],
    uint32_t destination_address,
    uint32_t byte_length);

#endif
