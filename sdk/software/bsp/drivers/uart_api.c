#include "uart_api.h"

#define UART_RBR_OFFSET          0U
#define UART_IER_OFFSET          1U
#define UART_FCR_OFFSET          2U
#define UART_LSR_OFFSET          5U
#define UART_IER_RX_AVAILABLE    0x01U
#define UART_FCR_RX_TX_RESET     0x07U
#define UART_LSR_DATA_READY      0x01U
#define UART_LSR_TX_EMPTY        0x20U

#define CONFREG_INT_ENABLE_ADDR  0xbf20f000U

#define RX_BUFFER_SIZE           64U
#define RX_BUFFER_MASK           (RX_BUFFER_SIZE - 1U)

extern unsigned long UART_BASE;

static volatile unsigned char rx_buffer[RX_BUFFER_SIZE];
static volatile unsigned int rx_head;
static volatile unsigned int rx_tail;
static volatile unsigned int rx_overflows;

static volatile unsigned char *uart_reg(unsigned int offset)
{
    return (volatile unsigned char *)(UART_BASE + offset);
}

void uart_receive_init(void)
{
    unsigned int int_enable;

    *uart_reg(UART_IER_OFFSET) = 0U;
    *uart_reg(UART_FCR_OFFSET) = UART_FCR_RX_TX_RESET;
    while ((*uart_reg(UART_LSR_OFFSET) & UART_LSR_DATA_READY) != 0U) {
        (void)*uart_reg(UART_RBR_OFFSET);
    }

    rx_head = 0U;
    rx_tail = 0U;
    rx_overflows = 0U;

    int_enable = RegRead(CONFREG_INT_ENABLE_ADDR);
    RegWrite(CONFREG_INT_ENABLE_ADDR, int_enable | UART_RECEIVE_CONFREG_BIT);

    /* Enable only the RX-data-available/timeout interrupt. */
    *uart_reg(UART_IER_OFFSET) = UART_IER_RX_AVAILABLE;
}

void uart_receive_disable(void)
{
    unsigned int int_enable;

    *uart_reg(UART_IER_OFFSET) = 0U;
    int_enable = RegRead(CONFREG_INT_ENABLE_ADDR);
    RegWrite(CONFREG_INT_ENABLE_ADDR, int_enable & ~UART_RECEIVE_CONFREG_BIT);
}

void uart_receive_irq_handler(void)
{
    while ((*uart_reg(UART_LSR_OFFSET) & UART_LSR_DATA_READY) != 0U) {
        unsigned char data = *uart_reg(UART_RBR_OFFSET);
        unsigned int next_head = (rx_head + 1U) & RX_BUFFER_MASK;

        if (next_head == rx_tail) {
            ++rx_overflows;
        } else {
            rx_buffer[rx_head] = data;
            rx_head = next_head;
        }
    }
}

unsigned int uart_receive_available(void)
{
    return (rx_head - rx_tail) & RX_BUFFER_MASK;
}

int uart_receive_read(void)
{
    unsigned char data;

    if (rx_head == rx_tail) {
        return -1;
    }

    data = rx_buffer[rx_tail];
    rx_tail = (rx_tail + 1U) & RX_BUFFER_MASK;
    return (int)data;
}

unsigned char uart_receive_read_blocking(void)
{
    int data;

    do {
        data = uart_receive_read();
    } while (data < 0);

    return (unsigned char)data;
}

unsigned int uart_receive_overflow_count(void)
{
    return rx_overflows;
}

void uart_send_byte(unsigned char data)
{
    while ((*uart_reg(UART_LSR_OFFSET) & UART_LSR_TX_EMPTY) == 0U) {
    }
    *uart_reg(UART_RBR_OFFSET) = data;
}

void uart_send(const void *data, unsigned int length)
{
    const unsigned char *bytes = (const unsigned char *)data;
    unsigned int i;

    for (i = 0U; i < length; ++i) {
        uart_send_byte(bytes[i]);
    }
}
