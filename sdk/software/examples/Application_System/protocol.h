#ifndef APPLICATION_PROTOCOL_H
#define APPLICATION_PROTOCOL_H

#include <stdint.h>

#include "Kem_param.h"

#define PROTOCOL_FRAME_MAX_PAYLOAD KYBER_PUBLICKEYBYTES

enum protocol_message_type {
    MSG_HELLO = 0x01,
    MSG_SERVER_PK = 0x02,
    MSG_KEM_CIPHERTEXT = 0x03,
    MSG_SERVER_FINISH = 0x04,
    MSG_ECG_DATA = 0x10,
    MSG_ECG_RESULT = 0x11,
    MSG_ERROR = 0x7f
};

struct protocol_frame {
    uint8_t type;
    uint32_t length;
    uint8_t payload[PROTOCOL_FRAME_MAX_PAYLOAD];
};

void protocol_send(uint8_t type, const uint8_t *payload, uint32_t length);
int protocol_receive(struct protocol_frame *frame);

#endif
