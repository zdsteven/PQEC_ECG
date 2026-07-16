TARGET = user-sample

CFLAGS += -O3 -g
MATMUL_GROUP_NUM ?= 5000
CFLAGS += -DMATMUL_GROUP_NUM=$(MATMUL_GROUP_NUM)
EVAL_DEBUG_COUNTERS ?= 0
CFLAGS += -DEVAL_DEBUG_COUNTERS=$(EVAL_DEBUG_COUNTERS)
EVAL_FAST_DMA_START ?= 1
CFLAGS += -DEVAL_FAST_DMA_START=$(EVAL_FAST_DMA_START)

C_SRCS := $(wildcard ./*.c )

OBJDIR = obj
COMMON_DIR = ../../bsp
GCC_DIR=../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0
PICOLIBC_DIR=../../../toolchains/picolibc
include ../../bsp/common.mk
