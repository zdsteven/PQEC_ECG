#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "confreg_time.h"
#include "ecg.h"

unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#define ECG_VALIDATION_COUNT 10000u
#define ECG_BATCH_SIZE       1000u
#define ECG_BATCH_COUNT      (ECG_VALIDATION_COUNT / ECG_BATCH_SIZE)
#define ECG_SAMPLE_BYTES     198u
#define ECG_DMA_BYTES        200u
#define ECG_CLASS_COUNT      5u
#define CONFREG_CYCLES_PER_US (CONFREG_CLOCKS_PER_SEC / 1000000ul)

#define CONFREG_TIMER_CMP_ADDR (CONFREG_TIMER_BASE + 0x4u)
#define CONFREG_TIMER_EN_ADDR  (CONFREG_TIMER_BASE + 0x8u)

__asm__(
    ".section .validation_data,\"a\",@progbits\n"
    ".balign 64\n"
    ".global validation_ecg_data\n"
    "validation_ecg_data:\n"
    ".incbin \"validation_ecg_uint8_198_10000.bin\"\n"
    ".global validation_ecg_data_end\n"
    "validation_ecg_data_end:\n"
    ".balign 4\n"
    ".global validation_labels\n"
    "validation_labels:\n"
    ".incbin \"validation_golden_labels_10000.bin\"\n"
    ".previous\n"
);

extern const U8 validation_ecg_data[];
extern const U8 validation_ecg_data_end[];
extern const U8 validation_labels[];

static U8 ecg_dma_buffer[ECG_DMA_BYTES] __attribute__((aligned(64)));

static void load_sample(uint32_t index)
{
    const U8 *sample = validation_ecg_data + index * ECG_SAMPLE_BYTES;

    memcpy(ecg_dma_buffer, sample, ECG_SAMPLE_BYTES);
    memset(ecg_dma_buffer + ECG_SAMPLE_BYTES, 0, ECG_DMA_BYTES - ECG_SAMPLE_BYTES);
    ecg_load(ecg_dma_buffer);
}

static unsigned long cycles_to_us(unsigned long cycles)
{
    return cycles / CONFREG_CYCLES_PER_US;
}

static void init_timer(void)
{
    RegWrite(CONFREG_TIMER_EN_ADDR, 0u);
    RegWrite(CONFREG_TIMER_CMP_ADDR, 0xffffffffu);
    RegWrite(CONFREG_TIMER_EN_ADDR, 1u);
}

static U8 run_inference(uint32_t index, unsigned long *cycles)
{
    unsigned long start;
    unsigned long end;
    U8 pred;

    load_sample(index);

    start = get_confreg_clock_count();
    ecg_start();
    pred = ecg_read_result(0);
    end = get_confreg_clock_count();

    *cycles = end - start;
    return pred;
}

int main(int argc, char **argv)
{
    uint32_t i;
    uint32_t batch;
    uint32_t correct = 0u;
    uint32_t batch_correct = 0u;
    unsigned long total_cycles = 0ul;

    (void)argc;
    (void)argv;

    init_timer();

    printf("ecg validation start\n");

    for (i = 0u; i < ECG_VALIDATION_COUNT; ++i) {
        unsigned long cycles;
        U8 label = validation_labels[i];
        U8 pred = run_inference(i, &cycles);

        total_cycles += cycles;

        if (label < ECG_CLASS_COUNT) {
            if (pred == label) {
                ++correct;
                ++batch_correct;
            }
        }

        if (((i + 1u) % ECG_BATCH_SIZE) == 0u) {
            batch = (i + 1u) / ECG_BATCH_SIZE;
            printf("batch %u/%u: correct=%u/%u accuracy=%u.%u%%\n",
                    batch,
                    ECG_BATCH_COUNT,
                    batch_correct,
                    ECG_BATCH_SIZE,
                    batch_correct / 10u,
                    batch_correct % 10u);
            batch_correct = 0u;
        }
    }

    printf("ecg validation done\n");

    printf("avg_cycles=%lu avg_us=%lu\n",
            total_cycles / ECG_VALIDATION_COUNT,
            cycles_to_us(total_cycles / ECG_VALIDATION_COUNT));

    while (1) {
    }

    return 0;
}
