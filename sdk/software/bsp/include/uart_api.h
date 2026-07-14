#ifndef UART_API_H
#define UART_API_H

#include "common_func.h"

#define UART_RECEIVE_CONFREG_BIT  (1U << 5)

void uart_receive_init(void);
void uart_receive_disable(void);
void uart_receive_irq_handler(void);
unsigned int uart_receive_available(void);
int uart_receive_read(void);
unsigned char uart_receive_read_blocking(void);
unsigned int uart_receive_overflow_count(void);
void uart_send_byte(unsigned char data);
void uart_send(const void *data, unsigned int length);

#endif
