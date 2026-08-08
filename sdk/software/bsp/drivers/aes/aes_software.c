#include <string.h>
#include "aes.h"

/* GCM construction follows the Apache-2.0 reference in AES-GCM_software. */

#define Nb 4

#if defined(AES256) && (AES256 == 1)
#define Nk 8
#define Nr 14
#define AES_KEY_EXP_SIZE 240
#else
#define Nk 4
#define Nr 10
#define AES_KEY_EXP_SIZE 176
#endif

typedef uint8_t state_t[4][4];

struct aes_context
{
    uint8_t RoundKey[AES_KEY_EXP_SIZE];
};

static const uint8_t sbox[256] = {
    // 0     1    2      3     4    5     6     7      8    9     A      B    C     D     E     F
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16};

static const uint8_t Rcon[11] = {0x8d, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36};

#define getSBoxValue(num) (sbox[(num)])

static void KeyExpansion(uint8_t *RoundKey, const uint8_t *Key)
{
    unsigned i, j, k;
    uint8_t tempa[4];
    for (i = 0; i < Nk; ++i)
    {
        RoundKey[(i * 4) + 0] = Key[(i * 4) + 0];
        RoundKey[(i * 4) + 1] = Key[(i * 4) + 1];
        RoundKey[(i * 4) + 2] = Key[(i * 4) + 2];
        RoundKey[(i * 4) + 3] = Key[(i * 4) + 3];
    }

    for (i = Nk; i < Nb * (Nr + 1); ++i)
    {
        {
            k = (i - 1) * 4;
            tempa[0] = RoundKey[k + 0];
            tempa[1] = RoundKey[k + 1];
            tempa[2] = RoundKey[k + 2];
            tempa[3] = RoundKey[k + 3];
        }

        if (i % Nk == 0)
        {
            // Function RotWord()
            {
                const uint8_t u8tmp = tempa[0];
                tempa[0] = tempa[1];
                tempa[1] = tempa[2];
                tempa[2] = tempa[3];
                tempa[3] = u8tmp;
            }
            // Function Subword()
            {
                tempa[0] = getSBoxValue(tempa[0]);
                tempa[1] = getSBoxValue(tempa[1]);
                tempa[2] = getSBoxValue(tempa[2]);
                tempa[3] = getSBoxValue(tempa[3]);
            }
            tempa[0] = tempa[0] ^ Rcon[i / Nk];
        }
#if defined(AES256) && (AES256 == 1)
        if (i % Nk == 4)
        {
            // Function Subword()
            {
                tempa[0] = getSBoxValue(tempa[0]);
                tempa[1] = getSBoxValue(tempa[1]);
                tempa[2] = getSBoxValue(tempa[2]);
                tempa[3] = getSBoxValue(tempa[3]);
            }
        }
#endif
        j = i * 4;
        k = (i - Nk) * 4;
        RoundKey[j + 0] = RoundKey[k + 0] ^ tempa[0];
        RoundKey[j + 1] = RoundKey[k + 1] ^ tempa[1];
        RoundKey[j + 2] = RoundKey[k + 2] ^ tempa[2];
        RoundKey[j + 3] = RoundKey[k + 3] ^ tempa[3];
    }
}

static void AddRoundKey(uint8_t round, state_t *state, const uint8_t *RoundKey)
{
    uint8_t i, j;
    for (i = 0; i < 4; ++i)
    {
        for (j = 0; j < 4; ++j)
        {
            (*state)[i][j] ^= RoundKey[(round * Nb * 4) + (i * Nb) + j];
        }
    }
}

static void SubBytes(state_t *state)
{
    uint8_t i, j;
    for (i = 0; i < 4; ++i)
    {
        for (j = 0; j < 4; ++j)
        {
            (*state)[j][i] = getSBoxValue((*state)[j][i]);
        }
    }
}

static void ShiftRows(state_t *state)
{
    uint8_t temp;

    temp = (*state)[0][1];
    (*state)[0][1] = (*state)[1][1];
    (*state)[1][1] = (*state)[2][1];
    (*state)[2][1] = (*state)[3][1];
    (*state)[3][1] = temp;

    temp = (*state)[0][2];
    (*state)[0][2] = (*state)[2][2];
    (*state)[2][2] = temp;

    temp = (*state)[1][2];
    (*state)[1][2] = (*state)[3][2];
    (*state)[3][2] = temp;

    temp = (*state)[0][3];
    (*state)[0][3] = (*state)[3][3];
    (*state)[3][3] = (*state)[2][3];
    (*state)[2][3] = (*state)[1][3];
    (*state)[1][3] = temp;
}

static uint8_t xtime(uint8_t x)
{
    return ((x << 1) ^ (((x >> 7) & 1) * 0x1b));
}

static void MixColumns(state_t *state)
{
    uint8_t i;
    uint8_t Tmp, Tm, t;
    for (i = 0; i < 4; ++i)
    {
        t = (*state)[i][0];
        Tmp = (*state)[i][0] ^ (*state)[i][1] ^ (*state)[i][2] ^ (*state)[i][3];
        Tm = (*state)[i][0] ^ (*state)[i][1];
        Tm = xtime(Tm);
        (*state)[i][0] ^= Tm ^ Tmp;
        Tm = (*state)[i][1] ^ (*state)[i][2];
        Tm = xtime(Tm);
        (*state)[i][1] ^= Tm ^ Tmp;
        Tm = (*state)[i][2] ^ (*state)[i][3];
        Tm = xtime(Tm);
        (*state)[i][2] ^= Tm ^ Tmp;
        Tm = (*state)[i][3] ^ t;
        Tm = xtime(Tm);
        (*state)[i][3] ^= Tm ^ Tmp;
    }
}

static void Cipher(state_t *state, const uint8_t *RoundKey)
{
    uint8_t round = 0;

    AddRoundKey(0, state, RoundKey);

    for (round = 1;; ++round)
    {
        SubBytes(state);
        ShiftRows(state);
        if (round == Nr)
        {
            break;
        }
        MixColumns(state);
        AddRoundKey(round, state, RoundKey);
    }

    AddRoundKey(Nr, state, RoundKey);
}


static void secure_zero(void *data, size_t length)
{
    volatile uint8_t *bytes = (volatile uint8_t *)data;

    while (length-- != 0u) {
        *bytes++ = 0u;
    }
}

static void encrypt_block  (const struct aes_context *context,
                            const uint8_t input[AES_BLOCKLEN],
                            uint8_t output[AES_BLOCKLEN])
{
    memcpy(output, input, AES_BLOCKLEN);
    Cipher((state_t *)output, context->RoundKey);
}

static void xor_block  (uint8_t destination[AES_BLOCKLEN],
                        const uint8_t source[AES_BLOCKLEN])
{
    size_t i;

    for (i = 0u; i < AES_BLOCKLEN; ++i) {
        destination[i] ^= source[i];
    }
}

static void multiply_gf128 (uint8_t value[AES_BLOCKLEN],
                            const uint8_t hash_key[AES_BLOCKLEN])
{
    uint8_t factor[AES_BLOCKLEN];
    uint8_t product[AES_BLOCKLEN];
    size_t bit;
    size_t i;

    memcpy(factor, hash_key, sizeof(factor));
    memset(product, 0, sizeof(product));

    for (bit = 0u; bit < 128u; ++bit) {
        uint8_t carry;
        uint8_t mask;

        mask = (uint8_t)(0u - ((value[bit / 8u] >> (7u - bit % 8u)) & 1u));
        for (i = 0u; i < AES_BLOCKLEN; ++i) {
            product[i] ^= factor[i] & mask;
        }

        carry = factor[AES_BLOCKLEN - 1u] & 1u;
        for (i = AES_BLOCKLEN - 1u; i != 0u; --i) {
            factor[i] = (uint8_t)((factor[i] >> 1) | (factor[i - 1u] << 7));
        }
        factor[0] >>= 1;
        factor[0] ^= (uint8_t)(0xe1u & (0u - carry));
    }

    memcpy(value, product, AES_BLOCKLEN);
    secure_zero(factor, sizeof(factor));
    secure_zero(product, sizeof(product));
}

static void ghash_update   (uint8_t state[AES_BLOCKLEN],
                            const uint8_t hash_key[AES_BLOCKLEN],
                            const uint8_t *data, size_t length)
{
    while (length >= AES_BLOCKLEN) {
        xor_block(state, data);
        multiply_gf128(state, hash_key);
        data += AES_BLOCKLEN;
        length -= AES_BLOCKLEN;
    }

    if (length != 0u) {
        uint8_t last[AES_BLOCKLEN];

        memset(last, 0, sizeof(last));
        memcpy(last, data, length);
        xor_block(state, last);
        multiply_gf128(state, hash_key);
        secure_zero(last, sizeof(last));
    }
}

static void store64_be(uint8_t output[8], uint64_t value)
{
    size_t i;

    for (i = 8u; i != 0u; --i) {
        output[i - 1u] = (uint8_t)value;
        value >>= 8;
    }
}

static void ghash  (const uint8_t hash_key[AES_BLOCKLEN],
                    const void *aad, size_t aad_length,
                    const void *ciphertext, size_t ciphertext_length,
                    uint8_t result[AES_BLOCKLEN])
{
    uint8_t lengths[AES_BLOCKLEN];

    memset(result, 0, AES_BLOCKLEN);
    ghash_update(result, hash_key, (const uint8_t *)aad, aad_length);
    ghash_update(result, hash_key, (const uint8_t *)ciphertext, ciphertext_length);

    store64_be(lengths, (uint64_t)aad_length * 8u);
    store64_be(lengths + 8u, (uint64_t)ciphertext_length * 8u);
    xor_block(result, lengths);
    multiply_gf128(result, hash_key);
    secure_zero(lengths, sizeof(lengths));
}

static void increment_counter(uint8_t counter[AES_BLOCKLEN])
{
    size_t i;

    for (i = AES_BLOCKLEN; i != AES_GCM_NONCE_BYTES;) {
        --i;
        ++counter[i];
        if (counter[i] != 0u) {
            break;
        }
    }
}

static void ctr_crypt  (const struct aes_context *context,
                        const uint8_t initial_counter[AES_BLOCKLEN],
                        const uint8_t *input, size_t input_length,
                        uint8_t *output)
{
    uint8_t counter[AES_BLOCKLEN];
    uint8_t stream[AES_BLOCKLEN];
    size_t offset = 0u;

    memcpy(counter, initial_counter, sizeof(counter));
    while (offset < input_length) {
        size_t block_length = input_length - offset;
        size_t i;

        if (block_length > AES_BLOCKLEN) {
            block_length = AES_BLOCKLEN;
        }
        increment_counter(counter);
        encrypt_block(context, counter, stream);
        for (i = 0u; i < block_length; ++i) {
            output[offset + i] = input[offset + i] ^ stream[i];
        }
        offset += block_length;
    }

    secure_zero(counter, sizeof(counter));
    secure_zero(stream, sizeof(stream));
}

static void gcm_setup  (const uint8_t *key,
                        const uint8_t nonce[AES_GCM_NONCE_BYTES],
                        struct aes_context *context,
                        uint8_t hash_key[AES_BLOCKLEN],
                        uint8_t initial_counter[AES_BLOCKLEN])
{
    uint8_t zero[AES_BLOCKLEN];

    memset(zero, 0, sizeof(zero));
    KeyExpansion(context->RoundKey, key);
    encrypt_block(context, zero, hash_key);
    memcpy(initial_counter, nonce, AES_GCM_NONCE_BYTES);
    memset(initial_counter + AES_GCM_NONCE_BYTES, 0, AES_BLOCKLEN - AES_GCM_NONCE_BYTES);
    initial_counter[AES_BLOCKLEN - 1u] = 1u;
    secure_zero(zero, sizeof(zero));
}

static int tags_differ(const uint8_t *left, const uint8_t *right)
{
    uint8_t difference = 0u;
    size_t i;

    for (i = 0u; i < AES_GCM_TAG_BYTES; ++i) {
        difference |= left[i] ^ right[i];
    }
    return difference != 0u;
}

void AES_GCM_encrypt_software  (const uint8_t *key,
                                const uint8_t nonce[AES_GCM_NONCE_BYTES],
                                const void *aad, size_t aad_length,
                                const void *plaintext, size_t plaintext_length,
                                void *ciphertext,
                                uint8_t tag[AES_GCM_TAG_BYTES])
{
    struct aes_context context;
    uint8_t hash_key[AES_BLOCKLEN];
    uint8_t initial_counter[AES_BLOCKLEN];
    uint8_t tag_mask[AES_BLOCKLEN];

    gcm_setup(key, nonce, &context, hash_key, initial_counter);
    ctr_crypt(&context, initial_counter, (const uint8_t *)plaintext,
              plaintext_length, (uint8_t *)ciphertext);
    ghash(hash_key, aad, aad_length, ciphertext, plaintext_length, tag);
    encrypt_block(&context, initial_counter, tag_mask);
    xor_block(tag, tag_mask);

    secure_zero(&context, sizeof(context));
    secure_zero(hash_key, sizeof(hash_key));
    secure_zero(initial_counter, sizeof(initial_counter));
    secure_zero(tag_mask, sizeof(tag_mask));
}

int AES_GCM_decrypt_software   (const uint8_t *key,
                                const uint8_t nonce[AES_GCM_NONCE_BYTES],
                                const void *aad, size_t aad_length,
                                const void *ciphertext, size_t ciphertext_length,
                                const uint8_t tag[AES_GCM_TAG_BYTES],
                                void *plaintext)
{
    struct aes_context context;
    uint8_t authentication[AES_BLOCKLEN];
    uint8_t hash_key[AES_BLOCKLEN];
    uint8_t initial_counter[AES_BLOCKLEN];
    uint8_t tag_mask[AES_BLOCKLEN];
    int result;

    gcm_setup(key, nonce, &context, hash_key, initial_counter);
    ghash(hash_key, aad, aad_length, ciphertext, ciphertext_length, authentication);
    encrypt_block(&context, initial_counter, tag_mask);
    xor_block(authentication, tag_mask);

    if (tags_differ(tag, authentication)) {
        result = AES_GCM_AUTHENTICATION_ERROR;
    } else {
        ctr_crypt(&context, initial_counter, (const uint8_t *)ciphertext,
                  ciphertext_length, (uint8_t *)plaintext);
        result = AES_GCM_SUCCESS;
    }

    secure_zero(&context, sizeof(context));
    secure_zero(authentication, sizeof(authentication));
    secure_zero(hash_key, sizeof(hash_key));
    secure_zero(initial_counter, sizeof(initial_counter));
    secure_zero(tag_mask, sizeof(tag_mask));
    return result;
}
