#include <stdio.h>

#include "NTT_INTT_hw.h"
#include "NTT_INTT_sw.h"
#include "confreg_time.h"

unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#define CONFREG_TIMER_CMP_OFFSET 0x4
#define CONFREG_TIMER_EN_OFFSET  0x8

static S16 g_input[KYBER_N] __attribute__((aligned(64)));
static S16 g_sw_ntt[KYBER_N] __attribute__((aligned(64)));
static S16 g_hw_ntt[KYBER_N] __attribute__((aligned(64)));
static S16 g_sw_intt[KYBER_N] __attribute__((aligned(64)));
static S16 g_hw_intt[KYBER_N] __attribute__((aligned(64)));

static void copy_poly(S16 *dst, const S16 *src)
{
    U32 i;

    for (i = 0; i < KYBER_N; ++i) {
        dst[i] = src[i];
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

    hw_ntt_cycles = run_hw_ntt(g_input, g_hw_ntt);
    print_poly("Hardware NTT:", g_hw_ntt);
    print_perf("Hardware NTT", hw_ntt_cycles);
    errors += compare_poly("NTT compare", g_hw_ntt, g_sw_ntt);

    copy_poly(g_sw_intt, g_sw_ntt);
    start_cycles = get_confreg_clock_count();
    invntt_ref(g_sw_intt);
    sw_intt_cycles = get_confreg_clock_count() - start_cycles;
    print_poly("Software INTT:", g_sw_intt);
    print_perf("Software INTT", sw_intt_cycles);

    hw_intt_cycles = run_hw_intt(g_sw_ntt, g_hw_intt);
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
