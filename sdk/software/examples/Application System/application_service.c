#include "application_service.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "Kem_api.h"
#include "aes.h"
#include "ecg.h"
#include "random_api.h"

#define HELLO_PAYLOAD_BYTES 2U
#define ECG_PLAINTEXT_BYTES 198U
#define ECG_REQUEST_BYTES   (4U + ECG_PLAINTEXT_BYTES)
#define ECG_RESULT_BYTES    10U

enum server_state {
    STATE_WAIT_HELLO = 0,
    STATE_WAIT_KEM_CIPHERTEXT = 1,
    STATE_ESTABLISHED = 2
};

enum error_code {
    ERROR_BAD_FRAME = 1,
    ERROR_BAD_LENGTH = 2,
    ERROR_UNEXPECTED_MESSAGE = 3,
    ERROR_BAD_SEQUENCE = 4,
    ERROR_HARDWARE = 5
};

struct session_keys {
    uint8_t client_to_server_aes[AES_KEYLEN];
    uint8_t client_to_server_nonce[8];
    uint8_t server_to_client_aes[AES_KEYLEN];
    uint8_t server_to_client_nonce[8];
};

static uint8_t public_key[KYBER_PUBLICKEYBYTES] __attribute__((aligned(64)));
static uint8_t secret_key[KYBER_SECRETKEYBYTES] __attribute__((aligned(64)));
static uint8_t kem_ciphertext[KYBER_CIPHERTEXTBYTES] __attribute__((aligned(64)));
static uint8_t shared_secret[KYBER_SSBYTES] __attribute__((aligned(64)));
static uint8_t keypair_coins[2U * KYBER_SYMBYTES] __attribute__((aligned(64)));
static uint32_t aes_ecg_buffer[AES_DATA_WORDS] __attribute__((aligned(64)));
static struct session_keys session_keys;
static enum server_state current_state;
static uint32_t expected_ecg_sequence;

static void store32_le(uint8_t output[4], uint32_t value)
{
    output[0] = (uint8_t)value;
    output[1] = (uint8_t)(value >> 8);
    output[2] = (uint8_t)(value >> 16);
    output[3] = (uint8_t)(value >> 24);
}

static uint32_t load32_le(const uint8_t input[4])
{
    return (uint32_t)input[0]
        | ((uint32_t)input[1] << 8)
        | ((uint32_t)input[2] << 16)
        | ((uint32_t)input[3] << 24);
}

static void secure_zero(void *data, size_t length)
{
    volatile uint8_t *bytes = (volatile uint8_t *)data;

    while (length-- != 0U) {
        *bytes++ = 0U;
    }
}

static void send_error(enum error_code code)
{
    uint8_t payload[6];

    payload[0] = (uint8_t)code;
    payload[1] = (uint8_t)current_state;
    store32_le(payload + 2, expected_ecg_sequence);
    protocol_send(MSG_ERROR, payload, sizeof(payload));
}

static void reset_session(void)
{
    secure_zero(secret_key, sizeof(secret_key));
    secure_zero(shared_secret, sizeof(shared_secret));
    secure_zero(keypair_coins, sizeof(keypair_coins));
    secure_zero(&session_keys, sizeof(session_keys));
    secure_zero(aes_ecg_buffer, sizeof(aes_ecg_buffer));
    expected_ecg_sequence = 0U;
    current_state = STATE_WAIT_HELLO;
}

static void derive_session_keys(void)
{
    uint8_t material[PQEC_SESSION_KEY_MATERIAL_BYTES] __attribute__((aligned(64)));
    const uint8_t *cursor = material;

    pqec_session_kdf(material, shared_secret);
    memcpy(session_keys.client_to_server_aes, cursor, AES_KEYLEN);
    cursor += AES_KEYLEN;
    memcpy(session_keys.client_to_server_nonce, cursor, 8U);
    cursor += 8U;
    memcpy(session_keys.server_to_client_aes, cursor, AES_KEYLEN);
    cursor += AES_KEYLEN;
    memcpy(session_keys.server_to_client_nonce, cursor, 8U);
    secure_zero(material, sizeof(material));
}

static void handle_hello(const struct protocol_frame *frame)
{
    if (frame->length != HELLO_PAYLOAD_BYTES ||
        frame->payload[0] != KYBER_K ||
        frame->payload[1] != AES_KEYLEN) {
        send_error(ERROR_BAD_LENGTH);
        return;
    }

    reset_session();
    if (random_bytes(keypair_coins, sizeof(keypair_coins)) != 0 ||
        crypto_kem_keypair_derand(public_key, secret_key, keypair_coins) != 0) {
        send_error(ERROR_HARDWARE);
        reset_session();
        return;
    }

    protocol_send(MSG_SERVER_PK, public_key, sizeof(public_key));
    current_state = STATE_WAIT_KEM_CIPHERTEXT;
}

static void handle_kem_ciphertext(const struct protocol_frame *frame)
{
    if (frame->type != MSG_KEM_CIPHERTEXT) {
        send_error(ERROR_UNEXPECTED_MESSAGE);
        return;
    }
    if (frame->length != KYBER_CIPHERTEXTBYTES) {
        send_error(ERROR_BAD_LENGTH);
        return;
    }

    memcpy(kem_ciphertext, frame->payload, sizeof(kem_ciphertext));
    if (crypto_kem_dec(shared_secret, kem_ciphertext, secret_key) != 0) {
        send_error(ERROR_HARDWARE);
        reset_session();
        return;
    }

    derive_session_keys();
    AES_init_hardware(session_keys.client_to_server_aes);
    protocol_send(MSG_SERVER_FINISH, 0, 0U);

    secure_zero(secret_key, sizeof(secret_key));
    secure_zero(shared_secret, sizeof(shared_secret));
    secure_zero(keypair_coins, sizeof(keypair_coins));
    expected_ecg_sequence = 1U;
    current_state = STATE_ESTABLISHED;
}

static int decrypt_ecg(const uint8_t *ciphertext, uint32_t sequence)
{
    uint32_t nonce_words[2];
    int result;

    memcpy(aes_ecg_buffer, ciphertext, ECG_PLAINTEXT_BYTES);
    memset((uint8_t *)aes_ecg_buffer + ECG_PLAINTEXT_BYTES, 0, AES_DATA_BYTES - ECG_PLAINTEXT_BYTES);
    memcpy(nonce_words, session_keys.client_to_server_nonce, sizeof(nonce_words));

    AES_set_nonce_hardware(nonce_words, sequence);
    result = AES_CTR_hardware(aes_ecg_buffer);
    if (result == 0) {
        result = AES_read_result_hardware(aes_ecg_buffer);
    }
    return result;
}

static void handle_ecg_data(const struct protocol_frame *frame)
{
    uint8_t result[ECG_RESULT_BYTES];
    uint8_t scores[5];
    uint32_t sequence;

    if (frame->type != MSG_ECG_DATA) {
        send_error(ERROR_UNEXPECTED_MESSAGE);
        return;
    }
    if (frame->length != ECG_REQUEST_BYTES) {
        send_error(ERROR_BAD_LENGTH);
        return;
    }

    sequence = load32_le(frame->payload);
    if (sequence != expected_ecg_sequence) {
        send_error(ERROR_BAD_SEQUENCE);
        return;
    }
    if (decrypt_ecg(frame->payload + 4U, sequence) != 0) {
        send_error(ERROR_HARDWARE);
        reset_session();
        return;
    }

    ecg_load((U8 *)aes_ecg_buffer);
    ecg_start();
    store32_le(result, sequence);
    result[4] = ecg_read_result(scores);
    memcpy(result + 5U, scores, sizeof(scores));
    secure_zero(aes_ecg_buffer, sizeof(aes_ecg_buffer));
    secure_zero(scores, sizeof(scores));

    AES_CTR_software_message(session_keys.server_to_client_aes,
                            session_keys.server_to_client_nonce,
                            sequence, result, sizeof(result));
    protocol_send(MSG_ECG_RESULT, result, sizeof(result));
    secure_zero(result, sizeof(result));

    ++expected_ecg_sequence;
    if (expected_ecg_sequence == 0U) {
        reset_session();
    }
}

void application_service_init(void)
{
    crypto_kem_init();
    reset_session();
}

void application_service_handle_frame(const struct protocol_frame *frame)
{
    if (frame->type == MSG_HELLO) {
        handle_hello(frame);
        return;
    }

    switch (current_state) {
    case STATE_WAIT_KEM_CIPHERTEXT:
        handle_kem_ciphertext(frame);
        break;
    case STATE_ESTABLISHED:
        handle_ecg_data(frame);
        break;
    case STATE_WAIT_HELLO:
    default:
        send_error(ERROR_UNEXPECTED_MESSAGE);
        break;
    }
}

void application_service_handle_receive_error(int receive_result)
{
    send_error((receive_result == -2) ? ERROR_BAD_LENGTH : ERROR_BAD_FRAME);
}
