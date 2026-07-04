#include "Kem_api.h"


#include <string.h>

#include "dma.h"

static void flush_cache_lines(const void *buffer, uint32_t byte_length)
{
    uintptr_t address;
    uintptr_t first;
    uintptr_t last;
    uintptr_t line_bytes = (uintptr_t)1u << cache_offset_width;

    first = (uintptr_t)buffer & ~(line_bytes - 1u);
    last = ((uintptr_t)buffer + byte_length + line_bytes - 1u) & ~(line_bytes - 1u);
    for (address = first; address < last; address += line_bytes) {
        flush_dcache_line((unsigned long)address);
    }
}

static inline void ntt_start(void)
{
    RegWrite(KYBER_CTRL_ADDR, 5u);
}

static inline void intt_start(void)
{
    RegWrite(KYBER_CTRL_ADDR, 1u);
}

static inline void basemul_start(uint32_t highaddr)
{
    RegWrite(KYBER_CTRL_ADDR, (1u << 7) | (highaddr << 10));
}

static inline void polyvec_fadd_from_sample(uint32_t hignaddr)
{
    RegWrite(KYBER_CTRL_ADDR, (1u << 8) | (hignaddr << 10));
}

static inline void polyvec_fadd_from_ntt_intt(uint32_t hignaddr, uint32_t is_sub)
{
    RegWrite(KYBER_CTRL_ADDR, (1u << 9) | (hignaddr << 10) | (is_sub << 15));
}

static inline void hash_reset(void)
{
    RegWrite(KYBER_CTRL_ADDR, 8u);
}

static inline void hash_iterate(uint32_t mode)
{
    RegWrite(KYBER_CTRL_ADDR, 16u | (mode << 5));
}

static inline void cbd_prepare(const uint8_t seed[KYBER_SYMBYTES], uint32_t nonce)
{
    while (KYBER_HASH_IS_BUZY);
    hash_reset();
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)seed, KYBER_HASH_DATA_BASE_ADDR, KYBER_SYMBYTES, 0);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 8u * 4u, (uint32_t)nonce | 0x00001f00u);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 33u * 4u, 0x80000000u);
}

static inline void rej_prepare(const uint8_t seed[KYBER_SYMBYTES], uint32_t row, uint32_t column)
{
    while (KYBER_HASH_IS_BUZY);
    hash_reset();
    DMA_Transfer_Blocking((uint32_t)(uintptr_t)seed, KYBER_HASH_DATA_BASE_ADDR, KYBER_SYMBYTES, 0);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 8u * 4u, (uint32_t)(column | (row << 8)) | 0x001f0000u);
    RegWrite(KYBER_HASH_DATA_BASE_ADDR + 41u * 4u, 0x80000000u);
}



/*************************************************
* Name:        crypto_kem_keypair_derand
*
* Description: init crypto kem
*              must run the function before firsr time use kem
*              once is enough after system start up
*
**************************************************/
void crypto_kem_init()
{
    RegWrite(KYBER_CTRL_ADDR, (1u << 12) | (KYBER_POLYVEC_RESET_NUM << 13));
    while (KYBER_POLYVEC_RESET_IS_BUZY);
}

/*************************************************
* Name:        crypto_kem_keypair_derand
*
* Description: Generates public and private key
*              for CCA-secure Kyber key encapsulation mechanism
*
* Arguments:   - uint8_t *pk: pointer to output public key
*                (an already allocated array of KYBER_PUBLICKEYBYTES bytes)
*              - uint8_t *sk: pointer to output private key
*                (an already allocated array of KYBER_SECRETKEYBYTES bytes)
*              - uint8_t *coins: pointer to input randomness
*                (an already allocated array filled with 2*KYBER_SYMBYTES random bytes)
**
* Returns 0 (success)
**************************************************/
int crypto_kem_keypair_derand(uint8_t *pk, uint8_t *sk, const uint8_t *coins)
{
    unsigned int i;
    uint8_t buf[2*KYBER_SYMBYTES] __attribute__((aligned(4)));
    const uint8_t *publicseed = buf;
    const uint8_t *noiseseed = buf+KYBER_SYMBYTES;
    polyvec pkpv, skpv;

    memcpy(buf, coins, KYBER_SYMBYTES);
    buf[KYBER_SYMBYTES] = KYBER_K;
    flush_cache_lines(buf, 64u);
    hash_g_33(buf, buf);
    
    //As + e
    for (i=0;i<KYBER_K;i++) {
        //prepare e
        cbd_prepare(noiseseed, i + KYBER_K);
        //sample e
        hash_iterate(HASH_MODE_PRF1);
        //prepare s
        cbd_prepare(noiseseed, i);
        //e -> ntt
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_NTT_INTT_BASE_ADDR, KYBER_POLY_BYTES_HW);
        //sample s
        hash_iterate(HASH_MODE_PRF1);
        //ntt e
        while (DMA_Is_Busy());
        ntt_start();
        //prepare a0
        rej_prepare(publicseed, 0, i);
        //s -> ntt
        while (KYBER_NTT_INTT_IS_BUZY);
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_NTT_INTT_BASE_ADDR, KYBER_POLY_BYTES_HW);
        //sample a0
        hash_iterate(HASH_MODE_REJECTION);
        //polyvec_fadd e
        polyvec_fadd_from_ntt_intt(i, 0);
        while (KYBER_POLYVEC_IS_BUZY);
        //ntt s
        ntt_start();
        //prepare a1
        rej_prepare(publicseed, 1, i);
        //a0 -> basemul
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_BASEMUL_BASE_ADDR, KYBER_POLY_BYTES_HW);
        //sample a1
        hash_iterate(HASH_MODE_REJECTION);
        //s readback
        flush_cache_lines(skpv.vec[i].coeffs, KYBER_POLY_BYTES_HW);
        while (DMA_Is_Busy());
        DMA_Transfer_Blocking(
            KYBER_NTT_INTT_BASE_ADDR, 
            (uint32_t)(uintptr_t)skpv.vec[i].coeffs, 
            KYBER_POLY_BYTES_HW, 0);
        //basemul a0*s
        basemul_start(0);
        #if KYBER_K != 2
        //prepare a2
        rej_prepare(publicseed, 2, i);
        #else
        while (KYBER_HASH_IS_BUZY);
        #endif
        //a1 -> basemul
        while (KYBER_POLYVEC_IS_BUZY);
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_BASEMUL_BASE_ADDR, KYBER_POLY_BYTES_HW);
        #if KYBER_K != 2
        //sample a2
        hash_iterate(HASH_MODE_REJECTION);
        #endif
        //basemul a1*s
        while (DMA_Is_Busy());
        basemul_start(1);

        #if KYBER_K != 2
        //prepare a3
        #if KYBER_K != 3
        rej_prepare(publicseed, 3, i);
        #else
        while (KYBER_HASH_IS_BUZY);
        #endif
        //a2 -> basemul
        while (KYBER_POLYVEC_IS_BUZY);
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_BASEMUL_BASE_ADDR, KYBER_POLY_BYTES_HW);
        #if KYBER_K != 3
        //sample a3
        hash_iterate(HASH_MODE_REJECTION);
        #endif
        while (DMA_Is_Busy());
        basemul_start(2);

        #if KYBER_K != 3
        //a3 -> basemul
        while (KYBER_HASH_IS_BUZY);
        while (KYBER_POLYVEC_IS_BUZY);
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_BASEMUL_BASE_ADDR, KYBER_POLY_BYTES_HW);
        while (DMA_Is_Busy());
        basemul_start(3);
        #endif
        #endif
    }
    kem_pack_sk(sk, &skpv);
    for (i=0;i<KYBER_K;i++) {
        flush_cache_lines(pkpv.vec[i].coeffs, KYBER_POLY_BYTES_HW);
    }
    while (KYBER_POLYVEC_IS_BUZY);

    for (i=0;i<KYBER_K;i++) {
        DMA_Transfer_Blocking(
            KYBER_POLYVEC_BASE_ADDR + i * KYBER_POLY_BYTES_HW,
            (uint32_t)(uintptr_t)pkpv.vec[i].coeffs,
            KYBER_POLY_BYTES_HW, 0);
    }
    kem_pack_pk(pk, &pkpv, publicseed);

    memcpy(sk+KYBER_INDCPA_SECRETKEYBYTES, pk, KYBER_PUBLICKEYBYTES);
    flush_cache_lines(pk, KYBER_PUBLICKEYBYTES);
    flush_cache_lines(sk+KYBER_SECRETKEYBYTES-2*KYBER_SYMBYTES, KYBER_SYMBYTES);
    hash_h(sk+KYBER_SECRETKEYBYTES-2*KYBER_SYMBYTES, pk);
  /* Value z for pseudo-random output on reject */
    memcpy(sk+KYBER_SECRETKEYBYTES-KYBER_SYMBYTES, coins+KYBER_SYMBYTES, KYBER_SYMBYTES);
    return 0;
}

/*************************************************
* Name:        crypto_kem_enc_derand
*
* Description: Generates cipher text and shared
*              secret for given public key
*
* Arguments:   - uint8_t *ct: pointer to output cipher text
*                (an already allocated array of KYBER_CIPHERTEXTBYTES bytes)
*              - uint8_t *ss: pointer to output shared secret
*                (an already allocated array of KYBER_SSBYTES bytes)
*              - const uint8_t *pk: pointer to input public key
*                (an already allocated array of KYBER_PUBLICKEYBYTES bytes)
*              - const uint8_t *coins: pointer to input randomness
*                (an already allocated array filled with KYBER_SYMBYTES random bytes)
**
* Returns 0 (success)
**************************************************/
int crypto_kem_enc_derand(uint8_t *ct, uint8_t *ss, const uint8_t *pk, const uint8_t *coins)
{
    uint8_t buf[2*KYBER_SYMBYTES] __attribute__((aligned(4)));
    /* Will contain key, coins */
    uint8_t kr[2*KYBER_SYMBYTES] __attribute__((aligned(4)));

    memcpy(buf, coins, KYBER_SYMBYTES);

    /* Multitarget countermeasure for coins + contributory KEM */
    flush_cache_lines(buf, 64u);
    flush_cache_lines(pk, KYBER_PUBLICKEYBYTES);
    hash_h(buf+KYBER_SYMBYTES, pk);
    //print_byte_array_indcpa("m_Hek_soft", buf, 2 * KYBER_SYMBYTES);
    flush_cache_lines(kr, 64u);
    hash_g_64(kr, buf);
    //print_byte_array_indcpa("kr_soft", kr, 2*KYBER_SYMBYTES);

    /* coins are in kr+KYBER_SYMBYTES */
    unsigned int i;
    uint8_t seed[KYBER_SYMBYTES] __attribute__((aligned(4)));
    polyvec pkpv, u;
    poly v, k;

    kem_unpack_pk(&pkpv, seed, pk); // t_hat
    // print_polyvec_indcpa("t_hat_soft", &pkpv);
    // print_byte_array_indcpa("seed_soft", seed, KYBER_SYMBYTES);

    //u = AT * y + e1
    for (i=0;i<KYBER_K;i++) {
        //prepare y
        cbd_prepare(kr+KYBER_SYMBYTES, i);
        //sample y
        hash_iterate(HASH_MODE_PRF1);
        //prepare a0
        flush_cache_lines(seed, KYBER_SYMBYTES);
        rej_prepare(seed, i, 0);
        //y -> ntt
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_NTT_INTT_BASE_ADDR, KYBER_POLY_BYTES_HW);
        //sample a0
        hash_iterate(HASH_MODE_REJECTION);
        //ntt y
        while (DMA_Is_Busy());
        ntt_start();
        //prepare a1
        rej_prepare(seed, i, 1);
        //a0 -> basemul
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_BASEMUL_BASE_ADDR, KYBER_POLY_BYTES_HW);
        //sample a1
        hash_iterate(HASH_MODE_REJECTION);
        //basemul a0*s
        while (DMA_Is_Busy());
        basemul_start(0);
        #if KYBER_K != 2
        //prepare a2
        rej_prepare(seed, i, 2);
        #else
        while (KYBER_HASH_IS_BUZY);
        #endif
        //a1 -> basemul
        while (KYBER_POLYVEC_IS_BUZY);
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_BASEMUL_BASE_ADDR, KYBER_POLY_BYTES_HW);
        #if KYBER_K != 2
        //sample a2
        hash_iterate(HASH_MODE_REJECTION);
        #endif
        //basemul a1*s
        while (DMA_Is_Busy());
        basemul_start(1);

        #if KYBER_K != 2
        //prepare a3
        #if KYBER_K != 3
        rej_prepare(seed, i, 3);
        #else
        while (KYBER_HASH_IS_BUZY);
        #endif
        //a2 -> basemul
        while (KYBER_POLYVEC_IS_BUZY);
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_BASEMUL_BASE_ADDR, KYBER_POLY_BYTES_HW);
        #if KYBER_K != 3
        //sample a3
        hash_iterate(HASH_MODE_REJECTION);
        #endif
        while (DMA_Is_Busy());
        basemul_start(2);

        #if KYBER_K != 3
        //a3 -> basemul
        while (KYBER_HASH_IS_BUZY);
        while (KYBER_POLYVEC_IS_BUZY);
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_BASEMUL_BASE_ADDR, KYBER_POLY_BYTES_HW);
        while (DMA_Is_Busy());
        basemul_start(3);
        #endif
        #endif
    }
    for (i=0;i<KYBER_K;i++) {
        //prepare e1
        cbd_prepare(kr+KYBER_SYMBYTES, i + KYBER_K);
        //polyvec -> intt
        while (KYBER_POLYVEC_IS_BUZY);
        DMA_Transfer_Async(KYBER_POLYVEC_BASE_ADDR + i * KYBER_POLY_BYTES_HW, 
                            KYBER_NTT_INTT_BASE_ADDR, KYBER_POLY_BYTES_HW);
        //sample e1
        hash_iterate(HASH_MODE_PRF2);
        //intt e1
        while (DMA_Is_Busy());
        intt_start();
        //fqadd sample
        while (KYBER_HASH_IS_BUZY);
        polyvec_fadd_from_sample(i);
        //fqadd intt
        while (KYBER_NTT_INTT_IS_BUZY);
        while (KYBER_POLYVEC_IS_BUZY);
        polyvec_fadd_from_ntt_intt(i, 0);
    }


    //v = tT * y + e2 + mu  and  read back u
    kem_poly_frommsg(&k, buf); // mu
    // print_poly_indcpa("mu_soft", &k);
    for (i=0;i<KYBER_K;i++) {
        //prepare y
        cbd_prepare(kr+KYBER_SYMBYTES, i);
        //sample y
        hash_iterate(HASH_MODE_PRF1);
        //tT -> basemul
        flush_cache_lines(pkpv.vec[i].coeffs, KYBER_POLY_BYTES_HW);
        while (KYBER_POLYVEC_IS_BUZY);
        DMA_Transfer_Async((uint32_t)(uintptr_t)pkpv.vec[i].coeffs, KYBER_BASEMUL_BASE_ADDR, KYBER_POLY_BYTES_HW);
        //y -> ntt
        while (DMA_Is_Busy());
        while (KYBER_HASH_IS_BUZY);
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_NTT_INTT_BASE_ADDR, KYBER_POLY_BYTES_HW);
        //readback u
        flush_cache_lines(u.vec[i].coeffs, KYBER_POLY_BYTES_HW);
        while (DMA_Is_Busy());
        DMA_Transfer_Async(KYBER_POLYVEC_BASE_ADDR + i * KYBER_POLY_BYTES_HW, 
                            (uint32_t)(uintptr_t)u.vec[i].coeffs, KYBER_POLY_BYTES_HW);
        //ntt y
        ntt_start();
        //basemul tT*y
        while (DMA_Is_Busy());
        while (KYBER_NTT_INTT_IS_BUZY);
        basemul_start(0);
    }
    //prepare e2
    cbd_prepare(kr+KYBER_SYMBYTES, KYBER_K + KYBER_K);
    //polyvec -> intt
    while (KYBER_POLYVEC_IS_BUZY);
    DMA_Transfer_Async(KYBER_POLYVEC_BASE_ADDR, KYBER_NTT_INTT_BASE_ADDR, KYBER_POLY_BYTES_HW);
    //sample e2
    hash_iterate(HASH_MODE_PRF2);
    //intt e2
    while (DMA_Is_Busy());
    intt_start();
    //mu -> polyvec
    flush_cache_lines(k.coeffs, KYBER_POLY_BYTES_HW);
    DMA_Transfer_Async((uint32_t)(uintptr_t)k.coeffs, KYBER_POLYVEC_BASE_ADDR, KYBER_POLY_BYTES_HW);
    //fqadd sample
    while (KYBER_HASH_IS_BUZY);
    while (DMA_Is_Busy());
    polyvec_fadd_from_sample(0);
    //fqadd intt
    while (KYBER_NTT_INTT_IS_BUZY);
    while (KYBER_POLYVEC_IS_BUZY);
    polyvec_fadd_from_ntt_intt(0, 0);

    //read back v
    flush_cache_lines(v.coeffs, KYBER_POLY_BYTES_HW);
    while (KYBER_POLYVEC_IS_BUZY);
    DMA_Transfer_Blocking(KYBER_POLYVEC_BASE_ADDR, (uint32_t)(uintptr_t)v.coeffs, KYBER_POLY_BYTES_HW, 0);

    kem_pack_ciphertext(ct, &u, &v);
    memcpy(ss,kr,KYBER_SYMBYTES);
    return 0;
}

/*************************************************
* Name:        crypto_kem_dec
*
* Description: Generates shared secret for given
*              cipher text and private key
*
* Arguments:   - uint8_t *ss: pointer to output shared secret
*                (an already allocated array of KYBER_SSBYTES bytes)
*              - const uint8_t *ct: pointer to input cipher text
*                (an already allocated array of KYBER_CIPHERTEXTBYTES bytes)
*              - const uint8_t *sk: pointer to input private key
*                (an already allocated array of KYBER_SECRETKEYBYTES bytes)
*
* Returns 0.
*
* On failure, ss will contain a pseudo-random value.
**************************************************/
int crypto_kem_dec(uint8_t *ss, const uint8_t *ct, const uint8_t *sk)
{
    int fail;
    uint8_t buf[2*KYBER_SYMBYTES] __attribute__((aligned(4)));
    /* Will contain key, coins */
    uint8_t kr[2*KYBER_SYMBYTES] __attribute__((aligned(4)));
    uint8_t cmp[KYBER_CIPHERTEXTBYTES] __attribute__((aligned(4)));
    const uint8_t *pk = sk+KYBER_INDCPA_SECRETKEYBYTES;
    unsigned int i;
    polyvec up, skpv;
    poly vp, w;

    kem_unpack_ciphertext(&up, &vp, ct);
    // print_polyvec_indcpa("u", &u);
    // print_poly_indcpa("v", &v);
    kem_unpack_sk(&skpv, sk);
    // print_polyvec_indcpa("skpv", &skpv);

    //w = v - s * u
    for (i=0;i<KYBER_K;i++) {
        //u -> ntt
        flush_cache_lines(up.vec[i].coeffs, KYBER_POLY_BYTES_HW);
        DMA_Transfer_Async((uint32_t)(uintptr_t)up.vec[i].coeffs, KYBER_NTT_INTT_BASE_ADDR, KYBER_POLY_BYTES_HW);
        //ntt u
        while (KYBER_POLYVEC_IS_BUZY);
        while (DMA_Is_Busy());
        ntt_start();
        //s -> basemul
        flush_cache_lines(skpv.vec[i].coeffs, KYBER_POLY_BYTES_HW);
        DMA_Transfer_Async((uint32_t)(uintptr_t)skpv.vec[i].coeffs, KYBER_BASEMUL_BASE_ADDR, KYBER_POLY_BYTES_HW);
        //basemul s*u
        while (KYBER_NTT_INTT_IS_BUZY);
        while (DMA_Is_Busy());
        basemul_start(0);
    }
    //s * u -> intt
    while (KYBER_POLYVEC_IS_BUZY);
    DMA_Transfer_Async(KYBER_POLYVEC_BASE_ADDR, KYBER_NTT_INTT_BASE_ADDR, KYBER_POLY_BYTES_HW);
    //intt s*u
    while (DMA_Is_Busy());
    intt_start();
    //v -> polyvec
    flush_cache_lines(vp.coeffs, KYBER_POLY_BYTES_HW);
    DMA_Transfer_Async((uint32_t)(uintptr_t)vp.coeffs, KYBER_POLYVEC_BASE_ADDR, KYBER_POLY_BYTES_HW);
    //sub v - s*u
    while (DMA_Is_Busy());
    while (KYBER_NTT_INTT_IS_BUZY);
    polyvec_fadd_from_ntt_intt(0, 1);

    //read back w
    flush_cache_lines(w.coeffs, KYBER_POLY_BYTES_HW);
    while (KYBER_POLYVEC_IS_BUZY);
    DMA_Transfer_Blocking(KYBER_POLYVEC_BASE_ADDR, (uint32_t)(uintptr_t)w.coeffs, KYBER_POLY_BYTES_HW, 0);
    flush_cache_lines(kr, 64u);
    kem_poly_tomsg(buf, &w);
    // print_byte_array_indcpa("mprime", buf, KYBER_SYMBYTES);

    /* Multitarget countermeasure for coins + contributory KEM */
    memcpy(buf+KYBER_SYMBYTES, sk+KYBER_SECRETKEYBYTES-2*KYBER_SYMBYTES, KYBER_SYMBYTES);
    flush_cache_lines(buf, 64u);
    hash_g_64(kr, buf);
    // print_byte_array_indcpa("kr", kr, 2*KYBER_SYMBYTES);

    /* coins are in kr+KYBER_SYMBYTES */
    //indcpa_enc(cmp, buf, pk, kr+KYBER_SYMBYTES);
    uint8_t seed[KYBER_SYMBYTES] __attribute__((aligned(4)));
    polyvec pkpv, u;
    poly v, k;

    kem_unpack_pk(&pkpv, seed, pk); // t_hat
    // print_polyvec_indcpa("t_hat_soft", &pkpv);
    // print_byte_array_indcpa("seed_soft", seed, KYBER_SYMBYTES);

    //u = AT * y + e1
    for (i=0;i<KYBER_K;i++) {
        //prepare y
        cbd_prepare(kr+KYBER_SYMBYTES, i);
        //sample y
        hash_iterate(HASH_MODE_PRF1);
        //prepare a0
        flush_cache_lines(seed, KYBER_SYMBYTES);
        rej_prepare(seed, i, 0);
        //y -> ntt
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_NTT_INTT_BASE_ADDR, KYBER_POLY_BYTES_HW);
        //sample a0
        hash_iterate(HASH_MODE_REJECTION);
        //ntt y
        while (DMA_Is_Busy());
        ntt_start();
        //prepare a1
        rej_prepare(seed, i, 1);
        //a0 -> basemul
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_BASEMUL_BASE_ADDR, KYBER_POLY_BYTES_HW);
        //sample a1
        hash_iterate(HASH_MODE_REJECTION);
        //basemul a0*s
        while (DMA_Is_Busy());
        basemul_start(0);
        #if KYBER_K != 2
        //prepare a2
        rej_prepare(seed, i, 2);
        #else
        while (KYBER_HASH_IS_BUZY);
        #endif
        //a1 -> basemul
        while (KYBER_POLYVEC_IS_BUZY);
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_BASEMUL_BASE_ADDR, KYBER_POLY_BYTES_HW);
        #if KYBER_K != 2
        //sample a2
        hash_iterate(HASH_MODE_REJECTION);
        #endif
        //basemul a1*s
        while (DMA_Is_Busy());
        basemul_start(1);

        #if KYBER_K != 2
        //prepare a3
        #if KYBER_K != 3
        rej_prepare(seed, i, 3);
        #else
        while (KYBER_HASH_IS_BUZY);
        #endif
        //a2 -> basemul
        while (KYBER_POLYVEC_IS_BUZY);
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_BASEMUL_BASE_ADDR, KYBER_POLY_BYTES_HW);
        #if KYBER_K != 3
        //sample a3
        hash_iterate(HASH_MODE_REJECTION);
        #endif
        while (DMA_Is_Busy());
        basemul_start(2);

        #if KYBER_K != 3
        //a3 -> basemul
        while (KYBER_HASH_IS_BUZY);
        while (KYBER_POLYVEC_IS_BUZY);
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_BASEMUL_BASE_ADDR, KYBER_POLY_BYTES_HW);
        while (DMA_Is_Busy());
        basemul_start(3);
        #endif
        #endif
    }
    for (i=0;i<KYBER_K;i++) {
        //prepare e1
        cbd_prepare(kr+KYBER_SYMBYTES, i + KYBER_K);
        //polyvec -> intt
        while (KYBER_POLYVEC_IS_BUZY);
        DMA_Transfer_Async(KYBER_POLYVEC_BASE_ADDR + i * KYBER_POLY_BYTES_HW, 
                            KYBER_NTT_INTT_BASE_ADDR, KYBER_POLY_BYTES_HW);
        //sample e1
        hash_iterate(HASH_MODE_PRF2);
        //intt e1
        while (DMA_Is_Busy());
        intt_start();
        //fqadd sample
        while (KYBER_HASH_IS_BUZY);
        polyvec_fadd_from_sample(i);
        //fqadd intt
        while (KYBER_NTT_INTT_IS_BUZY);
        while (KYBER_POLYVEC_IS_BUZY);
        polyvec_fadd_from_ntt_intt(i, 0);
    }


    //v = tT * y + e2 + mu  and  read back u
    kem_poly_frommsg(&k, buf); // mu
    // print_poly_indcpa("mu_soft", &k);
    for (i=0;i<KYBER_K;i++) {
        //prepare y
        cbd_prepare(kr+KYBER_SYMBYTES, i);
        //sample y
        hash_iterate(HASH_MODE_PRF1);
        //tT -> basemul
        flush_cache_lines(pkpv.vec[i].coeffs, KYBER_POLY_BYTES_HW);
        while (KYBER_POLYVEC_IS_BUZY);
        DMA_Transfer_Async((uint32_t)(uintptr_t)pkpv.vec[i].coeffs, KYBER_BASEMUL_BASE_ADDR, KYBER_POLY_BYTES_HW);
        //y -> ntt
        while (DMA_Is_Busy());
        while (KYBER_HASH_IS_BUZY);
        DMA_Transfer_Async(KYBER_HASH_DATA_BASE_ADDR, KYBER_NTT_INTT_BASE_ADDR, KYBER_POLY_BYTES_HW);
        //readback u
        flush_cache_lines(u.vec[i].coeffs, KYBER_POLY_BYTES_HW);
        while (DMA_Is_Busy());
        DMA_Transfer_Async(KYBER_POLYVEC_BASE_ADDR + i * KYBER_POLY_BYTES_HW, 
                            (uint32_t)(uintptr_t)u.vec[i].coeffs, KYBER_POLY_BYTES_HW);
        //ntt y
        ntt_start();
        //basemul tT*y
        while (DMA_Is_Busy());
        while (KYBER_NTT_INTT_IS_BUZY);
        basemul_start(0);
    }
    //prepare e2
    cbd_prepare(kr+KYBER_SYMBYTES, KYBER_K + KYBER_K);
    //polyvec -> intt
    while (KYBER_POLYVEC_IS_BUZY);
    DMA_Transfer_Async(KYBER_POLYVEC_BASE_ADDR, KYBER_NTT_INTT_BASE_ADDR, KYBER_POLY_BYTES_HW);
    //sample e2
    hash_iterate(HASH_MODE_PRF2);
    //intt e2
    while (DMA_Is_Busy());
    intt_start();
    //mu -> polyvec
    flush_cache_lines(k.coeffs, KYBER_POLY_BYTES_HW);
    DMA_Transfer_Async((uint32_t)(uintptr_t)k.coeffs, KYBER_POLYVEC_BASE_ADDR, KYBER_POLY_BYTES_HW);
    //fqadd sample
    while (KYBER_HASH_IS_BUZY);
    while (DMA_Is_Busy());
    polyvec_fadd_from_sample(0);
    //fqadd intt
    while (KYBER_NTT_INTT_IS_BUZY);
    while (KYBER_POLYVEC_IS_BUZY);
    polyvec_fadd_from_ntt_intt(0, 0);

    //read back v
    flush_cache_lines(v.coeffs, KYBER_POLY_BYTES_HW);
    while (KYBER_POLYVEC_IS_BUZY);
    DMA_Transfer_Blocking(KYBER_POLYVEC_BASE_ADDR, (uint32_t)(uintptr_t)v.coeffs, KYBER_POLY_BYTES_HW, 0);

    kem_pack_ciphertext(cmp, &u, &v);
    // print_byte_array_indcpa("m", buf, KYBER_SYMBYTES);
    // print_byte_array_indcpa("ek", pk, KYBER_PUBLICKEYBYTES);
    // print_byte_array_indcpa("r", kr+KYBER_SYMBYTES, KYBER_SYMBYTES);
    fail = kem_verify(ct, cmp, KYBER_CIPHERTEXTBYTES);
    //printf("fail:%d\n", fail);

    /* Compute rejection key */
    flush_cache_lines(ct, KYBER_CIPHERTEXTBYTES);
    flush_cache_lines(sk+KYBER_SECRETKEYBYTES-KYBER_SYMBYTES, KYBER_SYMBYTES);
    flush_cache_lines(ss, KYBER_SYMBYTES);
    rkprf(ss,sk+KYBER_SECRETKEYBYTES-KYBER_SYMBYTES,ct);

    /* Copy true key to return buffer if fail is false */
    kem_cmov(ss,kr,KYBER_SYMBYTES,!fail);

    return 0;
}
