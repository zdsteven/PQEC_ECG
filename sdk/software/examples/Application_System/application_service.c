#include "application_service.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "Kem_api.h"
#include "aes.h"
#include "dvi.h"
#include "ecg.h"
#include "led.h"
#include "random_api.h"
#include "seg7.h"

#define MAX_CLIENT_SESSIONS 8U
#define HELLO_PAYLOAD_BYTES 2U
#define ECG_PLAINTEXT_BYTES 198U
#define ECG_PADDED_BYTES    AES_DATA_BYTES
#define ECG_REQUEST_BYTES   (4U + ECG_PADDED_BYTES + AES_GCM_TAG_BYTES)
#define ECG_RESULT_PLAINTEXT_BYTES 10U
#define ECG_RESULT_BYTES    (ECG_RESULT_PLAINTEXT_BYTES + AES_GCM_TAG_BYTES)

enum session_state {
    SESSION_FREE = 0,
    SESSION_WAIT_KEM_CIPHERTEXT = 1,
    SESSION_ESTABLISHED = 2
};

enum error_code {
    ERROR_BAD_FRAME = 1,
    ERROR_BAD_LENGTH = 2,
    ERROR_UNEXPECTED_MESSAGE = 3,
    ERROR_BAD_SEQUENCE = 4,
    ERROR_HARDWARE = 5,
    ERROR_AUTHENTICATION = 6,
    ERROR_NO_SESSION = 7,
    ERROR_SERVER_BUSY = 8
};

struct session_keys {
    uint8_t client_to_server_aes[AES_KEYLEN];
    uint8_t client_to_server_nonce[8];
    uint8_t server_to_client_aes[AES_KEYLEN];
    uint8_t server_to_client_nonce[8];
};

struct client_session {
    uint32_t session_id;
    uint32_t expected_ecg_sequence;
    enum session_state state;
    struct session_keys keys;
};

static uint8_t server_public_key[KYBER_PUBLICKEYBYTES] __attribute__((aligned(64)));
static uint8_t server_secret_key[KYBER_SECRETKEYBYTES] __attribute__((aligned(64)));
static uint8_t keypair_coins[2U * KYBER_SYMBYTES] __attribute__((aligned(64)));
static uint8_t kem_ciphertext[KYBER_CIPHERTEXTBYTES] __attribute__((aligned(64)));
static uint8_t shared_secret[KYBER_SSBYTES] __attribute__((aligned(64)));
static uint32_t aes_ecg_buffer[AES_GCM_INPUT_WORDS] __attribute__((aligned(64)));
static struct client_session sessions[MAX_CLIENT_SESSIONS];
static int server_ready;

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

static struct client_session *find_session(uint32_t session_id)
{
    uint32_t i;

    if (session_id == 0U) {
        return NULL;
    }
    for (i = 0U; i < MAX_CLIENT_SESSIONS; ++i) {
        if (sessions[i].state != SESSION_FREE &&
            sessions[i].session_id == session_id) {
            return &sessions[i];
        }
    }
    return NULL;
}

static uint32_t create_session_id(void)
{
    uint32_t session_id;
    uint32_t attempt;

    for (attempt = 0U; attempt < 32U; ++attempt) {
        if (random_bytes((uint8_t *)&session_id, sizeof(session_id)) != 0) {
            return 0U;
        }
        if (session_id != 0U && find_session(session_id) == NULL) {
            return session_id;
        }
    }
    return 0U;
}

static struct client_session *allocate_session(void)
{
    struct client_session *session;
    uint32_t session_id;
    uint32_t i;

    for (i = 0U; i < MAX_CLIENT_SESSIONS; ++i) {
        if (sessions[i].state == SESSION_FREE) {
            session_id = create_session_id();
            if (session_id == 0U) {
                return NULL;
            }
            session = &sessions[i];
            secure_zero(session, sizeof(*session));
            session->session_id = session_id;
            session->state = SESSION_WAIT_KEM_CIPHERTEXT;
            return session;
        }
    }
    return NULL;
}

static void release_session(struct client_session *session)
{
    if (session != NULL) {
        secure_zero(session, sizeof(*session));
    }
}

static void send_error(uint32_t session_id, enum error_code code,
                       const struct client_session *session)
{
    uint8_t payload[6];

    payload[0] = (uint8_t)code;
    payload[1] = (uint8_t)(session != NULL ? session->state : SESSION_FREE);
    store32_le(payload + 2, session != NULL ? session->expected_ecg_sequence : 0U);
    protocol_send(MSG_ERROR, session_id, payload, sizeof(payload));
}

static void derive_session_keys(struct client_session *session)
{
    uint8_t material[PQEC_SESSION_KEY_MATERIAL_BYTES] __attribute__((aligned(64)));
    const uint8_t *cursor = material;

    /* Keep the original SHAKE256("PQEC-ECG" || K) derivation unchanged. */
    pqec_session_kdf(material, shared_secret);
    memcpy(session->keys.client_to_server_aes, cursor, AES_KEYLEN);
    cursor += AES_KEYLEN;
    memcpy(session->keys.client_to_server_nonce, cursor, 8U);
    cursor += 8U;
    memcpy(session->keys.server_to_client_aes, cursor, AES_KEYLEN);
    cursor += AES_KEYLEN;
    memcpy(session->keys.server_to_client_nonce, cursor, 8U);
    secure_zero(material, sizeof(material));
}

static void build_gcm_nonce(uint8_t nonce[AES_GCM_NONCE_BYTES], const uint8_t base_nonce[8], uint32_t sequence)
{
    memcpy(nonce, base_nonce, 8U);
    nonce[8] = (uint8_t)(sequence >> 24);
    nonce[9] = (uint8_t)(sequence >> 16);
    nonce[10] = (uint8_t)(sequence >> 8);
    nonce[11] = (uint8_t)sequence;
}

static void handle_hello(const struct protocol_frame *frame)
{
    struct client_session *session;

    if (frame->session_id != 0U) {
        send_error(frame->session_id, ERROR_UNEXPECTED_MESSAGE, NULL);
        return;
    }
    if (frame->length != HELLO_PAYLOAD_BYTES ||
        frame->payload[0] != KYBER_K ||
        frame->payload[1] != AES_KEYLEN) {
        send_error(0U, ERROR_BAD_LENGTH, NULL);
        return;
    }
    if (!server_ready) {
        send_error(0U, ERROR_HARDWARE, NULL);
        return;
    }

    session = allocate_session();
    if (session == NULL) {
        send_error(0U, ERROR_SERVER_BUSY, NULL);
        return;
    }

    protocol_send(MSG_SERVER_PK, session->session_id, server_public_key, sizeof(server_public_key));
}

static void handle_kem_ciphertext(struct client_session *session, const struct protocol_frame *frame)
{
    if (session->state != SESSION_WAIT_KEM_CIPHERTEXT) {
        send_error(session->session_id, ERROR_UNEXPECTED_MESSAGE, session);
        return;
    }
    if (frame->length != KYBER_CIPHERTEXTBYTES) {
        send_error(session->session_id, ERROR_BAD_LENGTH, session);
        return;
    }

    memcpy(kem_ciphertext, frame->payload, sizeof(kem_ciphertext));
    if (crypto_kem_dec(shared_secret, kem_ciphertext, server_secret_key) != 0) {
        send_error(session->session_id, ERROR_HARDWARE, session);
        release_session(session);
        return;
    }

    derive_session_keys(session);
    secure_zero(shared_secret, sizeof(shared_secret));
    secure_zero(kem_ciphertext, sizeof(kem_ciphertext));
    session->expected_ecg_sequence = 1U;
    session->state = SESSION_ESTABLISHED;
    protocol_send(MSG_SERVER_FINISH, session->session_id, NULL, 0U);
}

static int decrypt_ecg(struct client_session *session, const uint8_t *ciphertext_and_tag, uint32_t sequence)
{
    uint8_t nonce[AES_GCM_NONCE_BYTES];

    memcpy(aes_ecg_buffer, ciphertext_and_tag, ECG_PADDED_BYTES + AES_GCM_TAG_BYTES);
    build_gcm_nonce(nonce, session->keys.client_to_server_nonce, sequence);
    AES_init_hardware(session->keys.client_to_server_aes);
    AES_set_nonce_hardware(nonce);
    return AES_GCM_decrypt_to_peripheral_hardware(aes_ecg_buffer, ECG_DATA_BASE_ADDR, ECG_PADDED_BYTES);
}

static void handle_ecg_data(struct client_session *session, const struct protocol_frame *frame)
{
    uint8_t result[ECG_RESULT_PLAINTEXT_BYTES];
    uint8_t encrypted_result[ECG_RESULT_BYTES];
    uint8_t nonce[AES_GCM_NONCE_BYTES];
    uint8_t scores[5];
    uint32_t sequence;
    int decrypt_result;

    if (session->state != SESSION_ESTABLISHED) {
        send_error(session->session_id, ERROR_UNEXPECTED_MESSAGE, session);
        return;
    }
    if (frame->length != ECG_REQUEST_BYTES) {
        send_error(session->session_id, ERROR_BAD_LENGTH, session);
        return;
    }

    sequence = load32_le(frame->payload);
    if (sequence != session->expected_ecg_sequence) {
        send_error(session->session_id, ERROR_BAD_SEQUENCE, session);
        return;
    }

    decrypt_result = decrypt_ecg(session, frame->payload + 4U, sequence);
    if (decrypt_result == AES_GCM_AUTHENTICATION_ERROR) {
        send_error(session->session_id, ERROR_AUTHENTICATION, session);
        return;
    }
    if (decrypt_result != AES_GCM_SUCCESS) {
        send_error(session->session_id, ERROR_HARDWARE, session);
        release_session(session);
        return;
    }

    ecg_start();
    store32_le(result, sequence);
    result[4] = ecg_read_result(scores);
    if (result[4] < 5U) {
        setLedPin(1U << result[4]);
        setSegNum(0U, 0U, 1U, result[4]);
        if (result[4] == 0U) {
            DVI_Draw_Rect(0U, 0U, 0U, 0U);
        } else {
            DVI_Draw_Rect(400U, 0U, 400U, 600U);
        }
    } else {
        setLedPin(0U);
        setSegNum(0U, 0U, 0U, 0U);
        DVI_Draw_Rect(0U, 0U, 0U, 0U);
    }
    memcpy(result + 5U, scores, sizeof(scores));

    build_gcm_nonce(nonce, session->keys.server_to_client_nonce, sequence);
    AES_GCM_encrypt_software(session->keys.server_to_client_aes,
                            nonce, NULL, 0U,
                            result, sizeof(result),
                            encrypted_result,
                            encrypted_result + sizeof(result));
    protocol_send(MSG_ECG_RESULT, session->session_id, encrypted_result, sizeof(encrypted_result));

    secure_zero(aes_ecg_buffer, sizeof(aes_ecg_buffer));
    secure_zero(scores, sizeof(scores));
    secure_zero(result, sizeof(result));
    secure_zero(encrypted_result, sizeof(encrypted_result));

    ++session->expected_ecg_sequence;
    if (session->expected_ecg_sequence == 0U) {
        release_session(session);
    }
}

static void handle_close_session(struct client_session *session, const struct protocol_frame *frame)
{
    uint32_t session_id = frame->session_id;

    if (frame->length != 0U) {
        send_error(session_id, ERROR_BAD_LENGTH, session);
        return;
    }
    protocol_send(MSG_CLOSE_ACK, session_id, NULL, 0U);
    release_session(session);
}

void application_service_init(void)
{
    uint32_t i;

    crypto_kem_init();
    setLedPin(0U);
    setSegNum(0U, 0U, 0U, 0U);
    DVI_Draw_Rect(0U, 0U, 0U, 0U);
    for (i = 0U; i < MAX_CLIENT_SESSIONS; ++i) {
        release_session(&sessions[i]);
    }

    server_ready = 0;
    if (random_bytes(keypair_coins, sizeof(keypair_coins)) == 0 &&
        crypto_kem_keypair_derand(server_public_key, server_secret_key, keypair_coins) == 0) 
    {
        server_ready = 1;
    }
    secure_zero(keypair_coins, sizeof(keypair_coins));
}

void application_service_handle_frame(const struct protocol_frame *frame)
{
    struct client_session *session;

    if (frame->type == MSG_HELLO) {
        handle_hello(frame);
        return;
    }

    session = find_session(frame->session_id);
    if (session == NULL) {
        send_error(frame->session_id, ERROR_NO_SESSION, NULL);
        return;
    }

    switch (frame->type) {
    case MSG_KEM_CIPHERTEXT:
        handle_kem_ciphertext(session, frame);
        break;
    case MSG_ECG_DATA:
        handle_ecg_data(session, frame);
        break;
    case MSG_CLOSE_SESSION:
        handle_close_session(session, frame);
        break;
    default:
        send_error(frame->session_id, ERROR_UNEXPECTED_MESSAGE, session);
        break;
    }
}

void application_service_handle_receive_error(int receive_result, uint32_t session_id)
{
    struct client_session *session = find_session(session_id);
    send_error(session_id, receive_result == -2 ? ERROR_BAD_LENGTH : ERROR_BAD_FRAME, session);
}
