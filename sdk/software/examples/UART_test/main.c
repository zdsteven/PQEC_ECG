#include <stdio.h>

#include "common_func.h"
#include "uart_api.h"

unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

void HWI0_IntrHandler(void)
{
    unsigned int int_state = RegRead(0xbf20f014U);

    if ((int_state & UART_RECEIVE_CONFREG_BIT) != 0U) {
        uart_receive_irq_handler();
    }
}

int main(void)
{
    uart_receive_init();
    printf("UART RX interrupt test ready.\n");
    printf("Send characters from the serial terminal.\n");

    while (1) {
        unsigned char data = uart_receive_read_blocking();

        if (data >= 32U && data <= 126U) {
            printf("RX: '%c' (0x%02x)\n", data, (unsigned int)data);
        } else {
            printf("RX: 0x%02x\n", (unsigned int)data);
        }
    }

    return 0;
}
