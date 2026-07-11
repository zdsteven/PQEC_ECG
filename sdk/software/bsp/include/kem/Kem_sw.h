#ifndef KEM_SW_H
#define KEM_SW_H
#include "Kem_types.h"

void kem_pack_sk(uint8_t r[KYBER_INDCPA_SECRETKEYBYTES], const polyvec *sk);
void kem_pack_pk(uint8_t r[KYBER_INDCPA_PUBLICKEYBYTES], const polyvec *pk, const uint8_t seed[KYBER_SYMBYTES]);
void kem_unpack_pk(polyvec *pk, uint8_t seed[KYBER_SYMBYTES], const uint8_t packed_pk[KYBER_INDCPA_PUBLICKEYBYTES]);
void kem_unpack_sk(polyvec *sk, const uint8_t packed_sk[KYBER_INDCPA_SECRETKEYBYTES]);
void kem_pack_ciphertext(uint8_t output[KYBER_INDCPA_BYTES], const polyvec *b, const poly *v);
void kem_unpack_ciphertext(polyvec *b, poly *v, const uint8_t input[KYBER_INDCPA_BYTES]);
void kem_compress_polyvec_component(uint8_t *output, const poly *value);
void kem_compress_poly(uint8_t output[KYBER_POLYCOMPRESSEDBYTES], const poly *value);
void kem_poly_frommsg(poly *value, const uint8_t message[KYBER_INDCPA_MSGBYTES]);
void kem_poly_tomsg(uint8_t message[KYBER_INDCPA_MSGBYTES], const poly *value);
void kem_poly_add_modq(poly *result, const poly *left, const poly *right);
void kem_poly_add3_modq(poly *result, const poly *first, const poly *second, const poly *third);
int kem_verify(const uint8_t *left, const uint8_t *right, uint32_t length);
void kem_cmov  (uint8_t *result, const uint8_t *source, uint32_t length, uint8_t condition);

#endif
