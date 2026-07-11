#include <stdio.h>

#include "dma.h"
#include "led.h"

unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#define DMA_EXPECTED_VERSION  0x41584402u
#define DMA_POLL_LIMIT        10000000u
#define CACHE_LINE_BYTES      16u
#define LOCAL_WORDS           8192u

/* Uncached DMW aliases of otherwise unused ExtRAM regions. */
#define EXT_SRC_VADDR         0xbc600000u
#define EXT_DST_VADDR         0xbc620000u

static U32 src_buf[LOCAL_WORDS + 1024u] __attribute__((aligned(4096)));
static U32 dst_buf[LOCAL_WORDS + 1024u] __attribute__((aligned(4096)));

static U32 tests_passed;
static U32 tests_failed;

static U32 dma_bus_addr(const volatile U32 *ptr)
{
    return ((U32)ptr) & 0x1fffffffu;
}

static void cache_sync_range(volatile U32 *buf, U32 words)
{
    U32 begin = ((U32)buf) & ~(CACHE_LINE_BYTES - 1u);
    U32 end = ((U32)(buf + words) + CACHE_LINE_BYTES - 1u) &
              ~(CACHE_LINE_BYTES - 1u);
    U32 addr;

    /* ExtRAM test pointers use the uncached 0xbc______ DMW alias. */
    if (((U32)buf & 0xe0000000u) == 0xa0000000u)
        return;

    for (addr = begin; addr < end; addr += CACHE_LINE_BYTES)
        flush_dcache_line((unsigned long)addr);
}

static U32 pattern_word(U32 seed, U32 index)
{
    U32 x = seed ^ (index * 0x9e3779b9u);
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x;
}

static void prepare_buffers(volatile U32 *src, volatile U32 *dst,
                            U32 words, U32 seed)
{
    U32 i;

    for (i = 0u; i < words; ++i) {
        src[i] = pattern_word(seed, i);
        dst[i] = 0xa5a5a5a5u;
    }
    cache_sync_range(src, words);
    cache_sync_range(dst, words);
}

static U32 verify_buffers(volatile U32 *src, volatile U32 *dst,
                          U32 words, U32 seed, U32 *first_bad)
{
    U32 i;

    cache_sync_range(dst, words);
    for (i = 0u; i < words; ++i) {
        U32 expected = pattern_word(seed, i);
        if ((src[i] != expected) || (dst[i] != expected)) {
            *first_bad = i;
            return 0u;
        }
    }
    return 1u;
}

static void report(const char *name, U32 passed)
{
    if (passed) {
        ++tests_passed;
        printf("[PASS] %s\n", name);
    } else {
        ++tests_failed;
        printf("[FAIL] %s\n", name);
    }
}

static U32 wait_done(U32 limit, U32 *busy_seen)
{
    U32 status;

    *busy_seen = 0u;
    while (limit-- != 0u) {
        status = DMA_Get_Status();
        if ((status & DMA_STATUS_BUSY) != 0u)
            *busy_seen = 1u;
        if ((status & DMA_STATUS_DONE) != 0u)
            return status;
    }
    return DMA_Get_Status();
}

static U32 run_copy(const char *name, volatile U32 *src, volatile U32 *dst,
                    U32 words, U32 seed)
{
    U32 status;
    U32 busy_seen;
    U32 first_bad = 0u;
    U32 bytes = words << 2;
    U32 src_bus = dma_bus_addr(src);
    U32 dst_bus = dma_bus_addr(dst);
    const U32 guard_before = 0x13579bdfu;
    const U32 guard_after = 0x2468ace0u;
    int rc;

    prepare_buffers(src, dst, words, seed);
    dst[-1] = guard_before;
    dst[words] = guard_after;
    cache_sync_range(dst - 1, words + 2u);
    rc = DMA_Transfer_Async((U32)src, (U32)dst, bytes);
    if (rc != 0) {
        printf("       start rc=%d\n", rc);
        report(name, 0u);
        return 0u;
    }

    status = wait_done(DMA_POLL_LIMIT, &busy_seen);
    /* A one-word transfer may finish before the CPU's first status read, so
     * BUSY observability is tested separately with the long transfer. */
    if ((status & (DMA_STATUS_DONE | DMA_STATUS_ERROR | DMA_STATUS_BUSY)) !=
        DMA_STATUS_DONE) {
        printf("       status=%08x busy_seen=%u\n", status, busy_seen);
        report(name, 0u);
        return 0u;
    }

    if ((RegRead(DMA_CUR_SRC_ADDR) != src_bus + bytes) ||
        (RegRead(DMA_CUR_DST_ADDR) != dst_bus + bytes) ||
        (RegRead(DMA_REMAIN_ADDR) != 0u)) {
        printf("       progress src=%08x/%08x dst=%08x/%08x remain=%u\n",
               RegRead(DMA_CUR_SRC_ADDR), src_bus + bytes,
               RegRead(DMA_CUR_DST_ADDR), dst_bus + bytes,
               RegRead(DMA_REMAIN_ADDR));
        report(name, 0u);
        return 0u;
    }

    if (!verify_buffers(src, dst, words, seed, &first_bad)) {
        printf("       mismatch[%u] expected=%08x src=%08x dst=%08x\n",
               first_bad, pattern_word(seed, first_bad),
               src[first_bad], dst[first_bad]);
        report(name, 0u);
        return 0u;
    }

    cache_sync_range(dst - 1, words + 2u);
    if ((dst[-1] != guard_before) || (dst[words] != guard_after)) {
        printf("       guard before=%08x after=%08x\n",
               dst[-1], dst[words]);
        report(name, 0u);
        return 0u;
    }

    report(name, 1u);
    return 1u;
}

static void test_identity_and_reset(void)
{
    U32 version = RegRead(DMA_VERSION_ADDR);
    U32 status = DMA_Get_Status();

    if (version != DMA_EXPECTED_VERSION)
        printf("       version=%08x expected=%08x\n",
               version, DMA_EXPECTED_VERSION);
    report("DMA version/register decode", version == DMA_EXPECTED_VERSION);

    if (status != 0u)
        printf("       reset status=%08x\n", status);
    report("reset status idle", status == 0u);
}

static void test_register_readback(void)
{
    U32 src = dma_bus_addr(src_buf + 3u);
    U32 dst = dma_bus_addr(dst_buf + 7u);
    U32 len = 68u;

    DMA_Set_Source((U32)(src_buf + 3u));
    DMA_Set_Destination((U32)(dst_buf + 7u));
    DMA_Set_Length(len);
    report("configuration register readback",
           (RegRead(DMA_SRC_ADDR) == src) &&
           (RegRead(DMA_DST_ADDR) == dst) &&
           (RegRead(DMA_LEN_ADDR) == len));
}

static void test_driver_rejection(void)
{
    U32 src = (U32)src_buf;
    U32 dst = (U32)dst_buf;
    U32 passed = 1u;

    passed &= (DMA_Transfer_Async(src, dst, 0u) == -1);
    passed &= (DMA_Transfer_Async(src + 1u, dst, 4u) == -1);
    passed &= (DMA_Transfer_Async(src, dst + 2u, 4u) == -1);
    passed &= (DMA_Transfer_Async(src, dst, 6u) == -1);
    report("driver rejects zero/unaligned requests", passed);
}

static void test_hardware_rejection(void)
{
    U32 status;
    U32 busy_seen;

    DMA_Clear_Done();
    RegWrite(DMA_SRC_ADDR, dma_bus_addr(src_buf));
    RegWrite(DMA_DST_ADDR, dma_bus_addr(dst_buf));
    RegWrite(DMA_LEN_ADDR, 0u);
    RegWrite(DMA_CTRL_ADDR, DMA_CTRL_START);
    status = wait_done(10000u, &busy_seen);
    report("hardware rejects zero length",
           ((status & (DMA_STATUS_DONE | DMA_STATUS_ERROR)) ==
            (DMA_STATUS_DONE | DMA_STATUS_ERROR)) && !busy_seen);

    DMA_Clear_Done();
    report("clear done/error",
           (DMA_Get_Status() & (DMA_STATUS_DONE | DMA_STATUS_ERROR)) == 0u);

    RegWrite(DMA_SRC_ADDR, dma_bus_addr(src_buf) + 2u);
    RegWrite(DMA_DST_ADDR, dma_bus_addr(dst_buf));
    RegWrite(DMA_LEN_ADDR, 4u);
    RegWrite(DMA_CTRL_ADDR, DMA_CTRL_START);
    status = wait_done(10000u, &busy_seen);
    report("hardware rejects unaligned address",
           ((status & (DMA_STATUS_DONE | DMA_STATUS_ERROR)) ==
            (DMA_STATUS_DONE | DMA_STATUS_ERROR)) && !busy_seen);
    DMA_Clear_Done();
}

static void test_busy_write_protection(void)
{
    volatile U32 *src = (volatile U32 *)EXT_SRC_VADDR;
    volatile U32 *dst = (volatile U32 *)EXT_DST_VADDR;
    U32 bytes = LOCAL_WORDS << 2;
    U32 src_bus = dma_bus_addr(src);
    U32 dst_bus = dma_bus_addr(dst);
    U32 status;
    U32 busy_seen = 0u;
    U32 protection_checked = 0u;
    U32 progress_seen = 0u;
    U32 first_bad = 0u;
    U32 limit = DMA_POLL_LIMIT;

    prepare_buffers(src, dst, LOCAL_WORDS, 0x81000001u);
    if (DMA_Transfer_Async((U32)src, (U32)dst, bytes) != 0) {
        report("busy/progress/write protection", 0u);
        return;
    }

    while (limit-- != 0u) {
        status = DMA_Get_Status();
        if ((status & DMA_STATUS_BUSY) != 0u) {
            busy_seen = 1u;
            if ((RegRead(DMA_CUR_SRC_ADDR) != src_bus) ||
                (RegRead(DMA_REMAIN_ADDR) != bytes))
                progress_seen = 1u;

            if (!protection_checked) {
                RegWrite(DMA_SRC_ADDR, 0x1c400000u);
                RegWrite(DMA_DST_ADDR, 0x1c401000u);
                RegWrite(DMA_LEN_ADDR, 4u);
                protection_checked =
                    (RegRead(DMA_SRC_ADDR) == src_bus) &&
                    (RegRead(DMA_DST_ADDR) == dst_bus) &&
                    (RegRead(DMA_LEN_ADDR) == bytes);
            }
        }
        if ((status & DMA_STATUS_DONE) != 0u)
            break;
    }

    status = DMA_Get_Status();
    if (!verify_buffers(src, dst, LOCAL_WORDS, 0x81000001u, &first_bad)) {
        printf("       long mismatch[%u]=%08x/%08x\n",
               first_bad, src[first_bad], dst[first_bad]);
        protection_checked = 0u;
    }
    if (!progress_seen)
        printf("       progress window was not observed\n");
    report("busy/progress/write protection",
           busy_seen && progress_seen && protection_checked &&
           ((status & (DMA_STATUS_DONE | DMA_STATUS_ERROR | DMA_STATUS_BUSY)) ==
           DMA_STATUS_DONE));
}

static void test_blocking_api(void)
{
    volatile U32 *src = src_buf + 320u;
    volatile U32 *dst = dst_buf + 384u;
    U32 first_bad = 0u;
    U32 status;
    int rc;

    prepare_buffers(src, dst, 64u, 0x71000001u);
    rc = DMA_Transfer_Blocking((U32)src, (U32)dst, 64u * 4u,
                               DMA_POLL_LIMIT);
    status = DMA_Get_Status();
    report("blocking API",
           (rc == 0) &&
           ((status & (DMA_STATUS_DONE | DMA_STATUS_ERROR | DMA_STATUS_BUSY)) ==
            DMA_STATUS_DONE) &&
           verify_buffers(src, dst, 64u, 0x71000001u, &first_bad));
}

static void test_blocking_timeout(void)
{
    volatile U32 *src = (volatile U32 *)EXT_SRC_VADDR;
    volatile U32 *dst = (volatile U32 *)EXT_DST_VADDR;
    const U32 words = 2048u;
    U32 first_bad = 0u;
    U32 busy_seen;
    U32 status;
    int rc;

    prepare_buffers(src, dst, words, 0x72000001u);
    rc = DMA_Transfer_Blocking((U32)src, (U32)dst, words * 4u, 1u);
    status = wait_done(DMA_POLL_LIMIT, &busy_seen);
    report("blocking timeout and later completion",
           (rc == -2) && busy_seen &&
           ((status & (DMA_STATUS_DONE | DMA_STATUS_ERROR | DMA_STATUS_BUSY)) ==
            DMA_STATUS_DONE) &&
           verify_buffers(src, dst, words, 0x72000001u, &first_bad));
}

int main(int argc, char **argv)
{
    volatile U32 *ext_src = (volatile U32 *)EXT_SRC_VADDR;
    volatile U32 *ext_dst = (volatile U32 *)EXT_DST_VADDR;

    (void)argc;
    (void)argv;

    printf("DMA_DEMO_BEGIN\n");
    test_identity_and_reset();
    test_register_readback();
    test_driver_rejection();
    test_hardware_rejection();

    run_copy("single word", src_buf + 1u, dst_buf + 1u,
             1u, 0x10000001u);
    run_copy("15 words (partial bank)", src_buf + 5u, dst_buf + 9u,
             15u, 0x10000002u);
    run_copy("16 words (one bank)", src_buf + 8u, dst_buf + 12u,
             16u, 0x10000003u);
    run_copy("17 words (bank turnover)", src_buf + 11u, dst_buf + 19u,
             17u, 0x10000004u);
    run_copy("33 words (three banks)", src_buf + 17u, dst_buf + 23u,
             33u, 0x10000005u);

    /* Start one word before a 4 KiB boundary to force AR/AW clipping. */
    run_copy("source crosses 4KiB", src_buf + 1023u, dst_buf + 128u,
             40u, 0x20000001u);
    run_copy("destination crosses 4KiB", src_buf + 256u, dst_buf + 1023u,
             40u, 0x20000002u);
    run_copy("both sides cross 4KiB", src_buf + 1021u, dst_buf + 1019u,
             80u, 0x20000003u);

    run_copy("BaseRAM to ExtRAM", src_buf + 64u, ext_dst,
             257u, 0x30000001u);
    run_copy("ExtRAM to BaseRAM", ext_src, dst_buf + 64u,
             257u, 0x30000002u);
    run_copy("ExtRAM to ExtRAM", ext_src + 3u, ext_dst + 7u,
             513u, 0x30000003u);

    test_blocking_api();
    test_blocking_timeout();
    test_busy_write_protection();

    printf("DMA_DEMO_SUMMARY pass=%u fail=%u\n", tests_passed, tests_failed);
    if (tests_failed == 0u) {
        setLedPin(0x00ffu);
        printf("DMA_DEMO_PASS\n");
    } else {
        setLedPin(0xff00u);
        printf("DMA_DEMO_FAIL\n");
    }

    while (1) {
    }
    return 0;
}
