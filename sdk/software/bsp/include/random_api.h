#ifndef RANDOM_API_H
#define RANDOM_API_H

#include <stddef.h>
#include <stdint.h>

int application_trng_read(uint8_t *output, size_t length);
int random_bytes(uint8_t *output, size_t length);

#endif
