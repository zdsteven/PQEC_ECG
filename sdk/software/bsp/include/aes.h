#ifndef _AES_H_
#define _AES_H_

#include <stdint.h>
#include <stddef.h>

// CTR mode only. Define AES256=1 at compile time to select AES-256.
#if !defined(AES128) && !defined(AES256)
#define AES128 1
#endif

#define AES_BLOCKLEN 16
#define AES_NONCELEN 12
#define AES_DATA_WORDS 50u
#define AES_DATA_BYTES (AES_DATA_WORDS * sizeof(uint32_t))

#define AES_CRYPTO_BASE_ADDR         0xbf600000u
#define AES_CTRL_ADDR                (AES_CRYPTO_BASE_ADDR + 0x000u)
#define AES_STATUS_ADDR              (AES_CRYPTO_BASE_ADDR + 0x004u)
#define AES_DATA_BASE_ADDR           (AES_CRYPTO_BASE_ADDR + 0x0f00u)
#define AES_KEY_BASE_ADDR            (AES_CRYPTO_BASE_ADDR + 0x1000u)
#define AES_NONCE_COUNTER_ADDR       (AES_CRYPTO_BASE_ADDR + 0x1020u)
#define AES_NONCE_WORD_1_ADDR        (AES_CRYPTO_BASE_ADDR + 0x1024u)
#define AES_NONCE_WORD_0_ADDR        (AES_CRYPTO_BASE_ADDR + 0x1028u)

#define AES_CTRL_INIT                (1u << 16)
#define AES_CTRL_KEYLEN_256          (1u << 17)
#define AES_CTRL_START               (1u << 18)
#define AES_STATUS_BUSY              (1u << 4)

#if defined(AES256) && (AES256 == 1)
    #define AES_KEYLEN 32
    #define AES_keyExpSize 240
#else
    #define AES_KEYLEN 16   
    #define AES_keyExpSize 176
#endif

struct AES_ctx
{
    uint8_t RoundKey[AES_keyExpSize];
    uint8_t Iv[AES_BLOCKLEN];
};

void AES_init_ctx_software(struct AES_ctx* ctx, const uint8_t* key);
void AES_init_ctx_iv_software(struct AES_ctx* ctx, const uint8_t* key, const uint8_t* iv);
void AES_ctx_set_iv_software(struct AES_ctx* ctx, const uint8_t* iv);

void AES_CTR_software(struct AES_ctx* ctx, uint8_t* buf, size_t length);

void AES_init_hardware(const uint8_t* key);
void AES_set_nonce_hardware(const uint32_t nonce_key[2], uint32_t message_index);
int AES_CTR_hardware(uint32_t data[AES_DATA_WORDS]);
int AES_read_result_hardware(uint32_t data[AES_DATA_WORDS]);

#endif 
