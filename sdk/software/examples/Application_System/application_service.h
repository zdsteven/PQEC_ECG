#ifndef APPLICATION_SERVICE_H
#define APPLICATION_SERVICE_H

#include "protocol.h"

void application_service_init(void);
void application_service_handle_frame(const struct protocol_frame *frame);
void application_service_handle_receive_error(int receive_result,
                                              uint32_t session_id);

#endif
