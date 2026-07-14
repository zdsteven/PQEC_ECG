#include "NTT_INTT_hw.h"

#include "confreg_time.h"
#include "dma.h"

static void flush_poly_cache_lines(const S16 coeffs[KYBER_N])
{
    unsigned long address;
    const unsigned long line_bytes = 1ul << cache_offset_width;
    const unsigned long base = (unsigned long)coeffs;
    const unsigned long first = base & ~(line_bytes - 1ul);
    const unsigned long last =
        (base + NTT_INTT_HW_POLY_BYTES + line_bytes - 1ul) &
        ~(line_bytes - 1ul);

    for (address = first; address < last; address += line_bytes) {
        flush_dcache_line(address);
    }
}

static S16 signed_to_modq(S16 value)
{
    return value < 0 ? (S16)(value + KYBER_Q) : value;
}

static S16 modq_to_signed(S16 value)
{
    value = (S16)((U16)value & 0x0fffu);
    return value > KYBER_Q_HALF ? (S16)(value - KYBER_Q) : value;
}

static U32 ntt_intt_is_buzy(void)
{
    return RegRead(NTT_INTT_HW_STATUS_ADDR) & 0x1u;
}

static unsigned long run_hw_transform(const S16 input[KYBER_N], S16 output[KYBER_N], U32 control)
{
    U32 i;
    unsigned long start_cycles;
    unsigned long hardware_cycles;

    for (i = 0; i < KYBER_N; ++i) {
        output[i] = signed_to_modq(input[i]);
    }

    flush_poly_cache_lines(output);
    DMA_Transfer_Blocking((U32)(unsigned long)output, NTT_INTT_HW_DATA_BASE_ADDR, NTT_INTT_HW_POLY_BYTES, 0);

    start_cycles = get_confreg_clock_count();
    RegWrite(NTT_INTT_HW_CTRL_ADDR, control);
    while (ntt_intt_is_buzy());
    hardware_cycles = get_confreg_clock_count() - start_cycles;

    DMA_Transfer_Blocking(NTT_INTT_HW_DATA_BASE_ADDR, (U32)(unsigned long)output, NTT_INTT_HW_POLY_BYTES, 0);
    for (i = 0; i < KYBER_N; ++i) {
        output[i] = modq_to_signed(output[i]);
    }

    return hardware_cycles;
}

unsigned long run_hw_ntt(const S16 input[KYBER_N], S16 output[KYBER_N])
{
    return run_hw_transform(input, output,
                            NTT_INTT_HW_CTRL_START |
                            NTT_INTT_HW_CTRL_MODE_NTT);
}

unsigned long run_hw_intt(const S16 input[KYBER_N], S16 output[KYBER_N])
{
    return run_hw_transform(input, output, NTT_INTT_HW_CTRL_START);
}
