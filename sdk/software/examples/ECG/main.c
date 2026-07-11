#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "confreg_time.h"
#include "ecg.h"

unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#define ECG_VALIDATION_COUNT 1000u
#define ECG_SAMPLE_BYTES     198u
#define ECG_DMA_BYTES        200u
#define ECG_CLASS_COUNT      5u
#define ECG_PROGRESS_STEP    100u
#define CONFREG_CYCLES_PER_US (CONFREG_CLOCKS_PER_SEC / 1000000ul)

#define CONFREG_TIMER_CMP_ADDR (CONFREG_TIMER_BASE + 0x4u)
#define CONFREG_TIMER_EN_ADDR  (CONFREG_TIMER_BASE + 0x8u)

__asm__(
    ".section .rodata\n"
    ".balign 64\n"
    ".global validation_ecg_data\n"
    "validation_ecg_data:\n"
    ".incbin \"validation_ecg_uint8_198.bin\"\n"
    ".global validation_ecg_data_end\n"
    "validation_ecg_data_end:\n"
    ".balign 4\n"
    ".global validation_labels\n"
    "validation_labels:\n"
    ".incbin \"validation_golden_labels.bin\"\n"
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
    uint32_t correct = 0u;
    uint32_t class_total[ECG_CLASS_COUNT] = {0u, 0u, 0u, 0u, 0u};
    uint32_t class_correct[ECG_CLASS_COUNT] = {0u, 0u, 0u, 0u, 0u};
    unsigned long total_cycles = 0ul;

    (void)argc;
    (void)argv;

    init_timer();

    printf("ecg validation start\n");
    printf("samples=%u\n", ECG_VALIDATION_COUNT);

    for (i = 0u; i < ECG_VALIDATION_COUNT; ++i) {
        unsigned long cycles;
        U8 label = validation_labels[i];
        U8 pred = run_inference(i, &cycles);

        total_cycles += cycles;

        if (label < ECG_CLASS_COUNT) {
            ++class_total[label];
            if (pred == label) {
                ++correct;
                ++class_correct[label];
            }
        }

        if (((i + 1u) % ECG_PROGRESS_STEP) == 0u) {
            printf("processed %u/%u, correct=%u\n", i + 1u, ECG_VALIDATION_COUNT, correct);
        }
    }

    printf("ecg validation done\n");
    printf("correct=%u total=%u accuracy=%u.%u%%\n",
            correct,
            ECG_VALIDATION_COUNT,
            correct / 10u,
            correct % 10u);
    printf("total inference cycles=%lu us=%lu avg_cycles=%lu avg_us=%lu\n",
            total_cycles,
            cycles_to_us(total_cycles),
            total_cycles / ECG_VALIDATION_COUNT,
            cycles_to_us(total_cycles / ECG_VALIDATION_COUNT));
    printf("class correct/total: N=%u/%u L=%u/%u R=%u/%u A=%u/%u V=%u/%u\n",
            class_correct[0], class_total[0],
            class_correct[1], class_total[1],
            class_correct[2], class_total[2],
            class_correct[3], class_total[3],
            class_correct[4], class_total[4]);

    while (1) {
    }

    return 0;
}
