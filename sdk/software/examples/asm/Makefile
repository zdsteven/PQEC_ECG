TARGET = user-sample

CFLAGS += -O3 -g
MATMUL_GROUP_NUM ?= 5000
CFLAGS += -DMATMUL_GROUP_NUM=$(MATMUL_GROUP_NUM)
EVAL_FAST_DMA_START ?= 1
CFLAGS += -DEVAL_FAST_DMA_START=$(EVAL_FAST_DMA_START)
EVAL_CPU_START_BANNER ?= 1
CFLAGS += -DEVAL_CPU_START_BANNER=$(EVAL_CPU_START_BANNER)

C_SRCS := $(wildcard ./*.c )

OBJDIR = obj
COMMON_DIR = ../../bsp
GCC_DIR=../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0
PICOLIBC_DIR=../../../toolchains/picolibc
include ../../bsp/common.mk
