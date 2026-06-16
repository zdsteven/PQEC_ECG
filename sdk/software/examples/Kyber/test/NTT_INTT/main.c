#include <stdio.h>

#include "Kyber.h"
#include "confreg_time.h"

unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#define KYBER_N        256
#define KYBER_Q        3329
#define KYBER_Q_HALF   1664
#define QINV          (-3327)
#define INVNTT_F       512   /* MONT / 128 mod q */

#define CONFREG_TIMER_CMP_OFFSET 0x4
#define CONFREG_TIMER_EN_OFFSET  0x8

static const S16 zetas[128] = {
    -1044,  -758,  -359, -1517,  1493,  1422,   287,   202,
    -171 ,   622,  1577,   182,   962, -1202, -1474,  1468,
    573  , -1325,   264,   383,  -829,  1458, -1602,  -130,
    -681 ,  1017,   732,   608, -1542,   411,  -205, -1571,
    1223 ,   652,  -552,  1015, -1293,  1491,  -282, -1544,
    516  ,    -8,  -320,  -666, -1618, -1162,   126,  1469,
    -853 ,   -90,  -271,   830,   107, -1421,  -247,  -951,
    -398 ,   961, -1508,  -725,   448, -1065,   677, -1275,
    -1103,   430,   555,   843, -1251,   871,  1550,   105,
    422  ,   587,   177,  -235,  -291,  -460,  1574,  1653,
    -246 ,   778,  1159,  -147,  -777,  1483,  -602,  1119,
    -1590,   644,  -872,   349,   418,   329,  -156,   -75,
    817  ,  1097,   603,   610,  1322, -1285, -1465,   384,
    -1215,  -136,  1218, -1335,  -874,   220, -1187, -1659,
    -1185, -1530, -1278,   794, -1510,  -854,  -870,   478,
    -108 ,  -308,   996,   991,   958, -1460,  1522,  1628
};

static S16 g_input[KYBER_N] __attribute__((aligned(64)));
static S16 g_sw_ntt[KYBER_N] __attribute__((aligned(64)));
static S16 g_hw_ntt[KYBER_N] __attribute__((aligned(64)));
static S16 g_sw_intt[KYBER_N] __attribute__((aligned(64)));
static S16 g_hw_intt[KYBER_N] __attribute__((aligned(64)));

//#define KYBER_TO_UNCACHED_PTR(ptr) ((S16 *)KYBER_TO_UNCACHED_ADDR((uint32_t)(ptr)))

//#define g_input    KYBER_TO_UNCACHED_PTR(g_input_mem)
//#define g_sw_ntt   KYBER_TO_UNCACHED_PTR(g_sw_ntt_mem)
//#define g_hw_ntt   KYBER_TO_UNCACHED_PTR(g_hw_ntt_mem)
//#define g_sw_intt  KYBER_TO_UNCACHED_PTR(g_sw_intt_mem)
//#define g_hw_intt  KYBER_TO_UNCACHED_PTR(g_hw_intt_mem)

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
    return montgomery_reduce((S32)a*b);
}

static void copy_poly(S16 *dst, const S16 *src)
{
    U32 i;

    for (i = 0; i < KYBER_N; ++i) {
        dst[i] = src[i];
    }
}

static void ntt_ref(S16 r[KYBER_N])
{
    U32 len;
    U32 start;
    U32 j;
    U32 k;
    S16 t;
    S16 zeta;

    k = 1;
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

static void invntt_ref(S16 r[KYBER_N])
{
    U32 start;
    U32 len;
    U32 j;
    S32 k;
    S16 t;
    S16 zeta;

    k = 127;
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

static void generate_test_input(S16 r[KYBER_N])
{
    U32 i;

    for (i = 0; i < KYBER_N; ++i) {
        S32 value = ((S32)(i * 97u + i * i * 13u + 211u) % KYBER_Q) - KYBER_Q_HALF;
        r[i] = (S16)value;
    }
}

static void print_poly(const char *title, const S16 *r)
{
    U32 i;

    printf("%s\n", title);
    for (i = 0; i < KYBER_N; ++i) {
        printf("%6d", (int)r[i]);
        if ((i & 7u) == 7u) {
            printf("\n");
        }
    }
    if ((KYBER_N & 7u) != 0u) {
        printf("\n");
    }
}

static U32 compare_poly(const char *title, const S16 *lhs, const S16 *rhs)
{
    U32 i;
    U32 mismatch_count = 0;

    for (i = 0; i < KYBER_N; ++i) {
        if (lhs[i] != rhs[i]) {
            if (mismatch_count < 8u) {
                printf("%s mismatch @%u: got=%d exp=%d\n",title,i,(int)lhs[i],(int)rhs[i]);
            }
            ++mismatch_count;
        }
    }

    if (mismatch_count == 0u) {
        printf("%s PASS\n", title);
    } else {
        printf("%s FAIL, mismatches=%u\n", title, mismatch_count);
    }

    return mismatch_count;
}

static unsigned long cycles_to_us(unsigned long cycles)
{
    return (unsigned long)(((U64)cycles * (U64)USEC_PER_SEC) / (U64)CONFREG_CLOCKS_PER_SEC);
}

static void print_perf(const char *title, unsigned long cycles)
{
    printf("%s: %lu cycles (confreg sys_clk), about %lu us\n",title,cycles,cycles_to_us(cycles));
}

static void init_confreg_timer(void)
{
    RegWrite((unsigned int)(CONFREG_TIMER_BASE + CONFREG_TIMER_CMP_OFFSET), 0xffffffffu);
    RegWrite((unsigned int)(CONFREG_TIMER_BASE + CONFREG_TIMER_EN_OFFSET), 1u);
}

static void run_hw_ntt(const S16 *input, S16 *output)
{
    Kyber_WritePoly(input);
    Kyber_StartNTT();
    while (!Kyber_IsDone()) {
    }
    Kyber_ReadPoly(output);
}

static void run_hw_intt(const S16 *input, S16 *output)
{
    Kyber_WritePoly(input);
    Kyber_StartINTT();
    while (!Kyber_IsDone()) {
    }
    Kyber_ReadPoly(output);
}

int main(int argc, char **argv)
{
    U32 errors = 0u;
    unsigned long start_cycles;
    unsigned long sw_ntt_cycles;
    unsigned long hw_ntt_cycles;
    unsigned long sw_intt_cycles;
    unsigned long hw_intt_cycles;

    (void)argc;
    (void)argv;

    printf("Kyber NTT/INTT test start\n");
    init_confreg_timer();

    generate_test_input(g_input);
    print_poly("Input data:", g_input);

    copy_poly(g_sw_ntt, g_input);
    start_cycles = get_confreg_clock_count();
    ntt_ref(g_sw_ntt);
    sw_ntt_cycles = get_confreg_clock_count() - start_cycles;
    print_poly("Software NTT:", g_sw_ntt);
    print_perf("Software NTT", sw_ntt_cycles);

    start_cycles = get_confreg_clock_count();
    run_hw_ntt(g_input, g_hw_ntt);
    hw_ntt_cycles = get_confreg_clock_count() - start_cycles;
    print_poly("Hardware NTT:", g_hw_ntt);
    print_perf("Hardware NTT", hw_ntt_cycles);
    errors += compare_poly("NTT compare", g_hw_ntt, g_sw_ntt);

    copy_poly(g_sw_intt, g_sw_ntt);
    start_cycles = get_confreg_clock_count();
    invntt_ref(g_sw_intt);
    sw_intt_cycles = get_confreg_clock_count() - start_cycles;
    print_poly("Software INTT:", g_sw_intt);
    print_perf("Software INTT", sw_intt_cycles);

    start_cycles = get_confreg_clock_count();
    run_hw_intt(g_sw_ntt, g_hw_intt);
    hw_intt_cycles = get_confreg_clock_count() - start_cycles;
    print_poly("Hardware INTT:", g_hw_intt);
    print_perf("Hardware INTT", hw_intt_cycles);
    errors += compare_poly("INTT compare", g_hw_intt, g_sw_intt);
    errors += compare_poly("Roundtrip compare", g_hw_intt, g_input);

    if (errors == 0u) {
        printf("All Kyber NTT/INTT checks PASS\n");
    } else {
        printf("Kyber NTT/INTT checks FAIL, errors=%u\n", errors);
    }

    while (1) {
    }

    return 0;
}
