#include "Kyber.h"
#include "dma.h"
static void Kyber_FlushPolyCacheLines(const S16 *coeffs)
{
    uint32_t i;
    uint32_t line_words;
    unsigned long base = (unsigned long)coeffs;

    line_words = 1u << (cache_offset_width - 2u);

    for (i = 0; i < KYBER_WORD_COUNT; i += line_words) {
        flush_dcache_line(base + ((unsigned long)i << 2));
    }
}
void Kyber_WriteWord(uint32_t index, S16 low, S16 high)
{
    uint32_t value;

    if (index >= KYBER_WORD_COUNT) {
        return;
    }

    value = (((uint32_t)((U16)high) & 0x0FFFu) << 16) | ((uint32_t)((U16)low) & 0x0FFFu);

    RegWrite(KYBER_DATA_BASE_ADDR + (index << 2), value);
}

void Kyber_ReadWord(uint32_t index, S16 *low, S16 *high)
{
    uint32_t value;

    if (index >= KYBER_WORD_COUNT) {
        return;
    }

    value = RegRead(KYBER_DATA_BASE_ADDR + (index << 2));
    *low = (S16)(value & 0xFFFFu);
    *high = (S16)(value >> 16);
}

void Kyber_WritePoly(const S16 *coeffs)
{
    //uint32_t i;
    //for (i = 0; i < KYBER_WORD_COUNT; ++i) {
    //    Kyber_WriteWord(i, coeffs[i << 1], coeffs[(i << 1) + 1u]);
    //}
    Kyber_FlushPolyCacheLines(coeffs);
    DMA_Transfer_Blocking((uint32_t)coeffs, KYBER_DATA_BASE_ADDR, KYBER_WORD_COUNT * 4u, 0);
}

void Kyber_ReadPoly(S16 *coeffs)
{
    //uint32_t i;
    //S16 low;
    //S16 high;
    //for (i = 0; i < KYBER_WORD_COUNT; ++i) {
    //    Kyber_ReadWord(i, &low, &high);
    //    coeffs[i << 1] = low;
    //    coeffs[(i << 1) + 1u] = high;
    //}
    DMA_Transfer_Blocking(KYBER_DATA_BASE_ADDR, (uint32_t)coeffs, KYBER_WORD_COUNT * 4u, 0);
}

void Kyber_ClearDone(void)
{
    RegWrite(KYBER_CTRL_ADDR, KYBER_CTRL_CLEARDONE);
}

void Kyber_StartNTT(void)
{
    RegWrite(KYBER_CTRL_ADDR, KYBER_CTRL_START | KYBER_CTRL_MODE_NTT);
}

void Kyber_StartINTT(void)
{
    RegWrite(KYBER_CTRL_ADDR, KYBER_CTRL_START);
}

uint32_t Kyber_ReadStatus(void)
{
    return RegRead(KYBER_STATUS_ADDR);
}

uint32_t Kyber_IsDone(void)
{
    return Kyber_ReadStatus() & 0x1u;
}

uint32_t Kyber_GetModeBit(void)
{
    return (Kyber_ReadStatus() >> 1) & 0x1u;
}
