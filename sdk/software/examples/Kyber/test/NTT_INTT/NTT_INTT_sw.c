#include "NTT_INTT_sw.h"

#define QINV      (-3327)
#define INVNTT_F  512

static const S16 zetas[128] = {
    -1044,  -758,  -359, -1517,  1493,  1422,   287,   202,
    -171,    622,  1577,   182,   962, -1202, -1474,  1468,
    573,   -1325,   264,   383,  -829,  1458, -1602,  -130,
    -681,   1017,   732,   608, -1542,   411,  -205, -1571,
    1223,    652,  -552,  1015, -1293,  1491,  -282, -1544,
    516,      -8,  -320,  -666, -1618, -1162,   126,  1469,
    -853,    -90,  -271,   830,   107, -1421,  -247,  -951,
    -398,    961, -1508,  -725,   448, -1065,   677, -1275,
    -1103,   430,   555,   843, -1251,   871,  1550,   105,
    422,     587,   177,  -235,  -291,  -460,  1574,  1653,
    -246,    778,  1159,  -147,  -777,  1483,  -602,  1119,
    -1590,   644,  -872,   349,   418,   329,  -156,   -75,
    817,    1097,   603,   610,  1322, -1285, -1465,   384,
    -1215,  -136,  1218, -1335,  -874,   220, -1187, -1659,
    -1185, -1530, -1278,   794, -1510,  -854,  -870,   478,
    -108,   -308,   996,   991,   958, -1460,  1522,  1628
};

static S16 montgomery_reduce(S32 a)
{
    S16 t;

    t = (S16)a * QINV;
    t = (S16)((a - (S32)t * KYBER_Q) >> 16);
    return t;
}

static S16 barrett_reduce(S16 a)
{
    S16 t;
    const S16 v = (S16)(((1 << 26) + KYBER_Q / 2) / KYBER_Q);

    t = (S16)(((S32)v * a + (1 << 25)) >> 26);
    t = (S16)(t * KYBER_Q);
    return (S16)(a - t);
}

static S16 fqmul(S16 a, S16 b)
{
    return montgomery_reduce((S32)a * b);
}

void ntt_ref(S16 r[KYBER_N])
{
    U32 len;
    U32 start;
    U32 j;
    U32 k = 1;
    S16 t;
    S16 zeta;

    for (len = 128; len >= 2; len >>= 1) {
        for (start = 0; start < KYBER_N; start = j + len) {
            zeta = zetas[k++];
            for (j = start; j < start + len; ++j) {
                t = fqmul(zeta, r[j + len]);
                r[j + len] = (S16)(r[j] - t);
                r[j] = (S16)(r[j] + t);
            }
        }
    }

    for (j = 0; j < KYBER_N; ++j) {
        r[j] = barrett_reduce(r[j]);
    }
}

void invntt_ref(S16 r[KYBER_N])
{
    U32 start;
    U32 len;
    U32 j;
    S32 k = 127;
    S16 t;
    S16 zeta;

    for (len = 2; len <= 128; len <<= 1) {
        for (start = 0; start < KYBER_N; start = j + len) {
            zeta = zetas[k--];
            for (j = start; j < start + len; ++j) {
                t = r[j];
                r[j] = barrett_reduce((S16)(t + r[j + len]));
                r[j + len] = (S16)(r[j + len] - t);
                r[j + len] = fqmul(zeta, r[j + len]);
            }
        }
    }

    for (j = 0; j < KYBER_N; ++j) {
        r[j] = fqmul(r[j], INVNTT_F);
        r[j] = barrett_reduce(r[j]);
    }
}
