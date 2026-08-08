#include "protocol.h"

#include <stddef.h>
#include <string.h>

#include "uart_api.h"

static const uint8_t frame_magic[4] = {0xa5U, 0x5aU, 0xc3U, 0x3cU};

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

static uint32_t crc32_update(uint32_t crc, const uint8_t *data, size_t length)
{
    size_t i;

    while (length-- != 0U) {
        crc ^= *data++;
        for (i = 0U; i < 8U; ++i) {
            crc = (crc >> 1) ^ (0xedb88320U & (0U - (crc & 1U)));
        }
    }
    return crc;
}

void protocol_send(uint8_t type, uint32_t session_id,
                   const uint8_t *payload, uint32_t length)
{
    uint8_t header[13];
    uint8_t crc_bytes[4];
    uint32_t crc;

    memcpy(header, frame_magic, sizeof(frame_magic));
    header[4] = type;
    store32_le(header + 5, session_id);
    store32_le(header + 9, length);

    crc = crc32_update(0xffffffffU, header + 4, 9U);
    crc = crc32_update(crc, payload, length) ^ 0xffffffffU;
    store32_le(crc_bytes, crc);

    uart_send(header, sizeof(header));
    if (length != 0U) {
        uart_send(payload, length);
    }
    uart_send(crc_bytes, sizeof(crc_bytes));
}

int protocol_receive(struct protocol_frame *frame)
{
    uint8_t header[9];
    uint8_t crc_bytes[4];
    uint32_t crc;
    uint32_t i;
    unsigned int magic_index = 0U;

    while (magic_index < sizeof(frame_magic)) {
        uint8_t data = uart_receive_read_blocking();

        if (data == frame_magic[magic_index]) {
            ++magic_index;
        } else {
            magic_index = (data == frame_magic[0]) ? 1U : 0U;
        }
    }

    for (i = 0U; i < sizeof(header); ++i) {
        header[i] = uart_receive_read_blocking();
    }

    frame->type = header[0];
    frame->session_id = load32_le(header + 1);
    frame->length = load32_le(header + 5);
    if (frame->length > PROTOCOL_FRAME_MAX_PAYLOAD) {
        return -2;
    }

    for (i = 0U; i < frame->length; ++i) {
        frame->payload[i] = uart_receive_read_blocking();
    }
    for (i = 0U; i < sizeof(crc_bytes); ++i) {
        crc_bytes[i] = uart_receive_read_blocking();
    }

    crc = crc32_update(0xffffffffU, header, sizeof(header));
    crc = crc32_update(crc, frame->payload, frame->length) ^ 0xffffffffU;
    return (crc == load32_le(crc_bytes)) ? 0 : -1;
}
