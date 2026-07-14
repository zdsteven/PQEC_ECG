#include "application_service.h"
#include "common_func.h"
#include "protocol.h"
#include "uart_api.h"

unsigned long UART_BASE = 0xbf000000;

int main(void)
{
    static struct protocol_frame frame;
    int result;

    uart_receive_init();
    application_service_init();

    while (1) {
        result = protocol_receive(&frame);
        if (result == 0) {
            application_service_handle_frame(&frame);
        } else {
            application_service_handle_receive_error(result);
        }
    }

    return 0;
}

void HWI0_IntrHandler(void)
{
    if ((RegRead(0xbf20f014U) & UART_RECEIVE_CONFREG_BIT) != 0U) {
        uart_receive_irq_handler();
    }
}
