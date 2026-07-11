#include <stdio.h>

#include "matmul.h"
#include "dma.h"
#include "led.h"

unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#define TEST_CASES       5u
#define WAIT_POLLS       10000000u

static U32 matrix_words[MATMUL_INPUT_WORDS] __attribute__((aligned(64)));
static U32 cpu_result[MATMUL_RESULT_WORDS] __attribute__((aligned(64)));
static U32 dma_result[MATMUL_RESULT_WORDS] __attribute__((aligned(64)));
static U32 reference_result[MATMUL_RESULT_WORDS] __attribute__((aligned(64)));

static U32 pattern(U32 seed, U32 index)
{
    U32 value = seed + index * 0x9e3779b9u;
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    return value;
}

static void prepare_case(U32 case_number)
{
    U32 *a = matrix_words;
    U32 *b = matrix_words + 16u;
    U32 i;

    for (i = 0u; i < 16u; ++i) {
        a[i] = 0u;
        b[i] = 0u;
    }

    switch (case_number) {
        case 0u: /* Identity multiplied by a visible sequence. */
            for (i = 0u; i < 16u; ++i) {
                a[i] = ((i >> 2) == (i & 3u)) ? 1u : 0u;
                b[i] = 0x100u + i;
            }
            break;
        case 1u: /* Zero matrix. */
            break;
        case 2u: /* Small values, easy to inspect manually. */
            for (i = 0u; i < 16u; ++i) {
                a[i] = i + 1u;
                b[i] = 31u - i;
            }
            break;
        case 3u: /* Full-width pseudo-random unsigned values. */
            for (i = 0u; i < 16u; ++i) {
                a[i] = pattern(0x12345678u, i);
                b[i] = pattern(0x89abcdefu, i);
            }
            break;
        default: /* Forces the upper two result bits to be non-zero. */
            for (i = 0u; i < 16u; ++i) {
                a[i] = 0xffffffffu;
                b[i] = 0xffffffffu;
            }
            break;
    }
}

static void calculate_reference(void)
{
    const U32 *a = matrix_words;
    const U32 *b = matrix_words + 16u;
    U32 row;
    U32 column;
    U32 k;

    for (row = 0u; row < 4u; ++row) {
        for (column = 0u; column < 4u; ++column) {
            U64 low = 0u;
            U32 high = 0u;
            U32 element = row * 4u + column;

            for (k = 0u; k < 4u; ++k) {
                U64 product = (U64)a[row * 4u + k] *
                              (U64)b[k * 4u + column];
                U64 previous = low;
                low += product;
                if (low < previous)
                    ++high;
            }
            reference_result[element * 3u] = (U32)low;
            reference_result[element * 3u + 1u] = (U32)(low >> 32);
            reference_result[element * 3u + 2u] = high & 3u;
        }
    }
}

static U32 compare_result(const char *path, U32 case_number,
                          const U32 *actual)
{
    U32 i;

    for (i = 0u; i < MATMUL_RESULT_WORDS; ++i) {
        if (actual[i] != reference_result[i]) {
            printf("[FAIL] case=%u path=%s word=%u expected=%08x actual=%08x\n",
                   case_number, path, i, reference_result[i], actual[i]);
            return 0u;
        }
    }
    printf("[PASS] case=%u path=%s\n", case_number, path);
    return 1u;
}

int main(int argc, char **argv)
{
    U32 case_number;
    U32 failures = 0u;
    int rc;

    (void)argc;
    (void)argv;

    printf("MATMUL_GENERIC_DEMO_BEGIN\n");
    printf("DMA_VERSION=%08x\n", RegRead(DMA_VERSION_ADDR));

    for (case_number = 0u; case_number < TEST_CASES; ++case_number) {
        prepare_case(case_number);
        calculate_reference();

        rc = MATMul_Compute_CPU(matrix_words, matrix_words + 16u,
                                cpu_result, WAIT_POLLS);
        if (rc != 0) {
            printf("[FAIL] case=%u path=CPU rc=%d status=%08x\n",
                   case_number, rc, RegRead(MATMUL_STATUS_ADDR));
            ++failures;
        } else if (!compare_result("CPU_STREAM", case_number, cpu_result)) {
            ++failures;
        }

        rc = MATMul_Compute_DMA(matrix_words, dma_result,
                                WAIT_POLLS, WAIT_POLLS);
        if (rc != 0) {
            printf("[FAIL] case=%u path=DMA rc=%d dma=%08x matmul=%08x\n",
                   case_number, rc, DMA_Get_Status(),
                   RegRead(MATMUL_STATUS_ADDR));
            ++failures;
        } else if (!compare_result("DMA_STREAM", case_number, dma_result)) {
            ++failures;
        }
    }

    if (failures == 0u) {
        setLedPin(0x00ffu);
        printf("MATMUL_GENERIC_DEMO_PASS\n");
    } else {
        setLedPin(0xff00u);
        printf("MATMUL_GENERIC_DEMO_FAIL failures=%u\n", failures);
    }

    while (1) {
    }
    return 0;
}
